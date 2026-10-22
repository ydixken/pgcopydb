#! /bin/bash

# Roles whose names need quoting, copied into a target that already has them:
# the retry of clone --all-databases (--resume --not-consistent), which copies
# the roles that attempt 1 created again, and a single-database clone --roles.
# The roles own tables, so the target needs them under their exact names.
# A guard runs restore roles on a hand-written CREATE ROLE with options.

set -euo pipefail

scenario=${1:-all}
scenarios='all-databases-retry single-database restore-hand-written'

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
# an empty value is a query that failed, never a match
equal() { test -n "$2" && test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
# sql <source|target> <database> <statement>...
sql() {
    local uri=${PGCOPYDB_SOURCE_PGURI} db=$2 statement commands=()
    test "$1" = source || uri=${PGCOPYDB_TARGET_PGURI}
    shift 2
    for statement in "$@"; do
        commands+=(-c "${statement}")
    done
    timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${uri%/*}/${db}" "${commands[@]}"
}

case "${scenario}" in
    all)
        pgcopydb ping
        echo "source: $(sql source postgres 'select version()')"
        echo "target: $(sql target postgres 'select version()')"
        status=0
        for scenario in ${scenarios}; do
            bash "$0" "${scenario}" || status=1
        done
        exit "${status}"
        ;;
    all-databases-retry|single-database|restore-hand-written) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-roles/${scenario}
mkdir -p "${TMPDIR}"

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (errors)"
            grep -E ' (ERROR|FATAL) ' "${log}" | tail -n 20 || true
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

# quoted as pg_dumpall writes them in CREATE ROLE
app='"App-User"' hi='"Say ""Hi"""'
# 63 bytes, the longest role name; its quoted form takes 66, which a copy into
# NAMEDATALEN bytes cuts inside the quotes
half=$(printf 'L%.0s' {1..31})
long_name=${half}\"${half} long=\"${half}\"\"${half}\"
roles="select string_agg(rolname, '|' order by rolname) from pg_roles where rolname ~ 'App-User|Hi|LL'"
owners="select string_agg(tablename || ' ' || tableowner, ', ' order by tablename)
    from pg_tables where schemaname = 'public'"

# clone <step> <argument>...: pgcopydb clone in this scenario's work directory
clone() {
    local step=$1 rc=0
    shift
    pgcopydb clone --dir "${TMPDIR}/work" --notice "$@" >"${TMPDIR}/${step}.log" 2>&1 || rc=$?
    echo "${step}: pgcopydb clone $* exited ${rc}"
    test "${rc}" -eq 0 || fail "${step}: pgcopydb clone exited ${rc}"
}
# a role copied under its quoted name would be listed next to the right one
roles_copied() {
    equal "$(sql target postgres "${roles}")" "App-User|${long_name}|Say \"Hi\"" "$1: roles on the target"
    equal "$(sql target rolesdb "${owners}")" "t Say \"Hi\", u App-User, v ${long_name}" \
        "$1: table owners on the target"
    echo "$1: the target has the three roles, and they own the tables"
}
# skipped <step> <quoted role>...: the step ran the role step and found each
# role; a JSON log line carries the text in .message
skipped() {
    local step=$1 role messages
    shift
    messages=$(jq -Rr '. as $line | try (fromjson | .message) catch $line' "${TMPDIR}/${step}.log") ||
        fail "${step}: cannot read ${step}.log"
    for role in "$@"; do
        grep -qF "Skipping CREATE ROLE ${role}, which already exists" <<<"${messages}" ||
            fail "${step}: no \"Skipping CREATE ROLE ${role}\" in ${step}.log"
    done
    echo "${step}: the log shows the skip of each of the $# roles"
}

for side in source target; do
    sql "${side}" postgres 'drop database if exists rolesdb with (force)' \
        "drop role if exists ${app}, ${hi}, ${long}" >/dev/null
done
sql source postgres "create role ${app}" "create role ${hi}" "create role ${long}" \
    'create database rolesdb' >/dev/null
sql source rolesdb 'create table t(id integer primary key)' "alter table t owner to ${hi}" \
    'create table u(id integer primary key)' "alter table u owner to ${app}" \
    'create table v(id integer primary key)' "alter table v owner to ${long}" >/dev/null

case "${scenario}" in
    all-databases-retry)
        clone attempt-1 --all-databases
        roles_copied "after attempt 1"
        # the operator's retry flags
        clone retry --all-databases --resume --not-consistent
        roles_copied "after the retry"
        skipped retry "${app}" "${hi}" "${long}"
        echo "PASS [${scenario}]: the retry finds the roles that attempt 1 created"
        ;;
    single-database)
        sql target postgres "create role ${app}" "create role ${hi}" "create role ${long}" \
            'create database rolesdb' >/dev/null
        clone clone --roles \
            --source "${PGCOPYDB_SOURCE_PGURI%/*}/rolesdb" \
            --target "${PGCOPYDB_TARGET_PGURI%/*}/rolesdb"
        roles_copied "after the clone"
        echo "PASS [${scenario}]: clone --roles finds the roles that the target already has"
        ;;
    # a guard: a line whose name is not one identifier goes to the target as written
    restore-hand-written)
        login=hand_written rc=0
        sql target postgres "drop role if exists ${login}" >/dev/null
        mkdir -p "${TMPDIR}/work/schema"
        echo "CREATE ROLE ${login} WITH LOGIN;" >"${TMPDIR}/work/schema/roles.sql"
        pgcopydb restore roles --dir "${TMPDIR}/work" --notice >"${TMPDIR}/restore.log" 2>&1 || rc=$?
        echo "restore: pgcopydb restore roles exited ${rc}"
        test "${rc}" -eq 0 || fail "restore: pgcopydb restore roles exited ${rc}"
        equal "$(sql target postgres "select rolcanlogin from pg_roles where rolname = '${login}'")" t \
            "${login} can log in on the target"
        echo "PASS [${scenario}]: a guard: restore roles sends CREATE ROLE ${login} WITH LOGIN as written"
        ;;
esac
