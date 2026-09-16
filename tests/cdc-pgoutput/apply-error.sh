#! /bin/bash

set -euxo pipefail

source /usr/src/pgcopydb/spool.sh

boundary=${1:?expected commit or between}
case "${boundary}" in
    commit|between) ;;
    *) exit 1 ;;
esac

TMPDIR=$(mktemp -d /tmp/pgcopydb-apply-${boundary}.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid=
trap 'test -z "${snapshot_pid}" || { kill -TERM "${snapshot_pid}" 2>/dev/null || true; wait "${snapshot_pid}" 2>/dev/null || true; }' EXIT

source_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
catalog_sql() { sqlite3 -init /dev/null -batch -noheader -list "${TMPDIR}/pgcopydb/schema/source.db" "$1"; }

pgcopydb ping
source_sql 'drop table if exists apply_guard; create table apply_guard(id integer primary key)'
target_sql 'drop table if exists apply_guard'

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
wait "${snapshot_pid}"
snapshot_pid=

# CHECK constraints are enforced even with session_replication_role = replica.
target_sql 'alter table apply_guard add constraint reject_two check (id <> 2)'
xid1=$(source_sql 'begin; select pg_current_xact_id(); insert into apply_guard values (1); commit')
xid2=$(source_sql 'begin; select pg_current_xact_id(); insert into apply_guard values (2); commit')
if test "${boundary}" = between; then
    source_sql 'select pg_switch_wal()' >/dev/null
    endpos=$(source_sql 'select pg_current_wal_flush_lsn()')
fi
xid3=$(source_sql 'begin; select pg_current_xact_id(); insert into apply_guard values (3); commit')
receive_bound=$(source_sql 'select pg_current_wal_flush_lsn()')

timeout 60s pgcopydb stream prefetch --resume --endpos "${receive_bound}"
spool_transaction "${xid1}" 1
confirmed=${commit_lsn}
spool_transaction "${xid2}" 1
recovered=${commit_lsn}
spool_transaction "${xid3}" 1
b3=${begin_lsn}
if test "${boundary}" = commit; then
    endpos=${recovered}
else
    test "$(source_sql "select '${recovered}'::pg_lsn < '${endpos}'::pg_lsn and '${endpos}'::pg_lsn < '${b3}'::pg_lsn")" = t
    echo "Between boundary: C2=${recovered} < endpos=${endpos} < B3=${b3}"
fi

pgcopydb stream sentinel set endpos "${endpos}"
pgcopydb stream sentinel set apply
status=0
timeout 60s pgcopydb stream catchup --resume --endpos "${endpos}" || status=$?
replay=$(pgcopydb stream sentinel get --replay-lsn)
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', true)")
state=$(catalog_sql "select run_state, run_end_lsn, last_txn_processed from pipeline_state where process_name = 'apply'")
rows=$(target_sql "select string_agg(id::text, ',' order by id) from apply_guard")
echo "Rejected (${boundary}): exit=${status}, replay=${replay}, origin=${origin}, state=${state}, rows=${rows}, expected=${confirmed}"
test "${status}" -ne 0
test "${status}" -ne 124
test "${replay}" = "${confirmed}"
test "${origin}" = "${confirmed}"
test "${state}" = "error|${confirmed}|0"
test "${rows}" = 1
test "$(target_sql 'select count(*) from apply_guard where id = 2')" -eq 0

target_sql 'alter table apply_guard drop constraint reject_two'
timeout 60s pgcopydb stream catchup --resume --endpos "${endpos}"
replay=$(pgcopydb stream sentinel get --replay-lsn)
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', true)")
state=$(catalog_sql "select run_state, run_end_lsn, last_txn_processed from pipeline_state where process_name = 'apply'")
rows=$(target_sql "select string_agg(id::text, ',' order by id) from apply_guard")
echo "Recovered (${boundary}): replay=${replay}, origin=${origin}, state=${state}, ids=${rows}, endpos=${endpos}"
test "${replay}" = "${recovered}"
test "${origin}" = "${recovered}"
if test "${boundary}" = commit; then
    test "${state}" = "done|${recovered}|1"
else
    # Inline transform sees B3 past endpos but must not apply that transaction.
    test "${state}" = "done|${recovered}|0"
fi
test "${rows}" = '1,2'

pgcopydb stream cleanup
trap - EXIT
echo "PASS: confirmed apply progress and SQL error handling (${boundary})"
