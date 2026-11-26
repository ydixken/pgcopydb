#! /bin/bash

# Source sessions write with a replication origin, as a subscriber or another
# pgcopydb apply does.  pgoutput sends the BEGIN of such a transaction with a
# header LSN of 0/0, and follow must still apply it like any other.
# Case A puts endpos inside the last origin transaction, case B after it.
# Both cases run against the PGVERSION source and a PostgreSQL 13 source.

set -euo pipefail

WORKDIR=$(mktemp -d /tmp/pgcopydb-origin-source.XXXXXX)
snapshot_pid='' follow_pid='' rc='' failures=0

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${WORKDIR}"/*/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
rows() { target_sql "select coalesce(string_agg(id::text, ',' order by id), '') from t"; }

# origin_sql <sql>: run sql in a session whose commits carry the origin g5
origin_sql() {
    timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
        -c '\o /dev/null' -c "select pg_replication_origin_session_setup('g5')" -c '\o' -c "$1"
}

# Only a commit with the origin moves its local_lsn, so this proves the writes used it.
origin_past() {
    source_sql "select coalesce(bool_or(s.local_lsn > '$1'), false)
        from pg_replication_origin o join pg_replication_origin_status s on s.local_id = o.roident
        where o.roname = 'g5'"
}

# zero_begins: the BEGIN rows stored at LSN 0/0, over every output.db
zero_begins() {
    local file n total=0
    for file in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        test -f "${file}" || fail "no output.db in ${XDG_DATA_HOME}/pgcopydb"
        n=$(sqlite3 -readonly -init /dev/null -batch -noheader "${file}" \
            "select count(*) from output where action = 'B' and lsn = 0")
        total=$((total + n))
    done
    echo "${total}"
}

check() {
    if test "$2" = "$3"; then
        echo "OK   $1: $3"
    else
        echo "FAIL $1: expected $2, got $3"
        failures=$((failures + 1))
    fi
}

# follow_to <tag>: follow to the sentinel endpos, its exit status in rc
follow_to() {
    setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/$1.log" 2>&1 &
    follow_pid=$!
    local deadline=$((SECONDS + 120))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" ||
            fail "$1: follow did not exit at endpos within 120 s, with rows $(rows) on the target"
        sleep 0.2
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    follow_pid=
    echo "$1: follow exited ${rc} with rows $(rows) on the target"
    test "${rc}" = 0 || grep -E 'ERROR' "${TMPDIR}/$1.log" | cut -c1-240 | tail -n 5 || true
}

# run_case <A|B> <source host>: rows 1 and 3 carry the origin, row 2 does not
run_case() {
    local name="$1-$2" start mid endpos expected
    export PGCOPYDB_SOURCE_PGURI="postgres://postgres:h4ckm3@$2/postgres"
    export TMPDIR="${WORKDIR}/${name}" XDG_DATA_HOME="${WORKDIR}/${name}/cdc"
    mkdir -p "${TMPDIR}"
    pgcopydb ping
    echo "${name}: source PostgreSQL $(source_sql 'show server_version')"

    source_sql 'drop table if exists t; create table t (id integer primary key, v text)'
    source_sql "select pg_replication_origin_drop(roname) from pg_replication_origin where roname = 'g5'" > /dev/null
    # a clone without --follow restores the publication pgcopydb on the target
    target_sql 'drop table if exists t; drop publication if exists pgcopydb'

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
    pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
    pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}"
    snapshot_pid=
    pgcopydb stream sentinel set apply
    source_sql "select pg_replication_origin_create('g5')" > /dev/null

    start=$(source_sql 'select pg_current_wal_insert_lsn()')
    origin_sql "insert into t values (1, 'origin')"
    test "$(origin_past "${start}")" = t || fail "${name}: row 1 was written without the origin g5"
    source_sql "insert into t values (2, 'plain')"
    mid=$(origin_sql "begin; insert into t values (3, 'origin'); select pg_current_wal_insert_lsn(); commit")
    test "$(origin_past "${mid}")" = t || fail "${name}: row 3 was written without the origin g5"

    if test "$1" = A; then
        endpos=${mid} expected=1,2
    else
        endpos=$(source_sql 'select pg_current_wal_insert_lsn()') expected=1,2,3
    fi
    echo "${name}: endpos ${endpos}, the insert of row 3 ends at ${mid}"

    pgcopydb stream sentinel set endpos "${endpos}"
    follow_to "${name}"
    check "${name} follow exit status" 0 "${rc}"
    check "${name} rows on the target" "${expected}" "$(rows)"
    check "${name} BEGIN rows at 0/0 in output.db" 0 "$(zero_begins)"
    pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
}

for host in source source13; do
    run_case A "${host}"
    run_case B "${host}"
done

test "${failures}" = 0 || fail "${failures} checks failed"
echo "PASS: transactions with a replication origin were applied like any other, on both sources"
