#! /bin/bash

# Apply runs live (no endpos) behind a receive that has already closed
# several output.db files.  Receive rotates after every COMMIT and spools a
# KEEPALIVE between transactions, so each closed file hands apply a marker
# before its transaction: apply must not leave the file before applying it.

set -euo pipefail

txns=6
export TMPDIR=/tmp/pgcopydb-rotation-live
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid='' prefetch_pid='' catchup_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${catchup_pid}" || kill -KILL -- "-${catchup_pid}" 2>/dev/null || true
    test -z "${prefetch_pid}" || kill -KILL -- "-${prefetch_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 60 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
verify() { python3 /usr/src/pgcopydb/verify.py "$1"; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
pretty() { printf '%X/%X' $(($1 >> 32)) $(($1 & 4294967295)); }

# runs $1 on every output.db; receive may be creating or writing the newest
spool() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" "$1" || true
    done
}

spooled() {
    commit_lsn=$(spool "select lsn from output where action = 'C' and xid = $1")
    test -n "${commit_lsn}"
}

marker_after() {
    test -n "$(spool "select 1 from output where action = 'K' and lsn >= $1 limit 1")"
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}

alive() {
    local pid
    for pid in "${prefetch_pid}" "${catchup_pid}"; do
        test -z "${pid}" || kill -0 "${pid}" 2>/dev/null || return 1
    done
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        alive || fail "pgcopydb exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# wait_exit <pid> <what>: no new WAL means no keepalive to stop receive at
# endpos, so emit a message that pgoutput does not publish while waiting
wait_exit() {
    local deadline=$((SECONDS + 120)) rc=0
    while kill -0 "$1" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "$2 did not stop at endpos ${endpos}"
        source_sql "select pg_logical_emit_message(false, 'cdc-file-rotation-live', 'past endpos')" > /dev/null
        sleep 1
    done
    wait "$1" || rc=$?
    test "${rc}" = 0 || fail "$2 exited ${rc}"
}

pgcopydb ping
source_sql 'drop table if exists rotation_live; create table rotation_live (id integer primary key, txn integer not null, payload text not null)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=

# live receive, rotating after every COMMIT
setsid pgcopydb stream prefetch --resume --notice --max-replaydb-size 1kB > "${TMPDIR}/prefetch.log" 2>&1 &
prefetch_pid=$!
poll 'the slot to be streamed' 60 slot_active

# Receive flushes every 10 s and spools a KEEPALIVE when it does.  Waiting
# for one after each COMMIT puts it in the next file, before that file's
# transaction.
for i in $(seq 1 "${txns}"); do
    xid=$(source_sql "begin; select txid_current(); insert into rotation_live select g, ${i}, md5(g::text) from generate_series(${i} * 10 - 9, ${i} * 10) g; commit")
    poll "the COMMIT of transaction ${i} in the spool" 60 spooled "${xid}"
    poll "a KEEPALIVE after transaction ${i}" 60 marker_after "${commit_lsn}"
    echo "transaction ${i}: xid ${xid}, COMMIT at $(pretty "${commit_lsn}"), KEEPALIVE spooled after it"
done
endpos=$(source_sql 'select pg_current_wal_flush_lsn()')

verify markers-before-commits

last=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list \
    "${TMPDIR}/pgcopydb/schema/source.db" \
    "select filename from cdc_files where done_time_epoch is null")
test -n "${last}" -a "$(wc -l <<<"${last}")" = 1 || fail "expected one open output.db, got: ${last}"

# apply starts with no endpos, and receive keeps streaming
test "$(pgcopydb stream sentinel get --endpos)" = 0/0 || fail 'the sentinel has an endpos before the test set one'
pgcopydb stream sentinel set apply > "${TMPDIR}/sentinel.log" 2>&1
setsid pgcopydb stream catchup --resume --notice > "${TMPDIR}/catchup.log" 2>&1 &
catchup_pid=$!

reached_last() { grep -qF "Apply advanced to outputDB \"${last}\"" "${TMPDIR}/catchup.log"; }
poll 'apply to open the last output.db' 120 reached_last
grep -F 'Apply advanc' "${TMPDIR}/catchup.log"

# only now may apply learn the endpos, and drain to it
pgcopydb stream sentinel set endpos "${endpos}" >> "${TMPDIR}/sentinel.log" 2>&1
wait_exit "${prefetch_pid}" prefetch
prefetch_pid=
wait_exit "${catchup_pid}" catchup
catchup_pid=

verify rows

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: live apply kept every transaction of ${txns} rotated output.db files"
