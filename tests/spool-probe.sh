#! /bin/bash
#
# Readers of the change spool for suite scripts: source this file.
# spool_apply and its two callers read "pgcopydb stream apply --target -" of
# the default work directory, on either layout. That command transforms
# output.db into replay.db again, so it runs on a copy.
# The spool_records group reads "pgcopydb list spool" and needs the raw spool.
#

# spool_apply: the stdout apply of a copy of the work directory, without replay.db
spool_apply() {
    local topdir=${TMPDIR:-/tmp}/pgcopydb
    local cdcdir=${XDG_DATA_HOME:-${HOME}/.local/share}/pgcopydb
    local copy left rc=0 fail=""

    test -d "${topdir}" && test -d "${cdcdir}" || {
        echo "FAIL: no work directory at ${topdir} and ${cdcdir}" >&2
        return 1
    }
    copy=$(mktemp -d) || return 1
    # cdc_files holds absolute paths: point them at the copy, or apply writes the original
    local moved="update cdc_files set filename = '${copy}/cdc/' || substr(filename, length('${cdcdir}/') + 1)
                 where filename like '${cdcdir}/%';
                 select count(*) from cdc_files where filename not like '${copy}/cdc/%';"
    cp -a "${topdir}/." "${copy}/" && mkdir -p "${copy}/cdc" &&
        cp -a "${cdcdir}/." "${copy}/cdc/" && rm -f "${copy}"/cdc/*-replay.db* ||
        fail="cannot copy the work directory"
    if test -z "${fail}"; then
        left=$(sqlite3 -init /dev/null -batch -noheader "${copy}/schema/source.db" "${moved}")
        test "${left}" = 0 || fail="cdc_files rewrite left '${left}' rows outside the copy"
    fi
    if test -z "${fail}"; then
        timeout -s KILL 120 pgcopydb stream apply --target - --dir "${copy}" > "${copy}/apply.out" || rc=$?
        if test ${rc} -eq 137; then
            fail="stream apply --target - was killed, or ran past 120s"
        elif test ${rc} -ne 0; then
            fail="stream apply --target - exited with status ${rc}"
        elif ! grep -q '^COMMIT$' "${copy}/apply.out"; then
            fail="stream apply --target - printed no transaction"
        fi
    fi
    test -n "${fail}" || cat "${copy}/apply.out" || fail="cannot print the apply output"
    rm -rf "${copy}"
    test -z "${fail}" || {
        echo "FAIL: ${fail}" >&2
        return 1
    }
}

# spool_records: the index records of the raw spool, as one JSON array.
# Performance mode only: the SQLite layout has no spool to read.
spool_records() {
    local js
    js=$(pgcopydb list spool --json) || {
        echo 'FAIL: pgcopydb list spool --json' >&2
        return 1
    }
    jq -e 'type == "array"' <<<"${js}" > /dev/null || {
        echo "FAIL: pgcopydb list spool --json printed no array: ${js}" >&2
        return 1
    }
    echo "${js}"
}

# spool_commits: the number of complete transactions in the raw spool
spool_commits() {
    local js
    js=$(spool_records) || return 1
    jq 'length' <<<"${js}"
}

# spool_commit_lsns: one commit position per line, in commit order.
# The commit position is the end LSN of the commit record, which is what
# origins, endpos and the low-water mark all use.
spool_commit_lsns() {
    local js
    js=$(spool_records) || return 1
    jq -r '.[].end_lsn' <<<"${js}"
}

# spool_commit_lsn <xid> [changes]: the commit position of that transaction,
# which the spool must hold exactly once, with that many I/U/D/T messages
spool_commit_lsn() {
    local js row
    js=$(spool_records) || return 1
    row=$(jq -r --argjson xid "$1" \
        'map(select(.xid == $xid)) | if length == 1 then "\(.[0].end_lsn) \(.[0].changes)" else "" end' \
        <<<"${js}")
    test -n "${row}" || {
        echo "FAIL: the raw spool holds no single transaction with xid $1" >&2
        return 1
    }
    if test $# -gt 1 && test "${row#* }" != "$2"; then
        echo "FAIL: xid $1 has ${row#* } changes, expected $2" >&2
        return 1
    fi
    echo "${row% *}"
}

# spool_stmts: the distinct statement texts, in first-use order
spool_stmts() {
    local out
    out=$(spool_apply) || return 1
    sed -n 's/^PREPARE [0-9a-f]* AS \(.*\);$/\1/p' <<<"${out}" | awk '!seen[$0]++'
}

# spool_apply_shape: the transactions with the EXECUTE arguments cut off,
# because the DML scripts write clock values; a line of a multi-line value is dropped
spool_apply_shape() {
    local out
    out=$(spool_apply) || return 1
    awk '/^(BEGIN|COMMIT|ROLLBACK)$/ || /^PREPARE / { print; next }
         /^EXECUTE / { print $1, $2 }' <<<"${out}"
}

# spool_zero_final_lsns: index records of the raw spool whose final_lsn is 0/0.
# A spool without an index record is a failure, so the count is never 0 for
# want of a record to read.
spool_zero_final_lsns() {
    local records
    records=$(timeout 60s pgcopydb list spool --json) || {
        echo "FAIL: cannot read the raw spool" >&2
        return 1
    }
    test "$(jq 'length' <<<"${records}")" -gt 0 || {
        echo "FAIL: the raw spool holds no index record" >&2
        return 1
    }
    jq '[.[] | select(.final_lsn == "0/0")] | length' <<<"${records}"
}
