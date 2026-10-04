#! /bin/bash

set -euo pipefail

workroot=$(mktemp -d /tmp/pgcopydb-compare-partitions.XXXXXX)
fixture_db="pgcopydb_compare_partitions_${BASHPID}"
source_uri="${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}"
target_uri="${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}"
source_created=false
target_created=false
compare_number=0

cleanup()
{
    if $source_created; then
        psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" \
            -c "DROP DATABASE ${fixture_db}" >/dev/null
    fi
    if $target_created; then
        psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" \
            -c "DROP DATABASE ${fixture_db}" >/dev/null
    fi
    rm -rf "$workroot"
}
trap cleanup EXIT

psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" \
    -c "CREATE DATABASE ${fixture_db}" >/dev/null
source_created=true
psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" \
    -c "CREATE DATABASE ${fixture_db}" >/dev/null
target_created=true

source_sql()
{
    psql -Xq -v ON_ERROR_STOP=1 -d "$source_uri" "$@" >/dev/null
}

target_sql()
{
    psql -Xq -v ON_ERROR_STOP=1 -d "$target_uri" "$@" >/dev/null
}

compare()
{
    local label=$1 mode=$2 expected_status=$3 diagnostic=$4
    local directory=${5:-"$workroot/compare-$compare_number"}
    local status=0
    compare_number=$((compare_number + 1))

    pgcopydb compare "$mode" --source "$source_uri" --target "$target_uri" \
        --dir "$directory" --table-jobs 1 --quiet --json \
        >"$workroot/report.json" 2>"$workroot/compare.log" || status=$?

    if [ "$status" -ne "$expected_status" ]; then
        echo "${label}: ${mode} expected exit ${expected_status}, got ${status}" >&2
        cat "$workroot/compare.log" >&2
        exit 1
    fi
    if [ -n "$diagnostic" ] && ! grep -Eiq "$diagnostic" "$workroot/compare.log"; then
        echo "${label}: ${mode} failed without the expected diagnostic" >&2
        cat "$workroot/compare.log" >&2
        exit 1
    fi
    echo "${label}: ${mode} exit ${status}"
}

compare_both()
{
    local label=$1 status=${2:-0} diagnostic=${3:-} directory=${4:-}
    if [ -n "$directory" ]; then
        compare "$label" schema "$status" "$diagnostic" "$directory"
        compare "$label" data "$status" "$diagnostic" "$directory"
    else
        compare "$label" schema "$status" "$diagnostic"
        compare "$label" data "$status" "$diagnostic"
    fi
}

clone()
{
    local directory=$1
    shift
    pgcopydb clone --source "$source_uri" --target "$target_uri" \
        --dir "$directory" --table-jobs 1 --index-jobs 1 \
        --skip-extensions --skip-collations --skip-large-objects \
        --skip-db-properties --not-consistent --fail-fast --quiet "$@" \
        >"$workroot/clone.log" 2>&1 || {
        cat "$workroot/clone.log" >&2
        exit 1
    }
}

reset_target()
{
    psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" \
        -c "DROP DATABASE ${fixture_db}" >/dev/null
    target_created=false
    psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" \
        -c "CREATE DATABASE ${fixture_db}" >/dev/null
    target_created=true
}

source_sql <<'SQL'
CREATE SCHEMA part;
CREATE SCHEMA outside;
CREATE SCHEMA "Quoted Schema";
CREATE TABLE outside.unselected (id integer);
INSERT INTO outside.unselected VALUES (7);

CREATE TABLE part.range_parent (id integer, payload text) PARTITION BY RANGE (id);
CREATE TABLE part.range_low PARTITION OF part.range_parent FOR VALUES FROM (0) TO (10);
CREATE TABLE part.range_empty PARTITION OF part.range_parent FOR VALUES FROM (10) TO (20);
CREATE TABLE part.range_default PARTITION OF part.range_parent DEFAULT;
INSERT INTO part.range_parent VALUES (1, 'one'), (2, 'two'), (99, 'default');
CREATE TABLE part.other_parent (id integer, payload text) PARTITION BY RANGE (id);
CREATE TABLE part.empty_parent (id integer, other integer) PARTITION BY RANGE (id);

