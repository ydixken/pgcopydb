#! /bin/bash

# Receive must survive a stream the server closes while it drains at endpos.
# GDB holds receive after it reached endpos and before it sends CopyDone,
# until wal_sender_timeout closes the walsender. The drain then reads EOF.

set -euxo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-drain-error.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid= debugger_pid=

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    for pid in "${debugger_pid}" "${snapshot_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }

# wait_for <description> <command...>: poll with a deadline
wait_for() {
    local description=$1 deadline=$((SECONDS + 60))
    shift
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || { echo "FAIL: timed out: ${description}"; return 1; }
        sleep 0.1
    done
}

pgcopydb ping
source_sql 'drop table if exists drain; create table drain (id integer primary key, v text)'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" &
snapshot_pid=$!
wait_for 'exported snapshot' test -s "${TMPDIR}/snapshot.out"
pgcopydb stream setup
pgcopydb clone --drop-if-exists
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}" || true
snapshot_pid=

source_sql "insert into drain select i, md5(i::text) from generate_series(1, 100) i"
endpos=$(source_sql 'select pg_current_wal_flush_lsn()')
source_sql "insert into drain values (101, 'after endpos')"

barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
timeout 120s gdb -q -batch \
    -ex "set \$barrier_dir = \"${barrier_dir}\"" \
    -x /usr/src/pgcopydb/hold-at-endpos.gdb \
    --args pgcopydb stream receive --resume --endpos "${endpos}" >"${TMPDIR}/receive.log" 2>&1 &
debugger_pid=$!
wait_for 'receive held at endpos' test -s "${barrier_dir}/paused"

walsender_gone() {
    kill -0 "${debugger_pid}"
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 0
}
wait_for 'wal_sender_timeout closes the stream' walsender_gone
touch "${barrier_dir}/release"

status=0
wait "${debugger_pid}" || status=$?
debugger_pid=
cat "${TMPDIR}/receive.log"

# Without this line the drain never met the closed stream and nothing was tested.
grep -q 'could not read COPY data' "${TMPDIR}/receive.log"
test "${status}" -eq 0
grep -q 'stopping: endpos is' "${TMPDIR}/receive.log"

pgcopydb stream cleanup
echo "PASS: receive reconnected after the stream closed during the endpos drain"
