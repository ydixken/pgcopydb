#! /bin/bash

# A clone --all-databases killed in its global COPY step is retried with
# --resume --not-consistent, which has to treat each database's catalog as a
# single-database resume treats its own. A CHECK constraint or an index
# expression holds the run on an advisory lock, which holds only the database
# the test takes it in.

set -euo pipefail

scenario=${1:-all}
mode=${2:-}
scenarios='elect mixed unrecorded unrecorded-nokey live live-key copy-pid-live index-pid-live trunc-fail constraint'
name=${scenario}

fail() { echo "FAIL [${name}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
# sql <source|target> <database> <statement>...
sql() {
    local uri=${PGCOPYDB_SOURCE_PGURI} db=$2 statement commands=()
    test "$1" = source || uri=${PGCOPYDB_TARGET_PGURI}
    shift 2
    for statement in "$@"; do
        commands+=(-c "${statement}")
    done
    timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${uri%/*}/${db}" "${commands[@]}"
}

case "${scenario}" in
    all)
        pgcopydb ping
        echo "source: $(sql source postgres 'select version()')"
        echo "target: $(sql target postgres 'select version()')"
        status=0
        for scenario in ${scenarios}; do
            bash "$0" "${scenario}" || status=1
        done
        echo "elapsed: ${SECONDS} s"
        exit "${status}"
        ;;
    constraint)
        # a resume loses the constraint election without --all-databases too
        if test -z "${mode}"; then
            status=0
            for mode in all-databases single; do
                bash "$0" constraint "${mode}" || status=1
            done
            exit "${status}"
        fi
        name="${scenario} ${mode}"
        ;;
    elect|mixed|unrecorded|unrecorded-nokey|live|live-key|copy-pid-live|index-pid-live|trunc-fail) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac
mode=${mode:-all-databases}
case "${scenario}:${mode}" in
    *:all-databases|constraint:single) ;;
    *) echo "Unknown mode of ${scenario}: ${mode}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-all-databases-resume/${name// /-}
workdir=${TMPDIR}/work
mkdir -p "${TMPDIR}"
clone_pid='' gate_pids=() holder_pid=''
others="backend_type = 'client backend' and pid <> pg_backend_pid()
    and application_name not in ('gate', 'holder')"

# end_sessions <application name>: the test's own sessions on the target
end_sessions() {
    sql target postgres "select count(pg_terminate_backend(pid)) from pg_stat_activity
        where application_name = '$1'" >/dev/null
}

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    if test "${#gate_pids[@]}" -gt 0 || test -n "${holder_pid}"; then
        { end_sessions gate; end_sessions holder; } >/dev/null 2>&1 || true
    fi
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (errors)"
            grep -E ' (ERROR|FATAL) ' "${log}" | tail -n 20 || true
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

# catalog <database>: its catalog in the work directory, which the clone
# creates only in its pre-data step
catalog() {
    if test "${mode}" = single; then
        echo "${workdir}/schema/source.db"
    else
        echo "${workdir}/db/$1/schema/source.db"
    fi
}
sqlite() {
    test -f "$(catalog "$1")" || return 1
    timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list \
        "$(catalog "$1")" "$2"
}
# writes to a catalog of the work directory, only while no pgcopydb runs
sqlite_write() {
    timeout 10s sqlite3 -init /dev/null -cmd '.timeout 5000' -batch "$(catalog "$1")" "$2"
}
digest() { echo "select count(*), count(distinct id), md5(coalesce(string_agg(t::text, ',' order by t::text), '')) from $1 t"; }
# indexes and constraints of a table; PG18 lists NOT NULL constraints, PG16 does not
shape() {
    echo "select coalesce(string_agg(d, '; ' order by d), '') from (
        select indexdef as d from pg_indexes where schemaname = 'public' and tablename = '$1'
        union all
        select conname || ': ' || pg_get_constraintdef(oid) from pg_constraint
         where conrelid = 'public.$1'::regclass and contype <> 'n') s"
}
# same <database> <table>: rows, indexes and constraints equal on both sides
same() {
    equal "$(sql target "$1" "$(digest "$2")")" "$(sql source "$1" "$(digest "$2")")" "$1.$2 rows|distinct ids|md5 on the target"
    equal "$(sql target "$1" "$(shape "$2")")" "$(sql source "$1" "$(shape "$2")")" "$1.$2 indexes and constraints on the target"
}
# resume_logs <regex> <count> <what>: the last resume's log has count matching
# lines, which are printed
resume_logs() {
    equal "$(grep -cE "$1" "${log}" || true)" "$2" "$3"
    grep -E "$1" "${log}" | sed -E 's/^.* (INFO|NOTICE) +[a-z_-]+\.c:[0-9]+ +/  resume: /' || true
}
gate_locks() { sql target postgres "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }

poll() {
    local what=$1 deadline=$((SECONDS + 120)) rc=''
    shift
    until "$@"; do
        if test -n "${clone_pid}" && ! kill -0 "${clone_pid}" 2>/dev/null; then
            wait "${clone_pid}" || rc=$?
            clone_pid=
            fail "pgcopydb exited ${rc:-0} while waiting for ${what}"
        fi
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

gate_held() {
    test "$(gate_locks "granted and mode = 'ExclusiveLock'
        and database = (select oid from pg_database where datname = '$1')")" = 1
}
gate_open() { test "$(gate_locks 'true')" = 0; }
run_gone() { test "$(sql target postgres "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"; }

# waits <database> <progress view> <table>: a COPY or CREATE INDEX on table
# waits on the gate
waits() {
    test "$(sql target "$1" "select count(*) from $2 p join pg_locks l on l.pid = p.pid
        where p.relid = to_regclass('public.$3')
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

# alter_waits <constraint>: the ALTER TABLE that adds it waits on the gate
alter_waits() {
    test "$(sql target postgres "select count(*) from pg_stat_activity a join pg_locks l on l.pid = a.pid
        where a.query like 'ALTER TABLE % ADD CONSTRAINT $1 %'
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

# copies_done <database> <count>: COPY units done, a split table counting one per part
copies_done() {
    test "$(sqlite "$1" 'select count(*) from summary
        where tableoid is not null and done_time_epoch is not null')" = "$2"
}

# parts_done <database> <table>
parts_done() {
    sqlite "$1" "select count(*) from summary s join s_table t on t.oid = s.tableoid
        where t.relname = '$2' and s.partnum > 0 and s.done_time_epoch is not null"
}
three_parts_done() { test "$(parts_done "$1" "$2")" = 3; }

# vacuumed <database> <table>...: the VACUUM of each table is done
vacuumed() {
    local db=$1 list
    shift
    list=$(printf "'%s'," "$@")
    test "$(sqlite "${db}" "select count(*) from vacuum_summary v join s_table t on t.oid = v.tableoid
        where t.relname in (${list%,}) and v.done_time_epoch is not null")" = "$#"
}

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI%/*}/$1" \
        -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >>"${TMPDIR}/gate.out" 2>&1 &
    gate_pids+=("$!")
    poll "the gate in $1 to close" gate_held "$1"
}

release_gate() {
    end_sessions gate
    wait "${gate_pids[@]}" || true
    gate_pids=()
    poll 'the gates to open' gate_open
}

# a session of d1 keeps ACCESS SHARE on heap, which a TRUNCATE there waits on
# until lock_timeout cancels it
hold_heap() {
    PGAPPNAME=holder psql -AtqX -d "${PGCOPYDB_TARGET_PGURI%/*}/d1" -c 'begin' \
        -c 'lock table heap in access share mode' -c 'select pg_sleep(600)' >"${TMPDIR}/holder.out" 2>&1 &
    holder_pid=$!
    poll 'the holder to lock heap' heap_locks 1
}
heap_locks() {
    test "$(sql target d1 "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'holder' and l.relation = 'public.heap'::regclass and l.granted")" = "$1"
}

release_heap() {
    end_sessions holder
    wait "${holder_pid}" || true
    holder_pid=
    poll 'the holder to unlock heap' heap_locks 0
}

start_clone() {
    setsid pgcopydb clone "${args[@]}" >"${TMPDIR}/attempt.log" 2>&1 &
    clone_pid=$!
    # $! is known before the child has called setsid()
    poll 'pgcopydb to own its process group' own_group
}

# a caller that retries with --resume waits for the dead run's target sessions
# to end; a backend that waits on the gate never reads its socket, so end it
kill_clone() {
    kill -KILL -- "-${clone_pid}"
    wait "${clone_pid}" || true
    clone_pid=
    sql target postgres "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
    poll 'the killed run to leave the target' run_gone
}

# resume <log> <seconds>: the caller's retry, bounded; -k ends a run that
# outlives the SIGTERM
resume() {
    log=${TMPDIR}/$1
    status=0
    timeout -k 10s "$2" pgcopydb clone "${args[@]}" --resume --not-consistent >"${log}" 2>&1 || status=$?
}

# d1 and d2 exist empty on the target, so the gate can connect there before
# the clone creates them
gates="create function gate_at(integer, integer) returns boolean language plpgsql
        as \$\$ begin if \$1 = \$2 then perform pg_advisory_xact_lock_shared(42); end if; return true; end \$\$;
    create function gate_key(integer) returns integer language plpgsql immutable
        as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$"
for side in source target; do
    sql "${side}" postgres 'drop database if exists d1 with (force)' 'drop database if exists d2 with (force)' \
        'create database d1' 'create database d2'
done
sql source d1 "${gates}"
sql source d2 "${gates}"

case "${scenario}" in
    # all copies done in d1 and d2, killed while d2's big2_gate is built
    elect)
        table=big2 db=d2
        sql source d1 "create table big(id integer primary key, payload text not null);
            insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
            analyze"
        sql source d2 "create table big2(id integer primary key);
            insert into big2 select generate_series(1, 200000);
            create index big2_gate on big2 (gate_key(id));
            create table small(id integer primary key, val integer not null);
            insert into small select g, g % 100 from generate_series(1, 1000) g;
            create index small_val on small (val);
            create table bare(id integer not null, payload text);
            insert into bare select g, md5(g::text) from generate_series(1, 1000) g;
            analyze"
        ;;
    # one kill leaves d1.big with 3 of 4 parts done and d2.big2 with all 4 done
    # and big2_gate held: one resume, two databases in different states
    mixed)
        table=big2 db=d2
        sql source d1 "create table big(id integer primary key, payload text not null);
            insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
            alter table big add constraint big_gate check (gate_at(id, 200000));
            analyze"
        sql source d2 "create table big2(id integer primary key);
            insert into big2 select generate_series(1, 200000);
            create index big2_gate on big2 (gate_key(id));
            analyze"
        ;;
    # 3 of 4 parts done; unrecorded* forget a done row, as a run dying between
    # a part's COPY and its done row does; live* change rows of a done part on
    # the source; trunc-fail holds a lock that the resume's TRUNCATE waits on
    unrecorded|unrecorded-nokey|live|live-key|trunc-fail)
        table=big db=d1 key='primary key'
        case "${scenario}" in
            unrecorded-nokey|live|trunc-fail) table=heap key='not null' ;;
        esac
        sql source d1 "create table ${table}(id integer ${key}, payload text not null);
            insert into ${table} select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
            alter table ${table} add constraint ${table}_gate check (gate_at(id, 200000));
            analyze"
        ;;
    # the unfinished COPY or CREATE INDEX row of small names a live pid, as a
    # retry in a fresh pid namespace reuses them
    copy-pid-live|index-pid-live)
        table=small db=d1 hold='alter table small add constraint small_gate check (gate_at(id, 1000))'
        test "${scenario}" = copy-pid-live || hold='create index small_gate on small (gate_key(id))'
        sql source d1 "create table small(id integer primary key, payload text not null);
            insert into small select g, md5(g::text) from generate_series(1, 1000) g;
            ${hold};
            analyze"
        ;;
    # killed while the ALTER TABLE adding cx_excl waits, which is built in the
    # constraint step after both indexes of cx are done; one index worker
    # then sees both done indexes of cx in the resume, and is elected once
    constraint)
        table=cx db=d2 index_jobs=1
        sql source d2 "create table cx(id integer not null, val integer not null);
            insert into cx select g, g % 100 from generate_series(1, 1000) g;
            alter table cx add constraint cx_excl exclude using btree (gate_key(id) with =);
            alter table cx add constraint cx_pkey primary key (id);
            analyze"
        ;;
esac

# 1MB splits a 200000-row table in 4 parts; 4 jobs take all 4 at once
args=(--dir "${workdir}" --table-jobs 4 --index-jobs "${index_jobs:-2}"
    --split-tables-larger-than 1MB --split-max-parts 4 --use-copy-binary --notice)
if test "${mode}" = single; then
    args+=(--source "${PGCOPYDB_SOURCE_PGURI%/*}/${db}" --target "${PGCOPYDB_TARGET_PGURI%/*}/${db}")
else
    args+=(--all-databases)
fi

hold_gate "${db}"
test "${scenario}" != mixed || hold_gate d1
start_clone
case "${scenario}" in
    elect)
        poll 'the 4 parts of big in d1 to be copied' copies_done d1 4
        poll 'the 4 parts of big2, small and bare in d2 to be copied' copies_done d2 6
        poll 'the CREATE INDEX of big2_gate to wait on the gate' waits d2 pg_stat_progress_create_index big2
        poll 'the VACUUM of big in d1 to be done' vacuumed d1 big
        poll 'the VACUUM of small and bare in d2 to be done' vacuumed d2 small bare
        ;;
    mixed)
        poll 'the COPY of the last part of big in d1 to wait on the gate' waits d1 pg_stat_progress_copy big
        poll '3 of the 4 parts of big in d1 to be done' three_parts_done d1 big
        poll 'the 4 parts of big2 in d2 to be copied' copies_done d2 4
        poll 'the CREATE INDEX of big2_gate in d2 to wait on the gate' waits d2 pg_stat_progress_create_index big2
        ;;
    unrecorded|unrecorded-nokey|live|live-key|trunc-fail)
        poll "the COPY of the last part of ${table} to wait on the gate" waits d1 pg_stat_progress_copy "${table}"
        poll "3 of the 4 parts of ${table} to be done" three_parts_done d1 "${table}"
        ;;
    copy-pid-live)
        poll 'the COPY of small to wait on the gate' waits d1 pg_stat_progress_copy small
        ;;
    index-pid-live)
        poll 'the CREATE INDEX of small_gate to wait on the gate' waits d1 pg_stat_progress_create_index small
        ;;
    constraint)
        poll 'the ALTER TABLE adding cx_excl to wait on the gate' alter_waits cx_excl
        ;;
esac
kill_clone

case "${scenario}" in
    elect|mixed)
        equal "$(sqlite d2 "select count(*) from s_table_parts_done d join s_table t on t.oid = d.tableoid
            where t.relname = 'big2'")" 1 'the killed run left the parts election of big2'
        equal "$(sqlite d2 "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big2_gate' and s.done_time_epoch is null")" 1 'the killed run left big2_gate unfinished'
        ;;
esac
case "${scenario}" in
    mixed)
        equal "$(parts_done d1 big)" 3 'parts of big in d1 done before the resume'
        ;;
    unrecorded|unrecorded-nokey|live|live-key|trunc-fail)
        equal "$(sqlite d1 "select count(*) from s_table_part p join s_table t on t.oid = p.oid
            where t.relname = '${table}'")" 4 "${table} is split in 4 parts"
        if test "${table}" = heap; then
            equal "$(sqlite d1 "select coalesce(part_key, '') from s_table where relname = 'heap'")" '' 'heap is split by ctid'
        fi
        ;;
    constraint)
        equal "$(sqlite d2 "select count(*) from s_table_indexes_done d join s_table t on t.oid = d.tableoid
            where t.relname = 'cx'")" 1 'the killed run left the constraint election of cx'
        equal "$(sqlite d2 "select group_concat(c.conname || ' done=' || (s.done_time_epoch is not null), ', ')
            from summary s join s_constraint c on c.oid = s.conoid")" 'cx_excl done=0' 'constraints the killed run started'
        ;;
esac
case "${scenario}" in
    unrecorded|unrecorded-nokey)
        sqlite_write d1 "delete from summary where partnum = 2 and done_time_epoch is not null
            and tableoid = (select oid from s_table where relname = '${table}')"
        equal "$(parts_done d1 "${table}")" 2 "parts of ${table} done after forgetting part 2"
        echo "forgot the done row of part 2 of ${table}, whose rows stay on the target"
        ;;
    live|live-key)
        sql source d1 "update ${table} set payload = payload || 'u' where id <= 1000"
        echo "updated ids 1 to 1000 of ${table} on the source, in a part copied before the kill"
        ;;
    copy-pid-live|index-pid-live)
        what=${scenario%-pid-live}
        kind='tableoid = (select oid from s_table where relname = '"'small'"')'
        test "${what}" = copy || kind='indexoid = (select oid from s_index where relname = '"'small_gate'"')'
        equal "$(sqlite d1 "select count(*) from summary where done_time_epoch is null and ${kind}")" 1 \
            "the killed run left the ${what} row of small unfinished"
        sqlite_write d1 "update summary set pid = $$ where done_time_epoch is null and ${kind}"
        echo "the unfinished ${what} row of small now names the live pid $$"
        ;;
esac

release_gate

# a failed TRUNCATE has to end the resume, and the next one has to converge
if test "${scenario}" = trunc-fail; then
    sql target postgres "alter database d1 set lock_timeout = '2s'"
    hold_heap
    echo "the target's d1 has lock_timeout 2s, and a session holds ACCESS SHARE on heap"
    resume resume.log 60s
    if test "${status}" = 0; then
        same d1 heap
        echo "PASS [${name}]: the resume never truncated heap and leaves it equal to the source"
        exit 0
    fi
    case "${status}" in
        124|137) fail "the resume still ran at its 60 s deadline: exit status ${status}" ;;
    esac
    grep -qE ' (ERROR|FATAL) .*TRUNCATE ONLY public\.heap' "${log}" ||
        fail "the resume exited ${status} before it failed to truncate heap"
    echo "the resume exited ${status} on the TRUNCATE of heap"
    release_heap
    resume resume2.log 180s
    equal "${status}" 0 'the second resume exit status'
    same d1 heap
    resume_logs 'd1: TRUNCATE ONLY public\.heap$' 1 'the second resume truncates heap'
    resume_logs 'd1: COPY public\.heap ' 4 'the second resume copies the 4 parts of heap'
    echo "PASS [${name}]: the resume exits on the failed TRUNCATE, and the next one leaves heap equal to the source"
    exit 0
fi

resume resume.log 180s
equal "${status}" 0 'the resume exit status'
same "${db}" "${table}"

case "${scenario}" in
    elect)
        same d1 big
        same d2 small
        same d2 bare
        # big2 is kept; the per-table path, not the post-data restore, builds
        # big2_gate and then vacuums big2, once
        resume_logs 'd[12]: TRUNCATE ' 0 'TRUNCATE statements of the resume'
        resume_logs 'Skipping TRUNCATE .*public\.big2?\b' 2 'the resume keeps big and big2'
        resume_logs 'd2: CREATE INDEX IF NOT EXISTS big2_gate ' 1 'the resume builds big2_gate'
        resume_logs 'd2: VACUUM ANALYZE public\.big2;' 1 'the resume vacuums big2'
        ;;
    mixed)
        same d1 big
        resume_logs 'd1: TRUNCATE ONLY public\.big$' 1 'the resume truncates big in d1'
        resume_logs 'd1: COPY public\.big ' 4 'the resume copies the 4 parts of big in d1'
        resume_logs 'd2: (TRUNCATE|COPY) ' 0 'TRUNCATE and COPY statements of the resume in d2'
        resume_logs 'Skipping TRUNCATE .*public\.big2\b' 1 'the resume keeps big2 in d2'
        resume_logs 'd2: CREATE INDEX IF NOT EXISTS big2_gate ' 1 'the resume builds big2_gate'
        resume_logs 'd2: VACUUM ANALYZE public\.big2;' 1 'the resume vacuums big2'
        ;;
    unrecorded|unrecorded-nokey|live|live-key)
        resume_logs "d1: TRUNCATE ONLY public\.${table}\$" 1 "the resume truncates ${table}"
        resume_logs "d1: COPY public\.${table} " 4 "the resume copies the 4 parts of ${table}"
        ;;
    copy-pid-live)
        resume_logs 'd1: COPY public\.small' 1 'the resume copies small'
        ;;
    index-pid-live)
        resume_logs 'd1: CREATE INDEX IF NOT EXISTS small_gate ' 1 'the resume builds small_gate'
        ;;
    constraint)
        # each constraint and the VACUUM once, by the per-table path; a VACUUM
        # queued twice logs a second run or "Skipping VACUUM ANALYZE public.cx,"
        resume_logs 'ALTER TABLE public\.cx ADD CONSTRAINT cx_excl ' 1 'the resume adds cx_excl'
        resume_logs 'ALTER TABLE public\.cx ADD CONSTRAINT cx_pkey ' 1 'the resume adds cx_pkey'
        resume_logs 'VACUUM ANALYZE public\.cx[;,]' 1 'the resume vacuums cx'
        ;;
esac
echo "PASS [${name}]: the resume leaves ${db}.${table} equal to the source"
