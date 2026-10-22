#! /bin/bash

# A single-database clone killed once COPY, CREATE INDEX and the sequences are
# done, while its large-object step or its extension configuration data step
# waits on a session that holds the table the step writes, is retried with
# --resume --not-consistent, and the retry has to finish that step; in
# extension-retry a first retry fails in the large-object step. And copy blobs
# --drop-if-exists has to create the large objects that the target lacks.

set -euo pipefail

scenario=${1:-all}
case "${scenario}" in
    all)
        pgcopydb ping
        status=0
        for scenario in large-objects extension-data extension-retry drop; do
            bash "$0" "${scenario}" || status=1
        done
        exit "${status}"
        ;;
    large-objects) gated=(pg_catalog.pg_largeobject) ;;
    extension-data) gated=(public.cfgdump_settings) ;;
    extension-retry) gated=(public.cfgdump_settings pg_catalog.pg_largeobject) ;;
    drop) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-large-objects-resume/${scenario}
workdir=${TMPDIR}/work
catalog=${workdir}/schema/source.db
mkdir -p "${TMPDIR}"
args=(--dir "${workdir}" --source "${PGCOPYDB_SOURCE_PGURI%/*}/d1"
    --target "${PGCOPYDB_TARGET_PGURI%/*}/d1" --notice)
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name <> 'gate'"

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
# an empty value is a query that failed, never a match
equal() { test -n "$2" && test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
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
sqlite() {
    test -f "${catalog}" || return 1
    timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list "${catalog}" "$1"
}

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || sql target postgres "${free_gate}" >/dev/null 2>&1 || true
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

lo="select count(*) || ' objects, ' || coalesce(sum(length(lo_get(oid))), 0) || ' bytes, md5 ' ||
      md5(coalesce(string_agg(oid || ':' || md5(lo_get(oid)), ',' order by oid), '')) from pg_largeobject_metadata"
cfg="select string_agg(id || ' ' || val, ', ' order by id) || '; cfgdump_seq ' ||
      (select last_value || ' ' || is_called from cfgdump_seq) from cfgdump_settings"

# the gated tables, as lock table and a regclass[] literal take them
tables() { local IFS=,; echo "${gated[*]}"; }
# gate_locks <condition>: how many gated tables of d1 on the target have such a lock
gate_locks() {
    sql target d1 "select count(distinct relation) from pg_locks where locktype = 'relation'
        and database = (select oid from pg_database where datname = current_database())
        and relation = any('{$(tables)}'::regclass[]) and $1"
}
gate_held() { test "$(gate_locks "granted and mode = 'AccessExclusiveLock'")" = "${#gated[@]}"; }
gate_open() { test "$(gate_locks 'true')" = 0; }
step_waits() { test "$(gate_locks 'not granted')" = "${#gated[@]}"; }
blobs_done() {
    test "$(sqlite "select count(*) from timings where label = 'Large Objects (cumulative)'
        and done_time_epoch is not null")" = 1
}
# the resume skips the data step only once these three are done
steps_done() {
    test "$(sqlite "select count(*) from timings where done_time_epoch is not null
        and label in ('COPY (cumulative)', 'CREATE INDEX (cumulative)', 'Reset Sequences')")" = 3
}
run_gone() { test "$(sql target postgres "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"; }

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI%/*}/d1" -c 'begin' \
        -c "lock table $(tables) in access exclusive mode" \
        -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
    gate_pid=$!
    poll 'the gate to close' gate_held
}

release_gate() {
    sql target postgres "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
    poll 'the gate to open' gate_open
}

for side in source target; do
    sql "${side}" postgres 'drop database if exists d1 with (force)' 'create database d1'
done
sql source d1 'create table t(id integer primary key)' 'insert into t select generate_series(1, 100)' \
    "select count(lo_from_bytea(n, convert_to('in d1 as ' || n, 'UTF8'))) from generate_series(7101, 7110) n" \
    'create extension cfgdump' "insert into cfgdump_settings values (101, 'user 101'), (102, 'user 102')" \
    "select setval('cfgdump_seq', 42)" >/dev/null
# the gate needs the table before the clone, whose pre-data step keeps an
# extension that exists on the target
case "${scenario}" in
    extension-*) sql target d1 'create extension cfgdump' ;;
esac

# lo_unlink of an object that does not exist aborts the worker's transaction;
# the target has 7101 with other content and none of the other nine
if test "${scenario}" = drop; then
    sql target d1 "select lo_from_bytea(7101, convert_to('on the target, and longer', 'UTF8'))" >/dev/null
    # copy blobs reads the catalog that dump schema writes, as in tests/blobs
    rc=0
    timeout -k 10s 120s pgcopydb dump schema --source "${PGCOPYDB_SOURCE_PGURI%/*}/d1" --dir "${workdir}" \
        >"${TMPDIR}/dump.log" 2>&1 || rc=$?
    equal "${rc}" 0 'the dump schema exit status'
    rc=0
    timeout -k 10s 120s pgcopydb copy blobs "${args[@]}" --resume --not-consistent --drop-if-exists \
        >"${TMPDIR}/drop.log" 2>&1 || rc=$?
    equal "${rc}" 0 'the copy blobs --drop-if-exists exit status'
    equal "$(sql target d1 "${lo}")" "$(sql source d1 "${lo}")" 'd1 large objects on the target'
    echo "PASS [${scenario}]: copy blobs --drop-if-exists replaces 7101 and creates the nine objects the target lacks"
    exit 0
fi

hold_gate
setsid pgcopydb clone "${args[@]}" >"${TMPDIR}/attempt.log" 2>&1 &
clone_pid=$!
# $! is known before the child has called setsid()
poll 'pgcopydb to own its process group' own_group
poll "writes to $(tables) to wait on the gate" step_waits
poll 'COPY, CREATE INDEX and the sequences to be done' steps_done
for table in "${gated[@]}"; do
    case "${table}" in
        pg_catalog.pg_largeobject)
            equal "$(sqlite "select count(*) from timings where label = 'Large Objects (cumulative)'
                and done_time_epoch is null")" 1 'the killed run left the large-object step unfinished'
            ;;
        public.cfgdump_settings)
            equal "$(sqlite 'select count(*) from summary where extoid is not null and done_time_epoch is null')" 1 \
                'the killed run left the cfgdump data unfinished'
            ;;
    esac
done
# here the large-object step runs free and finishes, so the resume skips it
test "${scenario}" != extension-data || poll 'the large-object step to finish' blobs_done

# a backend that waits on the gate never reads its socket, so end it
kill -KILL -- "-${clone_pid}"
wait "${clone_pid}" || true
clone_pid=
sql target postgres "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
poll 'the killed run to leave the target' run_gone
release_gate
echo "killed the run while writes to $(tables) waited on the gate"

# the first retry copies the cfgdump data, then fails on the held table; the
# next retry has to find that data done and not copy it again
if test "${scenario}" = extension-retry; then
    sql target postgres "alter database d1 set lock_timeout = '2s'" >/dev/null
    gated=(pg_catalog.pg_largeobject)
    hold_gate
    rc=0
    timeout -k 10s 90s pgcopydb clone "${args[@]}" --resume --not-consistent >"${TMPDIR}/retry.log" 2>&1 || rc=$?
    release_gate
    sql target postgres 'alter database d1 reset lock_timeout' >/dev/null
    equal "$(sql target d1 "${cfg}")" "$(sql source d1 "${cfg}")" 'd1 cfgdump data on the target after the first retry'
    equal "${rc}" 12 'the first retry exit status, with pg_largeobject held'
    echo "the first retry copied the cfgdump data, then failed on the held pg_largeobject"
fi

rc=0
timeout -k 10s 180s pgcopydb clone "${args[@]}" --resume --not-consistent >"${TMPDIR}/resume.log" 2>&1 || rc=$?
equal "${rc}" 0 'the resume exit status'
equal "$(sql target d1 "${lo}")" "$(sql source d1 "${lo}")" 'd1 large objects on the target'
equal "$(sql target d1 "${cfg}")" "$(sql source d1 "${cfg}")" 'd1 cfgdump_settings rows and cfgdump_seq on the target'
if test "${scenario}" = extension-data; then
    grep -q 'Skipping large objects, already done on a previous run' "${TMPDIR}/resume.log" ||
        fail 'the resume did not skip the finished large-object step'
    ! grep -qE 'Added [0-9]+ large objects' "${TMPDIR}/resume.log" || fail 'the resume copied the large objects again'
fi
echo "PASS [${scenario}]: the resume leaves the large objects and the cfgdump data equal to the source"
