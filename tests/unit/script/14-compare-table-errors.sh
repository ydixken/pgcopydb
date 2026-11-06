#! /bin/bash

set -euo pipefail

# A table whose checksum query fails on the target is an error row: the worker
# closes both connections and goes on, the report lists every table, and the
# run exits 12. A lock on the target holds the last table so that the
# connection count is read while the worker is still running.

workroot=$(mktemp -d /tmp/pgcopydb-compare-errors.XXXXXX)
fixture_db="pgcopydb_compare_errors_${BASHPID}"
source_uri="${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}"
target_uri="${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}"
broken=20
gate_pid=
compare_pid=

# dropping the databases first ends the gate session, so the wait returns
cleanup()
{
    for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
        psql -Xq -d "$uri" -c "DROP DATABASE IF EXISTS ${fixture_db} WITH (FORCE)" >/dev/null || true
    done
    for pid in $gate_pid $compare_pid; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -rf "$workroot"
}
trap cleanup EXIT

poll()
{
    local what=$1 deadline=$((SECONDS + 90))
    shift
    until "$@"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "timed out waiting for ${what}" >&2
            cat "$workroot/compare.log" >&2 || true
            exit 1
        fi
        sleep 0.2
    done
}

sql()
{
    psql -XAt -v ON_ERROR_STOP=1 -d "$1" -c "$2"
}

gate_held()
{
    test "$(sql "$target_uri" "SELECT count(*) FROM pg_locks l
        JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE a.application_name = 'compare_gate'
          AND l.relation = 'gated'::regclass
          AND l.mode = 'AccessExclusiveLock' AND l.granted")" = 1
}

# pgsql.c names a session after its process title: pgcopydb[pid] title
worker_sessions()
{
    sql "$1" "SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database()
          AND application_name LIKE 'pgcopydb[%] compare worker%' ${2:-}"
}

# every broken table is done once the worker waits on gated, the last table
gated_waits()
{
    test "$(worker_sessions "$target_uri" "AND wait_event_type = 'Lock'")" = 1
}

# a closed session leaves pg_stat_activity once its backend exits: give a
# closed one 10s, then print what is left, so that a leak shows in the diff
settled_sessions()
{
    local uri=$1 expected=$2 deadline=$((SECONDS + 10)) count
    count=$(worker_sessions "$uri")
    while [ "$count" != "$expected" ] && [ "$SECONDS" -lt "$deadline" ]; do
        sleep 0.2
        count=$(worker_sessions "$uri")
    done
    echo "$count"
}

for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -c "CREATE DATABASE ${fixture_db}" >/dev/null
done

# largest first with one worker: good, then the broken tables, then gated
for uri in "$source_uri" "$target_uri"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -v broken="$broken" >/dev/null <<'SQL'
CREATE TABLE good (id integer PRIMARY KEY, val text);
INSERT INTO good SELECT i, md5(i::text) FROM generate_series(1, 2000) i;
CREATE TABLE gated (id integer PRIMARY KEY);
SELECT format('CREATE TABLE broken_%s (id integer PRIMARY KEY, extra text);
               INSERT INTO broken_%s SELECT i, i::text FROM generate_series(1, 10) i',
              n, n)
  FROM generate_series(1, :broken) n
\gexec
SQL
done

psql -Xq -v ON_ERROR_STOP=1 -d "$target_uri" -v broken="$broken" >/dev/null <<'SQL'
SELECT format('ALTER TABLE broken_%s DROP COLUMN extra', n)
  FROM generate_series(1, :broken) n
\gexec
SQL

echo "worker sessions before the run: source $(worker_sessions "$source_uri"), target $(worker_sessions "$target_uri")"

PGAPPNAME=compare_gate psql -Xq -d "$target_uri" >/dev/null 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE gated IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(300);
SQL
gate_pid=$!
poll 'the lock on gated' gate_held

pgcopydb compare data --source "$source_uri" --target "$target_uri" \
    --dir "$workroot/compare" --table-jobs 1 --json \
    >"$workroot/report.json" 2>"$workroot/compare.log" &
compare_pid=$!

poll 'the worker to wait on gated' gated_waits

# only gated's two sessions are left: no failed table kept one open
echo "worker sessions while gated waits: source $(settled_sessions "$source_uri" 1), target $(settled_sessions "$target_uri" 1)"

sql "$target_uri" "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = 'compare_gate'" >/dev/null
wait "$gate_pid" || true
gate_pid=

status=0
wait "$compare_pid" || status=$?
compare_pid=
echo "compare data: exit ${status}"

jq -r '"report rows: \(length)",
    (group_by(.status)[] | "\(.[0].status): \(length)"),
    "error rows with null checksums: \([.[] | select(.status == "error" and
        .source.checksum == null and .target.checksum == null)] | length)"' \
    "$workroot/report.json"

echo "failed table count logged: $(grep -c "Failed to compare ${broken} table(s)" "$workroot/compare.log")"
sed -n 's/.*compare progress: //p' "$workroot/compare.log" | jq -s -r 'last |
    "final: \(.comparedTables) of \(.plannedTables) tables, \(.failedTables) failed, final \(.final)"'

echo "worker sessions after the run: source $(settled_sessions "$source_uri" 0), target $(settled_sessions "$target_uri" 0)"
