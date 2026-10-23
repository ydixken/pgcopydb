#! /bin/bash

# --defer-indexes copies every table before it builds any index, constraint
# or VACUUM. A CHECK constraint or an index expression holds the run on an
# advisory lock that the test holds on the target, so each scenario can look
# at the held window, or kill and resume the run inside the deferred phase.

set -euo pipefail

scenario=${1:-all}
name=${scenario}

fail() { echo "FAIL [${name}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

case "${scenario}" in
    all)
        pgcopydb ping
        echo "source: $(source_sql 'select version()')"
        echo "target: $(target_sql 'select version()')"
        status=0
        for scenario in probe order control resume vacuum-resume elected copyfail steps follow constraint-orphan d3order; do
            bash "$0" "${scenario}" || status=1
        done
        echo "elapsed: ${SECONDS} s"
        exit "${status}"
        ;;
    probe|order|control|resume|vacuum-resume|elected|copyfail|steps|follow|constraint-orphan|d3order) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-defer-indexes/${scenario}
workdir=${TMPDIR}/work
catalog=${workdir}/schema/source.db
mkdir -p "${TMPDIR}"
# 1MB splits big in 4 parts and leaves the other tables alone
clone_args=(--dir "${workdir}" --table-jobs 4 --index-jobs 2 --split-tables-larger-than 1MB
    --split-max-parts 4 --use-copy-binary --notice)
run_pid='' gate_pid='' lock_pid='' snapshot_pid='' role_set=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
free_lock="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'tablelock'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name not in ('gate', 'tablelock')"
index_stmt='CREATE (UNIQUE )?INDEX (IF NOT EXISTS )?[a-z_0-9]+ ON '
vacuum_stmt='VACUUM ANALYZE public\.[a-z_0-9]*;'
big_gate_check='alter table big add constraint big_gate check (gate_at(id, 200000))'

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${run_pid}" || kill -KILL -- "-${run_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    test -z "${lock_pid}" || target_sql "${free_lock}" >/dev/null 2>&1 || true
    test -z "${role_set}" || target_sql 'alter role postgres reset pgcopydb_test.fail' >/dev/null 2>&1 || true
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
digest() { echo "select count(*), count(distinct id), md5(coalesce(string_agg(t::text, ',' order by id), '')) from $1 t"; }
# indexes and constraints of a table; PG18 lists NOT NULL constraints, PG16 does not
shape() {
    echo "select coalesce(string_agg(d, '; ' order by d), '') from (
        select indexdef as d from pg_indexes where schemaname = 'public' and tablename = '$1'
        union all
        select conname || ': ' || pg_get_constraintdef(oid) from pg_constraint
         where conrelid = 'public.$1'::regclass and contype <> 'n') s"
}
gate_locks() { target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }
stmt_count() { grep -cE "$1" "$2" || true; }
quoted() { printf "'%s'," "$@" | sed 's/,$//'; }

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

