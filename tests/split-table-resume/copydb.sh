#! /bin/bash

# A clone killed while a split table has some or all of its parts done is
# retried with --resume --not-consistent. The retry has to keep a table whose
# parts are all done, copy a half-done one again from scratch, build each
# index and vacuum each table once. A CHECK constraint or an index expression
# holds the run on an advisory lock that the test holds on the target.

set -euo pipefail

scenario=${1:-all}
case "${scenario}" in
    all)
        status=0
        for scenario in index copy unrecorded parts novac; do
            bash "$0" "${scenario}" || status=1
        done
        exit "${status}"
        ;;
    index|copy|unrecorded|parts|novac) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-split-resume/${scenario}
workdir=${TMPDIR}/work
catalog=${workdir}/schema/source.db
mkdir -p "${TMPDIR}"
# 1MB splits big in 4 parts and leaves small alone; 4 jobs take all 4 at once
clone_args=(--dir "${workdir}" --table-jobs 4 --split-tables-larger-than 1MB
    --split-max-parts 4 --use-copy-binary)
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name <> 'gate'"

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (errors)"
            grep -E ' (ERROR|FATAL) ' "${log}" | tail -n 20 || true
            echo "==> ${log} (tail)"
            tail -n 20 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
sqlite() { timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list "${catalog}" "$1"; }
# writes to the work directory's catalog, only while no pgcopydb runs
sqlite_write() { timeout 10s sqlite3 -init /dev/null -cmd '.timeout 5000' -batch "${catalog}" "$1"; }
digest() { echo "select count(*), count(distinct id), md5(coalesce(string_agg(t::text, ',' order by id), '')) from $1 t"; }
gate_locks() { target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }

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

gate_held() { test "$(gate_locks "granted and mode = 'ExclusiveLock'")" = 1; }
gate_open() { test "$(gate_locks 'true')" = 0; }
run_gone() { test "$(target_sql "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"; }

# waits <progress view> <table>: a COPY or CREATE INDEX on table waits on the gate
waits() {
    test "$(target_sql "select count(*) from $1 p join pg_locks l on l.pid = p.pid
        where p.relid = to_regclass('public.$2')
          and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

parts_done() {
    sqlite "select count(*) from summary s join s_table t on t.oid = s.tableoid
        where t.relname = 'big' and s.partnum > 0 and s.done_time_epoch is not null"
}

copy_phase_done() {
    sqlite "select coalesce(done_time_epoch is not null, 0) from timings where label = 'COPY (cumulative)'"
}

three_parts_done() { test "$(parts_done)" = 3; }
copy_phase_ended() { test "$(copy_phase_done)" = 1; }
big_small_vacuumed() {
    test "$(sqlite "select count(*) from vacuum_summary v join s_table t on t.oid = v.tableoid
        where t.relname in ('big', 'small') and v.done_time_epoch is not null")" = 2
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

start_clone() {
    local name=$1
    shift
    setsid pgcopydb clone "${clone_args[@]}" "$@" >"${TMPDIR}/${name}.log" 2>&1 &
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
    target_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
    poll 'the killed run to leave the target' run_gone
}

# gate_at() waits on the gate for one id, gate_key() for every row
seed() {
    source_sql "drop table if exists big, small, held;
        drop function if exists gate_at(integer, integer), gate_key(integer);
        create function gate_at(integer, integer) returns boolean language plpgsql
            as \$\$ begin if \$1 = \$2 then perform pg_advisory_xact_lock_shared(42); end if; return true; end \$\$;
        create function gate_key(integer) returns integer language plpgsql immutable
            as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$;
        create table big(id integer primary key, payload text not null);
        insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
        create table small(id integer primary key, payload text not null);
        insert into small select g, md5(g::text) from generate_series(1, 1000) g;
        $1;
        analyze big, small"
    target_sql "drop table if exists big, small, held;
        drop function if exists gate_at(integer, integer), gate_key(integer)"
}

pgcopydb ping

# index: all parts and the COPY phase done, killed while big_gate is built
# copy: killed with 3 of the 4 parts of big done
# unrecorded: as copy, then a done part loses its done row, as when a part
#   commits its COPY and the run dies before it records that
# parts: all parts of big done while the COPY of small still runs
# novac: big, split by ctid, and small have no index and are vacuumed, while
#   the index of a third table is held
case "${scenario}" in
    index) seed 'create index big_gate on big (gate_key(id))' ;;
    copy|unrecorded) seed 'alter table big add constraint big_gate check (gate_at(id, 200000))' ;;
    parts) seed 'create index big_gate on big (gate_key(id));
        alter table small add constraint small_gate check (gate_at(id, 1))' ;;
    novac) seed 'alter table big drop constraint big_pkey;
        alter table small drop constraint small_pkey;
        create table held(id integer primary key);
        insert into held select generate_series(1, 1000);
        create index held_gate on held (gate_key(id))' ;;
esac
want_big=$(source_sql "$(digest big)")
want_small=$(source_sql "$(digest small)")

