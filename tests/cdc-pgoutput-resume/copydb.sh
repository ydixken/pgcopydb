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

. /var/lib/postgres/spool-probe.sh

pgcopydb stream prefetch --resume --endpos "${endpos}" >/tmp/prefetch.log 2>&1 &
prefetch_pid=$!
sharedir=${XDG_DATA_HOME:-/var/lib/postgres/.local/share}/pgcopydb

# The threshold that proves receive holds an incomplete transaction: the
# SQLite layout spills it to the output.db WAL, the raw spool to its segment.
if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
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
else
deadline=$((SECONDS + 60))
seg=""
while test -z "${seg}"; do
    kill -0 "${prefetch_pid}"
    if test "${SECONDS}" -ge "${deadline}"; then
        cat /tmp/prefetch.log
        echo 'FAIL: no spool segment exceeded 4 MiB within 60 seconds' >&2
        exit 1
    fi
    for candidate in "${sharedir}"/*.seg; do
        if test -f "${candidate}" && test "$(stat -c %s "${candidate}")" -gt 4194304; then
            seg=${candidate}
            break
        fi
    done
    if test -z "${seg}"; then
        sleep 0.05
    fi
done

echo "Segment threshold reached: $(stat -c %s "${seg}") bytes"
receive_pid=$(fuser "${seg}" 2>/dev/null)
test "$(wc -w <<<"${receive_pid}")" -eq 1

# No index record of the incomplete transaction can be durable yet.
pkill -KILL -x pgcopydb
fi
status=0
wait "${prefetch_pid}" || status=$?
test "${status}" -eq 137

if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
sql() { sqlite3 -init /dev/null -batch -noheader -list "${outputdb}" "$1"; }
commits=$(sql "select count(*) from output where xid = ${xid} and action = 'C'")
rows=$(sql "select count(*) from output where xid = ${xid}")
columns=$(sql 'select count(*) from pgoutput_col')
echo "After SIGKILL: xid=${xid}, COMMIT=${commits}, output=${rows}, columns=${columns}"
test "${commits}" -eq 0
test "${rows}" -eq 0
test "${columns}" -eq 0
else
# an index record is the only proof of a transaction, and none was synced
commits=$(spool_commits)
echo "After SIGKILL: xid=${xid}, spool transactions=${commits}"
test "${commits}" -eq 0

# The start cut of this receive removes the last segment, which holds no
# complete transaction, and creates it again. Its run record comes after that,
# so a worker that reads the record never opens a reader in between, where it
# would log an error for a file that comes back.
timeout 300s gdb -q -batch -x /usr/src/pgcopydb/start-order.gdb \
    --args pgcopydb stream receive --resume --endpos "${endpos}" \
    > /tmp/start-order.log 2>&1 || { cat /tmp/start-order.log; exit 1; }
tail -20 /tmp/start-order.log
grep -q '^ORDER: spool_writer_open$' /tmp/start-order.log
grep -q '^PASS: the spool open comes before the run record$' /tmp/start-order.log

# Receive syncs the segment and the relation log before it writes the index
# records, and reports the flushed position only once all three are durable.
# A receive that dies at the index sync leaves the spool without the
# transaction, which the next run then receives again in full.
timeout 300s gdb -q -batch -x /usr/src/pgcopydb/flush-order-raw.gdb \
    --args pgcopydb stream receive --resume --endpos "${endpos}" \
    > /tmp/flush-order-raw.log 2>&1 || { cat /tmp/flush-order-raw.log; exit 1; }
tail -20 /tmp/flush-order-raw.log
grep -q '^Index sync after ' /tmp/flush-order-raw.log
grep -q '^PASS: killed receive before the index sync$' /tmp/flush-order-raw.log
test "$(spool_commits)" -eq 0
fi

timeout 600s pgcopydb stream prefetch --resume --endpos "${endpos}"
if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
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
else
# one record per complete transaction, with the change count of the source
commits=$(spool_commits)
commit_lsn=$(spool_commit_lsn "${xid}" 300000)
echo "After resume: spool transactions=${commits}, xid ${xid} commits at ${commit_lsn}"
test "${commits}" -eq 1
fi

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
