#! /bin/bash

# clone --all-databases --defer-indexes runs the deferred phase once for all
# databases, after the global COPY step. The default seed: d1 holds big, whose
# COPY a CHECK constraint holds on the gate; d2 holds small, bare and big2,
# whose index big2_gate holds the deferred phase. 'many' seeds ix_1..ix_n in
# d2; 'constraint-orphan' seeds cx in d2, with an exclusion constraint on the
# gate. Advisory locks are per database, so the gate holds only its database.

set -euo pipefail

scenario=${1:-all}
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
        for scenario in control order resume many constraint-orphan d3order; do
            bash "$0" "${scenario}" || status=1
        done
        echo "elapsed: ${SECONDS} s"
        exit "${status}"
        ;;
    control|order|resume|many|constraint-orphan|d3order) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-defer-indexes-all-databases/${scenario}
workdir=${TMPDIR}/work
mkdir -p "${TMPDIR}"
args=(--all-databases --dir "${workdir}" --table-jobs 4 --index-jobs 2
    --split-tables-larger-than 1MB --split-max-parts 4 --notice)
# a message carries sizeof(msg->data), 72 bytes (queue_utils.c), so n
# messages are more than one queue of msgmnb bytes holds
n=$(($(cat /proc/sys/kernel/msgmnb) / 72 + 50))
run_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name <> 'gate'"
index_stmt='CREATE (UNIQUE )?INDEX (IF NOT EXISTS )?[a-z_0-9]+ ON '

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${run_pid}" || kill -KILL -- "-${run_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || sql target postgres "${free_gate}" >/dev/null 2>&1 || true
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

# sqlite <database> <statement>: that database's catalog
sqlite() {
    timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list \
        "${workdir}/db/$1/schema/source.db" "$2"
}
# writes to a catalog of the work directory, only while no pgcopydb runs
sqlite_write() {
    timeout 10s sqlite3 -init /dev/null -cmd '.timeout 5000' -batch "${workdir}/db/$1/schema/source.db" "$2"
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
gate_locks() { sql target postgres "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }
stmt_count() { grep -cE "$1" "$2" || true; }

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
run_gone() { test "$(sql target postgres "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${run_pid}" | tr -d ' ')" = "${run_pid}"; }
supervisors() { pgrep -fc "^pgcopydb: ($1) supervisor" || true; }
index_backends() { sql target postgres "select count(*) from pg_stat_activity where application_name like '%create index worker%'"; }

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

small_bare_copied() {
    test "$(sqlite d2 "select count(*) from summary s join s_table t on t.oid = s.tableoid
        where t.relname in ('small', 'bare') and s.done_time_epoch is not null")" = 2
}

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI%/*}/$1" \
        -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
    gate_pid=$!
    poll 'the gate to close' gate_held
}

release_gate() {
    sql target postgres "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
    poll 'the gate to open' gate_open
}

# start_clone <log> <option>...: its own process group, so a kill reaches every child
start_clone() {
    local log=$1
    shift
    setsid pgcopydb clone "${args[@]}" "$@" >"${TMPDIR}/${log}.log" 2>&1 &
    run_pid=$!
    # $! is known before the child has called setsid()
    poll 'pgcopydb to own its process group' own_group
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
    sql target postgres "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
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
    pgcopydb compare "$1" --all-databases --dir "${TMPDIR}/compare-$1" >"${TMPDIR}/compare-$1.log" 2>&1 ||
        fail "compare $1 found differences"
}

# both databases exist empty on the target, so the gate can connect there
# before the clone starts
reset() {
    for side in source target; do
        sql "${side}" postgres 'drop database if exists d1 with (force)' 'drop database if exists d2 with (force)' \
            'create database d1' 'create database d2'
    done
}

# gate_at() waits on the gate for one id, gate_key() for every row
gates="create function gate_at(integer, integer) returns boolean language plpgsql
        as \$\$ begin if \$1 = \$2 then perform pg_advisory_xact_lock_shared(42); end if; return true; end \$\$;
    create function gate_key(integer) returns integer language plpgsql immutable
        as \$\$ begin perform pg_advisory_xact_lock_shared(42); return \$1; end \$\$"

seed() {
    reset
    sql source d1 "${gates};
        create table big(id integer primary key, payload text not null);
        insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
        alter table big add constraint big_gate check (gate_at(id, 200000));
        analyze"
    sql source d2 "${gates};
        create table small(id integer primary key, val integer not null);
        insert into small select g, g % 100 from generate_series(1, 1000) g;
        create index small_val on small (val);
        create table bare(id integer not null, payload text);
        insert into bare select g, md5(g::text) from generate_series(1, 1000) g;
        create table big2(id integer primary key);
        insert into big2 select generate_series(1, 200000);
        create index big2_gate on big2 (gate_key(id));
        analyze"
}

pgcopydb ping >"${TMPDIR}/ping.out" 2>&1 || { cat "${TMPDIR}/ping.out"; fail 'pgcopydb ping failed'; }

case "${scenario}" in
    control)
        # without the flag the global supervisors start before the COPY
        seed
        hold_gate d1
        start_clone attempt
        poll 'the COPY of big to wait on the gate' waits d1 pg_stat_progress_copy big
        equal "$(supervisors index)" 1 'index supervisors while big is held'
        release_gate
        finish attempt 180
        equal "${status}" 0 'the clone exit status'
        echo "PASS [${name}]: without the flag the index supervisor runs during the COPY"
        ;;

    order)
        seed
        hold_gate d1
        start_clone attempt --defer-indexes
        poll 'the COPY of big to wait on the gate' waits d1 pg_stat_progress_copy big
        poll 'the COPY of small and bare in d2 to be done' small_bare_copied
        equal "$(supervisors 'index|vacuum')" 0 'index and vacuum supervisors while big is held'
        equal "$(index_backends)" 0 'index workers connected while big is held'
        equal "$(sql target d2 "select to_regclass('public.small_val') is null")" t 'd2.small_val is absent while big is held'
        release_gate
        finish attempt 180
        equal "${status}" 0 'the clone exit status'
        compare schema
        compare data
        equal "$(stmt_count 'd2: CREATE INDEX small_val ' "${TMPDIR}/attempt.log")" 1 'd2.small_val builds'
        echo "PASS [${name}]: no index or VACUUM work starts before the last COPY of any database"
        ;;

    resume)
        seed
        hold_gate d2
        start_clone attempt --defer-indexes
        poll 'the CREATE INDEX of big2_gate to wait on the gate' waits d2 pg_stat_progress_create_index big2
        kill_clone
        equal "$(sqlite d2 "select count(*) from summary s join s_index i on i.oid = s.indexoid
            where i.relname = 'big2_gate' and s.done_time_epoch is null")" 1 'the killed run left big2_gate unfinished'
        # a retry in a fresh container reuses pids: point the row at a live one
        sqlite_write d2 "update summary set pid = $$ where done_time_epoch is null
            and indexoid = (select oid from s_index where relname = 'big2_gate')"
        release_gate
        start_clone resume --defer-indexes --resume --not-consistent
        finish resume 180
        equal "${status}" 0 'the resume exit status'
        compare schema
        compare data
        equal "$(stmt_count 'd2: CREATE INDEX IF NOT EXISTS big2_gate ' "${TMPDIR}/resume.log")" 1 'the resume builds d2.big2_gate'
        vacuums=$(($(stmt_count 'd2: VACUUM ANALYZE public\.big2;' "${TMPDIR}/attempt.log") +
            $(stmt_count 'd2: VACUUM ANALYZE public\.big2;' "${TMPDIR}/resume.log")))
        equal "${vacuums}" 1 'VACUUM of d2.big2 over both runs'
        echo "PASS [${name}]: a resume in the deferred step builds d2.big2_gate once"
        ;;

    many)
        reset
        sql source d2 "do \$\$ begin for i in 1..${n} loop
                execute format('create table ix_%s(id integer, val integer)', i);
                execute format('insert into ix_%s select g, g from generate_series(1, 10) g', i);
                execute format('create index ix_%s_val on ix_%s (val)', i, i);
            end loop; end \$\$" 'analyze'
        start_clone attempt --defer-indexes
        finish attempt 300
        equal "${status}" 0 'the clone exit status'
        equal "$(stmt_count 'd2: CREATE INDEX ix_' "${TMPDIR}/attempt.log")" "${n}" 'index statements in d2'
        equal "$(stmt_count 'd2: VACUUM ANALYZE public\.ix_[0-9]+;' "${TMPDIR}/attempt.log")" "${n}" 'VACUUM statements in d2'
        echo "PASS [${name}]: ${n} indexes and VACUUMs of d2 drain through the global queues"
        ;;

    constraint-orphan)
        # killed while the ALTER TABLE adding cx_excl waits, before cx_pkey;
        # its backend outlives the run and commits once the gate opens
        reset
        sql source d2 "${gates};
            create table cx(id integer not null, val integer not null);
            insert into cx select g, g % 100 from generate_series(1, 1000) g;
            alter table cx add constraint cx_excl exclude using btree (gate_key(id) with =);
            alter table cx add constraint cx_pkey primary key (id);
            analyze"
        hold_gate d2
        start_clone attempt --defer-indexes --index-jobs 1
        poll 'the ALTER TABLE adding cx_excl to wait on the gate' alter_waits cx_excl
        orphan_clone
        equal "$(sqlite d2 "select count(*) from s_table_indexes_done d join s_table t on t.oid = d.tableoid
            where t.relname = 'cx'")" 1 'the killed run left the constraint election of cx'
        equal "$(sqlite d2 "select group_concat(c.conname || ' done=' || (s.done_time_epoch is not null), ', ')
            from summary s join s_constraint c on c.oid = s.conoid")" 'cx_excl done=0' 'constraints the killed run started'
        equal "$(sql target d2 "select count(*) from pg_constraint where conrelid = 'public.cx'::regclass
            and conname = 'cx_excl'")" 1 'cx_excl committed on the target after the kill'
        start_clone resume --defer-indexes --index-jobs 1 --resume --not-consistent
        finish resume 180
        equal "${status}" 0 'the resume exit status'
        same d2 cx
        equal "$(stmt_count 'ALTER TABLE public\.cx ADD CONSTRAINT cx_excl ' "${TMPDIR}/resume.log")" 0 'the resume adds cx_excl'
        equal "$(stmt_count 'Skipping constraint cx_excl on public\.cx: found on the target database' "${TMPDIR}/resume.log")" 1 \
            'the resume finds cx_excl on the target'
        equal "$(stmt_count 'ALTER TABLE public\.cx ADD CONSTRAINT cx_pkey ' "${TMPDIR}/resume.log")" 1 'the resume adds cx_pkey'
        equal "$(stmt_count 'VACUUM ANALYZE public\.cx[;,]' "${TMPDIR}/resume.log")" 1 'the resume vacuums cx'
        equal "$(sqlite d2 "select group_concat(d, ', ') from (select c.conname || ' done=' || (s.done_time_epoch is not null) as d
            from summary s join s_constraint c on c.oid = s.conoid order by 1)")" 'cx_excl done=1, cx_pkey done=1' \
            'constraints done after the resume'
        echo "PASS [${name}]: a deferred resume finds d2.cx_excl on the target and adds only cx_pkey"
        ;;

    d3order)
        # one index worker takes the queue in order: largest table first across
        # databases, so d1.tiny, the smallest, comes after every index of d2
        reset
        sql source d1 "create table tiny(id integer primary key);
            insert into tiny select generate_series(1, 10);
            create table big(id integer primary key, payload text not null);
            insert into big select g, repeat(md5(g::text), 2) from generate_series(1, 200000) g;
            analyze"
        sql source d2 "create table small(id integer not null, val integer not null);
            insert into small select g, g % 100 from generate_series(1, 1000) g;
            create index small_val on small (val);
            alter table small add primary key (id);
            create table big2(id integer primary key);
            insert into big2 select generate_series(1, 200000);
            analyze"
        start_clone attempt --defer-indexes --index-jobs 1
        finish attempt 180
        equal "${status}" 0 'the clone exit status'
        order=$({ grep -oE "[a-z_0-9]+: ${index_stmt}" "${TMPDIR}/attempt.log" || true; } | awk '{ print $1 $(NF - 1) }' | paste -sd ' ' -)
        equal "${order}" 'd1:big_pkey d2:big2_pkey d2:small_val d2:small_pkey d1:tiny_pkey' 'index build order'
        echo "PASS [${name}]: the deferred step builds indexes largest table first across databases"
        ;;
esac