CREATE TABLE part.list_parent (id integer, payload text) PARTITION BY LIST (id);
CREATE TABLE part.list_one PARTITION OF part.list_parent FOR VALUES IN (1);
CREATE TABLE part.list_two PARTITION OF part.list_parent FOR VALUES IN (2);
INSERT INTO part.list_parent VALUES (1, 'list');

CREATE TABLE part.hash_parent (id integer) PARTITION BY HASH (id);
CREATE TABLE part.hash_zero PARTITION OF part.hash_parent FOR VALUES WITH (MODULUS 2, REMAINDER 0);
CREATE TABLE part.hash_one PARTITION OF part.hash_parent FOR VALUES WITH (MODULUS 2, REMAINDER 1);
INSERT INTO part.hash_parent VALUES (1), (2);

CREATE TABLE part.nested_parent (id integer, region text) PARTITION BY RANGE (id);
CREATE TABLE part.nested_branch PARTITION OF part.nested_parent FOR VALUES FROM (0) TO (10) PARTITION BY LIST (region);
CREATE TABLE part.nested_east PARTITION OF part.nested_branch FOR VALUES IN ('east');
CREATE TABLE part.nested_default PARTITION OF part.nested_branch DEFAULT;
INSERT INTO part.nested_parent VALUES (1, 'east'), (2, 'west');

CREATE TABLE "Quoted Schema"."Parent""Name" ("Key id" integer) PARTITION BY RANGE ("Key id");
CREATE TABLE "Quoted Schema"."Leaf with space" PARTITION OF "Quoted Schema"."Parent""Name" FOR VALUES FROM (0) TO (10);
INSERT INTO "Quoted Schema"."Parent""Name" VALUES (1);
CREATE TABLE "Quoted Schema"."Cross Parent" (id integer) PARTITION BY RANGE (id);
CREATE TABLE part.cross_leaf PARTITION OF "Quoted Schema"."Cross Parent" FOR VALUES FROM (0) TO (10);
INSERT INTO part.cross_leaf VALUES (1);

CREATE TABLE part.time_parent (ts timestamptz) PARTITION BY RANGE (ts);
CREATE TABLE part.time_leaf PARTITION OF part.time_parent FOR VALUES FROM ('2020-01-01 00:00+00') TO ('2021-01-01 00:00+00');
INSERT INTO part.time_parent VALUES ('2020-06-01 00:00+00');

CREATE TABLE part.inherit_parent (id integer);
CREATE TABLE "Quoted Schema".inherit_child () INHERITS (part.inherit_parent);
INSERT INTO part.inherit_parent VALUES (10);
INSERT INTO "Quoted Schema".inherit_child VALUES (20);

CREATE TABLE part.long_bound_parent (value text) PARTITION BY LIST (value);
DO $body$
BEGIN
    EXECUTE format('CREATE TABLE part.long_bound_leaf PARTITION OF part.long_bound_parent FOR VALUES IN (%L)', repeat('x', 1100) || 'a');
    EXECUTE format('CREATE TABLE part.long_key_parent (value text) PARTITION BY LIST ((value || %L))', repeat('x', 1100) || 'a');
END
$body$;
SQL

clone "$workroot/base-clone"
compare_both 'matching RANGE LIST HASH nested quoted and long metadata'

