#! /bin/bash

set -euxo pipefail

export TMPDIR=/tmp/pgcopydb-shutdown
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
trap 'pkill -KILL -x pgcopydb || true' EXIT

source_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
catalog_sql() { sqlite3 -init /dev/null -batch -noheader -list "${TMPDIR}/pgcopydb/schema/source.db" "$1"; }

pgcopydb ping
source_sql 'drop table if exists shutdown_guard; create table shutdown_guard(id integer primary key, payload text)'
target_sql 'drop table if exists shutdown_guard'
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

source_sql 'insert into shutdown_guard select i, md5(i::text) from generate_series(1, 1000) i'
confirmed=$(source_sql 'select pg_current_wal_flush_lsn()')
digest_sql="select count(*), md5(string_agg(row(id, payload)::text, ',' order by id)) from shutdown_guard"
expected=$(source_sql "${digest_sql}")
pgcopydb stream sentinel set apply
pgcopydb follow --resume >"${TMPDIR}/follow.log" 2>&1 &
follow_pid=$!
deadline=$((SECONDS + 60))
while test "$(catalog_sql 'select replay_lsn from sentinel')" != "${confirmed}"; do
    if ! kill -0 "${follow_pid}" || test "${SECONDS}" -ge "${deadline}"; then
        cat "${TMPDIR}/follow.log"
        exit 1
    fi
    sleep 0.1
done
test "$(target_sql "${digest_sql}")" = "${expected}"
test "$(target_sql "select pg_replication_origin_progress('pgcopydb', false)")" = "${confirmed}"

pkill -TERM -x pgcopydb
deadline=$((SECONDS + 60))
while kill -0 "${follow_pid}" 2>/dev/null; do
    if test "${SECONDS}" -ge "${deadline}"; then
        cat "${TMPDIR}/follow.log"
        echo 'FAIL: follow did not exit after SIGTERM' >&2
        exit 1
    fi
    sleep 0.1
done
status=0
wait "${follow_pid}" || status=$?
wait "${snapshot_pid}"
cat "${TMPDIR}/follow.log"
replay=$(catalog_sql 'select replay_lsn from sentinel')
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', false)")
state=$(catalog_sql "select run_state, run_end_lsn from pipeline_state where process_name = 'apply'")
actual=$(target_sql "${digest_sql}")
echo "SIGTERM: exit=${status}, replay=${replay}, origin=${origin}, state=${state}, content=${actual}"
test "${status}" -eq 0
test "${replay}" = "${confirmed}"
test "${origin}" = "${confirmed}"
test "${state}" = "done|${confirmed}"
test "${actual}" = "${expected}"

source_sql 'insert into shutdown_guard select i, md5(i::text) from generate_series(1001, 2000) i'
endpos=$(source_sql 'select pg_current_wal_flush_lsn()')
timeout 60s pgcopydb stream prefetch --resume --endpos "${endpos}"

# Drain DML inside the target transaction, then kill before queuing COMMIT.
timeout 60s gdb -q -batch -x /usr/src/pgcopydb/apply-kill.gdb \
    --args pgcopydb stream catchup --resume --endpos "${endpos}"
replay=$(catalog_sql 'select replay_lsn from sentinel')
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', false)")
actual=$(target_sql "${digest_sql}")
echo "SIGKILL before COMMIT: replay=${replay}, origin=${origin}, content=${actual}"
test "${replay}" = "${confirmed}"
test "${origin}" = "${confirmed}"
test "${actual}" = "${expected}"
test "$(catalog_sql "select run_state from pipeline_state where process_name = 'apply'")" != done

timeout 60s pgcopydb stream catchup --resume --endpos "${endpos}"
replay=$(catalog_sql 'select replay_lsn from sentinel')
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', false)")
expected=$(source_sql "${digest_sql}")
actual=$(target_sql "${digest_sql}")
echo "Resumed apply: replay=${replay}, origin=${origin}, content=${actual}"
test "${replay}" = "${endpos}"
test "${origin}" = "${endpos}"
test "${actual%%|*}" -eq 2000
test "${actual}" = "${expected}"
test "$(catalog_sql "select run_state from pipeline_state where process_name = 'apply'")" = done

pgcopydb stream cleanup
trap - EXIT
echo 'PASS: SIGTERM after apply and SIGKILL before COMMIT resume'
