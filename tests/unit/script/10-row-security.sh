#! /bin/bash

set -euo pipefail

# A table whose row-level security policy applies to the migration role must
# make clone and compare data fail, as pg_dump does, rather than copy and
# checksum only the rows the policy lets through.

workroot=$(mktemp -d /tmp/pgcopydb-row-security.XXXXXX)
fixture_db="pgcopydb_row_security_${BASHPID}"
role="pgcopydb_rls_owner_${BASHPID}"
source_host=${PGCOPYDB_SOURCE_PGURI#*@}
target_host=${PGCOPYDB_TARGET_PGURI#*@}
source_uri="postgres://${role}@${source_host%%/*}/${fixture_db}"
target_uri="postgres://${role}@${target_host%%/*}/${fixture_db}"
rls_error='query would be affected by row-level security policy for table "docs"'
failures=0

cleanup()
{
    for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
        psql -Xq -d "$uri" \
            -c "DROP DATABASE IF EXISTS ${fixture_db}" \
            -c "DROP ROLE IF EXISTS ${role}" >/dev/null
    done
    rm -rf "$workroot"
}
trap cleanup EXIT

create_fixture_db()
{
    psql -Xq -v ON_ERROR_STOP=1 -d "$1" \
        -c "CREATE DATABASE ${fixture_db} OWNER ${role}" >/dev/null
}

expect_rls_error()
{
    local label=$1 status=$2 log=$3

    if [ "$status" -eq 0 ] || ! grep -qF "$rls_error" "$log"; then
        echo "${label}: expected the row-level security error, got exit ${status}" >&2
        cat "$log" >&2
        failures=$((failures + 1))
        return 1
    fi
    echo "${label}: row-level security error"
}

for uri in "$PGCOPYDB_SOURCE_PGURI" "$PGCOPYDB_TARGET_PGURI"; do
    psql -Xq -v ON_ERROR_STOP=1 -d "$uri" -c "CREATE ROLE ${role} LOGIN" >/dev/null
    create_fixture_db "$uri"
done

# The owner is subject to its own policy only because of FORCE.
psql -Xq -v ON_ERROR_STOP=1 -d "$source_uri" >/dev/null <<'SQL'
CREATE TABLE docs (id integer PRIMARY KEY, tenant text NOT NULL);
INSERT INTO docs SELECT i, 'tenant' || i % 3 FROM generate_series(1, 30) i;
ALTER TABLE docs ENABLE ROW LEVEL SECURITY;
ALTER TABLE docs FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant0 ON docs USING (tenant = 'tenant0');
SQL

status=0
pgcopydb clone --source "$source_uri" --target "$target_uri" \
    --dir "$workroot/clone" --table-jobs 1 --index-jobs 1 \
    --skip-extensions --skip-collations --skip-large-objects \
    --skip-db-properties >"$workroot/clone.log" 2>&1 || status=$?
expect_rls_error clone "$status" "$workroot/clone.log" ||
    psql -XAt -d "${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}" \
        -c "SELECT 'clone: target docs holds ' || count(*) || ' of 30 rows' FROM docs" >&2

# Give the target all 30 rows behind the same policy; superusers bypass RLS.
psql -Xq -v ON_ERROR_STOP=1 -d "$PGCOPYDB_TARGET_PGURI" -c "DROP DATABASE ${fixture_db}"
create_fixture_db "$PGCOPYDB_TARGET_PGURI"
pg_dump "${PGCOPYDB_SOURCE_PGURI%/*}/${fixture_db}" |
    psql -Xq -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI%/*}/${fixture_db}" >/dev/null

status=0
pgcopydb compare data --source "$source_uri" --target "$target_uri" \
    --dir "$workroot/compare" --table-jobs 1 --json \
    >"$workroot/compare.json" 2>"$workroot/compare.log" || status=$?
expect_rls_error "compare data" "$status" "$workroot/compare.log" ||
    cat "$workroot/compare.json" >&2

[ "$failures" -eq 0 ]
