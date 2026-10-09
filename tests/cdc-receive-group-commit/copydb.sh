#! /bin/bash

# Receive commits output.db per batch of source transactions, not per COMMIT.
# A receive killed with a batch open must lose nothing the slot confirmed:
# burst cases kill it mid-burst, the guard case holds a batch open under gdb.
# The drop case kills the walsender in quick succession: receive must keep
# reconnecting while keepalives advance, though no batch commits in between.

set -euo pipefail

# guard, drop:<walsender drops>, or mode:fraction of the burst received before the kill
if test -z "${GC_CASE:-}"; then
    for c in guard drop:3 follow:0.3 follow:0.7 prefetch:0.3 prefetch:0.7; do
        GC_CASE=${c} bash "$0"
    done
    exit 0
fi
mode=${GC_CASE%%:*}
frac=${GC_CASE#*:}
echo "=== ${GC_CASE}"

burst=${GC_BURST:-20000}
db=gc_${mode}_${frac//./}
export TMPDIR=/tmp/gc-${mode}-${frac//./}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid= follow_pid= burst_pid= gdb_pid= walgen_pid=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${gdb_pid}" || sudo kill "${gdb_pid}" 2>/dev/null || true
    test -z "${burst_pid}" || kill "${burst_pid}" 2>/dev/null || true
    test -z "${walgen_pid}" || kill "${walgen_pid}" 2>/dev/null || true
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        tail -n 40 "${TMPDIR}/follow.log" 2>/dev/null || true
        cat "${TMPDIR}/gdb.log" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
lsn_ge() { test "$(source_sql "select '$1'::pg_lsn >= '$2'::pg_lsn")" = t; }

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# committed COMMIT rows across the spool: what a reader can see
spooled_commits() {
    local f n=0 c
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        test -e "${f}" || continue
        c=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "${f}" \
              "select count(*) from output where action = 'C'" 2>/dev/null || echo 0)
        n=$((n + c))
    done
    echo "${n}"
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}
slot_inactive() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 0
}

start_follow() {
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active
}

# kill -9 receive only; follow then stops apply and exits
kill_receive() {
    local pid
    pid=$(pgrep -f '^pgcopydb: follow receive')
    kill -KILL "${pid}"
    local deadline=$((SECONDS + 60))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        if test "${SECONDS}" -ge "${deadline}"; then
            kill -KILL -- "-${follow_pid}" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
    wait "${follow_pid}" || true
    follow_pid=
    poll 'the slot to be released' 60 slot_inactive
}

pgcopydb ping
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "create database ${db}"
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "create database ${db}"
source_admin=${PGCOPYDB_SOURCE_PGURI}
export PGCOPYDB_SOURCE_PGURI=${PGCOPYDB_SOURCE_PGURI%/*}/${db}
export PGCOPYDB_TARGET_PGURI=${PGCOPYDB_TARGET_PGURI%/*}/${db}
source_sql 'create table t (id integer primary key, v text)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup
pgcopydb clone
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=

slot_verdict=
if test "${mode}" = guard; then
    pgcopydb stream sentinel set apply
    start_follow
    source_sql "insert into t values (1, 'applied')"
    applied() { test "$(target_sql 'select count(*) from t')" = 1; }
    poll 'apply to commit the first row' 60 applied

    barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
    sudo timeout 300s gdb -q -batch -ex "set \$barrier_dir = \"${barrier_dir}\"" \
        -x /usr/src/pgcopydb/hold-batch.gdb \
        -p "$(pgrep -f '^pgcopydb: follow receive')" > "${TMPDIR}/gdb.log" 2>&1 &
    gdb_pid=$!
    poll 'the batch hold to be armed' 60 test -f "${barrier_dir}/armed"
    mark=$(wc -l < "${TMPDIR}/follow.log")

    lsn_x=$(source_sql "begin; insert into t values (2, 'held'); select pg_current_wal_insert_lsn(); commit")
    lsn_after=$(source_sql 'select pg_current_wal_lsn()')

    # wal_sender_timeout pings make receive report feedback while X is held
    reported_x() {
        local n=0 l
        for l in $(tail -n +"$((mark + 1))" "${TMPDIR}/follow.log" \
                       | grep -o 'Reported write_lsn [0-9A-F]*/[0-9A-F]*' | awk '{print $3}'); do
            if lsn_ge "${l}" "${lsn_x}"; then n=$((n + 1)); fi
        done
        test "${n}" -ge 2
    }
    poll 'two feedback reports with the held transaction received' 60 reported_x
    test "$(target_sql 'select count(*) from t')" = 1 || fail 'apply saw a transaction receive never committed'
    confirmed=$(source_sql "select confirmed_flush_lsn from pg_replication_slots where slot_name = 'pgcopydb'")
    echo "held X after ${lsn_x}: slot confirmed_flush_lsn ${confirmed}, WAL at ${lsn_after}"
    if lsn_ge "${confirmed}" "${lsn_after}"; then
        slot_verdict="slot confirmed ${confirmed} past the held transaction (${lsn_after})"
    fi

    kill_receive
    sudo kill "${gdb_pid}" 2>/dev/null || true
    wait "${gdb_pid}" || true
    gdb_pid=
    start_follow
elif test "${mode}" = drop; then
    pgcopydb stream sentinel set apply
    start_follow

    # WAL in another database: keepalives advance, nothing replicates
    psql -qX -v ON_ERROR_STOP=1 -d "${source_admin}" -c 'create table if not exists gc_wal (pad text)'
    while :; do
        psql -qX -d "${source_admin}" -c "insert into gc_wal select repeat('x', 200) from generate_series(1, 200)" > /dev/null 2>&1 || true
        sleep 0.1
    done &
    walgen_pid=$!

    walsender() {
        source_sql "select active_pid from pg_replication_slots where slot_name = 'pgcopydb' and active_pid is not null"
    }
    reconnected() {
        ! grep -q 'did not make any progress' "${TMPDIR}/follow.log" \
            || fail "receive stopped retrying after walsender drop ${i}"
        local pid
        pid=$(walsender)
        test -n "${pid}" && test "${pid}" != "${old}"
    }
    # drops 1 s apart: no flush interval and no wal_sender_timeout ping between them
    sleep 2
    for i in $(seq "${frac}"); do
        old=$(walsender)
        source_sql "select pg_terminate_backend(${old})" > /dev/null
        poll "receive to reconnect after walsender drop ${i}" 30 reconnected
        sleep 1
    done
    kill "${walgen_pid}"
    wait "${walgen_pid}" || true
    walgen_pid=
    echo "receive reconnected after ${frac} walsender drops"
else
    test "${mode}" = prefetch || pgcopydb stream sentinel set apply
    start_follow
    seq 1 "${burst}" | awk -v q="'" '{printf "insert into t values (%d, md5(%s%d%s));\n", $1, q, $1, q}' > "${TMPDIR}/burst.sql"
    psql -qX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f "${TMPDIR}/burst.sql" > /dev/null &
    burst_pid=$!
    at=$(awk -v n="${burst}" -v f="${frac}" 'BEGIN {printf "%d", n * f}')
    reached() { test "$(spooled_commits)" -ge "${at}"; }
    poll "receive to commit ${at} transactions" 300 reached
    kill_receive
    echo "killed receive with $(spooled_commits) of ${burst} transactions committed to output.db"
    wait "${burst_pid}"
    burst_pid=
    test "${mode}" = follow || pgcopydb stream sentinel set apply
    start_follow
fi

source_sql "insert into t values (-1, 'last')"
pgcopydb stream sentinel set endpos --current
deadline=$((SECONDS + 600))
while kill -0 "${follow_pid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
    sleep 1
done
wait "${follow_pid}" || fail "follow exited with $?"
follow_pid=

sql='copy (select * from t order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src.txt"
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt.txt"
lost=
if ! diff -q "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" > /dev/null; then
    diff "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" | head -5 || true
    lost="target has $(wc -l < "${TMPDIR}/tgt.txt") rows, source $(wc -l < "${TMPDIR}/src.txt")"
fi
test -z "${slot_verdict}${lost}" || fail "${slot_verdict:+${slot_verdict}; }${lost}"

# the burst must have been committed in groups, not one transaction per batch
if test "${mode}" = follow || test "${mode}" = prefetch; then
    read -r batches txns < <(grep -o 'batches/txns: .*' "${TMPDIR}/follow.log" \
        | grep -o '[0-9]*/[0-9]*' | awk -F/ '{b += $1; t += $2} END {print b + 0, t + 0}')
    echo "receive group commit: ${txns} transactions in ${batches} batches"
    test "${txns}" -gt "${batches}" || fail 'receive committed no batch of more than one transaction'
fi

pgcopydb stream cleanup
echo "PASS: ${GC_CASE}"
