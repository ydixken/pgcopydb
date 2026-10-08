#! /bin/bash

set -euxo pipefail

source /usr/src/pgcopydb/spool.sh

TMPDIR=$(mktemp -d /tmp/pgcopydb-shutdown.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid= follow_pid= debugger_pid= apply_pid= probe_pid= barrier_dir=

cleanup() {
    local status=$? pid
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    test -z "${apply_pid}" || kill -KILL "${apply_pid}" 2>/dev/null || true
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    for pid in "${debugger_pid}" "${probe_pid}" "${snapshot_pid}"; do
        if test -n "${pid}"; then
            kill -TERM "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    test -z "${barrier_dir}" || rm -rf "${barrier_dir}"
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
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

xid1=$(source_sql 'begin; select pg_current_xact_id(); insert into shutdown_guard select i, md5(i::text) from generate_series(1, 1000) i; commit')
receive_bound=$(source_sql 'select pg_current_wal_flush_lsn()')
timeout 60s pgcopydb stream prefetch --resume --endpos "${receive_bound}"
spool_transaction "${xid1}" 1000
confirmed=${commit_lsn}
digest_sql="select count(*), md5(string_agg(row(id, payload)::text, ',' order by id)) from shutdown_guard"
expected=$(source_sql "${digest_sql}")
pgcopydb stream sentinel set endpos 0/0
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

pgid=$(ps -o pgid= -p "${follow_pid}")
test "${pgid// /}" = "${follow_pid}"
kill -TERM -- "-${follow_pid}"
kill -TERM "${snapshot_pid}"
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
follow_pid=
wait "${snapshot_pid}"
snapshot_pid=
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

# The marker follows all INSERTs; the separate large UPDATE flushes it through libpq.
xid2=$(source_sql "begin; select pg_current_xact_id();
    insert into shutdown_guard select i, md5(i::text) from generate_series(1001, 2000) i;
    update shutdown_guard set payload = 'pre-commit marker' where id = 1;
    update shutdown_guard set payload = repeat('x', 16384) where id = 2;
    commit")
receive_bound=$(source_sql 'select pg_current_wal_flush_lsn()')
timeout 60s pgcopydb stream prefetch --resume --endpos "${receive_bound}"
spool_transaction "${xid2}" 1000 2
endpos=${commit_lsn}
pgcopydb stream sentinel set endpos "${endpos}"

barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
timeout 90s gdb -q -batch \
    -ex "set \$barrier_dir = \"${barrier_dir}\"" \
    -ex "set \$expected_lsn = \"${endpos}\"" \
    -x /usr/src/pgcopydb/apply-kill.gdb \
    --args pgcopydb stream catchup --resume --endpos "${endpos}" >"${TMPDIR}/gdb.log" 2>&1 &
debugger_pid=$!
deadline=$((SECONDS + 60))
while ! test -s "${barrier_dir}/paused"; do
    kill -0 "${debugger_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
read -r paused_pid paused_lsn <"${barrier_dir}/paused"
[[ ${paused_pid} =~ ^[1-9][0-9]*$ ]]
kill -0 "${paused_pid}"
apply_pid=${paused_pid}
test "${paused_lsn}" = "${endpos}"

# A blocked row lock proves the ordered marker UPDATE actually executed uncommitted.
probe_name=shutdown-probe-${apply_pid}
PGAPPNAME=${probe_name} timeout 125s psql -AtqX -v ON_ERROR_STOP=1 \
    -d "${PGCOPYDB_TARGET_PGURI}" \
    -c "set statement_timeout = '120s'; select id from shutdown_guard where id = 1 for update" \
    >"${TMPDIR}/probe.log" 2>&1 &
probe_pid=$!
deadline=$((SECONDS + 45))
# Apply, control, and transform connections share the process application name.
while true; do
    apply_backend=$(target_sql "select apply.pid
    from pg_stat_activity probe join pg_stat_activity apply
      on pg_blocking_pids(probe.pid) = array[apply.pid]
    where probe.application_name = '${probe_name}' and probe.wait_event_type = 'Lock'
      and apply.application_name like 'pgcopydb[${apply_pid}] %'
      and apply.backend_xid is not null and apply.xact_start is not null
      and apply.state in ('active', 'idle in transaction')")
    if [[ ${apply_backend} =~ ^[1-9][0-9]*$ ]]; then break; fi
    kill -0 "${debugger_pid}" "${apply_pid}" "${probe_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
kill -0 "${debugger_pid}" "${apply_pid}" "${probe_pid}"
echo "Pre-COMMIT barrier: inferior=${apply_pid}, backend=${apply_backend}, probe=${probe_name}, COMMIT=${endpos}"
test "$(target_sql "${digest_sql}")" = "${expected}"
printf '%s\n' "${apply_pid}" >"${barrier_dir}/kill.tmp"
mv "${barrier_dir}/kill.tmp" "${barrier_dir}/kill"
wait "${debugger_pid}"
debugger_pid= apply_pid=
cat "${TMPDIR}/gdb.log"
deadline=$((SECONDS + 60))
while test "$(target_sql "select count(*) from pg_stat_activity where pid = ${apply_backend}")" != 0 \
    || kill -0 "${probe_pid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done
wait "${probe_pid}"
probe_pid=
test "$(cat "${TMPDIR}/probe.log")" = 1
replay=$(catalog_sql 'select replay_lsn from sentinel')
origin=$(target_sql "select pg_replication_origin_progress('pgcopydb', false)")
actual=$(target_sql "${digest_sql}")
echo "SIGKILL before COMMIT: replay=${replay}, origin=${origin}, content=${actual}"
test "${replay}" = "${confirmed}"
test "${origin}" = "${confirmed}"
test "${actual}" = "${expected}"
state=$(catalog_sql "select run_state, run_end_lsn from pipeline_state where process_name = 'apply'")
test -n "${state}"
test "${state%%|*}" != done

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
test "$(catalog_sql "select run_state, run_end_lsn, last_txn_processed from pipeline_state where process_name = 'apply'")" = "done|${endpos}|1"

pgcopydb stream cleanup
echo 'PASS: SIGTERM after apply and SIGKILL before COMMIT resume'
