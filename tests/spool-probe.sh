#! /bin/bash
#
# Readers of the change spool for suite scripts: source this file.
# They read "pgcopydb stream apply --target -" of the default work directory.
# That command transforms output.db into replay.db again, so it runs on a copy.
#

# spool_apply: the stdout apply of a copy of the work directory, without replay.db
spool_apply() {
    local topdir=${TMPDIR:-/tmp}/pgcopydb
    local cdcdir=${XDG_DATA_HOME:-${HOME}/.local/share}/pgcopydb
    local copy rc=0

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
        cp -a "${cdcdir}/." "${copy}/cdc/" && rm -f "${copy}"/cdc/*-replay.db* &&
        test "$(sqlite3 -init /dev/null -batch -noheader "${copy}/schema/source.db" "${moved}")" = 0 &&
        timeout -s KILL 120 pgcopydb stream apply --target - --dir "${copy}" > "${copy}/apply.out" &&
        grep -q '^COMMIT$' "${copy}/apply.out" &&
        cat "${copy}/apply.out" || rc=1
    rm -rf "${copy}"
    test ${rc} -eq 0 || echo "FAIL: stream apply --target - printed no transaction" >&2
    return ${rc}
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
