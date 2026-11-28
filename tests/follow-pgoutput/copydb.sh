#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

# make sure source and target databases are ready
pgcopydb ping

# Verify that the source has a short idle_in_transaction_session_timeout so
# that this test exercises the fix for #960: GUC settings must be applied on
# the replication connection before CREATE_REPLICATION_SLOT is sent, otherwise
# a strict server-side timeout would abort slot creation.
timeout_ms=$(psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} \
  -c "show idle_in_transaction_session_timeout")
echo "source idle_in_transaction_session_timeout: ${timeout_ms}"
test "${timeout_ms}" = "1s"

psql -o /tmp/s.out -d ${PGCOPYDB_SOURCE_PGURI} -1 -f /usr/src/pagila/pagila-schema.sql
psql -o /tmp/d.out -d ${PGCOPYDB_SOURCE_PGURI} -1 -f /usr/src/pagila/pagila-data.sql

# alter the pagila schema to allow capturing DDLs without pkey
psql -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

#
# Two publications that each hold some of the tables, as the operator passes
# them for insertOnlyTables. The clone copies the two empty tables, and
# inject.sh writes to both once the follow streams.
#
if [ "${PGCOPYDB_FOLLOW_MODE:-}" = performance ]; then
  psql -d ${PGCOPYDB_SOURCE_PGURI} \
    -c 'create schema fp' \
    -c 'create table fp.one(id integer primary key, v text)' \
    -c 'create table fp.two(id integer primary key, v text)' \
    -c 'create publication fp_a for table fp.one' \
    -c 'create publication fp_b for table fp.two'
fi

# pgcopydb clone uses the environment variables (pgoutput plugin, auto-managed publication)
if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
pgcopydb clone --follow --plugin pgoutput --notice
else
pgcopydb clone --follow --plugin pgoutput --notice --publication fp_a,fp_b
fi

#
# Verify that the data made it to the target (row count assertions).
#
for tbl in actor film category address; do
  src_count=$(psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} -c "select count(*) from ${tbl}")
  tgt_count=$(psql -AtqX -d ${PGCOPYDB_TARGET_PGURI} -c "select count(*) from ${tbl}")
  echo "source ${tbl}: ${src_count}, target ${tbl}: ${tgt_count}"
  test "${src_count}" -eq "${tgt_count}"
done

#
# The rows of both publications reached the target: the one that carries the
# table of fp_b proves that a performance follow honors every name it is given.
#
if [ "${PGCOPYDB_FOLLOW_MODE:-}" = performance ]; then
  for tbl in fp.one fp.two; do
    src_count=$(psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} -c "select count(*) from ${tbl}")
    tgt_count=$(psql -AtqX -d ${PGCOPYDB_TARGET_PGURI} -c "select count(*) from ${tbl}")
    echo "source ${tbl}: ${src_count}, target ${tbl}: ${tgt_count}"
    test "${tgt_count}" -gt 0
    test "${src_count}" -eq "${tgt_count}"
  done
fi

# Query the SQLite CDC databases to verify the tables were populated.
if [ "${PGCOPYDB_FOLLOW_MODE:-}" != performance ]; then
outdb=$(find ${TMPDIR}/cdc/pgcopydb -name "*-output.db" -type f | head -1)
repdb=$(find ${TMPDIR}/cdc/pgcopydb -name "*-replay.db" -type f | head -1)

if [ -n "$outdb" ] && [ -f "$outdb" ]; then
  sqlite3 "$outdb" \
    "select id, action, xid, lsn, nspname, relname from output limit 10;"

  #
  # Validate that the pgoutput_col table exists and has rows.
  #
  col_rows=$(sqlite3 -init /dev/null -noheader -list "$outdb" \
    "select count(*) from pgoutput_col;")
  echo "pgoutput_col rows: ${col_rows}"
  test "${col_rows}" -gt 0

  #
  # Validate that DML rows have nspname/relname set and NULL message.
  #
  null_msg=$(sqlite3 -init /dev/null -noheader -list "$outdb" \
    "select count(*) from output where action in ('I','U','D','T') and message is not null;")
  echo "DML rows with non-NULL message (should be 0): ${null_msg}"
  test "${null_msg}" -eq 0

  nspname_set=$(sqlite3 -init /dev/null -noheader -list "$outdb" \
    "select count(*) from output where action in ('I','U','D') and nspname is not null;")
  echo "DML rows with nspname set: ${nspname_set}"
  test "${nspname_set}" -gt 0
else
  echo "CDC output database not found at ${TMPDIR}/cdc/pgcopydb/"
  exit 1
fi

if [ -n "$repdb" ] && [ -f "$repdb" ]; then
  sqlite3 "$repdb" "select hash, sql from stmt limit 5;"
  sqlite3 "$repdb" \
    "select id, action, xid, lsn, endlsn, stmt_hash, stmt_args from replay limit 10;"
else
  echo "CDC replay database not found at ${TMPDIR}/cdc/pgcopydb/"
  exit 1
fi
else
# the raw spool holds the transactions that the two SQLite files held
. /var/lib/postgres/spool-probe.sh
spool_commits
test "$(spool_commits)" -gt 0
fi

# cleanup (drops the auto-managed publication)
pgcopydb stream sentinel get

# make sure the inject service has had time to see the final sentinel values
sleep 2
pgcopydb stream cleanup

#
# Validate that the auto-managed publication was dropped by cleanup.
#
pub_after=$(psql -AtqX -d ${PGCOPYDB_SOURCE_PGURI} \
  -c "select count(*) from pg_publication where pubname = 'pgcopydb'" 2>/dev/null || echo 0)
echo "publication rows after cleanup (should be 0): ${pub_after}"
test "${pub_after}" -eq 0
