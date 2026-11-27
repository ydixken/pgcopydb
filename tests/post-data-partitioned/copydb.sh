#! /bin/bash

# With --restore-jobs > 1, a single parallel pg_restore of the post-data
# section deadlocks on multi-level partitioned tables: the last INDEX ATTACH
# of a partitioned index takes AccessExclusiveLock on the parent index and
# table, while a FK CONSTRAINT holds the table and waits for the index. It can
# also fail with "there is no unique constraint matching given keys" when a FK
# runs before all ATTACH entries of its referenced index are done.
#
# pgcopydb restores post-data in passes when the archive has INDEX ATTACH
# entries, so the clone must succeed every time and the target schema must
# match the source.

set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
schema_of() { pg_dump -s -n app -d "$1" | grep -v -E '^(--|\\(un)?restrict|$)'; }

pgcopydb ping

psql -qX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/source.sql

export TMPDIR=/tmp/pgcopydb-post-data-partitioned
mkdir -p "${TMPDIR}"

clone() {
    local name=$1
    shift
    target_sql 'drop schema if exists app cascade'
    rm -rf "${TMPDIR}/${name}"
    pgcopydb clone --dir "${TMPDIR}/${name}" --table-jobs 4 --index-jobs 4 "$@" \
        > "${TMPDIR}/${name}.log" 2>&1 \
        || { grep -E 'ERROR|deadlock' "${TMPDIR}/${name}.log" | head -20 >&2;
             fail "clone ${name} exited with an error"; }
}

check_target() {
    local name=$1
    equal "$(target_sql 'select count(*) from pg_index where not indisvalid')" 0 \
        "${name}: invalid indexes on the target"
    diff <(schema_of "${PGCOPYDB_SOURCE_PGURI}") <(schema_of "${PGCOPYDB_TARGET_PGURI}") \
        || fail "${name}: target schema differs from source"
}

# the deadlock depends on the order pg_restore picks ready items, repeat
for i in 1 2 3; do
    clone "parallel-${i}" --restore-jobs 8
    grep -q 'Restoring post-data in 3 passes' "${TMPDIR}/parallel-${i}.log" \
        || fail "parallel-${i}: post-data was not restored in passes"
    check_target "parallel-${i}"
    echo "PASS [parallel-${i}]: post-data restored in passes with --restore-jobs 8"
done

clone serial --restore-jobs 1
if grep -q 'Restoring post-data in 3 passes' "${TMPDIR}/serial.log"; then
    fail "serial: a single transaction restore must not be split"
fi
check_target serial
echo "PASS [serial]: --restore-jobs 1 keeps a single post-data pass"

# A run that stops during post-data leaves part of it on the target. Here the
# foreign keys of pass 3 are missing. The next run must skip the objects that
# exist, which fail with "already exists", or with --drop-if-exists with
# "cannot drop inherited constraint", and it must write the --use-list file
# again rather than append to it.
fkeys="select count(*) from pg_constraint
        where contype = 'f' and connamespace = 'app'::regnamespace"

drop_fkeys() {
    target_sql "select format('alter table %s drop constraint %I;',
                              conrelid::regclass, conname)
                  from pg_constraint
                 where contype = 'f' and conparentid = 0
                   and connamespace = 'app'::regnamespace" \
        | psql -qX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}"
    equal "$(target_sql "${fkeys}")" 0 "foreign keys dropped on the target"

    # and the run did not record post-data as done
    sqlite3 -init /dev/null -batch "${TMPDIR}/retry/schema/source.db" \
        "update timings set done_time_epoch = 0 where label = 'Finalize Schema'"
}

clone retry --restore-jobs 8
list="${TMPDIR}/retry/schema/post-filtered.list"
entries=$(wc -l < "${list}")
source_fkeys=$(source_sql "${fkeys}")

for opts in "" "--drop-if-exists"; do
    name="retry${opts:+ ${opts}}"
    drop_fkeys
    # the snapshot of the clone is gone, as it is on a real rerun
    pgcopydb restore post-data --dir "${TMPDIR}/retry" --resume --not-consistent \
        --restore-jobs 8 ${opts} > "${TMPDIR}/retry.log" 2>&1 \
        || { grep -E 'ERROR' "${TMPDIR}/retry.log" | head -20 >&2;
             fail "${name}: post-data exited with an error"; }
    grep -q 'post-data objects that already exist on the target' \
        "${TMPDIR}/retry.log" \
        || { tail -20 "${TMPDIR}/retry.log" >&2;
             fail "${name}: no existing object was skipped"; }
    equal "$(wc -l < "${list}")" "${entries}" "${name}: lines in ${list}"
    equal "$(target_sql "${fkeys}")" "${source_fkeys}" "${name}: foreign keys"
    check_target "${name}"
    echo "PASS [${name}]: post-data resumed after a partial restore"
done