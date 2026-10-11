#! /bin/bash

# endpos lies after one COMMIT and before the first record of the next
# transaction.  Receive stops at that record without writing it, so no BEGIN
# is open, and apply must still learn that receive is done and exit there.

set -euo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-endpos-before-txn.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid='' follow_pid='' rc=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
rows() { target_sql "select coalesce(string_agg(id::text, ',' order by id), '') from t"; }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', true)"; }
lsn() { echo $(((16#${1%/*} << 32) + 16#${1#*/})); }

# follow_to <tag>: follow to the sentinel endpos, its exit status in rc
follow_to() {
    setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/$1.log" 2>&1 &
    follow_pid=$!
    local deadline=$((SECONDS + 120))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" ||
            fail "$1: follow did not exit at endpos within 120 s, with rows $(rows) on the target"
        sleep 0.2
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    follow_pid=
    echo "$1: follow exited ${rc} with rows $(rows) on the target, origin $(origin)"
    test "${rc}" = 0 || fail "$1: follow exited ${rc}"
}

pgcopydb ping
source_sql 'drop table if exists t; create table t (id integer primary key, v text)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=
pgcopydb stream sentinel set apply

# The CHECKPOINT record is not decoded.  An endpos inside it is past the
# COMMIT of row 1 and before the first record of row 2's transaction.
source_sql "insert into t values (1, 'before')"
commit1=$(source_sql 'select pg_current_wal_insert_lsn()')
source_sql 'checkpoint'
endpos=$(source_sql 'select pg_current_wal_insert_lsn() - 1')
source_sql "insert into t values (2, 'after')"
source_sql "insert into t values (3, 'after')"
echo "COMMIT of row 1 ends at or before ${commit1}, endpos ${endpos}"

# The whole range is in WAL before receive starts, so the walsender sends
# row 2's transaction without a keepalive between it and row 1.
pgcopydb stream sentinel set endpos "${endpos}"
follow_to endpos
test "$(rows)" = 1 || fail "rows $(rows) on the target at endpos, expected 1"
o=$(origin)
test "$(lsn "${o}")" -le "$(lsn "${commit1}")" ||
    fail "origin ${o} is past the COMMIT of row 1, which ends at ${commit1}"

pgcopydb stream sentinel set endpos "$(source_sql 'select pg_current_wal_insert_lsn()')"
follow_to resume
test "$(rows)" = 1,2,3 || fail "rows $(rows) on the target after resume, expected 1,2,3"

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: apply exited at endpos ${endpos} with row 1, then resumed to rows 1,2,3"
