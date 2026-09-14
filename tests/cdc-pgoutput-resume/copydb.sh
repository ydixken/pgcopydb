#! /bin/bash

set -euxo pipefail

trap 'pkill -KILL -x pgcopydb || true' EXIT

pgcopydb ping
psql -X -v ON_ERROR_STOP=1 -o /tmp/schema.out -d "${PGCOPYDB_SOURCE_PGURI}" \
    -1 -f /usr/src/pagila/pagila-schema.sql
psql -X -v ON_ERROR_STOP=1 -o /tmp/data.out -d "${PGCOPYDB_SOURCE_PGURI}" \
    -1 -f /usr/src/pagila/pagila-data.sql
psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c \
    'create table bulk(id integer primary key, n bigint, payload text, extra text)'

pgcopydb snapshot --follow --plugin pgoutput >/tmp/snapshot.out &
snapshot_pid=$!
deadline=$((SECONDS + 60))
while ! test -s /tmp/snapshot.out; do
    kill -0 "${snapshot_pid}"
    test "${SECONDS}" -lt "${deadline}"
    sleep 0.1
done

pgcopydb stream setup
pgcopydb clone
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"

xid=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -1 \
    -c 'select pg_current_xact_id()' \
    -c "insert into bulk select i, i::bigint * 2, md5(i::text),
        case when i % 7 = 0 then null else 'row-' || i end
        from generate_series(1, 300000) i")
test "${xid}" -gt 0
endpos=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
    -c 'select pg_current_wal_flush_lsn()')
test -n "${endpos}"

pgcopydb stream prefetch --resume --endpos "${endpos}" >/tmp/prefetch.log 2>&1 &
prefetch_pid=$!
sharedir=${XDG_DATA_HOME:-/var/lib/postgres/.local/share}/pgcopydb

# An uncommitted batch spills beyond SQLite's default checkpoint threshold.
deadline=$((SECONDS + 60))
wal=""
while test -z "${wal}"; do
    kill -0 "${prefetch_pid}"
    if test "${SECONDS}" -ge "${deadline}"; then
        cat /tmp/prefetch.log
        echo 'FAIL: output WAL did not exceed 4 MiB within 60 seconds' >&2
        exit 1
    fi
    for candidate in "${sharedir}"/*-output.db-wal; do
        if test -f "${candidate}" && test "$(stat -c %s "${candidate}")" -gt 4194304; then
            wal=${candidate}
            break
        fi
    done
    if test -z "${wal}"; then
        sleep 0.05
    fi
done

pkill -STOP -x pgcopydb
outputdb=${wal%-wal}
echo "WAL threshold reached: $(stat -c %s "${wal}") bytes"
receive_pid=$(fuser "${wal}" 2>/dev/null)
test "$(wc -w <<<"${receive_pid}")" -eq 1

# Kill at the flush commit boundary, not at an arbitrary instruction after it.
sudo timeout 60s gdb -q -batch -x /usr/src/pgcopydb/flush-order.gdb -p "${receive_pid// /}"
status=0
wait "${prefetch_pid}" || status=$?
test "${status}" -eq 137

sql() { sqlite3 -init /dev/null -batch -noheader -list "${outputdb}" "$1"; }
commits=$(sql "select count(*) from output where xid = ${xid} and action = 'C'")
rows=$(sql "select count(*) from output where xid = ${xid}")
columns=$(sql 'select count(*) from pgoutput_col')
echo "After SIGKILL: xid=${xid}, COMMIT=${commits}, output=${rows}, columns=${columns}"
test "${commits}" -eq 0
test "${rows}" -eq 0
test "${columns}" -eq 0

timeout 600s pgcopydb stream prefetch --resume --endpos "${endpos}"
commits=$(sql "select count(*) from output where xid = ${xid} and action = 'C'")
rows=$(sql "select count(*) from output where xid = ${xid}")
inserts=$(sql "select count(*) from output
    where xid = ${xid} and action = 'I' and nspname = 'public' and relname = 'bulk'")
columns=$(sql 'select count(*) from pgoutput_col')
linked_columns=$(sql "select count(*) from pgoutput_col c join output o on o.id = c.output_id
    where o.xid = ${xid} and o.action = 'I'")
echo "After resume: COMMIT=${commits}, output=${rows}, inserts=${inserts}, columns=${columns}, linked=${linked_columns}"
test "${commits}" -eq 1
test "${rows}" -eq 300002
test "${inserts}" -eq 300000
test "${columns}" -eq 1200000
test "${linked_columns}" -eq 1200000
test "$(sql 'pragma integrity_check')" = ok

pgcopydb stream sentinel set apply
timeout 600s pgcopydb stream catchup --resume --endpos "${endpos}"
digest_sql="select count(*), md5(string_agg(row(id, n, payload, extra)::text, ',' order by id)) from bulk"
source_digest=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${digest_sql}")
target_digest=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${digest_sql}")
echo "Source count and ordered md5: ${source_digest}"
echo "Target count and ordered md5: ${target_digest}"
test "${source_digest%%|*}" -eq 300000
test "${source_digest}" = "${target_digest}"

pgcopydb stream cleanup
trap - EXIT
echo 'PASS: pgoutput receive rollback, flush ordering, resume, and catchup'
