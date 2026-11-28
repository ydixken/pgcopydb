#! /bin/bash

# Performance mode logs every RELATION message of a segment in the relation
# log, also inside a transaction that the rule for resends skips, because the
# reader of a later transaction needs that definition.
#
# Case skipped: a transaction is sent again after a restart of follow, and its
# RELATION reaches the relation log although the transaction itself is skipped.
# The next new transaction on that table still applies.
# Case altered: a column is added on source and target while follow runs, and
# the changes after it carry the column.

set -euo pipefail

if test -z "${RELATION_CASE:-}"; then
    for c in skipped altered; do
        RELATION_CASE=${c} bash "$0"
    done
    exit 0
fi
case "${RELATION_CASE}" in
    skipped | altered) ;;
    *) echo "FAIL: unknown RELATION_CASE ${RELATION_CASE}" >&2; exit 1 ;;
esac
echo "=== ${RELATION_CASE}"

db=relation_${RELATION_CASE}
export TMPDIR=/tmp/spool-relation-${RELATION_CASE}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid= follow_pid= lock_pid= rc=0 failures=0

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${lock_pid}" || kill "${lock_pid}" 2>/dev/null || true
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

check() {
    if test "$2" = "$3"; then
        echo "OK   $1: $3"
    else
        echo "FAIL $1: expected $2, got $3"
        failures=$((failures + 1))
    fi
}

check_ge() {
    if test "$3" -ge "$2"; then
        echo "OK   $1: $3"
    else
        echo "FAIL $1: expected $2 or more, got $3"
        failures=$((failures + 1))
    fi
}

# relation_records: the records of the relation log that name the table
# relcheck. Each record holds the name once, as a NUL-terminated string, so a
# count of the exact lines of the printable runs counts the records.
relation_records() {
    local log=${XDG_DATA_HOME}/pgcopydb/relation.log n
    test -f "${log}" || fail "no relation log at ${log}"
    n=$(tr -c '[:print:]' '\n' < "${log}" | grep -c -x relcheck || true)
    echo "${n}"
}

# spool_records [jq filter]: index records of the spool, all or the matching ones
spool_records() {
    local filter=${1:-true}
    timeout 60s pgcopydb list spool --json | jq "[.[] | select(${filter})] | length"
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots
                         where slot_name = 'pgcopydb' and active")" = 1
}

lock_granted() {
    test "$(target_sql "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
                         where c.relname = 'relcheck' and l.mode = 'AccessExclusiveLock'
                           and l.granted")" -ge 1
}

target_rows() { target_sql 'select count(*) from relcheck'; }
rows_are() { test "$(target_rows)" = "$1"; }
relations_at_least() { test "$(relation_records)" -ge "$1"; }
indexed_once() { test "$(spool_records ".xid == $1")" = 1; }

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        test -z "${follow_pid}" || kill -0 "${follow_pid}" 2>/dev/null ||
            fail "follow exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# follow_wait: wait for the background follow to exit, its status in rc
follow_wait() {
    local deadline=$((SECONDS + 300))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "follow did not exit within 300 s"
        sleep 0.5
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    follow_pid=
    test "${rc}" = 0 || grep -E 'ERROR|FATAL' "${TMPDIR}/follow.log" | cut -c1-240 | tail -n 5 || true
}

pgcopydb ping
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "create database ${db}"
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "create database ${db}"
export PGCOPYDB_SOURCE_PGURI=${PGCOPYDB_SOURCE_PGURI%/*}/${db}
export PGCOPYDB_TARGET_PGURI=${PGCOPYDB_TARGET_PGURI%/*}/${db}

# relcheck is the only table of the case, and its name is long enough that no
# run of printable bytes in the relation log matches it by chance
source_sql 'create table relcheck (id integer primary key, v text)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=
pgcopydb stream sentinel set apply

if test "${RELATION_CASE}" = skipped; then
    # apply waits on this lock, so no flush position is reported and the source
    # sends the first transaction again to the next receive
    psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
         -c 'begin; lock table relcheck in access exclusive mode; select pg_sleep(3600)' \
         > /dev/null 2>&1 &
    lock_pid=$!
    poll 'the target lock' 30 lock_granted

    setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active

    # the first change on relcheck makes pgoutput send its RELATION inside
    # this transaction
    xid=$(source_sql "begin; select txid_current();
                      insert into relcheck values (1, 'first'); commit")
    echo "skipped: the transaction of relcheck is xid ${xid}"
    poll 'the transaction to be indexed' 120 indexed_once "${xid}"
    check 'relation records before the resend' 1 "$(relation_records)"

    kill -KILL -- "-${follow_pid}" || true
    wait "${follow_pid}" || true
    follow_pid=
    # the killed apply still holds the origin through its target backend
    target_sql "select pg_terminate_backend(pid) from pg_stat_activity
                 where datname = current_database() and backend_type = 'client backend'
                   and pid <> pg_backend_pid() and query not like '%pg_sleep(3600)%'" > /dev/null

    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed again' 60 slot_active
    # The RELATION of the skipped transaction is logged a second time, and that
    # record is the proof that the source sent the transaction again.
    poll 'the RELATION of the resend' 300 relations_at_least 2
    check 'the resend added no index record' 1 "$(spool_records ".xid == ${xid}")"

    kill "${lock_pid}" || true
    lock_pid=
    target_sql "select pg_terminate_backend(pid) from pg_stat_activity
                 where query like '%pg_sleep(3600)%' and pid <> pg_backend_pid()" > /dev/null
    poll 'the skipped transaction on the target' 120 rows_are 1

    # the next new transaction on relcheck applies with the logged definition
    source_sql "insert into relcheck values (2, 'second')"
else
    setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active

    source_sql "insert into relcheck values (1, 'before')"
    poll 'the first transaction on the target' 120 rows_are 1

    # the column is added on both sides while follow runs: pgoutput then sends a
    # second definition of relcheck, and the changes after it carry w
    source_sql 'alter table relcheck add column w text'
    target_sql 'alter table relcheck add column w text'
    source_sql "insert into relcheck values (2, 'after', 'w2')"
    source_sql "update relcheck set w = 'w1' where id = 1"
    poll 'the second definition of relcheck' 300 relations_at_least 2
fi

pgcopydb stream sentinel set endpos --current
follow_wait
check "${RELATION_CASE} follow exit status" 0 "${rc}"
check "${RELATION_CASE} rows on the target" 2 "$(target_rows)"
check_ge "${RELATION_CASE} relation records for relcheck" 2 "$(relation_records)"
test "${RELATION_CASE}" != altered ||
    check 'the added column on the target' 2 \
        "$(target_sql "select count(*) from relcheck where w in ('w1', 'w2')")"

sql='copy (select * from relcheck order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src.txt"
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt.txt"
test -s "${TMPDIR}/src.txt" || fail "${RELATION_CASE}: the source table is empty"
if ! diff -q "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" > /dev/null; then
    diff "${TMPDIR}/src.txt" "${TMPDIR}/tgt.txt" | head -5 || true
    fail "${RELATION_CASE}: table relcheck differs"
fi

test "${failures}" = 0 || fail "${failures} checks failed"
pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: the relation log served the ${RELATION_CASE} case"
