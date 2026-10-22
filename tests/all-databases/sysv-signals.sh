#! /bin/bash

# The SysV queues and semaphores of clone --all-databases after a signal in
# Phase I. A session that holds d3.t on the source keeps Phase I waiting, then
# either the whole run gets SIGTERM or the pre-data supervisor alone gets
# SIGKILL; once every process is gone, no queue or semaphore set is left.

set -euo pipefail

scenario=${1:-all}
scenarios='term kill-supervisor'

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
    term|kill-supervisor) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-sysv-signals/${scenario}
mkdir -p "${TMPDIR}"
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'gate'"

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || sql source postgres "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0 && test -f "${TMPDIR}/clone.log"; then
        echo "==> ${TMPDIR}/clone.log (errors)"
        grep -E ' (ERROR|FATAL) ' "${TMPDIR}/clone.log" | tail -n 20 || true
    fi
    exit "${status}"
}
trap cleanup EXIT

poll() {
    local what=$1 deadline=$((SECONDS + 120))
    shift
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# objects <msg|sem>: the queues or semaphore sets of this IPC namespace; each
# file starts with a header line, and a missing file gives -1
objects() { echo $(($(wc -l <"/proc/sysvipc/$1") - 1)); }
gate_locks() {
    sql source d3 "select count(*) from pg_locks where locktype = 'relation'
        and database = (select oid from pg_database where datname = current_database())
        and relation = 't'::regclass and $1"
}
gate_held() { test "$(gate_locks "granted and mode = 'AccessExclusiveLock'")" = 1; }
phase_one_waits() {
    kill -0 "${clone_pid}" 2>/dev/null || fail "pgcopydb exited before Phase I waited on d3.t"
    test "$(gate_locks 'not granted')" -gt 0
}
clone_gone() { ! kill -0 "${clone_pid}" 2>/dev/null; }
release_gate() {
    sql source postgres "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
}
# a zombie has run its clean-up already; a failed ps lists no process at all
none_running() {
    local procs
    procs=$(ps -e -o stat=,comm=) || fail "ps failed while waiting for every process to exit"
    test "$(awk '$1 !~ /^Z/ && $2 ~ /^(pgcopydb|pg_dump|pg_restore)$/' <<<"${procs}" | wc -l)" = 0
}

for side in source target; do
    sql "${side}" postgres 'drop database if exists d1 with (force)' \
        'drop database if exists d2 with (force)' 'drop database if exists d3 with (force)' >/dev/null
done
for db in d1 d2 d3; do
    sql source postgres "create database ${db}" >/dev/null
    sql source "${db}" 'create table t(id integer primary key)' 'insert into t select generate_series(1, 10)' >/dev/null
done
equal "$(objects msg) $(objects sem)" "0 0" "queues and semaphore sets before the clone"

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
PGAPPNAME=gate psql -AtqX -d "${PGCOPYDB_SOURCE_PGURI%/*}/d3" -c 'begin' \
    -c 'lock table t in access exclusive mode' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
gate_pid=$!
poll 'the gate on d3.t to close' gate_held

setsid pgcopydb clone --all-databases --dir "${TMPDIR}/work" --notice >"${TMPDIR}/clone.log" 2>&1 &
clone_pid=$!
poll 'Phase I to wait on d3.t' phase_one_waits
# $! is known before the child has called setsid(), which it does before it connects
equal "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" "${clone_pid}" "the process group of pgcopydb"
queues=$(objects msg)
echo "while Phase I waits on d3.t: ${queues} queues, $(objects sem) semaphore sets"
test "${queues}" -gt 0 || fail "no queue while Phase I waits on d3.t"

case "${scenario}" in
    term)
        kill -TERM -- "-${clone_pid}"
        echo "sent SIGTERM to the process group of pgcopydb"
        ;;
    # a guard, not a fix check: it passes without the fixes only when it runs
    # alone, and fails when the main process leaves the queue of a killed supervisor
    kill-supervisor)
        supervisor=$(pgrep -f '^pgcopydb: pre-data supervisor') || fail "no pre-data supervisor while Phase I waits"
        kill -KILL "${supervisor}"
        echo "sent SIGKILL to the pre-data supervisor"
        # the main process exits only after the orphaned worker that waits on
        # the gate, which still holds the pipe the snapshot holder reads
        release_gate
        ;;
esac

poll 'pgcopydb to exit' clone_gone
rc=0
wait "${clone_pid}" || rc=$?
echo "pgcopydb exited ${rc}"
test "${rc}" -ne 0 || fail "the interrupted clone exited 0"

test -z "${gate_pid}" || release_gate
poll 'every pgcopydb, pg_dump and pg_restore process to exit' none_running
echo "after every process exited: $(objects msg) queues, $(objects sem) semaphore sets"
ipcs -q -s
equal "$(objects msg) $(objects sem)" "0 0" "queues and semaphore sets after every process exited"
case "${scenario}" in
    term) echo "PASS [${scenario}]: a SIGTERM to the run in Phase I leaves no queue or semaphore set" ;;
    kill-supervisor) echo "PASS [${scenario}]: a guard: a SIGKILL of the pre-data supervisor leaves no queue or semaphore set" ;;
esac
