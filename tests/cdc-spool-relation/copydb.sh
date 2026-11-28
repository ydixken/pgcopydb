#! /bin/bash

# Performance mode writes the RELATION messages of a segment to the relation
# log, also inside a transaction that the rule for resends skips, because the
# reader of a later transaction needs that definition. A message equal to the
# last one of its relation is not written again, and a restart reads the log
# back, so only a definition that changed appends a record.
#
# Case altered: a column is added on source and target while follow runs, and
# the changes after it carry the column.
#
# A transaction sent again carries the definition it carried before, so it
# appends nothing, and no case here can watch a resend. The skip rule has a
# unit case in tests/cdc-spool-format; a resend the spool does not take twice
# is cdc-resend-after-reconnect in performance mode, which keeps the segment
# of the first copy, and cdc-spool-resend, which deletes it first.

set -euo pipefail

# altered is the only case; the variable stays for the ones the suite may hold
RELATION_CASE=${RELATION_CASE:-altered}
case "${RELATION_CASE}" in
    altered) ;;
    *) echo "FAIL: unknown RELATION_CASE ${RELATION_CASE}" >&2; exit 1 ;;
esac
echo "=== ${RELATION_CASE}"

db=relation_${RELATION_CASE}
export TMPDIR=/tmp/spool-relation-${RELATION_CASE}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
snapshot_pid= follow_pid= rc=0 failures=0

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

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots
                         where slot_name = 'pgcopydb' and active")" = 1
}

target_rows() { target_sql 'select count(*) from relcheck'; }
rows_are() { test "$(target_rows)" = "$1"; }
relations_at_least() { test "$(relation_records)" -ge "$1"; }

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

pgcopydb stream sentinel set endpos --current
follow_wait
check "${RELATION_CASE} follow exit status" 0 "${rc}"
check "${RELATION_CASE} rows on the target" 2 "$(target_rows)"
check_ge "${RELATION_CASE} relation records for relcheck" 2 "$(relation_records)"
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
