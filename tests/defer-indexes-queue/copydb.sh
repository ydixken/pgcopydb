#! /bin/bash

# Failures between the end of COPY and the last STOP message must end the run
# with an error instead of a hang, and the deferred phase must drain more
# messages than one SysV queue holds. A hang deadline of 60 seconds tells the
# two apart; when it fires the script shows the queues and ends the run.

set -euo pipefail

scenario=${1:-all} round=${2:-}
name=${scenario}${round:+ ${round}}

fail() { echo "FAIL [${name}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

# each round is a separate process with its own work directory
rounds() {
    local status=0
    if test -z "${round}"; then
        for round in "$@"; do
            bash "$0" "${scenario}" "${round}" || status=1
        done
        exit "${status}"
    fi
}

case "${scenario}" in
    all)
        pgcopydb ping
        echo "source: $(source_sql 'select version()')"
        echo "target: $(target_sql 'select version()')"
        status=0
        for scenario in nohang-index nohang-vacuum nohang-pool many; do
            bash "$0" "${scenario}" || status=1
        done
        echo "elapsed: ${SECONDS} s"
        exit "${status}"
        ;;
    nohang-index) rounds plain tid flag ;;
    nohang-vacuum) rounds plain flag ;;
    nohang-pool) rounds sender workers supervisor vacuum ;;
    many) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-defer-indexes-queue/${scenario}${round:+-${round}}
workdir=${TMPDIR}/work
catalog=${workdir}/schema/source.db
mkdir -p "${TMPDIR}"
clone_args=(--dir "${workdir}" --table-jobs 4 --index-jobs 2 --split-tables-larger-than 1MB
    --split-max-parts 4 --use-copy-binary --notice)
# a message carries sizeof(msg->data), 72 bytes (queue_utils.c), so n
# messages are more than one queue of msgmnb bytes holds
msgmnb=$(cat /proc/sys/kernel/msgmnb)
n=$((msgmnb / 72 + 50))
defer=() run_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name <> 'gate'"
vacuum_stmt='VACUUM ANALYZE public\.[a-z_0-9]*;'
terminated='Terminating all processes in our process group'
# a worker retitles itself after the object it works on
index_worker='^pgcopydb: create index'
vacuum_worker='^pgcopydb: (vacuum worker|VACUUM ANALYZE )'
sender='^pgcopydb: deferred queue indexes'

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${run_pid:-${pid:-}}" || kill -KILL -- "-${run_pid:-${pid:-}}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (errors)"
            grep -E ' (ERROR|FATAL) |unrecognized option' "${log}" | tail -n 20 || true
            echo "==> ${log} (tail)"
            tail -n 20 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

sqlite() { timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list "${catalog}" "$1"; }
# writes to the work directory's catalog, only while no pgcopydb runs
sqlite_write() { timeout 10s sqlite3 -init /dev/null -cmd '.timeout 5000' -batch "${catalog}" "$1"; }
gate_locks() { target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }
stmt_count() { grep -cE "$1" "$2" || true; }
# a SIGKILL leaks the run's queues, and a stale full one satisfies queue_full
drop_queues() { ipcrm --all=msg; }

