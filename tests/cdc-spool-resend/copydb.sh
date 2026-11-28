#! /bin/bash

# The rule for transactions sent again holds when cleanup already deleted the
# segment of the first copy: the start then reads the high-water mark from the
# header of the segment it continues, and the keyless canary table shows a
# second apply as a second row.
#
# Cases source and source14 run that scenario against the PGVERSION source and
# an old one. Case diskfull fills a small work volume and pins the line that
# the operator matches.

set -euo pipefail

if test -z "${RESEND_CASE:-}"; then
    for c in source source14 diskfull; do
        RESEND_CASE=${c} bash "$0"
    done
    exit 0
fi
case "${RESEND_CASE}" in
    source | source14 | diskfull) ;;
    *) echo "FAIL: unknown RESEND_CASE ${RESEND_CASE}" >&2; exit 1 ;;
esac
echo "=== ${RESEND_CASE}"

db=spool_resend_${RESEND_CASE}
# the logs stay off the small volume of the disk-full case
LOGDIR=/tmp/spool-resend-${RESEND_CASE}
mkdir -p "${LOGDIR}"
if test "${RESEND_CASE}" = diskfull; then
    # only the CDC directory goes on the small volume: the catalog of the work
    # directory must stay writable, so that the spool write is what fails
    export TMPDIR=${LOGDIR}/work XDG_DATA_HOME=/mnt/spool-full/cdc
    mkdir -p "${TMPDIR}" "${XDG_DATA_HOME}" ||
        { echo "FAIL: the tmpfs at /mnt/spool-full is not writable" >&2; exit 1; }
else
    export PGCOPYDB_SOURCE_PGURI="postgres://postgres:h4ckm3@${RESEND_CASE}/postgres"
    export TMPDIR=${LOGDIR}/work XDG_DATA_HOME=${LOGDIR}/cdc
    mkdir -p "${TMPDIR}"
fi
snapshot_pid= receive_pid= catchup_pid= follow_pid= lock_pid= rc=0 failures=0

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${lock_pid}" || kill "${lock_pid}" 2>/dev/null || true
    for pid in "${receive_pid}" "${catchup_pid}" "${follow_pid}"; do
        test -z "${pid}" || kill -KILL -- "-${pid}" 2>/dev/null || true
    done
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${LOGDIR}"/*.log; do
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

# relation_records: the records of the relation log that name the table canary.
# Each record holds the name once, as a NUL-terminated string, so a count of
# the exact lines of the printable runs counts the records.
relation_records() {
    local log=${XDG_DATA_HOME}/pgcopydb/relation.log n
    test -f "${log}" || fail "no relation log at ${log}"
    n=$(tr -c '[:print:]' '\n' < "${log}" | grep -c -x canary || true)
    echo "${n}"
}

spool_records() {
    local filter=${1:-true}
    timeout 60s pgcopydb list spool --json | jq "[.[] | select(${filter})] | length"
}

spool_end_lsn() {
    timeout 60s pgcopydb list spool --json | jq -r ".[] | select(.xid == $1) | .end_lsn"
}

