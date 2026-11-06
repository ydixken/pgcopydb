#! /bin/bash

set -euo pipefail

# compare data reuses a work directory that list tables --filters seeded, so it
# compares only the filtered tables. A catalog whose s_table_chksum has the
# b42f560 columns gets the new ones and compares.

workroot=$(mktemp -d /tmp/pgcopydb-compare-seeded.XXXXXX)
fixture_db="pgcopydb_compare_seeded_${BASHPID}"
source_uri="${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}"
target_uri="${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}"

cleanup()
{
    for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
        psql -Xq -d "$uri" -c "DROP DATABASE IF EXISTS ${fixture_db}" >/dev/null
    done
    rm -rf "$workroot"
}
trap cleanup EXIT

run()
{
    local log=$1
    shift
    "$@" >/dev/null 2>"$log" || {
        echo "$* failed" >&2
        cat "$log" >&2
        exit 1
    }
}

compare()
{
    local label=$1 directory=$2 status=0
    pgcopydb compare data --source "$source_uri" --target "$target_uri" \
        --dir "$directory" --table-jobs 2 --json \
        >"$workroot/report.json" 2>"$workroot/compare.log" || status=$?
    echo "${label}: exit ${status}"
    if [ "$status" -ne 0 ]; then
        cat "$workroot/compare.log" >&2
    fi
    jq -r 'sort_by(.name)[] |
        "\(.schema).\(.name): \(.status), \(.source.rowcount) rows, " +
        "checksums match \(.source.checksum != null and .source.checksum == .target.checksum), " +
        "bytes \(.bytes > 0), durationMs \(.durationMs | type)"' \
        "$workroot/report.json"
}

for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -c "CREATE DATABASE ${fixture_db}" >/dev/null
done

for uri in "$source_uri" "$target_uri"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" >/dev/null <<'SQL'
CREATE TABLE kept (id integer PRIMARY KEY, val text);
INSERT INTO kept SELECT i, md5(i::text) FROM generate_series(1, 1000) i;
CREATE TABLE also_kept (id integer PRIMARY KEY);
INSERT INTO also_kept SELECT generate_series(1, 10);
CREATE TABLE skipped (id integer PRIMARY KEY);
INSERT INTO skipped SELECT generate_series(1, 10);
SQL
done

# b42f560 created s_table_chksum with these columns and no others
run "$workroot/old-list.log" \
    pgcopydb list tables --source "$source_uri" --dir "$workroot/old"
test -f "$workroot/old/schema/source.db"
for db in "$workroot"/old/schema/{source,filter}.db; do
    [ -f "$db" ] || continue
    sqlite3 -init /dev/null "$db" \
        "DROP TABLE s_table_chksum;
         CREATE TABLE s_table_chksum(
           oid integer primary key references s_table(oid),
           srcrowcount integer, srcsum text, dstrowcount integer, dstsum text);"
done
compare 'b42f560 catalog' "$workroot/old"
echo "s_table_chksum columns: $(sqlite3 -init /dev/null "$workroot/old/schema/source.db" \
    "SELECT group_concat(name, ', ') FROM pragma_table_info('s_table_chksum')")"

# a target row the filters leave out: comparing skipped would exit 12
psql -Xq -v ON_ERROR_STOP=1 -d "$target_uri" -c 'INSERT INTO skipped VALUES (11)' >/dev/null

cat >"$workroot/filters.ini" <<'FILTER'
[include-only-table]
public.kept
public.also_kept
FILTER

run "$workroot/seeded-list.log" \
    pgcopydb list tables --source "$source_uri" --dir "$workroot/seeded" \
    --filters "$workroot/filters.ini"
compare 'list tables --filters seeded dir' "$workroot/seeded"