poll() {
    local what=$1 deadline=$((SECONDS + 120)) rc=''
    shift
    until "$@"; do
        if test -n "${run_pid}" && ! kill -0 "${run_pid}" 2>/dev/null; then
            wait "${run_pid}" || rc=$?
            run_pid=
            fail "pgcopydb exited ${rc:-0} while waiting for ${what}"
        fi
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

gate_held() { test "$(gate_locks "granted and mode = 'ExclusiveLock'")" = 1; }
gate_open() { test "$(gate_locks 'true')" = 0; }
run_gone() { test "$(target_sql "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${run_pid}" | tr -d ' ')" = "${run_pid}"; }
procs() { pgrep -fc "$1" || true; }
no_sender() { test "$(procs "${sender}")" = 0; }
vacuum_workers_up() { test "$(procs "${vacuum_worker}")" = 4; }

# waits <progress view> <table>: a COPY or CREATE INDEX on table waits on the gate
waits() {
    test "$(target_sql "select count(*) from $1 p join pg_locks l on l.pid = p.pid
        where p.relid = to_regclass('public.$2')
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

# some queue has less than one message of free space
queue_full() {
    ipcs -q | awk -v max="${msgmnb}" '$5 ~ /^[0-9]+$/ && $5 > max - 72 { full = 1 } END { exit !full }'
}

copy_phase_ended() {
    test "$(sqlite "select count(*) from timings
        where label = 'COPY (cumulative)' and done_time_epoch is not null")" = 1
}

small_bare_vacuumed() {
    test "$(sqlite "select count(*) from vacuum_summary v join s_table t on t.oid = v.tableoid
        where t.relname in ('small', 'bare') and v.done_time_epoch is not null")" = 2
}

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
        -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
    gate_pid=$!
    poll 'the gate to close' gate_held
}

release_gate() {
    target_sql "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
    poll 'the gate to open' gate_open
}

# start_clone <log> <option>...: its own process group, so a kill reaches every child
start_clone() {
    local log=$1
    shift
    setsid pgcopydb clone "${clone_args[@]}" "$@" >"${TMPDIR}/${log}.log" 2>&1 &
    run_pid=$!
    # $! is known before the child has called setsid()
    poll 'pgcopydb to own its process group' own_group
}

# finish <log> <seconds> [check]: status is the run's exit code; a run alive
# at the deadline hangs, so show the queues, run check, end its process group
finish() {
    local deadline=$((SECONDS + $2))
    status=0
    while kill -0 "${run_pid}" 2>/dev/null; do
        if test "${SECONDS}" -ge "${deadline}"; then
            ipcs -q
            if test -n "${3:-}"; then
                "$3" || fail "the $1 hung, and no queue is full"
            fi
            kill -KILL -- "-${run_pid}"
            wait "${run_pid}" || true
            run_pid=
            fail "the $1 hung"
        fi
        sleep 0.2
    done
    wait "${run_pid}" || status=$?
    run_pid=
}

# a caller that retries with --resume waits for the dead run's target sessions
# to end; a backend that waits on the gate never reads its socket, so end it
kill_clone() {
    kill -KILL -- "-${run_pid}"
    wait "${run_pid}" || true
    run_pid=
    drop_queues
    target_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
    poll 'the killed run to leave the target' run_gone
}

# plant <trigger> <timing label>: the supervisor that starts this timing
# fails before it forks a worker
plant() {
    sqlite_write "create trigger $1 before insert on timings when new.label = '$2'
        begin select raise(abort, 'injected'); end;"
}

ended_with_error() {
    test "${status}" -ne 0 || fail "the $1 exited 0"
    grep -qF "${terminated}" "${TMPDIR}/$1.log" || fail "the $1 log has no '${terminated}'"
}

# a scenario that died midway leaves sessions, objects and queues behind; the
# gate functions live in public, so they go too
reset() {
    local sql="select count(pg_terminate_backend(pid)) from pg_stat_activity
        where backend_type = 'client backend' and pid <> pg_backend_pid()"
    drop_queues
    for run in source_sql target_sql; do
        "${run}" "${sql}" >/dev/null
        "${run}" 'set client_min_messages to warning; drop schema public cascade; create schema public'
    done
}

# gate_at() waits on the gate for one id, gate_key() for every row
seed() {
    reset
    source_sql "create function gate_at(integer, integer) returns boolean language plpgsql
            as \$\$ begin if \$1 = \$2 then perform pg_advisory_xact_lock_shared(42); end if; return true; end \$\$;
        create function gate_key(integer) returns integer language plpgsql immutable
            as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$;
        $1;
        analyze"
}

base_tables="create table big(id integer primary key, payload text not null);
    insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
    create table small(id integer primary key, val integer not null);
    insert into small select g, g % 100 from generate_series(1, 1000) g;
    create index small_val on small (val);
    create table bare(id integer not null, payload text);
    insert into bare select g, md5(g::text) from generate_series(1, 1000) g"
ix_tables="do \$\$ begin for i in 1..${n} loop
        execute format('create table ix_%s(id integer, val integer)', i);
        execute format('insert into ix_%s select g, g from generate_series(1, 10) g', i);
        execute format('create index ix_%s_val on ix_%s (val)', i, i);
    end loop; end \$\$"
nx_tables="do \$\$ begin for i in 1..${n} loop
        execute format('create table nx_%s(id integer)', i);
        execute format('insert into nx_%s select generate_series(1, 10)', i);
    end loop; end \$\$"

pgcopydb ping >"${TMPDIR}/ping.out" 2>&1 || { cat "${TMPDIR}/ping.out"; fail 'pgcopydb ping failed'; }
case "${scenario}:${round}" in
    *:flag|nohang-pool:*) defer=(--defer-indexes) ;;
esac

