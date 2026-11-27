#! /bin/bash

# The walsender prints every value with the settings of its own session, and a
# role or database setting changes them.  The raw spool keeps that text, so in
# performance mode receive pins five settings on the replication connection:
# the key text of one row must then stay the same across a reconnect that
# brings other settings.  sqlite mode keeps the connection of 9d8b660, whose
# text does change, and that run is what makes the pin a real rule.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
src() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }

receive_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${receive_pid}" || kill -KILL -- "-${receive_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR:-/tmp}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

# until_true <seconds> <what> <command...>
until_true() {
    local deadline=$((SECONDS + $1)) what=$2
    shift 2
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || fail "${what}"
        sleep 1
    done
}

lsn() { echo $(((16#${1%/*} << 32) + 16#${1#*/})); }

written_past() {
    local w
    w=$(timeout 15s pgcopydb stream sentinel get --write-lsn) || return 1
    test "$(lsn "${w}")" -ge "$(lsn "$1")"
}

walsender() { src "select coalesce(active_pid, 0) from pg_replication_slots where slot_name = 'pgcopydb'"; }
other_walsender() { local p; p=$(walsender); test "${p}" != 0 && test "${p}" != "$1"; }

# receive <tag>: stream receive in its own session group, in the background
receive() {
    setsid pgcopydb stream receive --resume --notice > "${TMPDIR}/$1.log" 2>&1 &
    receive_pid=$!
}

# wait_receive <tag> <seconds>: the background receive must exit 0
wait_receive() {
    local deadline=$((SECONDS + $2)) rc=0
    while kill -0 "${receive_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "$1: receive did not exit within $2 s"
        sleep 0.2
    done
    wait "${receive_pid}" || rc=$?
    receive_pid=''
    test "${rc}" = 0 || fail "$1: receive exited ${rc}"
}

# distinct <file> <pattern>: the distinct quoted values that match, with their
# counts, one per line
distinct() { grep -o "'[^']*'" "$1" | grep -E "$2" | sort | uniq -c || true; }

# check_pin <mode> <column> <distinct values>: one text in performance mode,
# and more than one in sqlite mode, which is what makes the pin a rule
check_pin() {
    local lines
    lines=$(wc -l <<<"$3")
    if test "$1" = performance; then
        test "${lines}" = 1 || fail "performance: the $2 key text changed across the reconnect"
    else
        test "${lines}" -ge 2 || fail "sqlite: the $2 key text did not change across the reconnect"
    fi
}

# run_case <mode>: one row written before a reconnect and changed after it,
# and the key text that stdout apply prints for both changes
run_case() {
    local mode=$1 ins endpos sender ts b
    TMPDIR=$(mktemp -d "/tmp/pgcopydb-spool-settings-${mode}.XXXXXX")
    export TMPDIR XDG_DATA_HOME="${TMPDIR}/cdc" PGCOPYDB_FOLLOW_MODE="${mode}"
    echo "=== ${mode}"

    src "alter database $(src 'select current_database()') reset timezone"
    src "alter database $(src 'select current_database()') reset bytea_output"
    src "alter role $(src 'select current_user') reset timezone"
    src "alter role $(src 'select current_user') reset bytea_output"
    src 'drop table if exists s'
    src 'create table s (ts timestamptz, b bytea, v integer, primary key (ts, b))'

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    local snapshot_pid=$!
    until_true 60 'snapshot --follow printed no snapshot' test -s "${TMPDIR}/snapshot.out"
    pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
    pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}"

    # the INSERT is decoded and stored with the settings the source starts with
    src "insert into s values ('2026-03-04 05:06:07+00', '\\x0102', 1)"
    ins=$(src 'select pg_current_wal_insert_lsn()')
    receive insert
    until_true 120 "receive did not write past the INSERT at ${ins}" written_past "${ins}"
    kill -TERM "${receive_pid}"
    wait_receive insert 60

    src "alter database $(src 'select current_database()') set timezone = 'America/New_York'"
    src "alter database $(src 'select current_database()') set bytea_output = 'escape'"
    src "alter role $(src 'select current_user') set timezone = 'America/New_York'"
    src "alter role $(src 'select current_user') set bytea_output = 'escape'"

    # vacuity: a session that starts now takes the changed settings
    test "$(src 'show timezone')|$(src 'show bytea_output')" = 'America/New_York|escape' ||
        fail "a fresh source session shows $(src 'show timezone') and $(src 'show bytea_output')"

    # the UPDATE is decoded by a walsender that the reconnect started
    receive update
    until_true 120 'no walsender for the second receive' other_walsender 0
    sender=$(walsender)
    src "select pg_terminate_backend(${sender})" > /dev/null
    until_true 120 "receive did not reconnect after walsender ${sender} ended" \
               other_walsender "${sender}"
    src 'update s set v = 2'
    endpos=$(src 'select pg_current_wal_insert_lsn()')
    pgcopydb stream sentinel set endpos "${endpos}"
    wait_receive update 180

    timeout -s KILL 60 pgcopydb stream apply --target - \
        > "${TMPDIR}/apply.sql" 2> "${TMPDIR}/apply.log"
    grep '^EXECUTE ' "${TMPDIR}/apply.sql" > "${TMPDIR}/execute.sql" ||
        fail "${mode}: stdout apply printed no EXECUTE line"
    cat "${TMPDIR}/execute.sql"

    ts=$(distinct "${TMPDIR}/execute.sql" "^'2026-03-0")
    b=$(distinct "${TMPDIR}/execute.sql" "^'[\\]")
    printf '%s: timestamptz key text:\n%s\n%s: bytea key text:\n%s\n' "${mode}" "${ts}" "${mode}" "${b}"

    # vacuity: both key columns reach the EXECUTE lines, for the INSERT and
    # for the UPDATE, whatever their text is
    for v in "${ts}" "${b}"; do
        test -n "${v}" || fail "${mode}: a key column is missing from the EXECUTE lines"
        test "$(awk '{ n += $1 } END { print n + 0 }' <<<"${v}")" -ge 2 ||
            fail "${mode}: a key value is printed fewer than two times"
    done

    check_pin "${mode}" timestamptz "${ts}"
    check_pin "${mode}" bytea "${b}"

    pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
    echo "PASS [${mode}]"
}

pgcopydb ping

for c in ${CASE:-sqlite}; do
    case "${c}" in
        all) run_case sqlite; run_case performance ;;
        sqlite|performance) run_case "${c}" ;;
        *) fail "unknown case ${c}" ;;
    esac
done
