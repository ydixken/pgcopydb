#! /bin/bash

set -euo pipefail

# The target ends the session of the table in flight and stops accepting
# connections. The worker then connects for each remaining table without
# retrying, so the run ends in seconds instead of after a minute per table.

workroot=$(mktemp -d /tmp/pgcopydb-compare-lost.XXXXXX)
fixture_db="pgcopydb_compare_lost_${BASHPID}"
source_uri="${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}"
target_uri="${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}"
remaining=3
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

# the fixture database refuses connections later on, so ask the maintenance one
target_sql()
{
    psql -XAt -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -c "$1"
}

worker_target_sessions()
{
    target_sql "SELECT count(*) FROM pg_stat_activity
        WHERE datname = '${fixture_db}'
          AND application_name LIKE 'pgcopydb[%] compare worker%' ${1:-}"
}

gate_held()
{
    test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c "SELECT count(*)
        FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE a.application_name = 'compare_gate'
          AND l.relation = 'gated'::regclass
          AND l.mode = 'AccessExclusiveLock' AND l.granted")" = 1
}

gated_waits()
{
    test "$(worker_target_sessions "AND wait_event_type = 'Lock'")" = 1
}

compare_exited()
{
    ! kill -0 "$compare_pid" 2>/dev/null
}

for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -c "CREATE DATABASE ${fixture_db}" >/dev/null
done

# with one worker the largest table, gated, is compared first
for uri in "$source_uri" "$target_uri"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -v remaining="$remaining" >/dev/null <<'SQL'
CREATE TABLE gated (id integer PRIMARY KEY, val text);
INSERT INTO gated SELECT i, md5(i::text) FROM generate_series(1, 2000) i;
SELECT format('CREATE TABLE later_%s (id integer PRIMARY KEY);
               INSERT INTO later_%s SELECT generate_series(1, 10)', n, n)
  FROM generate_series(1, :remaining) n
\gexec
SQL
done

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

# open sessions survive ALLOW_CONNECTIONS false, so end the worker session too
target_sql "ALTER DATABASE ${fixture_db} ALLOW_CONNECTIONS false" >/dev/null
lost_at=$SECONDS
target_sql "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE datname = '${fixture_db}'
      AND application_name LIKE 'pgcopydb[%] compare worker%'" >/dev/null

# with a retry per table this takes a minute for each of the remaining tables
poll 'compare data to exit' compare_exited
echo "compare data ended within 30s of the lost session: $([ $((SECONDS - lost_at)) -lt 30 ] && echo yes || echo no)"

status=0
wait "$compare_pid" || status=$?
compare_pid=
echo "compare data: exit ${status}"

jq -r '"report rows: \(length)",
    (group_by(.status)[] | "\(.[0].status): \(length)")' \
    "$workroot/report.json"

echo "failed table count logged: $(grep -c "Failed to compare $((remaining + 1)) table(s)" "$workroot/compare.log")"