# A successful baseline makes the first red assertion a topology regression.
topology='Partition topology mismatch'
target_sql -c 'CREATE TABLE part.range_extra PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40)'
compare_both 'extra empty target leaf' 12 "$topology"
target_sql -c 'INSERT INTO part.range_extra VALUES (31, '\''extra'\'')'
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$source_uri" -c 'SELECT count(*) FROM part.range_parent')" = 3
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT count(*) FROM part.range_parent')" = 4
compare_both 'extra populated target leaf with 3 versus 4 parent rows' 12 "$topology"
target_sql -c 'DROP TABLE part.range_extra'

target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_low'
compare_both 'detached populated leaf with unchanged payload' 12 "$topology"
target_sql -c 'ALTER TABLE part.other_parent ATTACH PARTITION part.range_low FOR VALUES FROM (0) TO (10)'
compare_both 'leaf attached to wrong parent' 12 "$topology"
target_sql -c 'ALTER TABLE part.other_parent DETACH PARTITION part.range_low; ALTER TABLE part.range_parent ATTACH PARTITION part.range_low FOR VALUES FROM (0) TO (10)'

target_sql -c 'DROP TABLE part.range_low'
compare_both 'missing populated leaf' 12 "$topology"
target_sql -c 'CREATE TABLE part.range_low PARTITION OF part.range_parent FOR VALUES FROM (0) TO (10); INSERT INTO part.range_low VALUES (1, '\''one'\''), (2, '\''two'\'')'
target_sql -c 'DROP TABLE part.range_empty'
compare_both 'missing empty leaf' 12 "$topology"
target_sql -c 'CREATE TABLE part.range_empty PARTITION OF part.range_parent FOR VALUES FROM (10) TO (20)'
target_sql -c 'DROP TABLE part.empty_parent'
compare_both 'missing zero-leaf parent' 12 "$topology"
target_sql -c 'CREATE TABLE part.empty_parent (id integer, other integer) PARTITION BY RANGE (other)'
compare_both 'changed parent partition key' 12 "$topology"
target_sql -c 'DROP TABLE part.empty_parent; CREATE TABLE part.empty_parent (id integer, other integer) PARTITION BY LIST (id)'
compare_both 'changed parent partition strategy' 12 "$topology"
target_sql -c 'DROP TABLE part.empty_parent; CREATE TABLE part.empty_parent (id integer, other integer) PARTITION BY RANGE (id)'

target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_empty; ALTER TABLE part.range_parent ATTACH PARTITION part.range_empty FOR VALUES FROM (10) TO (21)'
compare_both 'changed empty leaf bounds' 12 "$topology"
target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_empty; ALTER TABLE part.range_parent ATTACH PARTITION part.range_empty FOR VALUES FROM (10) TO (20)'
target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_default; ALTER TABLE part.range_parent ATTACH PARTITION part.range_default FOR VALUES FROM (90) TO (100)'
compare_both 'default changed to bounded partition' 12 "$topology"
target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_default; ALTER TABLE part.range_parent ATTACH PARTITION part.range_default DEFAULT'
target_sql -c 'CREATE TABLE part.list_extra_default PARTITION OF part.list_parent DEFAULT'
compare_both 'extra default target partition' 12 "$topology"
target_sql -c 'DROP TABLE part.list_extra_default'
target_sql -c 'CREATE TABLE part.range_extra_branch PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40) PARTITION BY LIST (payload); CREATE TABLE part.range_extra_nested PARTITION OF part.range_extra_branch FOR VALUES IN ('\''extra'\''); INSERT INTO part.range_parent VALUES (31, '\''extra'\'')'
compare_both 'extra nested target partition' 12 "$topology"
target_sql -c 'DROP TABLE part.range_extra_branch CASCADE'

target_sql <<'SQL'
DROP TABLE part.long_bound_leaf;
DO $body$
BEGIN
    EXECUTE format('CREATE TABLE part.long_bound_leaf PARTITION OF part.long_bound_parent FOR VALUES IN (%L)', repeat('x', 1100) || 'b');
