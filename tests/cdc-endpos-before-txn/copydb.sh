#! /bin/bash

# endpos lies after one COMMIT and before the first record of the next
# transaction.  Receive stops at that record without writing it, so no BEGIN
# is open, and apply must still learn that receive is done and exit there.
# Then endpos is raised while receive still holds the old one: receive must
# stream on to the new endpos instead of stopping, or reporting it reached.

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

# Receive reads the sentinel endpos when it flushes, every 10 s while idle.
# Raise endpos right after one such read, so receive still holds the old one
# when WAL first passes it.  The old endpos is the last byte of the current
# WAL segment, which nothing else reaches before pg_switch_wal().
source_sql 'checkpoint'
old_endpos=$(source_sql "select pg_lsn '0/0' + ((pg_current_wal_insert_lsn() - '0/0')::bigint / s + 1) * s - 1
    from (select setting::bigint s from pg_settings where name = 'wal_segment_size') w")
new_endpos=$(source_sql "select '${old_endpos}'::pg_lsn + 1 + 1024 * 1024")
pgcopydb stream sentinel set endpos "${old_endpos}"
setsid pgcopydb follow --resume --not-consistent --debug > "${TMPDIR}/raised.log" 2>&1 &
follow_pid=$!
timeout 60s bash -c "until grep -q 'stream_sync_sentinel: ' '${TMPDIR}/raised.log'; do sleep 0.1; done" ||
    fail "receive did not read the sentinel within 60 s"
pgcopydb stream sentinel set endpos "${new_endpos}"
source_sql 'select pg_switch_wal()'
source_sql "insert into t values (4, 'raised')"
test "$(lsn "$(source_sql 'select pg_current_wal_insert_lsn()')")" -lt "$(lsn "${new_endpos}")" ||
    fail "row 4 ends past the new endpos ${new_endpos}"
source_sql 'select pg_switch_wal()'
source_sql "insert into t values (5, 'past')"
echo "endpos raised from ${old_endpos} to ${new_endpos} before WAL passed the old one"

deadline=$((SECONDS + 120))
while kill -0 "${follow_pid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}" ||
        fail "raised: follow did not exit at endpos within 120 s, with rows $(rows) on the target"
    sleep 0.2
done
rc=0
wait "${follow_pid}" || rc=$?
follow_pid=
grep -E 'endpos moved to|receive done at' "${TMPDIR}/raised.log" | cut -c1-200 || true
echo "raised: follow exited ${rc} with rows $(rows) on the target, origin $(origin)"
test "${rc}" = 0 || fail "raised: follow exited ${rc}"
grep -q "endpos moved to ${new_endpos}, past the" "${TMPDIR}/raised.log" ||
    fail "receive never held the old endpos ${old_endpos} when WAL passed it"
test "$(rows)" = 1,2,3,4 || fail "rows $(rows) on the target at the raised endpos, expected 1,2,3,4"

#
# Performance mode: the cut at the commit position of a transaction, and the
# done marker that proves the drain. Every case below reads the raw spool or
# the apply row of pipeline_state, so the sqlite pass ends with the three
# cases above.
#
if [ "${PGCOPYDB_FOLLOW_MODE:-}" = performance ]; then

catalog_sql() { timeout 30s sqlite3 -readonly -init /dev/null -batch -noheader -list \
    "${TMPDIR}/pgcopydb/schema/source.db" "$1"; }
apply_row() { catalog_sql "select run_state || ' ' || run_end_lsn from pipeline_state
    where process_name = 'apply'"; }
replay() { catalog_sql 'select replay_lsn from sentinel'; }
# spool_txn <index>: "<final_lsn> <end_lsn>" of that index record of the raw spool
spool_txn() { pgcopydb list spool --json | jq -r ".[$1] | \"\\(.final_lsn) \\(.end_lsn)\""; }

# rows_on_target <tag> <rows>: wait for the target to hold exactly those rows
rows_on_target() {
    local deadline=$((SECONDS + 120))
    until test "$(rows)" = "$2"; do
        test "${SECONDS}" -lt "${deadline}" ||
            fail "$1: rows $(rows) on the target, expected $2 within 120 s"
        kill -0 "${follow_pid}" 2>/dev/null || fail "$1: follow exited before it applied $2"
        sleep 0.2
    done
}

# follow_reap <tag>: wait for the running follow to exit, its status in rc
follow_reap() {
    local deadline=$((SECONDS + 120))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" ||
            fail "$1: follow did not exit within 120 s, with rows $(rows) on the target"
        sleep 0.2
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    follow_pid=
    echo "$1: follow exited ${rc} with rows $(rows), origin $(origin), apply $(apply_row)"
}

#
# An endpos below a commit the worker already made: the cut is the larger of
# the two, so the run ends done at the endpos it served and the origin stays
# above it. A resume that decided "done" from the two sentinel values would
# quit before the pipeline ran and leave the apply row where it was.
#
origin4=$(origin)
pgcopydb stream sentinel set endpos "${commit1}"
follow_to below
test "$(rows)" = 1,2,3,4 || fail "rows $(rows) at an endpos in the past, expected 1,2,3,4"
test "$(origin)" = "${origin4}" ||
    fail "origin $(origin) moved from ${origin4} at an endpos in the past"
test "$(lsn "${origin4}")" -gt "$(lsn "${commit1}")" ||
    fail "origin ${origin4} is not above the endpos ${commit1}"
test "$(apply_row)" = "done ${commit1}" ||
    fail "the apply row is $(apply_row), expected done at the endpos ${commit1}"
test "$(replay)" = "${origin4}" ||
    fail "the stored replay position $(replay) is not the origin ${origin4}"
grep -q "Apply cuts at ${origin4} for endpos ${commit1}" "${TMPDIR}/below.log" ||
    fail "the cut at the endpos ${commit1} is not the commit ${origin4} the target holds"

#
# A transaction that is complete in the spool and commits above the endpos is
# not applied. Receive writes a message whose position equals the endpos, so
# an endpos at the BEGIN position of the last transaction leaves its COMMIT in
# the spool and its commit position above the cut.
#
source_sql "insert into t values (6, 'spooled')"
pgcopydb stream sentinel set endpos "$(source_sql 'select pg_current_wal_insert_lsn()')"
pgcopydb stream receive --resume --notice > "${TMPDIR}/receive.log" 2>&1
read -r _ commit5 <<< "$(spool_txn -2)"
read -r begin6 commit6 <<< "$(spool_txn -1)"
echo "the last spooled transaction begins at ${begin6} and commits at ${commit6}"
test "$(lsn "${begin6}")" -lt "$(lsn "${commit6}")" ||
    fail "the BEGIN position ${begin6} is not below the commit position ${commit6}"

pgcopydb stream sentinel set endpos "${begin6}"
pgcopydb stream catchup --resume --notice > "${TMPDIR}/catchup-cut.log" 2>&1
test "$(rows)" = 1,2,3,4,5 ||
    fail "rows $(rows) with the cut at the BEGIN position ${begin6}, expected 1,2,3,4,5"
test "$(origin)" = "${commit5}" ||
    fail "origin $(origin) is not the commit ${commit5} below the cut ${begin6}"
test "$(replay)" = "${commit5}" ||
    fail "the stored replay position $(replay) is not the origin ${commit5}"
test "$(apply_row)" = "done ${begin6}" ||
    fail "the apply row is $(apply_row), expected done at the endpos ${begin6}"

# the raised endpos covers that commit, and the resume applies it
pgcopydb stream sentinel set endpos "${commit6}"
pgcopydb stream catchup --resume --notice > "${TMPDIR}/catchup-raised.log" 2>&1
test "$(rows)" = 1,2,3,4,5,6 ||
    fail "rows $(rows) at the raised endpos ${commit6}, expected 1,2,3,4,5,6"
test "$(origin)" = "${commit6}" ||
    fail "origin $(origin) is not the commit ${commit6} of the last transaction"
test "$(apply_row)" = "done ${commit6}" ||
    fail "the apply row is $(apply_row), expected done at the endpos ${commit6}"

# a resume at an endpos the marker records ends before it applies anything
follow_to again
grep -q "Current endpos ${commit6} was previously reached" "${TMPDIR}/again.log" ||
    fail "the resume at the recorded endpos ${commit6} did not read the done marker"
test "$(rows)" = 1,2,3,4,5,6 || fail "rows $(rows) after the resume, expected 1,2,3,4,5,6"

#
# A signal short of endpos writes no marker and fails the run, which is what
# the operator reads: an endpos the source never reaches keeps receive
# streaming, so the stop is the signal and nothing else.
#
far=$(source_sql "select pg_current_wal_insert_lsn() + 1024 * 1024 * 1024")
source_sql "insert into t select i, 'backlog' from generate_series(7, 16) i"
pgcopydb stream sentinel set endpos "${far}"
setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/signal.log" 2>&1 &
follow_pid=$!
rows_on_target signal 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
origin16=$(origin)
kill -TERM -- "-${follow_pid}"
follow_reap signal
test "${rc}" -ne 0 || fail "the follow a signal stopped short of the endpos ${far} exited 0"
test "$(apply_row)" = "error ${origin16}" ||
    fail "the apply row is $(apply_row), expected error at ${origin16} after the signal"

#
# A receive that dies short of endpos must not leave the run done either: the
# marker is the finish of the cut, and this run never reached it.
#
source_sql "insert into t select i, 'after-kill' from generate_series(17, 20) i"
setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/killed.log" 2>&1 &
follow_pid=$!
rows_on_target killed 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20
origin20=$(origin)
pkill -KILL -f '^pgcopydb: follow receive' || fail 'no receive process to kill'
follow_reap killed
test "${rc}" -ne 0 || fail "the follow whose receive died short of ${far} exited 0"
test "$(apply_row)" = "error ${origin20}" ||
    fail "the apply row is $(apply_row), expected error at ${origin20} after the kill"

# the next run reaches an endpos the source has passed, and records its finish
reached=$(source_sql 'select pg_current_wal_insert_lsn()')
pgcopydb stream sentinel set endpos "${reached}"
follow_to drained
test "$(rows)" = 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 ||
    fail "rows $(rows) after the drain, expected every row"
test "$(apply_row)" = "done ${reached}" ||
    fail "the apply row is $(apply_row), expected done at the endpos ${reached}"
echo "PASS: the cut is the commit position, and only a clean drain writes the marker"
fi

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: apply exited at endpos ${endpos} with row 1, resumed to rows 1,2,3, and followed a raised endpos to row 4"
