#! /bin/bash

set -euo pipefail
source "$(dirname "$0")/spool.sh"

XDG_DATA_HOME=$(mktemp -d)
export XDG_DATA_HOME
trap 'rm -rf "${XDG_DATA_HOME}"' EXIT
mkdir "${XDG_DATA_HOME}/pgcopydb"
first=${XDG_DATA_HOME}/pgcopydb/001-output.db
last=${XDG_DATA_HOME}/pgcopydb/002-output.db

reject() {
    if spool_transaction "$@"; then
        echo "FAIL: accepted invalid spool for xid=$1" >&2
        exit 1
    fi
}

reject 42 1
for file in "${first}" "${last}"; do
    sqlite3 "${file}" 'create table output(action text, xid integer, lsn integer)'
done
reject 42 1
sqlite3 "${first}" "insert into output values ('B',42,4294967312), ('I',42,4294967328), ('C',7,4294967296)"
sqlite3 "${last}" "insert into output values ('U',42,4294967344), ('C',42,4294967360), ('C',99,8589934592)"
spool_transaction 42 1 1
test "${begin_lsn}|${commit_lsn}" = '1/10|1/40'
reject 7 1
reject 43 1
reject 42 2 1
reject 42 1 0
sqlite3 "${first}" "insert into output values ('C',42,4294967360)"
reject 42 1 1
sqlite3 "${first}" "delete from output where action = 'C' and xid = 42; insert into output values ('B',42,4294967312)"
reject 42 1 1
sqlite3 "${first}" "delete from output where rowid = (select max(rowid) from output); insert into output values ('D',42,4294967345)"
reject 42 1 1
sqlite3 "${first}" "delete from output where action = 'D'"
sqlite3 "${last}" "delete from output where action = 'C' and xid = 42"
reject 42 1 1
sqlite3 "${last}" "insert into output values ('C',42,NULL)"
reject 42 1 1
echo 'PASS: exact-XID spool boundaries reject missing, duplicate, and unexpected DML evidence'