END
$body$;
SQL
compare_both 'bounds differ beyond 1024 bytes' 12 "$topology"
target_sql <<'SQL'
DROP TABLE part.long_bound_leaf;
DROP TABLE part.long_key_parent;
DO $body$
BEGIN
    EXECUTE format('CREATE TABLE part.long_bound_leaf PARTITION OF part.long_bound_parent FOR VALUES IN (%L)', repeat('x', 1100) || 'a');
    EXECUTE format('CREATE TABLE part.long_key_parent (value text) PARTITION BY LIST ((value || %L))', repeat('x', 1100) || 'b');
END
$body$;
SQL
compare_both 'key differs beyond 1024 bytes' 12 "$topology"
target_sql <<'SQL'
DROP TABLE part.long_key_parent;
DO $body$
BEGIN
    EXECUTE format('CREATE TABLE part.long_key_parent (value text) PARTITION BY LIST ((value || %L))', repeat('x', 1100) || 'a');
END
$body$;
SQL

target_sql -c 'UPDATE part.range_low SET payload = '\''corrupted'\'' WHERE id = 1'
compare 'leaf payload corruption' data 12 'Data on source and target database differ'
target_sql -c 'UPDATE part.range_low SET payload = '\''one'\'' WHERE id = 1'
target_sql -c 'CREATE TABLE outside.target_only (id integer); CREATE TABLE outside.target_family (id integer) PARTITION BY LIST (id); CREATE TABLE outside.target_leaf PARTITION OF outside.target_family FOR VALUES IN (1); INSERT INTO outside.target_leaf VALUES (1)'
compare_both 'unrelated target table and partition family'
target_sql -c 'ALTER TABLE "Quoted Schema".inherit_child NO INHERIT part.inherit_parent'
compare_both 'ordinary inheritance is outside partition topology'
target_sql -c 'ALTER TABLE "Quoted Schema".inherit_child INHERIT part.inherit_parent'
psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -c "ALTER DATABASE ${fixture_db} SET timezone = 'Pacific/Auckland'; ALTER DATABASE ${fixture_db} SET datestyle = 'SQL, DMY'; ALTER DATABASE ${fixture_db} SET search_path = outside, public" >/dev/null
compare_both 'different timezone datestyle and search path defaults'

reset_target
cat >"$workroot/schema.ini" <<'FILTER'
[include-only-schema]
part
~/^Quoted Schema$/
FILTER
clone "$workroot/schema-filter" --filters "$workroot/schema.ini"
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT count(*) FROM part.range_low')" = 2
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT to_regclass('\''outside.unselected'\'') IS NULL')" = t
compare_both 'stored exact and regex schema inclusions' 0 '' "$workroot/schema-filter"
target_sql -c 'CREATE TABLE part.range_extra PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40)'
compare_both 'schema inclusion checks extra target sibling' 12 "$topology" "$workroot/schema-filter"

reset_target
cat >"$workroot/tables.ini" <<'FILTER'
[include-only-table]
part.range_low
part.~/^cross_leaf$/
outside.unselected
[exclude-schema]
outside
FILTER
# Leaf-only filters can omit ancestor restore entries, so prepare that topology.
target_sql <<'SQL'
CREATE SCHEMA part;
CREATE SCHEMA "Quoted Schema";
CREATE TABLE part.range_parent (id integer, payload text) PARTITION BY RANGE (id);
CREATE TABLE part.range_low PARTITION OF part.range_parent FOR VALUES FROM (0) TO (10);
CREATE TABLE "Quoted Schema"."Cross Parent" (id integer) PARTITION BY RANGE (id);
CREATE TABLE part.cross_leaf PARTITION OF "Quoted Schema"."Cross Parent" FOR VALUES FROM (0) TO (10);
SQL
clone "$workroot/table-filter" --filters "$workroot/tables.ini" --drop-if-exists
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT count(*) FROM part.range_low')" = 2
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT count(*) FROM part.cross_leaf')" = 1
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT to_regclass('\''outside.unselected'\'') IS NULL')" = t
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT inhparent = '\''"Quoted Schema"."Cross Parent"'\''::regclass FROM pg_inherits WHERE inhrelid = '\''part.cross_leaf'\''::regclass')" = t
compare_both 'stored exact and regex leaf inclusions with cross-schema ancestor' 0 '' "$workroot/table-filter"
echo 'schema exclusion overrides exact table inclusion'
target_sql -c 'CREATE TABLE part.range_extra PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40)'
compare_both 'strict leaf inclusion ignores unselected target sibling' 0 '' "$workroot/table-filter"
target_sql -c 'ALTER TABLE part.range_parent DETACH PARTITION part.range_low'
compare_both 'strict leaf inclusion checks selected leaf ancestry' 12 "$topology" "$workroot/table-filter"

