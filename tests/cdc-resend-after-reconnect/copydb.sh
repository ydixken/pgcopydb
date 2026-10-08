#! /bin/bash

# A reconnect makes receive send the unapplied backlog again, rewriting each
# row with a new id, and its 10 s flush can commit part of a re-sent
# transaction.  Apply must wait for that transaction, not apply the next one.

set -euo pipefail

# plugin:mode; resume kills pgcopydb where reconnect only ends the walsender,
# endpos stops the run at A's COMMIT while A is being sent again
if test -z "${RESEND_CASE:-}"; then
    for c in pgoutput:reconnect pgoutput:resume pgoutput:endpos test_decoding:reconnect; do
        RESEND_CASE=${c} bash "$0"
    done
    exit 0
fi
plugin=${RESEND_CASE%%:*}
mode=${RESEND_CASE#*:}
echo "=== ${plugin} ${mode}"

rows=${RESEND_ROWS:-500000}
db=resend_${plugin}_${mode}
export PGCOPYDB_OUTPUT_PLUGIN=${plugin}
export TMPDIR=/tmp/resend-${plugin}-${mode}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid= follow_pid= lock_pid= receive_pid= catchup_pid=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${receive_pid}" || kill -CONT "${receive_pid}" 2>/dev/null || true
    test -z "${lock_pid}" || kill "${lock_pid}" 2>/dev/null || true
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${catchup_pid}" || kill -KILL -- "-${catchup_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        tail -n 40 "${TMPDIR}/follow.log" 2>/dev/null || true
        tail -n 40 "${TMPDIR}/catchup.log" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

# the spool file holding xid $1, then "newest BEGIN id|COMMIT id|rows after that BEGIN"
spool() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" \
            "select max(id) filter (where action = 'B') || '|' ||
                    coalesce(max(id) filter (where action = 'C'), '') || '|' ||
                    count(*) filter (where id > (select max(id) from output
                                                  where action = 'B' and xid = $1))
               from output where xid = $1 having count(*) > 0"
    done
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}

tx_lock() {
    test "$(target_sql "select count(*) from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'tx' and $1")" -ge 1
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        kill -0 "${follow_pid:-${catchup_pid}}" 2>/dev/null || fail "pgcopydb exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

pgcopydb ping
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "create database ${db}"
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "create database ${db}"
export PGCOPYDB_SOURCE_PGURI=${PGCOPYDB_SOURCE_PGURI%/*}/${db}
export PGCOPYDB_TARGET_PGURI=${PGCOPYDB_TARGET_PGURI%/*}/${db}
source_sql 'create table tx (id integer primary key); create table t (id integer primary key, v text); create table pad (id integer primary key)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup
pgcopydb clone
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=

pgcopydb stream sentinel set apply
setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/follow.log" 2>&1 &
follow_pid=$!
poll 'the slot to be streamed' 60 slot_active

# X waits on this lock, so confirmed_flush stays below A and D
psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
     -c 'begin; lock table tx in access exclusive mode; select pg_sleep(3600)' > /dev/null 2>&1 &
lock_pid=$!
poll 'the target lock' 30 tx_lock "l.mode = 'AccessExclusiveLock' and l.granted"

source_sql 'insert into tx values (1)'
xid_a=$(source_sql "begin; select txid_current(); insert into t select g, 'A' from generate_series(1, ${rows}) g; commit")
xid_d=$(source_sql "begin; select txid_current(); insert into t values (-1, 'D'); commit")
echo "A: xid ${xid_a}, ${rows} rows; D: xid ${xid_d}"

deadline=$((SECONDS + 300))
until IFS='|' read -r _ commit_d _ <<<"$(spool "${xid_d}")" && test -n "${commit_d}"; do
    test "${SECONDS}" -lt "${deadline}" || fail "D's COMMIT never reached output.db"
    sleep 0.5
done
poll 'apply to block on X' 60 tx_lock "not l.granted"

# Stop receive between two SQLite statements, with the window open; it is
# the only writer, so a semaphore it last left at 0 is one it holds.
hold_receive() {
    local id
    kill -STOP "${receive_pid}"
    until test "$(ps -o stat= -p "${receive_pid}" | cut -c1)" = T; do sleep 0.05; done
    for id in $(ipcs -s | awk '$1 ~ /^0x/ {print $2}'); do
        if ipcs -s -i "${id}" | awk -v pid="${receive_pid}" \
               '/^semnum/ {t = 1; next} t && NF == 5 && $2 == 0 && $5 == pid {f = 1} END {exit !f}'; then
            kill -CONT "${receive_pid}"
            return 1
        fi
    done
    IFS='|' read -r begin_a commit_a resent <<<"$(spool "${xid_a}")"
    test "${begin_a}" -gt "${commit_a}" && return 0
    kill -CONT "${receive_pid}"
    return 2
}

# Each attempt makes receive send the backlog again; a flush (forced every
# few seconds by wal_sender_timeout) commits part of A, then we hold receive.
held=
for attempt in 1 2 3 4 5; do
    if test "${attempt}" -gt 1; then
        # receive gives up when a reconnect ends where the last one did
        xid_p=$(source_sql "begin; select txid_current(); insert into pad values (${attempt}); commit")
        deadline=$((SECONDS + 300))
        until IFS='|' read -r _ commit_p _ <<<"$(spool "${xid_p}")" && test -n "${commit_p}"; do
            test "${SECONDS}" -lt "${deadline}" || fail 'the pad transaction never reached output.db'
            sleep 0.2
        done
    fi
    IFS='|' read -r _ commit_before _ <<<"$(spool "${xid_a}")"
    poll 'an active walsender' 60 slot_active
    receive_pid=$(pgrep -f '^pgcopydb: follow receive')
    source_sql "select pg_terminate_backend(active_pid) from pg_replication_slots where slot_name = 'pgcopydb'" > /dev/null
    deadline=$((SECONDS + 300))
    while true; do
        IFS='|' read -r begin_a commit_a resent <<<"$(spool "${xid_a}")"
        if test "${begin_a}" -gt "${commit_a}"; then
            rc=0
            hold_receive || rc=$?
            if test "${rc}" -eq 0; then
                held=yes
                break
            fi
            test "${rc}" -eq 1 || break
        fi
        test "${commit_a}" -eq "${commit_before}" || break
        test "${SECONDS}" -lt "${deadline}" || fail 'receive did not send A again'
        sleep 0.05
    done
    echo "attempt ${attempt}: A BEGIN id ${begin_a}, COMMIT id ${commit_a}, ${resent} rows re-sent, held=${held:-no}"
    test -z "${held}" || break
    deadline=$((SECONDS + 300))
    until IFS='|' read -r begin_a commit_a _ <<<"$(spool "${xid_a}")" && test "${commit_a}" -gt "${begin_a}"; do
        test "${SECONDS}" -lt "${deadline}" || fail 'A was never sent again in full'
        sleep 0.2
    done
done
test -n "${held}" || fail 'never held receive with A partly sent again'

# a crash leaves A's partial copy for the next run; with no receive, that
# run's apply can only wait on A
if test "${mode}" = resume; then
    kill -KILL -- "-${follow_pid}"
    wait "${follow_pid}" || true
    follow_pid= receive_pid=
    # the killed apply's backend waits on the lock and keeps the origin busy
    others="from pg_stat_activity where datname = current_database()
              and backend_type = 'client backend' and pid <> pg_backend_pid()
              and query not like '%pg_sleep(3600)%'"
    target_sql "select pg_terminate_backend(pid) ${others}" > /dev/null
    deadline=$((SECONDS + 60))
    until test "$(target_sql "select count(*) ${others}")" = 0; do
        test "${SECONDS}" -lt "${deadline}" || fail 'the killed apply is still on the target'
        sleep 0.2
    done
    setsid pgcopydb stream catchup --resume --notice > "${TMPDIR}/catchup.log" 2>&1 &
    catchup_pid=$!
fi

kill "${lock_pid}"
lock_pid=
target_sql "select pg_terminate_backend(pid) from pg_stat_activity where query like '%pg_sleep(3600)%' and pid <> pg_backend_pid()" > /dev/null
x_applied() { test "$(target_sql 'select count(*) from tx')" = 1; }
poll 'apply to commit X' 60 x_applied

# Nothing signals that apply chose to wait, so watch it for a while: D
# must not commit before A, which receive cannot finish while held.
early=
deadline=$((SECONDS + 5))
while test "${SECONDS}" -lt "${deadline}"; do
    if test "$(target_sql 'select count(*) from t where id = -1')" != 0; then
        early="apply committed D while A was partly sent again"
        echo "${early}: A has $(target_sql 'select count(*) from t where id > 0') rows on the target"
        break
    fi
    sleep 0.2
done
if test "${mode}" = resume; then
    kill -0 "${catchup_pid}" 2>/dev/null || fail 'catchup exited while A was partly sent again'
    kill -TERM -- "-${catchup_pid}"
    wait "${catchup_pid}" || true
    catchup_pid=
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
else
    # endpos at A's COMMIT while receive is inside A: receive must write all of
    # A before it stops, and the run must end with A applied and D not
    if test "${mode}" = endpos; then
        lsn_a=$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader \
            "${XDG_DATA_HOME}"/pgcopydb/*-output.db \
            "select printf('%X/%X', lsn >> 32, lsn & 4294967295) from output
              where action = 'C' and xid = ${xid_a}")
        pgcopydb stream sentinel set endpos "${lsn_a}"
    fi
    kill -CONT "${receive_pid}"
fi

if test "${mode}" = endpos; then
    deadline=$((SECONDS + 600))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "follow did not stop at endpos ${lsn_a}"
        sleep 1
    done
    wait "${follow_pid}" || fail "follow exited with $? at endpos ${lsn_a}"
    follow_pid=
    origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', true)")
    got=$(target_sql "select count(*) filter (where id > 0) || '|' || count(*) filter (where id = -1) from t")
    echo "endpos ${lsn_a}: origin ${origin}, A rows|D rows on the target ${got}"
    test "${origin}" = "${lsn_a}" -a "${got}" = "${rows}|0" || fail "follow stopped at endpos ${lsn_a} without A applied exactly"
fi

source_sql 'insert into tx values (2)'
pgcopydb stream sentinel set endpos --current
if test "${mode}" = endpos; then
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
fi
deadline=$((SECONDS + 600))
while kill -0 "${follow_pid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
    sleep 1
done
wait "${follow_pid}" || fail "follow exited with $?"
follow_pid=

for t in tx t; do
    sql="copy (select * from ${t} order by id) to stdout"
    psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src_${t}.txt"
    psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt_${t}.txt"
    test -s "${TMPDIR}/src_${t}.txt"
    if ! diff -q "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" > /dev/null; then
        echo "target ${t}: $(target_sql "select count(*) from ${t}") rows, source: $(source_sql "select count(*) from ${t}")"
        diff "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" | head -5 || true
        fail "table ${t} differs"
    fi
done

test -z "${early}" || fail "${early}"
pgcopydb stream cleanup
echo "PASS: A (${rows} rows) and D applied after a re-send (${plugin}, ${mode})"
