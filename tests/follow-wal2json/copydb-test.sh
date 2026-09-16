#! /bin/bash
set -eu

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export TMPDIR="$work" PGCOPYDB_SOURCE_PGURI=source PGCOPYDB_TARGET_PGURI=target
mkdir -p "$TMPDIR/cdc/pgcopydb"

# Stub external commands so cleanup cannot mask an earlier harness failure.
pgcopydb() {
    if [[ "$*" == clone* ]]; then
        [[ " $* " == *' --wal2json-numeric-as-string '* ]] || return 24
    fi
    if [[ "$*" == clone* && "$failure" == clone ]]; then return 23; fi
    if [[ "$*" == 'stream cleanup' ]]; then touch "$TMPDIR/cleanup"; fi
}
psql() {
    if [[ "$failure" == sql ]]; then return 23; fi
    case "$*" in
        *'select first_name'*) echo WAL2JSON ;;
        *'select count'*) echo '1|digest' ;;
    esac
}
sqlite3() {
    case "$*" in
        *'count(*)'*)
            if [[ "$*" == *"from $failure"* ]]; then echo 0; else echo 1; fi ;;
    esac
}
export -f pgcopydb psql sqlite3

for failure in clone sql missing-output missing-replay output stmt replay none; do
    export failure
    touch "$TMPDIR/cdc/pgcopydb/test-output.db" "$TMPDIR/cdc/pgcopydb/test-replay.db"
    case "$failure" in
        missing-output) rm "$TMPDIR/cdc/pgcopydb/test-output.db" ;;
        missing-replay) rm "$TMPDIR/cdc/pgcopydb/test-replay.db" ;;
    esac
    status=0
    bash "$(dirname "$0")/copydb.sh" > "$work/$failure.log" 2>&1 || status=$?
    if [[ "$failure" == none ]]; then
        test "$status" -eq 0
        test -f "$TMPDIR/cleanup"
    else
        test "$status" -ne 0
        test ! -f "$TMPDIR/cleanup"
    fi
    echo "$failure: exit $status"
done
echo 'PASS: follow propagates errors and rejects missing or empty CDC databases'
