#! /bin/bash

# Receive must keep its walsender alive while every spool COMMIT is slow.
# strace delays each fsync; with a 10s status interval and a 4s
# wal_sender_timeout, the source ended every session before flush was reported.

set -euxo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-status-interval.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid='' receive_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    pkill -TERM -x pgcopydb 2>/dev/null || true
    for pid in "${receive_pid}" "${snapshot_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }

pgcopydb ping
source_sql 'drop table if exists slow; create table slow (id integer primary key)'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" &
snapshot_pid=$!
deadline=$((SECONDS + 60))
until test -s "${TMPDIR}/snapshot.out"; do
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
pgcopydb stream setup
pgcopydb clone --drop-if-exists
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}" || true
snapshot_pid=

slot="from pg_replication_slots where slot_name = 'pgcopydb'"
start_lsn=$(source_sql "select confirmed_flush_lsn ${slot}")

# one spool COMMIT, and so one delayed fsync, per source transaction
seq 1 2000 | sed 's/.*/insert into slow values (&);/' |
    psql -qX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}"

strace -f -qq --seccomp-bpf -o /dev/null \
    -e trace=fsync,fdatasync -e inject=fsync,fdatasync:delay_exit=200000 \
    pgcopydb stream receive --resume >"${TMPDIR}/receive.log" 2>&1 &
receive_pid=$!

# fail on the first ended session rather than wait for the deadline
interrupted() { grep 'Streaming got interrupted' "${TMPDIR}/receive.log"; }
first_pid='' advanced=f
deadline=$((SECONDS + 90))
while test "${advanced}" != t; do
    kill -0 "${receive_pid}"
    if interrupted; then
        echo "FAIL: the source ended the receive session"
        exit 1
    fi
    IFS='|' read -r pid advanced < <(source_sql \
        "select active_pid, confirmed_flush_lsn > '${start_lsn}' ${slot}")
    # the receive only notices an ended session once it drains its socket
    first_pid=${first_pid:-${pid}}
    if test "${pid}" != "${first_pid}"; then
        echo "FAIL: the walsender changed from ${first_pid} to '${pid}'"
        exit 1
    fi
    if test "${SECONDS}" -ge "${deadline}"; then
        echo "FAIL: confirmed_flush_lsn stayed at ${start_lsn}"
        exit 1
    fi
    sleep 0.5
done

grep -q 'Sending standby status every 2000 ms' "${TMPDIR}/receive.log"
if interrupted; then
    exit 1
fi

pkill -TERM -x pgcopydb
wait "${receive_pid}" || true
receive_pid=

pgcopydb stream cleanup
echo "PASS: confirmed_flush_lsn moved past ${start_lsn} on one walsender session"