case "${scenario}" in
    nohang-index)
        # the index supervisor fails before its workers run: no VACUUM STOP
        seed "${base_tables}; create index big_gate on big (gate_key(id))"
        hold_gate
        start_clone attempt "${defer[@]}"
        poll 'the COPY phase to end' copy_phase_ended
        poll 'the CREATE INDEX of big_gate to wait on the gate' waits pg_stat_progress_create_index big
        poll 'the VACUUM of small and bare to be done' small_bare_vacuumed
        kill_clone
        if test "${round}" = tid; then
            # the supervisor forgets the elections first; a row trigger on an
            # empty table never fires, and small was elected before its VACUUM
            test "$(sqlite 'select count(*) from s_table_indexes_done')" -ge 1 ||
                fail 'the killed run left no s_table_indexes_done row'
            sqlite_write "create trigger fail_tid before delete on s_table_indexes_done
                begin select raise(abort, 'injected'); end;"
        else
            plant fail_index_start 'CREATE INDEX (cumulative)'
        fi
        release_gate
        start_clone resume "${defer[@]}" --resume --not-consistent
        finish resume 60
        ended_with_error resume
        echo "PASS [${name}]: an index supervisor that fails early ends the run"
        ;;

    nohang-vacuum)
        # the VACUUM supervisor fails before its workers run: the queue fills
        seed "create table held(id integer not null check (gate_at(id, 1000)));
            insert into held select generate_series(1, 1000);
            ${nx_tables}"
        hold_gate
        start_clone attempt "${defer[@]}"
        poll 'the COPY of held to wait on the gate' waits pg_stat_progress_copy held
        kill_clone
        plant fail_vacuum_start 'VACUUM (cumulative)'
        release_gate
        start_clone resume "${defer[@]}" --resume --not-consistent
        finish resume 60 queue_full
        ended_with_error resume
        echo "PASS [${name}]: a VACUUM supervisor that fails early ends the run"
        ;;

    nohang-pool)
        # g is the largest table, so the single index worker takes g_gate first
        clone_args+=(--index-jobs 1)
        if test "${round}" = supervisor; then
            seed "create table g(id integer); insert into g select generate_series(1, 20000);
                create index g_gate on g (gate_key(id));
                create table bare(id integer not null, payload text);
                insert into bare select g, md5(g::text) from generate_series(1, 1000) g"
        else
            seed "create table g(id integer); insert into g select generate_series(1, 20000);
                create index g_gate on g (gate_key(id));
                ${ix_tables}"
        fi
        hold_gate
        start_clone attempt "${defer[@]}"
        poll 'the CREATE INDEX of g_gate to wait on the gate' waits pg_stat_progress_create_index g
        if test "${round}" = supervisor; then
            poll 'the deferred sender to exit' no_sender
        else
            poll 'a queue to fill' queue_full
        fi
        case "${round}" in
            sender) pattern=${sender} ;;
            workers) pattern=${index_worker} ;;
            supervisor) pattern='^pgcopydb: index supervisor' ;;
            vacuum)
                pattern=${vacuum_worker}
                poll 'the 4 VACUUM workers' vacuum_workers_up
                ;;
        esac
        pkill -KILL -f "${pattern}" || fail "no process matches ${pattern}"
        echo "killed every process that matches ${pattern}"
        # a dead index worker's backend builds g_gate once the gate opens, and
        # the run may end before that commits: poll without the exit check
        pid=${run_pid} run_pid=
        release_gate
        run_pid=${pid}
        finish attempt 60
        ended_with_error attempt
        echo "PASS [${name}]: the run ends once a pool or the sender dies"
        ;;

    many)
        seed "${ix_tables}; ${nx_tables}"
        start_clone attempt --defer-indexes
        finish attempt 300
        equal "${status}" 0 'the clone exit status'
        equal "$(stmt_count ' CREATE INDEX ix_' "${TMPDIR}/attempt.log")" "${n}" 'index statements'
        equal "$(stmt_count "${vacuum_stmt}" "${TMPDIR}/attempt.log")" $((2 * n)) 'VACUUM statements'
        equal "$(sqlite 'select count(*), count(s.done_time_epoch) from s_index i
            left join summary s on s.indexoid = i.oid')" "${n}|${n}" 'indexes|indexes done'
        pgcopydb compare data --dir "${TMPDIR}/compare-data" >"${TMPDIR}/compare-data.log" 2>&1 ||
            fail 'compare data found differences'
        echo "PASS [${name}]: ${n} indexes and $((2 * n)) VACUUMs drain through the queues"
        ;;
esac
