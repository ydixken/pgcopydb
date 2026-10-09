#! /bin/bash

# A receive killed before it wrote a transaction's COMMIT closes the lifecycle
# pipe without the done-LSN.  Apply must not read that end-of-file as
# "receive is done" and report a drain short of endpos; the resumed run must
# then apply the transaction.

set -euo pipefail

rows=${CRASH_ROWS:-200000}
TMPDIR=$(mktemp -d /tmp/pgcopydb-receive-crash.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid= follow_pid= rc=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || tail -n 60 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

# rows of xid $1 with action $2 that receive committed to output.db
spooled() {
    local f n=0
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        n=$((n + $(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "${f}" \
            "select count(*) from output where xid = $1 and action = '$2'")))
    done
    echo "${n}"
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        kill -0 "${follow_pid}" 2>/dev/null || fail "pgcopydb exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# wait_follow <seconds>: wait for follow to exit, its exit status in rc
wait_follow() {
    local deadline=$((SECONDS + $1))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "follow did not exit within $1 s"
        sleep 0.5
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    follow_pid=
}

pgcopydb ping
source_sql 'drop table if exists t; create table t (id integer primary key, v text)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup
pgcopydb clone
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=

# endpos far past the workload, known to apply before X commits
pgcopydb stream sentinel set apply
pgcopydb stream sentinel set endpos "$(source_sql 'select pg_current_wal_lsn() + 1073741824')"

setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/crash.log" 2>&1 &
follow_pid=$!
source_sql "insert into t values (0, 'warm')"
warm_applied() { test "$(target_sql 'select count(*) from t where id = 0')" = 1; }
poll 'apply to commit the first row' 120 warm_applied

# receive decodes X only once it committed, so it is still writing X when killed
xid=$(source_sql "begin; select txid_current(); insert into t select g, 'X' from generate_series(1, ${rows}) g; commit")
pkill -KILL -f '^pgcopydb: follow receive' || fail 'no receive process to kill'
wait_follow 120
echo "X: xid ${xid}, ${rows} rows; follow exited ${rc} after receive was killed"

test "$(spooled "${xid}" C)" = 0 || fail "receive wrote X's COMMIT before the kill; raise CRASH_ROWS"
test "${rc}" -ne 0 || fail 'follow exited 0 although its receive was killed'
grep -q 'Upstream pipe closed without done-LSN' "${TMPDIR}/crash.log" ||
    fail 'apply never saw the lifecycle pipe close, so this run checks nothing'
if grep -E 'receive is done and outputDB holds|mid-transaction endpos|Apply reached end position' "${TMPDIR}/crash.log"; then
    fail 'apply took the end of the lifecycle pipe for receive being done'
fi

pgcopydb stream sentinel set endpos --current
setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/resume.log" 2>&1 &
follow_pid=$!
wait_follow 600
test "${rc}" = 0 || fail "resumed follow exited ${rc}"

sql='copy (select * from t order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src.txt"
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt.txt"
if ! diff -q "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" > /dev/null; then
    fail "table t differs: target $(target_sql 'select count(*) from t') rows, source $(source_sql 'select count(*) from t')"
fi

pgcopydb stream cleanup
echo "PASS: apply waited out a killed receive and the resumed run applied X (${rows} rows)"