# segment_without_index: a last segment that holds no indexed transaction, the
# state a rotation leaves. The next start removes it and takes the high-water
# mark from its header, which is what this case tests.
segment_without_index() {
    local seg last=
    for seg in "${XDG_DATA_HOME}"/pgcopydb/*.seg; do
        test -f "${seg}" || return 1
        last=${seg}
    done
    test ! -s "${last%.seg}.idx"
}

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots
                         where slot_name = 'pgcopydb' and active")" = 1
}

terminate_walsender() {
    source_sql "select pg_terminate_backend(active_pid) from pg_replication_slots
                 where slot_name = 'pgcopydb' and active" > /dev/null
}

lock_granted() {
    test "$(target_sql "select count(*) from pg_locks l join pg_class c on c.oid = l.relation
                         where c.relname = 'pad' and l.mode = 'AccessExclusiveLock'
                           and l.granted")" -ge 1
}

canary_rows() { target_sql 'select count(*) from canary'; }
pad_rows() { target_sql 'select count(*) from pad'; }
canary_is() { test "$(canary_rows)" = "$1"; }
pad_caught_up() { test "$(pad_rows)" = "$(source_sql 'select count(*) from pad')"; }
relations_at_least() { test "$(relation_records)" -ge "$1"; }
not_indexed() { test "$(spool_records ".xid == $1")" = 0; }
indexed_once() { test "$(spool_records ".xid == $1")" = 1; }

# pruned: the cleanup pass of applied segments, then the state it leaves.  The
# follow supervisor runs that pass every five minutes, and this phase runs
# receive and catchup on their own, so the pass is asked for here instead.
pruned() {
    timeout 60s pgcopydb stream prune > "${LOGDIR}/prune.log" 2>&1 ||
        fail "pgcopydb stream prune exited $?"
    not_indexed "$1"
}

poll() {
    local what=$1 deadline=$((SECONDS + $2)) pid
    shift 2
    until "$@"; do
        for pid in "${receive_pid}" "${catchup_pid}" "${follow_pid}"; do
            test -z "${pid}" || kill -0 "${pid}" 2>/dev/null ||
                fail "pgcopydb exited while waiting for ${what}"
        done
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# wait_pid <pid> <seconds> <name>: wait for it to exit, its status in rc
wait_pid() {
    local pid=$1 deadline=$((SECONDS + $2))
    while kill -0 "${pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "$3 did not exit within $2 s"
        sleep 0.5
    done
    rc=0
    wait "${pid}" || rc=$?
    kill -KILL -- "-${pid}" 2>/dev/null || true
}

pgcopydb ping
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "create database ${db}"
psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "create database ${db}"
export PGCOPYDB_SOURCE_PGURI=${PGCOPYDB_SOURCE_PGURI%/*}/${db}
export PGCOPYDB_TARGET_PGURI=${PGCOPYDB_TARGET_PGURI%/*}/${db}
echo "${RESEND_CASE}: source PostgreSQL $(source_sql 'show server_version')"

# canary has no key, so a second apply of its transaction adds a row instead of
# failing on a duplicate; pad fills the segments
source_sql 'create table canary (v text); create table pad (id integer primary key, v text)'

pgcopydb snapshot --follow > "${LOGDIR}/snapshot.out" 2> "${LOGDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${LOGDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${LOGDIR}/setup.log" 2>&1
pgcopydb clone > "${LOGDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=
pgcopydb stream sentinel set apply

if test "${RESEND_CASE}" = diskfull; then
    # apply waits on this lock, so the low-water mark stays put, cleanup
    # deletes no segment and the changes fill the volume
    psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
         -c 'begin; lock table pad in access exclusive mode; select pg_sleep(3600)' \
         > /dev/null 2>&1 &
    lock_pid=$!
    poll 'the target lock' 30 lock_granted

    setsid pgcopydb follow --resume --not-consistent --notice > "${LOGDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active

    # more changes than the volume holds, in batches, until follow gives up
    for batch in $(seq 1 40); do
        kill -0 "${follow_pid}" 2>/dev/null || break
        source_sql "insert into pad
                     select g + ${batch} * 20000, repeat('f', 200)
                       from generate_series(1, 20000) g" > /dev/null
    done
    wait_pid "${follow_pid}" 300 follow
    follow_pid=
    echo "diskfull: follow exited ${rc} after $(du -sk "${XDG_DATA_HOME}" | cut -f1) kB of spool"
    test "${rc}" != 0 || { echo "FAIL diskfull: follow exited 0 on a full volume";
                           failures=$((failures + 1)); }

    # the line that O2 matches: the segment file and the system error
    enospc=$(grep -E '(ERROR|FATAL)' "${LOGDIR}/follow.log" |
             grep -E '\.seg' | grep 'No space left on device' | head -n 1 || true)
    if test -n "${enospc}"; then
        echo "OK   diskfull: the full volume ended the run with"
        echo "     ${enospc}"
    else
        echo "FAIL diskfull: no ERROR or FATAL line names a segment file and"
        echo "     'No space left on device'; the last lines of the log were"
        grep -E '(ERROR|FATAL)' "${LOGDIR}/follow.log" | cut -c1-240 | tail -n 10 || true
        failures=$((failures + 1))
    fi
    # kept for the operator work package that matches this line
    echo "==> ${LOGDIR}/follow.log (kept)"
    tail -n 20 "${LOGDIR}/follow.log"

    kill "${lock_pid}" || true
    lock_pid=
    target_sql "select pg_terminate_backend(pid) from pg_stat_activity
                 where query like '%pg_sleep(3600)%' and pid <> pg_backend_pid()" > /dev/null
    test "${failures}" = 0 || fail "${failures} checks failed"
    echo "PASS: a full work volume ended the run with the ENOSPC line"
    exit 0
fi

# keeper never moves, so it holds the position the slot had before the canary
# transaction. Copying it later puts the slot back there, which is what a
# source that lost its confirmed position does.
source_sql "select pg_create_logical_replication_slot('keeper', 'pgoutput')" > /dev/null

# a small segment size, so that cleanup can delete whole segments
setsid pgcopydb stream receive --resume --notice --max-replaydb-size 64kB \
    > "${LOGDIR}/receive.log" 2>&1 &
receive_pid=$!
setsid pgcopydb stream catchup --resume --notice > "${LOGDIR}/catchup.log" 2>&1 &
catchup_pid=$!
poll 'the slot to be streamed' 60 slot_active

xid_a=$(source_sql "begin; select txid_current(); insert into canary values ('a'); commit")
poll 'the canary transaction to be indexed' 120 indexed_once "${xid_a}"
end_a=$(spool_end_lsn "${xid_a}")
test -n "${end_a}" || fail "no index record for the canary transaction ${xid_a}"
echo "${RESEND_CASE}: the canary transaction is xid ${xid_a}, which ends at ${end_a}"

# padding behind it, so that its segment is neither the first nor the last one,
# and a terminated walsender in between
for batch in 1 2 3; do
    source_sql "insert into pad
                 select g + ${batch} * 5000, repeat('p', 100)
                   from generate_series(1, 5000) g" > /dev/null
    test "${batch}" = 3 || terminate_walsender
done

poll 'the canary row on the target' 300 canary_is 1
poll 'the padding on the target' 300 pad_caught_up
poll 'cleanup to delete the segment of the canary transaction' 300 pruned "${xid_a}"
poll 'a rotation to leave a segment without an index record' 120 segment_without_index

# a reconnect of the first phase can have sent the canary RELATION again, so
# the proof of the resend counts from the records that are there now
before_relations=$(relation_records)
echo "${RESEND_CASE}: ${before_relations} relation records for canary before the resend"

kill -KILL -- "-${receive_pid}" "-${catchup_pid}" || true
wait "${receive_pid}" "${catchup_pid}" || true
receive_pid= catchup_pid=
# the killed apply holds the target origin through its backend
target_sql "select pg_terminate_backend(pid) from pg_stat_activity
             where datname = current_database() and backend_type = 'client backend'
               and pid <> pg_backend_pid()" > /dev/null

source_sql "select pg_drop_replication_slot('pgcopydb')" > /dev/null
source_sql "select pg_copy_logical_replication_slot('keeper', 'pgcopydb')" > /dev/null
check 'the slot moved back below the canary transaction' t \
    "$(source_sql "select confirmed_flush_lsn < '${end_a}'::pg_lsn
                     from pg_replication_slots where slot_name = 'pgcopydb'")"

setsid pgcopydb stream receive --resume --notice --max-replaydb-size 64kB \
    >> "${LOGDIR}/receive.log" 2>&1 &
receive_pid=$!
poll 'the slot to be streamed again' 60 slot_active
# The canary is written once, so a second relation record for it is the proof
# that the source sent its transaction again, with the segment of the first
# copy already deleted.
poll 'the canary RELATION of the resend' 300 relations_at_least $((before_relations + 1))
check 'the resend added no index record' 0 "$(spool_records ".xid == ${xid_a}")"

kill -KILL -- "-${receive_pid}" || true
wait "${receive_pid}" || true
receive_pid=

# the run ends at the current position, with everything applied
source_sql "insert into pad values (1, 'last')"
pgcopydb stream sentinel set endpos --current
setsid pgcopydb follow --resume --not-consistent --notice > "${LOGDIR}/follow.log" 2>&1 &
follow_pid=$!
wait_pid "${follow_pid}" 600 follow
follow_pid=
check "${RESEND_CASE} follow exit status" 0 "${rc}"
check "${RESEND_CASE} canary rows on the target" 1 "$(canary_rows)"

for t in canary pad; do
    sql="copy (select * from ${t} order by 1) to stdout"
    psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${LOGDIR}/src_${t}.txt"
    psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${LOGDIR}/tgt_${t}.txt"
    test -s "${LOGDIR}/src_${t}.txt" || fail "${RESEND_CASE}: the source table ${t} is empty"
    if ! diff -q "${LOGDIR}/src_${t}.txt" "${LOGDIR}/tgt_${t}.txt" > /dev/null; then
        echo "target ${t}: $(target_sql "select count(*) from ${t}") rows, source: $(source_sql "select count(*) from ${t}")"
        diff "${LOGDIR}/src_${t}.txt" "${LOGDIR}/tgt_${t}.txt" | head -5 || true
        fail "${RESEND_CASE}: table ${t} differs"
    fi
done

test "${failures}" = 0 || fail "${failures} checks failed"
pgcopydb stream cleanup > "${LOGDIR}/cleanup.log" 2>&1
source_sql "select pg_drop_replication_slot('keeper')" > /dev/null
echo "PASS: the canary transaction was applied once although its segment was gone (${RESEND_CASE})"
