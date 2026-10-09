#! /bin/bash

# A transaction the apply did not commit must not move the replication origin.
# Case A kills the apply once everything before its COMMIT ran on the target.
# Case B makes the COMMIT itself fail in a deferred trigger only the target has.
# Case C terminates the target backend while such a trigger runs at COMMIT.
# Cases D to G apply several transactions in one target transaction (a group):
# a refused group, a TRUNCATE after deferred trigger events, endpos inside a
# group, and a kill before a group COMMIT.
# Each case then resumes and expects the transactions applied, none skipped.

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

# kill_before_commit <case> <endpos>: SIGKILL the apply once the target ran
# everything sent before the COMMIT at endpos, then resume to endpos
kill_before_commit() {
    local endpos=$2 origin_before digest_before barrier_dir paused_lsn apply_backend deadline
    origin_before=$(origin)
    digest_before=$(target_sql "$(digest true)")

    barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
    timeout 120s gdb -q -batch \
        -ex "set \$barrier_dir = \"${barrier_dir}\"" \
        -ex "set \$expected_lsn = \"${endpos}\"" \
        -x /usr/src/pgcopydb/kill-at-commit.gdb \
        --args pgcopydb stream catchup --resume --endpos "${endpos}" >"${TMPDIR}/gdb.log" 2>&1 &
    debugger_pid=$!
    deadline=$((SECONDS + 60))
    while ! test -s "${barrier_dir}/paused"; do
        kill -0 "${debugger_pid}"
        test "${SECONDS}" -lt "${deadline}"
        sleep 0.1
    done
    read -r apply_pid paused_lsn <"${barrier_dir}/paused"
    [[ ${apply_pid} =~ ^[1-9][0-9]*$ ]]
    test "${paused_lsn}" = "${endpos}"

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

    check "$1: origin after kill before COMMIT" "${origin_before}" "$(origin)"
    check "$1: rows after kill before COMMIT" "${digest_before}" "$(target_sql "$(digest true)")"
    timeout 60s pgcopydb stream catchup --resume --endpos "${endpos}"
    check "$1: origin after resume" "${endpos}" "$(origin)"
    check "$1: rows after resume" "$(source_sql "$(digest true)")" "$(target_sql "$(digest true)")"
}