reset_target
cat >"$workroot/exclude.ini" <<'FILTER'
[exclude-schema]
outside
~/^Quoted Schema$/
[exclude-table]
part.range_empty
part.~/^list_/
part.cross_leaf
part.~/^foreign_/
FILTER
clone "$workroot/exclude-filter" --filters "$workroot/exclude.ini"
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT count(*) FROM part.range_low')" = 2
test "$(psql -XAt -v ON_ERROR_STOP=1 -d "$target_uri" -c 'SELECT to_regclass('\''part.range_empty'\'') IS NULL AND to_regclass('\''part.list_one'\'') IS NULL')" = t
compare_both 'stored exact and regex schema and table exclusions' 0 '' "$workroot/exclude-filter"
source_sql -c 'CREATE EXTENSION postgres_fdw; CREATE SERVER fixture_foreign FOREIGN DATA WRAPPER postgres_fdw; CREATE FOREIGN TABLE part.foreign_leaf PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40) SERVER fixture_foreign'
compare_both 'explicitly excluded foreign sibling ignored' 0 '' "$workroot/exclude-filter"
source_sql -c 'DROP FOREIGN TABLE part.foreign_leaf; DROP SERVER fixture_foreign; DROP EXTENSION postgres_fdw'

reset_target
cat >"$workroot/parent.ini" <<'FILTER'
[include-only-table]
part.range_parent
FILTER
clone "$workroot/parent-filter" --filters "$workroot/parent.ini"
compare_both 'parent-only inclusion preserves empty row selection' 0 '' "$workroot/parent-filter"
jq -e 'type == "array" and length == 0' "$workroot/report.json" >/dev/null
echo 'parent-only inclusion: empty data report'

reset_target
clone "$workroot/foreign-clone"
source_sql -c 'CREATE EXTENSION postgres_fdw; CREATE SERVER fixture_foreign FOREIGN DATA WRAPPER postgres_fdw; CREATE FOREIGN TABLE part.foreign_leaf PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40) SERVER fixture_foreign'
target_sql -c 'CREATE EXTENSION postgres_fdw; CREATE SERVER fixture_foreign FOREIGN DATA WRAPPER postgres_fdw; CREATE FOREIGN TABLE part.foreign_leaf PARTITION OF part.range_parent FOR VALUES FROM (30) TO (40) SERVER fixture_foreign'
compare_both 'selected foreign partition fails closed' 12 'unsupported.*foreign|foreign.*unsupported'

psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" -c "DROP DATABASE ${fixture_db}" >/dev/null
source_created=false
psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_SOURCE_PGURI" -c "CREATE DATABASE ${fixture_db}" >/dev/null
source_created=true
reset_target
source_sql -c 'CREATE TABLE public.empty_parent (id integer) PARTITION BY RANGE (id)'
target_sql -c 'CREATE TABLE public.empty_parent (id integer) PARTITION BY RANGE (id)'
compare_both 'identical parent-only databases'
jq -e 'type == "array" and length == 0' "$workroot/report.json" >/dev/null
echo 'identical parent-only databases: empty data report'
