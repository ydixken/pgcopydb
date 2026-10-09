#! /bin/bash

# Receive must exit cleanly when the source ends its walsender during
# IDENTIFY_SYSTEM. GDB holds receive there while the test terminates the
# walsender; a second receive and catchup must then reach endpos.

set -euxo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-dying-source.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid='' debugger_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    for pid in "${debugger_pid}" "${snapshot_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }

# wait_for <description> <command...>: poll with a deadline
wait_for() {
    local description=$1 deadline=$((SECONDS + 60))
    shift
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || { echo "FAIL: timed out: ${description}"; return 1; }
        sleep 0.1
    done
}

pgcopydb ping
source_sql 'drop table if exists dying; create table dying (id integer primary key, v text)'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" &
snapshot_pid=$!
wait_for 'exported snapshot' test -s "${TMPDIR}/snapshot.out"
pgcopydb stream setup
pgcopydb clone --drop-if-exists
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}" || true
snapshot_pid=

source_sql "insert into dying select i, md5(i::text) from generate_series(1, 100) i"
endpos=$(source_sql 'select pg_current_wal_flush_lsn()')
source_sql "insert into dying values (101, 'after endpos')"

barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
timeout 120s gdb -q -batch \
    -ex "set \$barrier_dir = \"${barrier_dir}\"" \
    -x /usr/src/pgcopydb/hold-at-identify-system.gdb \
    --args pgcopydb stream receive --resume --endpos "${endpos}" >"${TMPDIR}/receive.log" 2>&1 &
debugger_pid=$!
wait_for 'receive held at IDENTIFY_SYSTEM' test -s "${barrier_dir}/paused"

walsenders="from pg_stat_activity where backend_type = 'walsender'"
test "$(source_sql "select count(pg_terminate_backend(pid)) ${walsenders}")" = 1
walsender_gone() {
    kill -0 "${debugger_pid}"
    test "$(source_sql "select count(*) ${walsenders}")" = 0
}
wait_for 'the walsender exits' walsender_gone
touch "${barrier_dir}/release"

status=0
wait "${debugger_pid}" || status=$?
debugger_pid=
cat "${TMPDIR}/receive.log"

# Without this line IDENTIFY_SYSTEM never met the dead walsender.
grep -q 'Failed to IDENTIFY_SYSTEM' "${TMPDIR}/receive.log"
# EXIT_CODE_SOURCE: a source error, where an abort exits 1 through gdb
test "${status}" -eq 6

timeout 120s pgcopydb stream receive --resume --endpos "${endpos}" >"${TMPDIR}/receive2.log" 2>&1
grep -q 'stopping: endpos is' "${TMPDIR}/receive2.log"
pgcopydb stream sentinel set apply
timeout 120s pgcopydb stream catchup --resume --endpos "${endpos}" >"${TMPDIR}/catchup.log" 2>&1

sql='copy (select * from dying where id <= 100 order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" >"${TMPDIR}/source.txt"
sql='copy (select * from dying order by id) to stdout'
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" >"${TMPDIR}/target.txt"
test "$(wc -l <"${TMPDIR}/source.txt")" -eq 100
diff "${TMPDIR}/source.txt" "${TMPDIR}/target.txt"

pgcopydb stream cleanup
echo "PASS: receive exited cleanly on a walsender ended during IDENTIFY_SYSTEM, and the rerun reached endpos"