# keepalives_between <xid> <xid>: KEEPALIVE rows between the two COMMITs;
# each one commits the group, so a case that needs one group checks for none
keepalives_between() {
    local file
    for file in "${XDG_DATA_HOME}/pgcopydb"/*-output.db; do
        sqlite3 -readonly -init /dev/null -batch -noheader -list "${file}" \
            "select count(*) from output where action = 'K'
                and lsn > (select lsn from output where xid = $1 and action = 'C')
                and lsn < (select lsn from output where xid = $2 and action = 'C')"
    done | awk '{ n += $1 } END { print n + 0 }'
}

# txns <first id> <count> <v of the 3rd>: one single-row transaction per id
txns() {
    local i v
    for ((i = $1; i < $1 + $2; i++)); do
        v=row
        test "${i}" -ne $(($1 + 2)) || v=$3
        source_sql "begin; select pg_current_xact_id(); insert into oa values (${i}, ${i}, '${v}'); commit"
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
kill_before_commit A "${commit_a}"

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
# The groups below must not be cut short by the clock on a slow runner.
export PGCOPYDB_APPLY_GROUP_MS=60000

#
# Case D: the target refuses the 3rd of ten transactions applied as one group
#
target_sql "create constraint trigger oa_reject after insert on oa deferrable initially deferred
    for each row when (new.v = 'dup') execute function oa_reject();
    alter table oa enable always trigger oa_reject"
mapfile -t xids < <(txns 3001 10 dup)
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_d=$(commit_lsn "${xids[9]}")
check "D: KEEPALIVE rows inside the group" 0 "$(keepalives_between "${xids[0]}" "${xids[9]}")"
pgcopydb stream sentinel set endpos "${commit_d}"
origin_before=$(origin)

status=0
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_d}" >"${TMPDIR}/group.log" 2>&1 || status=$?
grep -E 'ERROR|FATAL' "${TMPDIR}/group.log" | cut -c1-300 || true
test "${status}" -ne 0
grep -q 'oa_reject refuses row 3003' "${TMPDIR}/group.log"
grep -q "Failed to commit 10 transactions, xid ${xids[0]} to ${xids[9]}" "${TMPDIR}/group.log"
check "D: origin after refused group" "${origin_before}" "$(origin)"
check "D: group rows after refused group" 0 "$(target_sql 'select count(*) from oa where id > 3000')"

target_sql 'drop trigger oa_reject on oa'
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_d}"
check "D: origin after resume" "${commit_d}" "$(origin)"
check "D: rows after resume" "$(source_sql "$(digest 'id > 3000')")" "$(target_sql "$(digest 'id > 3000')")"

#
# Case E: a TRUNCATE after a transaction that queued deferred trigger events
#
# In one target transaction the TRUNCATE fails on the pending events, so the
# apply has to give up the group and apply these one by one.
target_sql "create function oa_note() returns trigger language plpgsql as \$\$
    begin return null; end \$\$;
    create constraint trigger oa_note after insert on oa deferrable initially deferred
    for each row when (new.v = 'note') execute function oa_note();
    alter table oa enable always trigger oa_note"
xid_e1=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (4001, 1, 'note'); commit")
source_sql "begin; truncate oa; insert into oa values (4002, 2, 'after truncate'); commit"
xid_e3=$(source_sql "begin; select pg_current_xact_id(); insert into oa values (4003, 3, 'note'); commit")
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_e=$(commit_lsn "${xid_e3}")
check "E: KEEPALIVE rows inside the group" 0 "$(keepalives_between "${xid_e1}" "${xid_e3}")"
pgcopydb stream sentinel set endpos "${commit_e}"

timeout 60s pgcopydb stream catchup --resume --endpos "${commit_e}" >"${TMPDIR}/truncate.log" 2>&1 || {
    cat "${TMPDIR}/truncate.log"
    exit 1
}
grep -q 'holds a TRUNCATE: applying the transactions after' "${TMPDIR}/truncate.log"
check "E: origin after TRUNCATE" "${commit_e}" "$(origin)"
check "E: rows after TRUNCATE" "$(source_sql "$(digest true)")" "$(target_sql "$(digest true)")"
target_sql 'drop trigger oa_note on oa'

#
# Case F: endpos at the 3rd of six transactions ends the group there
#
mapfile -t xids < <(txns 5001 6 row)
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_f3=$(commit_lsn "${xids[2]}")
commit_f=$(commit_lsn "${xids[5]}")
check "F: KEEPALIVE rows inside the group" 0 "$(keepalives_between "${xids[0]}" "${xids[5]}")"
pgcopydb stream sentinel set endpos "${commit_f3}"
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_f3}"
check "F: origin at endpos" "${commit_f3}" "$(origin)"
check "F: rows at endpos" "5001,5002,5003" "$(target_sql "select string_agg(id::text, ',' order by id) from oa where id > 5000")"
pgcopydb stream sentinel set endpos "${commit_f}"
timeout 60s pgcopydb stream catchup --resume --endpos "${commit_f}"
check "F: rows after resume" "$(source_sql "$(digest 'id > 5000')")" "$(target_sql "$(digest 'id > 5000')")"

#
# Case G: SIGKILL before the COMMIT of a group of three
#
mapfile -t xids < <(txns 6001 3 row)
timeout 60s pgcopydb stream prefetch --resume --endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
commit_g=$(commit_lsn "${xids[2]}")
check "G: KEEPALIVE rows inside the group" 0 "$(keepalives_between "${xids[0]}" "${xids[2]}")"
pgcopydb stream sentinel set endpos "${commit_g}"
kill_before_commit G "${commit_g}"

pgcopydb stream cleanup
echo "RESULT failures=${failures}"
test "${failures}" -eq 0
