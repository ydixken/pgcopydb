#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# Regression test for issue where REPLICA IDENTITY USING INDEX (on a non-PK
# unique index) caused the test_decoding parser to fail UPDATE messages with
# "WHERE clause columns not found".
#
# See src/bin/pgcopydb/ld_test_decoding.c:prepareUpdateTuppleArrays.

# make sure source and target databases are ready
pgcopydb ping

# apply schema + initial data on the source (target will be restored by clone)
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

# create replication slot + snapshot, then clone the initial data
pgcopydb snapshot --follow --plugin test_decoding >/tmp/snapshot.out &
snapshot_pid=$!

# the snapshot is printed once the slot exists and the snapshot file is written
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

# the clone must keep REPLICA IDENTITY USING INDEX, on the same index
ri_sql="select c.relname, c.relreplident, coalesce(i.relname, '-')
          from pg_class c
               left join pg_index x on x.indrelid = c.oid and x.indisreplident
               left join pg_class i on i.oid = x.indexrelid
         where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
      order by c.relname"

cat > /tmp/ri.expected <<EOF
event_matches|i|event_matches_ri
event_matches_pk|i|event_matches_pk_pkey
event_matches_uc|i|event_matches_uc_id_key
EOF

psql -At -F '|' -d ${PGCOPYDB_SOURCE_PGURI} -c "${ri_sql}" > /tmp/ri.s.out
psql -At -F '|' -d ${PGCOPYDB_TARGET_PGURI} -c "${ri_sql}" > /tmp/ri.t.out

diff /tmp/ri.expected /tmp/ri.s.out
diff /tmp/ri.expected /tmp/ri.t.out

# produce CDC traffic on the source: INSERT, UPDATE, DELETE
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql

# mark the streaming end position at the current source WAL position
lsn=`psql -At -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_current_wal_flush_lsn()'`

# prefetch captures changes from the replication slot and decodes them.
# Without the fix, prefetch/transform fails on UPDATEs against tables that
# use REPLICA IDENTITY USING INDEX on a non-PK index.
pgcopydb stream prefetch --resume --endpos "${lsn}" --notice

# allow replaying/catching-up changes and apply them to the target
pgcopydb stream sentinel set apply
pgcopydb stream catchup --resume --endpos "${lsn}" --notice

# cleanup replication slot + origin
pgcopydb stream cleanup

# verify source and target match for the table we care about.
#
# Key assertion: if the parser had failed UPDATE messages, the target would
# still hold the initial-* rows with their original names. We expect the
# target to reflect every INSERT, UPDATE, and DELETE from dml.sql.

sql="select id, name from event_matches order by id"

psql -At -F '|' -d ${PGCOPYDB_SOURCE_PGURI} -c "${sql}" > /tmp/s.out
psql -At -F '|' -d ${PGCOPYDB_TARGET_PGURI} -c "${sql}" > /tmp/t.out

diff /tmp/s.out /tmp/t.out

# A work directory written before s_index.isreplident existed must still
# resume, as when a failed clone is resumed by an upgraded pgcopydb.
olddir=/tmp/pgcopydb-old
resume_pguri=postgres://postgres:h4ckm3@target/resume

psql -d ${PGCOPYDB_TARGET_PGURI} -c 'create database resume'

# the catalogs record the target, and --resume must find the same one
PGCOPYDB_TARGET_PGURI="${resume_pguri}" pgcopydb dump schema --dir "${olddir}"

for db in source filter target
do
    sqlite3 -init /dev/null "${olddir}/schema/${db}.db" \
            'alter table s_index drop column isreplident'
done

pgcopydb clone --dir "${olddir}" --target "${resume_pguri}" \
         --resume --not-consistent --notice
