#! /bin/bash

# The large-object step of clone --all-databases on a resume, on a failure and
# with the skip flags, and --skip-extensions against an extension filter. A
# session that holds pg_largeobject in one database of the target stops object
# writes there, and not object creation, so the run can be killed in that step
# or every one of its workers can fail.

set -euo pipefail

scenario=${1:-all}
scenarios='resume shrink hang skip contradiction'

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
# an empty value is a query that failed, never a match
equal() { test -n "$2" && test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
differ() { test -n "$1" && test "$1" != "$2" || fail "$3: expected anything but $2, actual=$1"; }
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
        exit "${status}"
        ;;
    resume|shrink|hang|skip|contradiction) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-lo-resume/${scenario}
workdir=${TMPDIR}/work
mkdir -p "${TMPDIR}"
args=(--all-databases --dir "${workdir}" --notice)
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"
others="backend_type = 'client backend' and pid <> pg_backend_pid() and application_name <> 'gate'"

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
lo_bytes="select coalesce(sum(length(lo_get(oid))), 0) from pg_largeobject_metadata"
cfg="select string_agg(id || ' ' || val, ', ' order by id) from cfgdump_settings"
cfgdump="select count(*) from pg_extension where extname = 'cfgdump'"

# gate_locks <database> <condition>: pg_largeobject locks in that database of
# the target; pg_locks lists every database, and pg_largeobject has one oid
gate_locks() {
    sql target "$1" "select count(*) from pg_locks where locktype = 'relation'
        and database = (select oid from pg_database where datname = current_database())
        and relation = 'pg_catalog.pg_largeobject'::regclass and $2"
}
gate_held() { test "$(gate_locks "$1" "granted and mode = 'AccessExclusiveLock'")" = 1; }
gate_open() { test "$(gate_locks "$1" 'true')" = 0; }
lo_step_waits() { test "$(gate_locks "$1" 'not granted')" -gt 0; }
run_gone() { test "$(sql target postgres "select count(*) from pg_stat_activity where ${others}")" = 0; }
own_group() { test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"; }

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI%/*}/$1" -c 'begin' \
        -c 'lock table pg_catalog.pg_largeobject in access exclusive mode' \
        -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
    gate_pid=$!
    poll "the gate in $1 to close" gate_held "$1"
}

release_gate() {
    sql target postgres "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
    poll "the gate in $1 to open" gate_open "$1"
}

# reset <side>...: d1 and d2 empty, no object in postgres; d1 and d2 exist on
# the target, so the gate can connect there before the clone reaches them
reset() {
    local side
    for side in "$@"; do
        sql "${side}" postgres 'drop database if exists d1 with (force)' 'drop database if exists d2 with (force)' \
            'select count(lo_unlink(oid)) from pg_largeobject_metadata' 'create database d1' 'create database d2' >/dev/null
    done
}

seed() {
    sql source postgres "select lo_from_bytea(7001, convert_to('in postgres', 'UTF8'))" >/dev/null
    sql source d1 'create table t(id integer primary key)' 'insert into t select generate_series(1, 100)' \
        "select lo_from_bytea(7101, convert_to('in d1', 'UTF8'))" \
        "select lo_from_bytea(7102, decode(repeat('cd', 300000), 'hex'))" \
        'create extension cfgdump' "insert into cfgdump_settings values (101, 'user 101'), (102, 'user 102')" >/dev/null
    sql source d2 'create table t(id integer primary key)' 'insert into t select generate_series(1, 100)' \
        "select lo_from_bytea(n, convert_to('in d2 as ' || n, 'UTF8')) from generate_series(7201, 7210) n" >/dev/null
}

# a run whose large-object workers all fail has to exit, and fail
if test "${scenario}" = hang; then
    reset source target
    # more objects than the supervisor's queue holds, which fills at about 230
    sql source d1 'create table t(id integer primary key)' \
        "select count(lo_from_bytea(n, convert_to('in d1 as ' || n, 'UTF8'))) from generate_series(100001, 101000) n" >/dev/null
    sql target postgres "alter database d1 set lock_timeout = '2s'"
    hold_gate d1
    echo "the target's d1 has lock_timeout 2s, and a session holds pg_largeobject there"
    rc=0
    timeout -k 10s 60s pgcopydb clone "${args[@]}" >"${TMPDIR}/attempt.log" 2>&1 || rc=$?
    release_gate d1
    case "${rc}" in
        0) fail "the clone exit status: expected a failure of the large-object step of d1, actual=0" ;;
        124|137) fail "the clone still ran at its 60 s deadline: exit status ${rc}" ;;
    esac
    grep -qE ' (ERROR|FATAL) .*canceling statement due to lock timeout' "${TMPDIR}/attempt.log" ||
        fail "the clone exited ${rc} before a large-object write of d1 timed out"
    echo "PASS [${scenario}]: the clone exits ${rc} when every large-object worker of d1 fails"
    exit 0
fi

# a guard, not a fix check: each skip flag applies to every database
if test "${scenario}" = skip; then
    reset source target
    seed
    sql source d2 'create extension cfgdump' "insert into cfgdump_settings values (101, 'user d2')" >/dev/null
    rc=0
    timeout -k 10s 180s pgcopydb clone "${args[@]}" --skip-large-objects >"${TMPDIR}/skip-large-objects.log" 2>&1 || rc=$?
    equal "${rc}" 0 "the --skip-large-objects clone exit status"
    for db in postgres d1 d2; do
        differ "$(sql source "${db}" "${lo_bytes}")" 0 "${db} large object bytes on the source"
        equal "$(sql target "${db}" "${lo_bytes}")" 0 "${db} large object bytes on the target after --skip-large-objects"
    done
    for db in d1 d2; do
        equal "$(sql target "${db}" 'select count(*) from t')" 100 "${db}.t rows on the target after --skip-large-objects"
    done

    reset target
    rm -rf "${workdir}"
    rc=0
    timeout -k 10s 180s pgcopydb clone "${args[@]}" --skip-extensions >"${TMPDIR}/skip-extensions.log" 2>&1 || rc=$?
    equal "${rc}" 0 "the --skip-extensions clone exit status"
    for db in d1 d2; do
        equal "$(sql source "${db}" "${cfgdump}")" 1 "${db} cfgdump extensions on the source"
        equal "$(sql target "${db}" "${cfgdump}")" 0 "${db} cfgdump extensions on the target after --skip-extensions"
        equal "$(sql target "${db}" 'select count(*) from t')" 100 "${db}.t rows on the target after --skip-extensions"
    done
    echo "PASS [${scenario}]: a guard: --skip-large-objects and --skip-extensions apply to every database"
    exit 0
fi

# a single-database clone refuses this pair only at its extension data step,
# which under --all-databases comes after the COPY of every database
if test "${scenario}" = contradiction; then
    reset source target
    seed
    printf '%s\n' '[include-only-extension]' 'cfgdump' >"${TMPDIR}/filters.ini"
    rc=0
    timeout -k 10s 180s pgcopydb clone "${args[@]}" --skip-extensions --filters "${TMPDIR}/filters.ini" \
        >"${TMPDIR}/contradiction.log" 2>&1 || rc=$?
    equal "${rc}" 1 "the --skip-extensions clone with [include-only-extension] exit status"
    grep -q 'contradictory; use one or the other' "${TMPDIR}/contradiction.log" ||
        fail "the clone exited 1 without the contradiction error"
    if grep -q 'Phase I:' "${TMPDIR}/contradiction.log"; then
        fail "the clone started Phase I before it refused the options"
    fi
    equal "$(sql target d1 "select count(*) from pg_class where relname = 't'")" 0 \
        "d1.t on the target after the refused clone"

    rm -rf "${workdir}"
    rc=0
    timeout -k 10s 180s pgcopydb clone "${args[@]}" --filters "${TMPDIR}/filters.ini" >"${TMPDIR}/include.log" 2>&1 || rc=$?
    equal "${rc}" 0 "the [include-only-extension] clone exit status"
    equal "$(sql target d1 "${cfg}")" "1 shipped 1, 2 shipped 2, 3 shipped 3, 101 user 101, 102 user 102" \
        "d1 cfgdump_settings rows on the target after [include-only-extension]"
    echo "PASS [${scenario}]: --skip-extensions with [include-only-extension] fails before Phase I, the filter alone copies the rows"
    exit 0
fi

reset source target
seed
hold_gate d2
setsid pgcopydb clone "${args[@]}" >"${TMPDIR}/attempt.log" 2>&1 &
clone_pid=$!
# $! is known before the child has called setsid()
poll 'pgcopydb to own its process group' own_group
poll "the large-object step of d2 to wait on the gate" lo_step_waits d2

# Phase III runs one database at a time in name order, so d1 is done
equal "$(sql target d1 "${lo}")" "$(sql source d1 "${lo}")" "d1 large objects on the target before the kill"
equal "$(sql target d1 "${cfg}")" "$(sql source d1 "${cfg}")" "d1 cfgdump_settings rows on the target before the kill"

# a backend that waits on the gate never reads its socket, so end it
kill -KILL -- "-${clone_pid}"
wait "${clone_pid}" || true
clone_pid=
sql target postgres "select count(pg_terminate_backend(pid)) from pg_stat_activity where ${others}" >/dev/null
poll 'the killed run to leave the target' run_gone
release_gate d2
echo "killed the run while the large-object step of d2 waited on the gate"
# with pg_dump 16 the pre-data step created d2's objects empty; 18 does not
differ "$(sql target d2 "${lo}")" "$(sql source d2 "${lo}")" "d2 large objects on the target after the kill"

case "${scenario}" in
    # no pre-data step created 7103 on the target, so the resume has to
    resume)
        sql source d1 "select lo_from_bytea(7103, convert_to('after the kill', 'UTF8'))" >/dev/null
        echo "created object 7103 in d1 on the source after the kill"
        ;;
    # the resume writes 7102 again from offset 0, over its old 300000 bytes
    shrink)
        sql source d1 "select lo_truncate(lo_open(7102, x'60000'::integer), 100)" >/dev/null
        equal "$(sql source d1 'select length(lo_get(7102))')" 100 "7102 bytes in d1 on the source after the shrink"
        echo "shrank object 7102 of d1 on the source from 300000 to 100 bytes after the kill"
        ;;
esac

rc=0
timeout -k 10s 180s pgcopydb clone "${args[@]}" --resume --not-consistent >"${TMPDIR}/resume.log" 2>&1 || rc=$?
equal "${rc}" 0 "the resume exit status"

for db in d1 d2 postgres; do
    equal "$(sql target "${db}" "${lo}")" "$(sql source "${db}" "${lo}")" "${db} large objects on the target"
done
equal "$(sql target d1 "${cfg}")" "1 shipped 1, 2 shipped 2, 3 shipped 3, 101 user 101, 102 user 102" \
    "d1 cfgdump_settings rows on the target"
equal "$(grep -cE 'Added [0-9]+ large objects to the queue' "${TMPDIR}/resume.log" || true)" 3 \
    "large-object steps in the resume"
grep -E 'Added [0-9]+ large objects to the queue' "${TMPDIR}/resume.log" |
    sed -E 's/^.* INFO +[a-z_-]+\.c:[0-9]+ +/  resume: /'
case "${scenario}" in
    resume) echo "PASS [${scenario}]: the resume copies the large objects of every database, 7103 included" ;;
    shrink) echo "PASS [${scenario}]: the resume leaves 7102 of d1 as short as on the source" ;;
esac
