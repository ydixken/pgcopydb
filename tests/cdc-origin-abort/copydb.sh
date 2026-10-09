#! /bin/bash

# A transaction the apply did not commit must not move the replication origin.
# Case A kills the apply once everything before its COMMIT ran on the target.
# Case B makes the COMMIT itself fail in a deferred trigger only the target has.
# Case C terminates the target backend while such a trigger runs at COMMIT.
# Case D refuses the COMMIT of a group of transactions (apply grouping).
# Case F kills the apply before the COMMIT of a group.
# Case E has a TRUNCATE after a transaction that left trigger events pending.
# Each case then resumes and expects the transaction applied, none skipped.

set -euxo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-origin-abort.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid= debugger_pid= apply_pid= barrier_dir= failures=0

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    test -z "${apply_pid}" || kill -KILL "${apply_pid}" 2>/dev/null || true
    for pid in "${debugger_pid}" "${snapshot_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', false)"; }
digest() { echo "select count(*), md5(string_agg(row(id, k, v)::text, ',' order by id)) from oa where $1"; }

# commit_lsn <xid>: the COMMIT LSN prefetch decoded for that transaction
commit_lsn() {
    local file lsn
    for file in "${XDG_DATA_HOME}/pgcopydb"/*-output.db; do
        lsn=$(sqlite3 -readonly -init /dev/null -batch -noheader -list "${file}" \
            "select printf('%X/%X', lsn >> 32, lsn & 4294967295) from output where xid = $1 and action = 'C'")
        if test -n "${lsn}"; then echo "${lsn}"; return; fi
    done
    echo "FAIL: no COMMIT decoded for xid $1" >&2
    return 1
}

check() {
    if test "$2" = "$3"; then
        echo "OK   $1: $3"
    else
        echo "FAIL $1: expected $2, got $3"
        failures=$((failures + 1))
    fi
}

# kill_before_commit <lsn>: run catchup under gdb up to the COMMIT with origin
# <lsn>, let the target run everything sent before it, then SIGKILL the apply.
kill_before_commit() {
    local lsn=$1 paused_lsn apply_backend
    barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
    timeout 120s gdb -q -batch \
        -ex "set \$barrier_dir = \"${barrier_dir}\"" \
        -ex "set \$expected_lsn = \"${lsn}\"" \
        -x /usr/src/pgcopydb/kill-at-commit.gdb \
        --args pgcopydb stream catchup --resume --endpos "${lsn}" >"${TMPDIR}/gdb.log" 2>&1 &
    debugger_pid=$!
    deadline=$((SECONDS + 60))
    while ! test -s "${barrier_dir}/paused"; do
        kill -0 "${debugger_pid}"
        test "${SECONDS}" -lt "${deadline}"
        sleep 0.1
    done
    read -r apply_pid paused_lsn <"${barrier_dir}/paused"
    [[ ${apply_pid} =~ ^[1-9][0-9]*$ ]]
    test "${paused_lsn}" = "${lsn}"

    # The apply backend has written rows and waits for input: all it was sent ran.
    deadline=$((SECONDS + 45))
    while true; do
        apply_backend=$(target_sql "select pid from pg_stat_activity
         where application_name like 'pgcopydb[${apply_pid}] %'
           and backend_xid is not null and wait_event = 'ClientRead'
           and (state = 'idle in transaction'
                or query like '%pg_replication_origin_xact_setup%')")
        if [[ ${apply_backend} =~ ^[1-9][0-9]*$ ]]; then break; fi
        kill -0 "${debugger_pid}" "${apply_pid}"
        test "${SECONDS}" -lt "${deadline}"
        sleep 0.1
    done
    target_sql "select state, query from pg_stat_activity where pid = ${apply_backend}"
    printf '%s\n' "${apply_pid}" >"${barrier_dir}/kill.tmp"
    mv "${barrier_dir}/kill.tmp" "${barrier_dir}/kill"
    wait "${debugger_pid}"
    debugger_pid= apply_pid=
    cat "${TMPDIR}/gdb.log"
    deadline=$((SECONDS + 60))
    while test "$(target_sql "select count(*) from pg_stat_activity where pid = ${apply_backend}")" != 0; do
        test "${SECONDS}" -lt "${deadline}"
        sleep 0.1
    done
}

pgcopydb ping
source_sql 'drop table if exists oa; create table oa (id integer primary key, k integer, v text)'
source_sql "insert into oa select i, i, md5(i::text) from generate_series(1, 10) i"
target_sql 'drop table if exists oa'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" &
snapshot_pid=$!
deadline=$((SECONDS + 60))
while ! test -s "${TMPDIR}/snapshot.out"; do
    kill -0 "${snapshot_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
pgcopydb stream setup
pgcopydb clone --drop-if-exists
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}" || true
snapshot_pid=
pgcopydb stream sentinel set apply

#
# Case A: SIGKILL once the target executed every statement sent before COMMIT
#
xid=$(source_sql "begin; select pg_current_xact_id();
    insert into oa select i, i, md5(i::text) from generate_series(11, 100) i; commit")
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_a=$(commit_lsn "${xid}")
pgcopydb stream sentinel set endpos "${commit_a}"
origin_before=$(origin)
digest_before=$(target_sql "$(digest true)")

kill_before_commit "${commit_a}"

check "A: origin after kill before COMMIT" "${origin_before}" "$(origin)"
check "A: rows after kill before COMMIT" "${digest_before}" "$(target_sql "$(digest true)")"
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_a}"
check "A: origin after resume" "${commit_a}" "$(origin)"
check "A: rows after resume" "$(source_sql "$(digest true)")" "$(target_sql "$(digest true)")"

#
# Case B: the COMMIT fails, the conflict is removed, and the apply resumes
#
# A deferred unique constraint would not do: session_replication_role = replica
# skips its recheck trigger. An ALWAYS constraint trigger still fires at COMMIT.
target_sql "create function oa_reject() returns trigger language plpgsql as \$\$
    begin raise exception 'oa_reject refuses row %', new.id; end \$\$;
    create constraint trigger oa_reject after insert on oa deferrable initially deferred
    for each row when (new.v = 'dup') execute function oa_reject();
    alter table oa enable always trigger oa_reject"
xid=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (1001, 1, 'dup'); commit")
xid2=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (1002, 1002, 'after'); commit")
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_b1=$(commit_lsn "${xid}")
commit_b2=$(commit_lsn "${xid2}")
pgcopydb stream sentinel set endpos "${commit_b2}"
origin_before=$(origin)

status=0
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_b2}" >"${TMPDIR}/fail.log" 2>&1 || status=$?
grep -E 'ERROR|FATAL' "${TMPDIR}/fail.log" | cut -c1-300 || true
test "${status}" -ne 0
grep -q 'oa_reject refuses row 1001' "${TMPDIR}/fail.log"
check "B: origin after failed COMMIT at ${commit_b1}" "${origin_before}" "$(origin)"

target_sql 'drop trigger oa_reject on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_b2}"
check "B: origin after resume" "${commit_b2}" "$(origin)"
check "B: rows after resume" "$(source_sql "$(digest 'id > 1000')")" "$(target_sql "$(digest 'id > 1000')")"

#
# Case C: the target backend is terminated while a deferred trigger runs
#
target_sql "create function oa_stall() returns trigger language plpgsql as \$\$
    begin perform pg_sleep(300); return null; end \$\$;
    create constraint trigger oa_stall after insert on oa deferrable initially deferred
    for each row when (new.v = 'stall') execute function oa_stall();
    alter table oa enable always trigger oa_stall"
xid=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (2001, 1, 'stall'); commit")
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_c=$(commit_lsn "${xid}")
pgcopydb stream sentinel set endpos "${commit_c}"
origin_before=$(origin)

timeout 120s pgcopydb stream catchup --resume --endpos "${commit_c}" >"${TMPDIR}/stall.log" 2>&1 &
apply_pid=$!
deadline=$((SECONDS + 60))
while true; do
    stalled=$(target_sql "select pid from pg_stat_activity
     where application_name like 'pgcopydb%' and wait_event = 'PgSleep'")
    if [[ ${stalled} =~ ^[1-9][0-9]*$ ]]; then break; fi
    kill -0 "${apply_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
target_sql "select state, query from pg_stat_activity where pid = ${stalled}"
target_sql "select pg_terminate_backend(${stalled}, 10000)"
status=0
wait "${apply_pid}" || status=$?
apply_pid=
grep -E 'ERROR|FATAL' "${TMPDIR}/stall.log" | cut -c1-300 || true
test "${status}" -ne 0
check "C: origin after termination at ${commit_c}" "${origin_before}" "$(origin)"

target_sql 'drop trigger oa_stall on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_c}"
check "C: origin after resume" "${commit_c}" "$(origin)"
check "C: rows after resume" "$(source_sql "$(digest 'id > 2000')")" "$(target_sql "$(digest 'id > 2000')")"

#
# Case D: the trigger refuses the 3rd of 10 transactions applied as a group
#
target_sql "create constraint trigger oa_reject after insert on oa deferrable initially deferred
    for each row when (new.v = 'dup') execute function oa_reject();
    alter table oa enable always trigger oa_reject"
xids_d=() commits_d=()
for i in $(seq 1 10); do
    v=$(test "${i}" = 3 && echo dup || echo "d${i}")
    xid=$(source_sql "begin; select pg_current_xact_id(); insert into oa values ($((4000 + i)), ${i}, '${v}'); commit")
    xids_d+=("${xid}")
done
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
for xid in "${xids_d[@]}"; do commits_d+=("$(commit_lsn "${xid}")"); done
commit_d=${commits_d[9]}
pgcopydb stream sentinel set endpos "${commit_d}"

status=0
PGCOPYDB_APPLY_GROUP_TXNS=100 timeout 60s pgcopydb stream catchup --resume --endpos "${commit_d}" \
    >"${TMPDIR}/group.log" 2>&1 || status=$?
grep -E 'ERROR|FATAL' "${TMPDIR}/group.log" | cut -c1-300 || true
test "${status}" -ne 0
grep -q 'oa_reject refuses row 4003' "${TMPDIR}/group.log"

# The origin sits at a group boundary below the refused transaction, and the
# target holds exactly the transactions at or below it: no part of a group.
origin_d=$(origin)
applied=0
for i in $(seq 1 10); do
    if test "$(target_sql "select '${commits_d[$((i - 1))]}'::pg_lsn <= '${origin_d}'::pg_lsn")" = t; then
        applied=$((applied + 1))
    fi
done
check "D: origin below the refused transaction" t \
    "$(target_sql "select '${origin_d}'::pg_lsn < '${commits_d[2]}'::pg_lsn")"
check "D: rows match the origin after the refused group" "${applied}" \
    "$(target_sql 'select count(*) from oa where id > 4000')"
grep -E 'Failed to commit [0-9]+ transaction' "${TMPDIR}/group.log" || true

target_sql 'drop trigger oa_reject on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_d}"
check "D: origin after resume" "${commit_d}" "$(origin)"
check "D: rows after resume" "$(source_sql "$(digest 'id > 4000')")" "$(target_sql "$(digest 'id > 4000')")"

#
# Case F: SIGKILL before the COMMIT of a group of 5 transactions
#
xids_f=() commits_f=()
for i in $(seq 1 5); do
    xids_f+=("$(source_sql "begin; select pg_current_xact_id(); insert into oa values ($((6000 + i)), ${i}, 'f${i}'); commit")")
done
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
for xid in "${xids_f[@]}"; do commits_f+=("$(commit_lsn "${xid}")"); done
commit_f=${commits_f[4]}
pgcopydb stream sentinel set endpos "${commit_f}"

kill_before_commit "${commit_f}"

# a KEEPALIVE can split the backlog: only the group holding the last one died
origin_f=$(origin)
applied=0
for lsn in "${commits_f[@]}"; do
    if test "$(target_sql "select '${lsn}'::pg_lsn <= '${origin_f}'::pg_lsn")" = t; then
        applied=$((applied + 1))
    fi
done
check "F: origin below the killed group" t \
    "$(target_sql "select '${origin_f}'::pg_lsn < '${commit_f}'::pg_lsn")"
check "F: rows match the origin after the kill" "${applied}" \
    "$(target_sql 'select count(*) from oa where id > 6000')"
grep -E 'COMMIT [0-9]+ transaction' "${TMPDIR}/gdb.log" || true

timeout 60s pgcopydb stream catchup --resume --endpos "${commit_f}"
check "F: origin after resume" "${commit_f}" "$(origin)"
check "F: rows after resume" "$(source_sql "$(digest 'id > 6000')")" "$(target_sql "$(digest 'id > 6000')")"

#
# Case E: TRUNCATE after a transaction that left deferred trigger events
#
# Postgres refuses TRUNCATE of a table with pending trigger events, so a
# grouped apply must not put the TRUNCATE in the same target transaction.
target_sql "create function oa_noop() returns trigger language plpgsql as \$\$
    begin return null; end \$\$;
    create constraint trigger oa_defer after insert on oa deferrable initially deferred
    for each row execute function oa_noop();
    alter table oa enable always trigger oa_defer"
source_sql "insert into oa values (5001, 1, 'e1')"
source_sql 'truncate oa'
xid=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (5002, 2, 'e2'); commit")
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_e=$(commit_lsn "${xid}")
pgcopydb stream sentinel set endpos "${commit_e}"

PGCOPYDB_APPLY_GROUP_TXNS=100 timeout 60s pgcopydb stream catchup --resume --endpos "${commit_e}"
check "E: origin after TRUNCATE" "${commit_e}" "$(origin)"
check "E: rows after TRUNCATE" "$(source_sql "$(digest true)")" "$(target_sql "$(digest true)")"

pgcopydb stream cleanup
echo "RESULT failures=${failures}"
test "${failures}" -eq 0
