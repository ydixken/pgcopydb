#! /bin/bash

set -x
set -e

# This script expects the following environment variables to be set:
#
#  - PGCOPYDB_SOURCE_PGURI
#  - PGCOPYDB_TARGET_PGURI
#  - PGCOPYDB_TABLE_JOBS
#  - PGCOPYDB_INDEX_JOBS

pgcopydb ping

#
# Follow coordinator TCP endpoint (provided by docker-compose). We remote-control
# the sentinel over TCP, so this container does NOT share the SQLite catalog
# volume with the follow process.
#
HP="--host ${PGCOPYDB_HOST} --port ${PGCOPYDB_PORT}"

#
# Wait for the follow coordinator; the initial snapshot copy may still be running.
#
until pgcopydb stream sentinel get ${HP} >/dev/null 2>&1
do
    sleep 1
done

#
# Inject a batch of DML changes.
# Then switch WAL segment to demonstrate that the SQLite CDC pipeline is
# independent of PostgreSQL WAL segment boundaries (in the old file-based
# design, WAL switches were critical milestones; now they're invisible).
#
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'

# Inject another batch on the new WAL segment to show pipeline continues
# across segment boundaries without any special handling.
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} -f /usr/src/pgcopydb/dml.sql
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} -c 'select pg_switch_wal()'

# Leave a visible change after both batches to distinguish follow from clone.
psql -v ON_ERROR_STOP=1 -d ${PGCOPYDB_SOURCE_PGURI} \
    -c "update actor set first_name = 'WAL2JSON' where actor_id = 1"

# Follow closes the coordinator on completion, so setting endpos is our last
# request. The main test verifies completion and target data before cleanup.
echo "Setting endpos to current WAL position..."
endpos=$(pgcopydb stream sentinel set endpos --current --debug ${HP})

if [ -z "${endpos}" ] || [ "${endpos}" = "0/0" ]
then
    echo "ERROR: endpos not set correctly (got: ${endpos})"
    exit 1
fi
echo "Successfully set endpos to ${endpos}"
