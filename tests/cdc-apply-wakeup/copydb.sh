#! /bin/bash

# Transactions that arrive while receive streams must not each wait out the
# 100 ms lifecycle-pipe timeout in apply.  A receive stopped short of endpos
# must not read as done, and every interrupted run must resume to the source
# rows with the origin on the last COMMIT.

set -euo pipefail

burst=300
# two 100 ms waits per transaction made this 200 ms each
limit_ms=$((burst * 50))
backlog=2000
TMPDIR=$(mktemp -d /tmp/pgcopydb-apply-wakeup.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid='' follow_pid='' follow_log='' rc='' holder_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${holder_pid}" || kill -TERM "${holder_pid}" 2>/dev/null || true
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
count() { target_sql "select count(*) from t where v = '$1'"; }
applied() { test "$(count "$1")" = "$2"; }
now_ms() { echo $(($(date +%s%N) / 1000000)); }
lsn() { echo $(((16#${1%/*} << 32) + 16#${1#*/})); }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', true)"; }
replay_lsn() { timeout 15s pgcopydb stream sentinel get --replay-lsn; }

# apply writes replay_lsn at most once a second, so it may trail the origin
replay_not_ahead() {
    local replay origin
    replay=$(replay_lsn)
    origin=$(origin)
    echo "$1: sentinel replay_lsn ${replay}, origin ${origin}"
    test "$(lsn "${replay}")" -le "$(lsn "${origin}")" ||
        fail "$1: sentinel replay_lsn ${replay} is ahead of the origin ${origin}"
}

# one source transaction per row
insert_txns() {
    seq "$1" "$2" | sed "s/.*/insert into t values (&, '$3');/" |
        psql -qX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}"
}

start_follow() {
    follow_log=${TMPDIR}/$1.log
    setsid pgcopydb follow --resume --not-consistent --notice >> "${follow_log}" 2>&1 &
    follow_pid=$!
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
        sleep 0.2
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    follow_pid=
}

holders() { target_sql "select count(*) from pg_stat_activity where application_name = 'holder'$1"; }
holder_sleeps() { test "$(holders " and wait_event = 'PgSleep'")" = 1; }
holder_blocks() { test "$(holders " and pid in (select unnest(pg_blocking_pids(a.pid)) from pg_stat_activity a)")" = 1; }

# hold_row <id>: an open target transaction inserts id, so apply waits on that row
# however fast it is; pg_sleep never reads the socket, so only pg_terminate_backend ends it
hold_row() {
    PGAPPNAME=holder psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c 'begin' \
        -c "insert into t values ($1, 'holder')" -c 'select pg_sleep(600)' > "${TMPDIR}/holder.log" 2>&1 &
    holder_pid=$!
    poll "the holder of row $1" 60 holder_sleeps
}

release_row() {
    local deadline=$((SECONDS + 30))
    target_sql "select count(pg_terminate_backend(pid)) from pg_stat_activity
        where application_name = 'holder'" > /dev/null
    wait "${holder_pid}" || true
    holder_pid=
    until test "$(holders '')" = 0; do
        test "${SECONDS}" -lt "${deadline}" || fail 'the holder session did not end'
        sleep 0.2
    done
}

# interrupt <tag> <how> <first id - 1>: stop follow halfway through a backlog, then resume.
# The middle row is held, so the stop lands while apply waits on it in pipeline sync.
interrupt() {
    local n
    hold_row $(($3 + backlog / 2))
    insert_txns $(($3 + 1)) $(($3 + backlog)) "$1"
    poll "apply to wait on the held row" 120 holder_blocks
    case "$2" in
        kill-apply) pkill -KILL -f '^pgcopydb: follow apply' || fail 'no apply process to kill' ;;
        term) kill -TERM -- "-${follow_pid}" ;;
    esac
    release_row
    wait_follow 120
    n=$(count "$1")
    echo "$1: follow exited ${rc} after $2 with ${n} of ${backlog} rows applied"
    test "${n}" -lt "${backlog}" || fail "$2 came after the whole backlog, so it checks nothing"
    # SIGTERM fails the pipeline sync that waits on the held row, so follow exits 12
    test "$2" != term -o "${rc}" = 12 || fail "SIGTERM in pipeline sync made follow exit ${rc}, not 12"
    replay_not_ahead "$1"

    start_follow "resume-$1"
    poll "the rest of $1" 300 applied "$1" "${backlog}"
}

# term_idle <first id - 1>: SIGTERM once apply has caught up with half a backlog and a paused
# receive holds back the rest. With no target work left apply takes the clean stop at the top
# of its loop, so follow exits 0 short of the backlog and the resume must apply the rest.
# In performance mode a signal writes no done marker, so the run fails instead.
term_idle() {
    local n rpid half=$((backlog / 2))
    insert_txns $(($1 + 1)) $(($1 + half)) term-idle
    poll 'the first term-idle rows' 120 applied term-idle "${half}"
    rpid=$(pgrep -f '^pgcopydb: follow receive') || fail 'no receive process'
    kill -STOP "${rpid}"
    insert_txns $(($1 + half + 1)) $(($1 + backlog)) term-idle
    kill -TERM -- "-${follow_pid}"
    kill -CONT "${rpid}"
    wait_follow 120
    n=$(count term-idle)
    echo "term-idle: follow exited ${rc} after SIGTERM with ${n} of ${backlog} rows applied"
    if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
    test "${rc}" = 0 || fail "follow stopped by SIGTERM between groups exited ${rc}"
    else
    test "${rc}" = 12 || fail "follow stopped by SIGTERM between groups exited ${rc}, not 12"
    fi
    test "${n}" = "${half}" || fail "${n} term-idle rows applied at the stop, expected ${half}"
    grep -q 'Apply process received a shutdown signal, stopping' "${follow_log}" ||
        fail 'apply did not take the clean stop at the top of its loop'
    if grep -E 'Apply leaves|Pipeline sync was interrupted|Failed to commit' "${follow_log}"; then
        fail 'SIGTERM between groups found a group open or reached a target commit'
    fi
    replay_not_ahead term-idle

    start_follow resume-term-idle
    poll 'the rest of term-idle' 300 applied term-idle "${backlog}"
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

# endpos far ahead keeps receive streaming for the whole test
pgcopydb stream sentinel set apply
pgcopydb stream sentinel set endpos "$(source_sql 'select pg_current_wal_lsn() + 1073741824')"

start_follow follow
source_sql "insert into t values (0, 'warm')"
poll 'the first row' 120 applied warm 1

t0=$(now_ms)
insert_txns 1 "${burst}" burst
poll 'the burst' 600 applied burst "${burst}"
ms=$(($(now_ms) - t0))
echo "burst: ${burst} transactions applied in ${ms} ms while receive streamed"
test "${ms}" -lt "${limit_ms}" ||
    fail "${ms} ms is over ${limit_ms}: apply waited on the lifecycle pipe between transactions"

interrupt crash kill-apply 1000
interrupt term term 10000
term_idle 15000

# receive stops short of an endpos that lies past the lag rows
rpid=$(pgrep -f '^pgcopydb: follow receive') || fail 'no receive process'
kill -STOP "${rpid}"
insert_txns 20001 20020 lag
timeout 60s pgcopydb stream sentinel set endpos --current
kill -TERM "${rpid}"
kill -CONT "${rpid}"
deadline=$((SECONDS + 30))
while kill -0 "${rpid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}" || fail 'receive did not exit on SIGTERM'
    sleep 0.2
done

# give apply time to take receive's exit for the end of the stream
deadline=$((SECONDS + 15))
while kill -0 "${follow_pid}" 2>/dev/null && test "${SECONDS}" -lt "${deadline}"; do
    sleep 0.5
done
cp "${follow_log}" "${TMPDIR}/lag-first.log"
running=f
kill -0 "${follow_pid}" 2>/dev/null && running=t
if test "${running}" = t; then
    kill -TERM -- "-${follow_pid}"
fi
wait_follow 60
lag=$(count lag)
echo "lag: receive stopped by SIGTERM, follow running=${running} exit=${rc}, ${lag} of 20 lag rows applied"
if test "${lag}" != 20; then
    test "${running}" = t -o "${rc}" -ne 0 ||
        fail "follow exited 0 with ${lag} of 20 rows below endpos applied"
    if grep -E 'receive is done and outputDB holds|Follow mode is now done' "${TMPDIR}/lag-first.log"; then
        fail 'apply took the exit of a receive short of endpos for the end of the stream'
    fi
fi

start_follow resume-final
wait_follow 300
test "${rc}" = 0 || fail "the final follow to endpos exited ${rc}"

sql='copy (select * from t order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src.txt"
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt.txt"
diff -q "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" > /dev/null ||
    fail "table t differs: target $(target_sql 'select count(*) from t') rows, source $(source_sql 'select count(*) from t')"

# the origin sits on the last COMMIT receive spooled, which is the last lag row
if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
last=0
for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
    l=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "${f}" \
        "select coalesce(max(lsn), 0) from output where action = 'C'")
    test "${l}" -le "${last}" || last=${l}
done
last=$(printf '%X/%X' $((last >> 32)) $((last & 4294967295)))
else
# the last index record of the raw spool is the last COMMIT receive wrote
. /var/lib/postgres/spool-probe.sh
last=$(spool_commit_lsns | tail -1)
test -n "${last}" || fail 'the raw spool holds no transaction'
fi
origin=$(origin)
test "${origin}" = "${last}" || fail "origin ${origin} is not the last COMMIT ${last}"
# the write at endpos and at exit is not held back
test "$(replay_lsn)" = "${origin}" || fail "sentinel replay_lsn $(replay_lsn) is not the origin ${origin}"

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: $(wc -l < "${TMPDIR}/tgt.txt") rows match, origin at the last COMMIT ${origin}"
