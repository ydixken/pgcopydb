#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# Regression test: under REPLICA IDENTITY FULL, a table without a primary key
# or replica identity index may hold identical rows. Replaying an UPDATE or
# DELETE of one of them must change one row on the target, not all of them.

# make sure source and target databases are ready
pgcopydb ping

# apply schema + initial data on the source (target will be restored by clone)
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

# create replication slot + snapshot, then clone the initial data
coproc ( pgcopydb snapshot --follow --plugin pgoutput )

sleep 1

pgcopydb stream setup
pgcopydb clone

kill -TERM ${COPROC_PID}
wait ${COPROC_PID}

# produce CDC traffic on the source
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql

# mark the streaming end position at the current source WAL position
lsn=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_current_wal_flush_lsn()'`

pgcopydb stream prefetch --resume --endpos "${lsn}" --notice

# allow replaying/catching-up changes and apply them to the target
pgcopydb stream sentinel set apply
pgcopydb stream catchup --resume --endpos "${lsn}" --notice

# every table keeps rows on the source, so an empty result is a failure
failed=0

for t in ri_full_del ri_full_upd ri_full_nulldup ri_full_three ri_full_keyed
do
    sql="select * from ${t} order by 1, 2"
    psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} -c "${sql}" > /tmp/src_${t}.txt
    psql -AtqX -d ${PGCOPYDB_TARGET_PGURI} -c "${sql}" > /tmp/tgt_${t}.txt
    test -s /tmp/src_${t}.txt
    diff /tmp/src_${t}.txt /tmp/tgt_${t}.txt || failed=1
done

test ${failed} -eq 0

# pin the generated SQL: keyless tables use one (tableoid, ctid) per change
SHAREDIR=${XDG_DATA_HOME:-/var/lib/postgres/.local/share}/pgcopydb
REPLAYDB=$(find ${SHAREDIR} -maxdepth 1 -name '*-replay.db' -type f | head -1)
test -s "${REPLAYDB}"

sqlite3 -init /dev/null -list -noheader ${REPLAYDB} \
  "select s.sql from stmt s join replay r on r.stmt_hash = s.hash where r.action not in ('B','C','R','K','X','E') group by s.hash order by min(r.id)" \
  > /tmp/stmt-actual.sql
diff /usr/src/pgcopydb/stmt.sql /tmp/stmt-actual.sql

# cleanup replication slot + origin
pgcopydb stream cleanup