# waits <progress view> <table>: a COPY or CREATE INDEX on table waits on the gate
waits() {
    test "$(target_sql "select count(*) from $1 p join pg_locks l on l.pid = p.pid
        where p.relid = to_regclass('public.$2')
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

index_backends() { target_sql "select count(*) from pg_stat_activity where application_name like '%create index worker%'"; }
supervisors() { pgrep -fc '^pgcopydb: (index|vacuum) supervisor' || true; }
# a new xid at a known instant: indexes built later carry a newer xmin
marker() { target_sql 'select pg_current_xact_id()'; }

# ADD CONSTRAINT ... USING INDEX rewrites the pg_class row of its index
indexes_after_marker() {
    target_sql "select bool_and(age(c.xmin) < age(xid('$1'::xid8)))
        from pg_class c join pg_index i on i.indexrelid = c.oid
        where c.relnamespace = 'public'::regnamespace
          and not exists (select 1 from pg_constraint k where k.conindid = c.oid)"
}

timing_done() { sqlite "select count(*) from timings where label = '$1' and done_time_epoch is not null"; }
copy_phase_ended() { test "$(timing_done 'COPY (cumulative)')" = 1; }
index_phase_ended() { test "$(timing_done 'CREATE INDEX (cumulative)')" = 1; }
index_workers_up() { test "$(index_backends)" -ge 1; }
small_val_built() { test "$(target_sql "select to_regclass('public.small_val') is not null")" = t; }

# copied <table>...: each table, none of them split, has its COPY done
copied() {
    test "$(sqlite "select count(*) from summary s join s_table t on t.oid = s.tableoid
        where t.relname in ($(quoted "$@")) and s.done_time_epoch is not null")" = "$#"
}

vacuumed() {
    test "$(sqlite "select count(*) from vacuum_summary v join s_table t on t.oid = v.tableoid
        where t.relname in ($(quoted "$@")) and v.done_time_epoch is not null")" = "$#"
}

table_locked() {
    test "$(target_sql "select count(*) from pg_locks l join pg_stat_activity a on a.pid = l.pid
        where a.application_name = 'tablelock' and l.relation = 'public.$1'::regclass and l.granted")" = 1
}

vacuum_waits() {
    test "$(target_sql "select count(*) from pg_stat_activity
        where query like 'VACUUM ANALYZE public.$1%' and wait_event_type = 'Lock'")" = 1
}

# alter_waits <constraint>: the ALTER TABLE that adds it waits on the gate
alter_waits() {
    test "$(target_sql "select count(*) from pg_stat_activity a join pg_locks l on l.pid = a.pid
        where a.query like 'ALTER TABLE % ADD CONSTRAINT $1 %'
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
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

hold_table_lock() {
    PGAPPNAME=tablelock psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" -c 'begin' \
        -c "lock table public.$1 in share update exclusive mode" -c 'select pg_sleep(600)' >"${TMPDIR}/tablelock.out" 2>&1 &
    lock_pid=$!
    poll "the lock on $1" table_locked "$1"
}

release_table_lock() {
    target_sql "${free_lock}" >/dev/null
    wait "${lock_pid}" || true
    lock_pid=
}

# start <log> <command>...: its own process group, so a kill reaches every child
start() {
    local log=$1
    shift
    setsid "$@" >"${TMPDIR}/${log}.log" 2>&1 &
    run_pid=$!
    # $! is known before the child has called setsid()
    poll 'pgcopydb to own its process group' own_group
}

start_clone() {
    local log=$1
    shift
    start "${log}" pgcopydb clone "${clone_args[@]}" "$@"
}

# finish <log> <seconds>: status is the run's exit code; a run alive at the
# deadline hangs, so show the queues and end its process group
finish() {
    local deadline=$((SECONDS + $2))
    status=0
    while kill -0 "${run_pid}" 2>/dev/null; do
        if test "${SECONDS}" -ge "${deadline}"; then
            ipcs -q
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
    target_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
    poll 'the killed run to leave the target' run_gone
}

# a caller that ends no session: the backend of a statement that waits on the
# gate outlives the run, and its statement commits once the gate opens
orphan_clone() {
    kill -KILL -- "-${run_pid}"
    wait "${run_pid}" || true
    run_pid=
    release_gate
    poll 'the backends of the killed run to end' run_gone
}

compare() {
    pgcopydb compare "$1" --dir "${TMPDIR}/compare-$1" >"${TMPDIR}/compare-$1.log" 2>&1 ||
        fail "compare $1 found differences"
}

same_data() {
    for table in "$@"; do
        equal "$(target_sql "$(digest "${table}")")" "$(source_sql "$(digest "${table}")")" "${table} on the target matches the source"
    done
}

same_shape() {
    equal "$(target_sql "$(shape "$1")")" "$(source_sql "$(shape "$1")")" "$1 indexes and constraints on the target"
}

# a scenario that died midway leaves sessions and objects behind; the gate
# functions live in public, so they go too
reset() {
    local sql="select count(pg_terminate_backend(pid)) from pg_stat_activity
        where backend_type = 'client backend' and pid <> pg_backend_pid()"
    for run in source_sql target_sql; do
        "${run}" "${sql}" >/dev/null
        "${run}" 'set client_min_messages to warning; drop schema public cascade; create schema public'
    done
}

# gate_at() waits on the gate for one id, gate_key() for every row
gates="create function gate_at(integer, integer) returns boolean language plpgsql
        as \$\$ begin if \$1 = \$2 then perform pg_advisory_xact_lock_shared(42); end if; return true; end \$\$;
    create function gate_key(integer) returns integer language plpgsql immutable
        as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$"

seed() {
    reset
    source_sql "${gates};
        create table big(id integer primary key, payload text not null);
        insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
        create table small(id integer primary key, val integer not null);
        insert into small select g, g % 100 from generate_series(1, 1000) g;
        create index small_val on small (val);
        create table bare(id integer not null, payload text);
        insert into bare select g, md5(g::text) from generate_series(1, 1000) g;
        $1;
        analyze"
}

# help exits 0 and 1 on a bad option before it reads anything else
probe_help() {
    local rc=0 lines
    pgcopydb "$@" --defer-indexes --help >/dev/null 2>&1 || rc=$?
    lines=$(pgcopydb "$@" --help 2>&1 | grep -F -- '--defer-indexes' |
        grep -cF 'Build indexes once all table data is copied' || true)
    equal "${rc}|${lines}" '0|1' "pgcopydb $* --defer-indexes --help exit status|help lines"
}

pgcopydb ping >"${TMPDIR}/ping.out" 2>&1 || { cat "${TMPDIR}/ping.out"; fail 'pgcopydb ping failed'; }

case "${scenario}" in
    probe)
        # the operator's preflight and runner canary read this help line
        probe_help clone
        probe_help copy db
        probe_help copy data
        echo "PASS [${name}]: clone, copy db and copy data take --defer-indexes"
        ;;

    order)
        seed "${big_gate_check}"
        hold_gate
        start_clone attempt --defer-indexes
        poll 'the COPY of big to wait on the gate' waits pg_stat_progress_copy big
        poll 'the COPY of small and bare to be done' copied small bare
        equal "$(index_backends)" 0 'index workers connected while big is held'
        equal "$(supervisors)" 0 'index and vacuum supervisors while big is held'
        equal "$(target_sql "select to_regclass('public.small_val') is null")" t 'small_val is absent while big is held'
        mark=$(marker)
        release_gate
        finish attempt 120
        equal "${status}" 0 'the clone exit status'
        same_data big small bare
        compare schema
        compare data
        equal "$(stmt_count 'CREATE INDEX small_val ' "${TMPDIR}/attempt.log")" 1 'small_val builds'
        for table in big small bare; do
            equal "$(stmt_count "VACUUM ANALYZE public\.${table};" "${TMPDIR}/attempt.log")" 1 "VACUUM of ${table}"
        done
        equal "$(indexes_after_marker "${mark}")" t 'every index is newer than the marker'
        echo "PASS [${name}]: no index, constraint or VACUUM work starts before the last COPY"
        ;;

    control)
        # without the flag the probes of order see the index pool and small_val
        seed "${big_gate_check}"
        hold_gate
        start_clone attempt
        poll 'the COPY of big to wait on the gate' waits pg_stat_progress_copy big
        poll 'an index worker to connect' index_workers_up
        equal "$(supervisors)" 2 'index and vacuum supervisors while big is held'
        poll 'small_val to be built' small_val_built
        waits pg_stat_progress_copy big || fail 'big is no longer held once small_val is built'
        mark=$(marker)
        release_gate
        finish attempt 120
        equal "${status}" 0 'the clone exit status'
        equal "$(indexes_after_marker "${mark}")" f 'every index is newer than the marker'
        echo "PASS [${name}]: without the flag indexes are built while a COPY runs"
        ;;

    resume)
        seed 'create index big_gate on big (gate_key(id))'
        hold_gate
        start_clone attempt --defer-indexes
        poll 'the COPY phase to end' copy_phase_ended
        poll 'the CREATE INDEX of big_gate to wait on the gate' waits pg_stat_progress_create_index big
        poll 'the VACUUM of small and bare to be done' vacuumed small bare
        kill_clone
        equal "$(timing_done 'COPY (cumulative)')" 1 'the COPY phase is done before the resume'
        equal "$(sqlite "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big_gate' and s.done_time_epoch is null")" 1 'the killed run left big_gate unfinished'
        # a retry in a fresh container reuses pids: point the row at a live one
        sqlite_write "update summary set pid = $$ where done_time_epoch is null
            and indexoid = (select oid from s_index where relname = 'big_gate')"
        release_gate
        start_clone resume --defer-indexes --resume --not-consistent
        finish resume 120
        equal "${status}" 0 'the resume exit status'
        same_data big small bare
        equal "$(target_sql 'select count(*) - count(distinct id) from big')" 0 'duplicate ids in big'
        compare schema
        compare data
        equal "$(stmt_count 'Started COPY supervisor' "${TMPDIR}/resume.log")" 0 'COPY supervisors the resume starts'
        equal "$(stmt_count 'CREATE INDEX IF NOT EXISTS big_gate ' "${TMPDIR}/resume.log")" 1 'the resume builds big_gate'
        equal "$(sqlite "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big_gate' and s.done_time_epoch is not null")" 1 'big_gate is done in the summary'
        for table in small bare; do
            equal "$(stmt_count "VACUUM ANALYZE public\.${table};" "${TMPDIR}/attempt.log")" 1 "the attempt vacuums ${table}"
            equal "$(stmt_count "VACUUM ANALYZE public\.${table};" "${TMPDIR}/resume.log")" 0 "the resume vacuums ${table}"
        done
        equal "$(stmt_count 'VACUUM ANALYZE public\.big;' "${TMPDIR}/resume.log")" 1 'the resume vacuums big'
        echo "PASS [${name}]: a resume in the deferred phase builds and vacuums only what is left"
        ;;

    vacuum-resume)
        # the index timing stops before the VACUUM queue drains
        seed "${big_gate_check}"
        hold_gate
        start_clone attempt --defer-indexes
        poll 'the COPY of bare to be done' copied bare
        hold_table_lock bare
        release_gate
        poll 'the CREATE INDEX timing to end' index_phase_ended
        poll 'the VACUUM of big and small to be done' vacuumed big small
        poll 'the VACUUM of bare to wait on a lock' vacuum_waits bare
        kill_clone
        release_table_lock
        equal "$(sqlite "select count(*) from vacuum_summary v join s_table t on t.oid = v.tableoid
            where t.relname = 'bare' and v.done_time_epoch is null")" 1 'the killed run left the VACUUM of bare unfinished'
        start_clone resume --defer-indexes --resume --not-consistent
        finish resume 120
        equal "${status}" 0 'the resume exit status'
        equal "$(stmt_count 'Started COPY supervisor' "${TMPDIR}/resume.log")" 0 'COPY supervisors the resume starts'
        equal "$(stmt_count "${index_stmt}" "${TMPDIR}/resume.log")" 0 'index statements in the resume'
        equal "$(stmt_count 'VACUUM ANALYZE public\.bare;' "${TMPDIR}/resume.log")" 1 'the resume vacuums bare'
        for table in big small; do
            equal "$(stmt_count "VACUUM ANALYZE public\.${table};" "${TMPDIR}/resume.log")" 0 "the resume vacuums ${table}"
        done
        vacuumed bare || fail 'the VACUUM of bare is not done after the resume'
        compare data
        echo "PASS [${name}]: a resume after the index phase runs only the pending VACUUM"
        ;;

    elected)
        # EXCLUDE builds its index inside the ALTER, after ex won the election
        # and added ex_pkey; one index job then sees both done indexes of ex
        seed 'create table ex(id integer primary key, constraint ex_gate exclude using btree (gate_key(id) with =));
            insert into ex select generate_series(1, 1000)'
        hold_gate
        start_clone attempt --defer-indexes --index-jobs 1
        poll 'the ALTER TABLE of ex_gate to wait on the gate' alter_waits ex_gate
        equal "$(sqlite "select count(*) from s_table_indexes_done d join s_table t on t.oid = d.tableoid
            where t.relname = 'ex'")" 1 'the killed run elected ex'
        kill_clone
        release_gate
        start_clone resume --defer-indexes --index-jobs 1 --resume --not-consistent
        finish resume 120
        equal "${status}" 0 'the resume exit status'
        compare schema
        equal "$(stmt_count 'ALTER TABLE public\.ex ADD CONSTRAINT ex_gate ' "${TMPDIR}/resume.log")" 1 'the resume adds ex_gate'
        equal "$(stmt_count 'ALTER TABLE public\.ex ADD CONSTRAINT ex_pkey ' "${TMPDIR}/resume.log")" 0 'the resume adds ex_pkey'
        # a VACUUM queued twice logs a second run or "Skipping VACUUM ANALYZE public.ex,"
        equal "$(stmt_count 'VACUUM ANALYZE public\.ex[;,]' "${TMPDIR}/resume.log")" 1 'the resume vacuums ex'
        echo "PASS [${name}]: a resume elects ex again and adds only its unfinished constraint"
        ;;

    copyfail)
        # without --fail-fast a failed COPY still ends the attempt with an error
        seed "create function fail_on_target(integer) returns boolean language plpgsql
                as \$\$ begin
                    if \$1 = 1000 and current_setting('pgcopydb_test.fail', true) = 'on' then
                        raise exception 'fail_on_target: id %', \$1;
                    end if;
                    return true;
                end \$\$;
            create table bad(id integer primary key, val integer, check (fail_on_target(id)));
            insert into bad select g, g from generate_series(1, 1000) g"
        role_set=yes
        target_sql "alter role postgres set pgcopydb_test.fail = 'on'"
        start_clone attempt --defer-indexes
        finish attempt 120
        test "${status}" -ne 0 || fail 'the attempt with a failing COPY exited 0'
        equal "$(stmt_count "${index_stmt}" "${TMPDIR}/attempt.log")" 0 'index statements in the failed attempt'
        target_sql 'alter role postgres reset pgcopydb_test.fail'
        role_set=
        start_clone resume --defer-indexes --resume --not-consistent
        finish resume 120
        equal "${status}" 0 'the resume exit status'
        compare schema
        compare data
        echo "PASS [${name}]: an attempt whose COPY failed builds no index, and the resume completes"
        ;;

    steps)
        # copy data runs the same data phase as clone
        seed "${big_gate_check}"
        pgcopydb snapshot --dir "${workdir}" >"${TMPDIR}/snapshot.out" 2>"${TMPDIR}/snapshot.log" &
        snapshot_pid=$!
        poll 'the snapshot to be exported' test -s "${TMPDIR}/snapshot.out"
        pgcopydb dump schema --dir "${workdir}" --resume >"${TMPDIR}/dump-schema.log" 2>&1
        pgcopydb restore pre-data --dir "${workdir}" --resume >"${TMPDIR}/pre-data.log" 2>&1
        hold_gate
        start copy-data pgcopydb copy data --dir "${workdir}" --table-jobs 4 --index-jobs 2 \
            --defer-indexes --resume --skip-vacuum --notice
        poll 'the COPY of big to wait on the gate' waits pg_stat_progress_copy big
        equal "$(index_backends)" 0 'index workers connected while big is held'
        equal "$(supervisors)" 0 'index and vacuum supervisors while big is held'
        release_gate
        finish copy-data 120
        equal "${status}" 0 'the copy data exit status'
        pgcopydb restore post-data --dir "${workdir}" --resume >"${TMPDIR}/post-data.log" 2>&1
        kill -TERM "${snapshot_pid}"
        wait "${snapshot_pid}" || true
        snapshot_pid=
        compare schema
        compare data
        equal "$(stmt_count "${vacuum_stmt}" "${TMPDIR}/copy-data.log")" 0 'VACUUM statements with --skip-vacuum'
        equal "$(stmt_count 'CREATE INDEX (IF NOT EXISTS )?small_val ON ' "${TMPDIR}/copy-data.log")" 1 'small_val builds'
        echo "PASS [${name}]: copy data defers its indexes too"
        ;;

    follow)
        # apply starts from the sentinel that clone sets after post-data
        seed "${big_gate_check}"
        hold_gate
        start_clone attempt --follow --defer-indexes --plugin test_decoding
        poll 'the COPY of big to wait on the gate' waits pg_stat_progress_copy big
        source_sql 'insert into small values (1001, 1)'
        release_gate
        apply_line='Updating the pgcopydb.sentinel to enable applying changes'
        poll 'the clone to enable apply' grep -qF "${apply_line}" "${TMPDIR}/attempt.log"
        pgcopydb stream sentinel set endpos --current --dir "${workdir}" >"${TMPDIR}/endpos.log" 2>&1
        finish attempt 180
        equal "${status}" 0 'the clone --follow exit status'
        sentinel=$(grep -nF "${apply_line}" "${TMPDIR}/attempt.log" | head -n 1 | cut -d: -f1)
        last_index=$(grep -nE "${index_stmt}" "${TMPDIR}/attempt.log" | tail -n 1 | cut -d: -f1 || true)
        test -n "${last_index}" || fail 'the clone logged no index statement'
        test "${sentinel}" -gt "${last_index}" ||
            fail "apply was enabled at log line ${sentinel}, before the index statement at line ${last_index}"
        equal "$(target_sql 'select count(*) from small where id = 1001')" 1 'the target small holds id 1001'
        compare data
        pgcopydb stream cleanup --dir "${workdir}" >"${TMPDIR}/stream-cleanup.log" 2>&1
        echo "PASS [${name}]: apply starts after the deferred indexes"
        ;;

    constraint-orphan)
        # killed while the ALTER TABLE adding cx_excl waits, before cx_pkey;
        # its backend outlives the run and commits once the gate opens
        reset
        source_sql "${gates};
            create table cx(id integer not null, val integer not null);
            insert into cx select g, g % 100 from generate_series(1, 1000) g;
            alter table cx add constraint cx_excl exclude using btree (gate_key(id) with =);
            alter table cx add constraint cx_pkey primary key (id);
            analyze"
        hold_gate
        start_clone attempt --defer-indexes --index-jobs 1
        poll 'the ALTER TABLE adding cx_excl to wait on the gate' alter_waits cx_excl
        orphan_clone
        equal "$(sqlite "select count(*) from s_table_indexes_done d join s_table t on t.oid = d.tableoid
            where t.relname = 'cx'")" 1 'the killed run left the constraint election of cx'
        equal "$(sqlite "select group_concat(c.conname || ' done=' || (s.done_time_epoch is not null), ', ')
            from summary s join s_constraint c on c.oid = s.conoid")" 'cx_excl done=0' 'constraints the killed run started'
        equal "$(target_sql "select count(*) from pg_constraint where conrelid = 'public.cx'::regclass
            and conname = 'cx_excl'")" 1 'cx_excl committed on the target after the kill'
        start_clone resume --defer-indexes --index-jobs 1 --resume --not-consistent
        finish resume 180
        equal "${status}" 0 'the resume exit status'
        same_data cx
        same_shape cx
        equal "$(stmt_count 'ALTER TABLE public\.cx ADD CONSTRAINT cx_excl ' "${TMPDIR}/resume.log")" 0 'the resume adds cx_excl'
        equal "$(stmt_count 'Skipping constraint cx_excl on public\.cx: found on the target database' "${TMPDIR}/resume.log")" 1 \
            'the resume finds cx_excl on the target'
        equal "$(stmt_count 'ALTER TABLE public\.cx ADD CONSTRAINT cx_pkey ' "${TMPDIR}/resume.log")" 1 'the resume adds cx_pkey'
        equal "$(stmt_count 'VACUUM ANALYZE public\.cx[;,]' "${TMPDIR}/resume.log")" 1 'the resume vacuums cx'
        equal "$(sqlite "select group_concat(d, ', ') from (select c.conname || ' done=' || (s.done_time_epoch is not null) as d
            from summary s join s_constraint c on c.oid = s.conoid order by 1)")" 'cx_excl done=1, cx_pkey done=1' \
            'constraints done after the resume'
        echo "PASS [${name}]: a deferred resume finds cx_excl on the target and adds only cx_pkey"
        ;;

    d3order)
        # one index worker takes the queue in order: largest table first,
        # whatever the OIDs, each table's indexes in catalog order (small_val first)
        reset
        source_sql "create table tiny(id integer primary key);
            insert into tiny select generate_series(1, 10);
            create table small(id integer not null, val integer not null);
            insert into small select g, g % 100 from generate_series(1, 1000) g;
            create index small_val on small (val);
            alter table small add primary key (id);
            create table big(id integer primary key, payload text not null);
            insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
            analyze"
        start_clone attempt --defer-indexes --index-jobs 1
        finish attempt 120
        equal "${status}" 0 'the clone exit status'
        order=$({ grep -oE "${index_stmt}" "${TMPDIR}/attempt.log" || true; } | awk '{ print $(NF - 1) }' | paste -sd ' ' -)
        equal "${order}" 'big_pkey small_val small_pkey tiny_pkey' 'index build order'
        echo "PASS [${name}]: the deferred phase builds indexes largest table first, each table's in catalog order"
        ;;
esac
