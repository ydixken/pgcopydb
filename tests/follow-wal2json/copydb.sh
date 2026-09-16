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

psql -v ON_ERROR_STOP=1 -o /tmp/s.out -d ${PGCOPYDB_SOURCE_PGURI} -1 -f /usr/src/pagila/pagila-schema.sql
psql -v ON_ERROR_STOP=1 -o /tmp/d.out -d ${PGCOPYDB_SOURCE_PGURI} -1 -f /usr/src/pagila/pagila-data.sql

# alter the pagila schema to allow capturing DDLs without pkey
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/ddl.sql

# pgcopydb clone uses the environment variables
pgcopydb clone --follow --plugin wal2json --wal2json-numeric-as-string --notice

# Query the SQLite CDC databases to verify the tables were populated.  In the
# 2-process model the `output` table lives in the *-output.db while `stmt` and
# `replay` live in the *-replay.db.
outdb=$(find ${TMPDIR}/cdc/pgcopydb -name "*-output.db" -type f | head -1)
repdb=$(find ${TMPDIR}/cdc/pgcopydb -name "*-replay.db" -type f | head -1)

if [ -n "$outdb" ] && [ -f "$outdb" ]; then
  sqlite3 "$outdb" \
    "select id, action, xid, lsn, substring(message, 1, 48) from output limit 10;"
  test "$(sqlite3 -init /dev/null "$outdb" "select count(*) from output where action in ('I','U','D')")" -gt 0
else
  echo "CDC output database not found at ${TMPDIR}/cdc/pgcopydb/"
  exit 1
fi

if [ -n "$repdb" ] && [ -f "$repdb" ]; then
  sqlite3 "$repdb" "select hash, sql from stmt limit 5;"
  sqlite3 "$repdb" \
    "select id, action, xid, lsn, endlsn, stmt_hash, stmt_args from replay limit 10;"
  test "$(sqlite3 -init /dev/null "$repdb" "select count(*) from stmt")" -gt 0
  test "$(sqlite3 -init /dev/null "$repdb" "select count(*) from replay where action in ('I','U','D')")" -gt 0
else
  echo "CDC replay database not found at ${TMPDIR}/cdc/pgcopydb/"
  exit 1
fi

# The injected batches undo their changes; this final marker must survive CDC.
test "$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" \
  -c "select first_name from actor where actor_id = 1")" = WAL2JSON

for table in actor rental payment; do
  sql="select count(*), md5(string_agg(t::text, ',' order by t::text)) from ${table} t"
  source_digest=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$sql")
  target_digest=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$sql")
  echo "${table}: source ${source_digest}, target ${target_digest}"
  test "${source_digest%%|*}" -gt 0
  test "$source_digest" = "$target_digest"
done

# cleanup
pgcopydb stream sentinel get
pgcopydb stream cleanup
