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

#
# Load pagila database on source
#
createdb -h source -U postgres pagila
psql -o /tmp/pagila-schema.out -h source -U postgres -d pagila \
     -1 -f /usr/src/pagila/pagila-schema.sql
psql -o /tmp/pagila-data.out -h source -U postgres -d pagila \
     -1 -f /usr/src/pagila/pagila-data.sql

#
# Load f1db database on source (pg_restore from custom-format dump)
#
createdb -h source -U postgres f1db
pg_restore -h source -U postgres -d f1db --no-owner --no-privileges \
           /usr/src/f1db/f1db.dump

#
# Load chinook database on source (the SQL file creates its own database)
#
psql -h source -U postgres -f /usr/src/chinook/Chinook_PostgreSql.sql

#
# Large objects in two databases, the maintenance database included, and the
# cfgdump extension, whose configuration table and sequence hold user data
#
psql -v ON_ERROR_STOP=1 -h source -U postgres -d postgres \
     -c "select lo_from_bytea(9001, convert_to('in postgres', 'UTF8'))"
psql -v ON_ERROR_STOP=1 -h source -U postgres -d pagila <<'EOF'
select lo_from_bytea(9002, convert_to('in pagila', 'UTF8'));
select lo_from_bytea(9003, decode(repeat('ab', 300000), 'hex'));
create extension cfgdump;
insert into cfgdump_settings values (101, 'user 101'), (102, 'user 102');
select setval('cfgdump_seq', 42);
EOF

#
# 24 small databases, 28 in all, so that each of the 4 pre-data workers
# handles about 7: the SysV slots a worker holds must not grow with that count
#
for i in $(seq 1 24)
do
    createdb -h source -U postgres "small${i}"
    psql -h source -U postgres -d "small${i}" -c 'create table t(id integer primary key)'
done

# every queue and semaphore set of a clone is gone once it exits; /proc/sysvipc
# lists a header line, then one line per object
sysv_none_left() {
    cat /proc/sysvipc/msg /proc/sysvipc/sem
    test "$(cat /proc/sysvipc/msg /proc/sysvipc/sem | wc -l)" -eq 2
}

#
# Clone all databases from source to target using --all-databases, then
# retry with --resume --not-consistent at the same count
#
pgcopydb clone --all-databases \
         --notice \
         --skip-collations \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" > /tmp/clone.out
cat /tmp/clone.out
sysv_none_left

pgcopydb clone --all-databases \
         --resume --not-consistent \
         --notice \
         --skip-collations \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" > /tmp/resume.out
cat /tmp/resume.out
sysv_none_left

pgcopydb compare schema \
         --all-databases \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" \
         --dir "/tmp/pgcopydb" > /tmp/compare-schema.out
cat /tmp/compare-schema.out

pgcopydb compare data \
         --all-databases \
         --source "${PGCOPYDB_SOURCE_PGURI}" \
         --target "${PGCOPYDB_TARGET_PGURI}" \
         --dir "/tmp/pgcopydb" > /tmp/compare-data.out
cat /tmp/compare-data.out

# both clone summaries and both reports count every small database, not only
# those whose catalog the reporting process could still open
summary='^ *small[0-9]+ [|] +[0-9]+ [|] public [|] +t [|]'
test "$(grep -cE "${summary}" /tmp/clone.out)" -eq 24
test "$(grep -cE "${summary}" /tmp/resume.out)" -eq 24
test "$(grep -cE '^small[0-9]+ +[|]   1 [|]     1 [|]   1 [|]     1 [|]' /tmp/compare-schema.out)" -eq 24
test "$(grep -cE '^ *small[0-9]+[.]public[.]t [|]   [|] ' /tmp/compare-data.out)" -eq 24

# same <database> <what> <query> <prefix>: the source prints prefix first and
# the target prints what the source prints
status=0
same() {
    local src tgt
    src=$(psql -AtqX -v ON_ERROR_STOP=1 -h source -U postgres -d "$1" -c "$3")
    tgt=$(psql -AtqX -v ON_ERROR_STOP=1 -h target -U postgres -d "$1" -c "$3")
    case "${src}" in
        "$4"*) ;;
        *) echo "FAIL: $1 $2 on the source: expected=$4... actual=${src}" >&2; status=1; return ;;
    esac
    if [ "${tgt}" != "${src}" ]; then
        echo "FAIL: $1 $2 on the target: expected=${src} actual=${tgt}" >&2
        status=1
        return
    fi
    echo "PASS: $1 $2: ${tgt}"
}

lo="select count(*) || ' objects, md5 ' || md5(coalesce(string_agg(
      oid || ':' || md5(lo_get(oid)), ',' order by oid), '')) from pg_largeobject_metadata"

same postgres "large objects" "${lo}" "1 objects"
same pagila "large objects" "${lo}" "2 objects"
same pagila "cfgdump_settings rows" \
     "select string_agg(id || ' ' || val, ', ' order by id) from cfgdump_settings" \
     "1 shipped 1, 2 shipped 2, 3 shipped 3, 101 user 101, 102 user 102"
same pagila "cfgdump_seq" "select last_value || ' ' || is_called from cfgdump_seq" "42 true"
test "${status}" = 0

#
# Debug: dump timing tables from per-database catalogs
#
echo "=== Timing table dump ==="
for db in pagila f1db chinook; do
    dbfile="/tmp/pgcopydb/db/${db}/schema/source.db"
    if [ -f "${dbfile}" ]; then
        echo "--- ${db}: timings ---"
        sqlite3 -separator '|' "${dbfile}" \
            "select id, label, duration, count, bytes from timings order by id;"
        echo "--- ${db}: summary count ---"
        sqlite3 "${dbfile}" \
            "select count(*), sum(duration), sum(bytes) from summary where done_time_epoch > 0;"
    else
        echo "--- ${db}: source.db not found at ${dbfile}"
    fi
done
