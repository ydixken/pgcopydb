#! /bin/bash

set -euo pipefail

# While a lock on the target holds one table, compare data logs a progress line
# with that table in flight. Once the lock goes, the run ends with exactly one
# final line, and that line counts every table as compared.

workroot=$(mktemp -d /tmp/pgcopydb-compare-progress.XXXXXX)
fixture_db="pgcopydb_compare_progress_${BASHPID}"
source_uri="${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}"
target_uri="${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}"
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

target_count()
{
    psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c "$1"
}

gate_held()
{
    test "$(target_count "SELECT count(*) FROM pg_locks l
        JOIN pg_stat_activity a ON a.pid = l.pid
        WHERE a.application_name = 'compare_gate'
          AND l.relation = 'gated'::regclass
          AND l.mode = 'AccessExclusiveLock' AND l.granted")" = 1
}

progress_lines()
{
    sed -n 's/.*compare progress: //p' "$workroot/compare.log"
}

# the 10s line, not the one logged when the progress process starts
gated_in_flight()
{
    progress_lines | jq -e -s 'any(.[]; .final == false and
        any(.inFlight[]; .name == "gated" and .elapsedMs >= 5000))' >/dev/null 2>&1
}

for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -c "CREATE DATABASE ${fixture_db}" >/dev/null
done

for uri in "$source_uri" "$target_uri"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" >/dev/null <<'SQL'
CREATE TABLE gated (id integer PRIMARY KEY, val text);
INSERT INTO gated SELECT i, md5(i::text) FROM generate_series(1, 100) i;
CREATE TABLE free_a (id integer PRIMARY KEY);
INSERT INTO free_a SELECT generate_series(1, 10);
CREATE TABLE free_b (id integer PRIMARY KEY);
INSERT INTO free_b SELECT generate_series(1, 10);
SQL
done

# the gate holds its lock until the test ends its session
PGAPPNAME=compare_gate psql -Xq -d "$target_uri" >/dev/null 2>&1 <<'SQL' &
BEGIN;
LOCK TABLE gated IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(300);
SQL
gate_pid=$!
poll 'the lock on gated' gate_held

pgcopydb compare data --source "$source_uri" --target "$target_uri" \
    --dir "$workroot/compare" --table-jobs 2 --json \
    >"$workroot/report.json" 2>"$workroot/compare.log" &
compare_pid=$!

poll 'a progress line with gated in flight' gated_in_flight
echo 'progress line: gated in flight for 5s or more'
progress_lines | jq -s -r '[.[] | select(.final == false) | .inFlight[] |
    select(.name == "gated")] | last |
    "in-flight entry keys: \(keys_unsorted | join(", ")), " +
    "schema \(.schema), bytes \(.bytes > 0)"'

target_count "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = 'compare_gate'" >/dev/null
wait "$gate_pid" || true
gate_pid=

status=0
wait "$compare_pid" || status=$?
compare_pid=
echo "compare data: exit ${status}"

progress_lines | jq -s -r '
    (map(select(.final)) | length) as $finals |
    last as $last |
    "final lines: \($finals), last line final: \($last.final)",
    "keys: \($last | keys_unsorted | join(", "))",
    "final: \($last.comparedTables) of \($last.plannedTables) tables, " +
    "bytes all compared \($last.comparedBytes == $last.plannedBytes and $last.plannedBytes > 0), " +
    "\($last.comparedRows) rows, \($last.differingTables) differing, " +
    "\($last.failedTables) failed, \($last.inFlightCount) in flight \($last.inFlight | length), " +
    "elapsedMs \($last.elapsedMs >= 5000)"'

jq -r 'sort_by(.name)[] | "\(.schema).\(.name): \(.status)"' "$workroot/report.json"