hold_gate
start_clone attempt
case "${scenario}" in
    index)
        poll 'the CREATE INDEX of big_gate to wait on the gate' waits pg_stat_progress_create_index big
        poll 'the COPY phase to end' copy_phase_ended
        want_state='4|1'
        ;;
    copy|unrecorded)
        poll 'the COPY of the last part of big to wait on the gate' waits pg_stat_progress_copy big
        poll '3 of the 4 parts of big to be done' three_parts_done
        want_state='3|0'
        ;;
    parts)
        poll 'the COPY of small to wait on the gate' waits pg_stat_progress_copy small
        poll 'the CREATE INDEX of big_gate to wait on the gate' waits pg_stat_progress_create_index big
        want_state='4|0'
        ;;
    novac)
        poll 'the CREATE INDEX of held_gate to wait on the gate' waits pg_stat_progress_create_index held
        poll 'the COPY phase to end' copy_phase_ended
        poll 'the VACUUM of big and small to be done' big_small_vacuumed
        want_state='4|1'
        ;;
esac
kill_clone

equal "$(sqlite "select count(*) from s_table_part p join s_table t on t.oid = p.oid where t.relname = 'big'")" 4 'big is split in 4 parts'
equal "$(parts_done)|$(copy_phase_done)" "${want_state}" 'parts of big done|COPY phase done, before the resume'
echo "killed the run with ${want_state%|*} of the 4 parts of big done"

case "${scenario}" in
    index)
        equal "$(sqlite "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big_gate' and s.done_time_epoch is null")" 1 'the killed run left big_gate unfinished'
        # a retry in a fresh container reuses pids: point the row at a live one
        sqlite_write "update summary set pid = $$ where done_time_epoch is null
            and indexoid = (select oid from s_index where relname = 'big_gate')"
        echo "the unfinished big_gate row now names the live pid $$"
        ;;
    unrecorded)
        part=$(sqlite "select p.partnum from s_table_part p join s_table t on t.oid = p.oid
            join summary s on s.tableoid = p.oid and s.partnum = p.partnum
            where t.relname = 'big' and s.done_time_epoch is not null and p.min > 0 and p.max >= p.min
            order by p.partnum limit 1")
        [[ ${part} =~ ^[0-9]+$ ]] || fail "no done part of big with rows: '${part}'"
        sqlite_write "delete from summary where partnum = ${part}
            and tableoid = (select oid from s_table where relname = 'big')"
        equal "$(parts_done)" 2 'parts of big done after forgetting one'
        echo "forgot the done row of part ${part}, whose rows stay on the target"
        ;;
    novac)
        equal "$(sqlite "select coalesce(part_key, '') from s_table where relname = 'big'")" '' 'big is split by ctid'
        ;;
esac

release_gate
status=0
timeout 120s pgcopydb clone "${clone_args[@]}" --resume --not-consistent --notice >"${TMPDIR}/resume.log" 2>&1 || status=$?
equal "${status}" 0 'the resume exit status'

equal "$(target_sql "$(digest big)")" "${want_big}" 'big on the target matches the source'
equal "$(target_sql "$(digest small)")" "${want_small}" 'small on the target matches the source'
equal "$(target_sql 'select count(*) - count(distinct id) from big')" 0 'duplicate ids in big'
pgcopydb compare schema --dir "${TMPDIR}/compare-schema" >"${TMPDIR}/compare-schema.log" 2>&1 ||
    fail 'compare schema found differences'
pgcopydb compare data --dir "${TMPDIR}/compare-data" >"${TMPDIR}/compare-data.log" 2>&1 ||
    fail 'compare data found differences'

case "${scenario}" in
    index|parts)
        # the per-table path, not the post-data restore, builds big_gate and
        # then vacuums big, once
        equal "$(grep -c 'CREATE INDEX IF NOT EXISTS big_gate ' "${TMPDIR}/resume.log")" 1 'the resume builds big_gate'
        equal "$(sqlite "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big_gate' and s.done_time_epoch is not null")" 1 'big_gate is done in the summary'
        equal "$(grep -c 'VACUUM ANALYZE public.big;' "${TMPDIR}/resume.log")" 1 'the resume vacuums big'
        ;;
    copy|unrecorded)
        # the killed run never vacuumed big, so the re-copied table needs one
        equal "$(grep -c 'VACUUM ANALYZE public.big;' "${TMPDIR}/resume.log")" 1 'the resume vacuums the re-copied big'
        ;;
    novac)
        for table in big small; do
            equal "$(grep -c "VACUUM ANALYZE public.${table};" "${TMPDIR}/resume.log")" 0 "the resume vacuums ${table} again"
        done
        equal "$(grep -c 'CREATE INDEX IF NOT EXISTS held_gate ' "${TMPDIR}/resume.log")" 1 'the resume builds held_gate'
        ;;
esac
echo "PASS [${scenario}]: the resume leaves big equal to the source"
