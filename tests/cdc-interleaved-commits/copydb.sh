#! /bin/bash

# Logical decoding sends transactions in commit order, and a BEGIN row carries
# the transaction's first LSN.  Each workload commits B while A is open, so
# A's BEGIN sits below B's COMMIT, and the target must still get both.

set -x -euo pipefail

pgcopydb ping

src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}

# dblink drives the two sessions from one script, outside the migrated database
psql -X -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c 'create database ctl'
psql -X -v ON_ERROR_STOP=1 -d "${src_base}/ctl" -c 'create extension dblink'

workload() {
    psql -X -q -v ON_ERROR_STOP=1 -v db="${db}" -d "${src_base}/ctl" \
         -o /dev/null -f "/usr/src/pgcopydb/$1"
}

drain() {
    pgcopydb stream sentinel set endpos --current
    timeout 120s pgcopydb follow --resume --not-consistent --notice
}

# without the overlap this suite would pass on a build that loses it; count
# each workload's pairs on their own, so one workload cannot cover another
interleaved() {
    local n=0 f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        n=$((n + $(sqlite3 -init /dev/null -batch -noheader "${f}" \
            "select count(*) from output b
               join output c on c.action = 'C' and c.id < b.id and c.lsn > b.lsn
              where b.action = 'B'")))
    done
    test "$((n - seen))" -eq "$1"
    seen=${n}
}

. /var/lib/postgres/spool-probe.sh

# The index of the raw spool carries no BEGIN position, so the overlap itself
# has no raw form here: it is the workload that makes it, and
# cdc-commit-order-resume pins what the apply does with it. What an index
# record answers is the commit order, which the sqlite query reads from the
# row ids: one record per transaction, and the sequence number rising with the
# commit position.
if [ "${PGCOPYDB_FOLLOW_MODE:-}" = performance ]; then
    interleaved() {
        local js n
        js=$(spool_records) || return 1
        n=$(jq 'length' <<<"${js}")
        test "$((n - seen))" -ge "$1" ||
            { echo "FAIL: ${n} records in the raw spool, ${seen} before, expected $1 more" >&2; return 1; }
        jq -e '(map(.xid) | unique | length) == length' <<<"${js}" > /dev/null ||
            { echo 'FAIL: a transaction has more than one index record' >&2; return 1; }
        local sq lsn cur pseq=-1 prev=-1
        while read -r sq lsn; do
            cur=$(( 16#${lsn%%/*} * 4294967296 + 16#${lsn##*/} ))
            test "${sq}" -gt "${pseq}" -a "${cur}" -gt "${prev}" ||
                { echo "FAIL: record ${sq} at ${lsn} does not rise above ${pseq}" >&2; return 1; }
            pseq=${sq} prev=${cur}
        done < <(jq -r '.[] | "\(.seq) \(.end_lsn)"' <<<"${js}")
        seen=${n}
    }
fi

compare() {
    local t sql
    for t in ta tb; do
        sql="copy (select * from ${t} order by id) to stdout"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "/tmp/src_${t}.txt"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "/tmp/tgt_${t}.txt"
        test -s "/tmp/src_${t}.txt"
        diff "/tmp/src_${t}.txt" "/tmp/tgt_${t}.txt"
    done
}

for plugin in pgoutput test_decoding; do
    if [ "${PGCOPYDB_FOLLOW_MODE:-}" = performance ] && [ "${plugin}" != pgoutput ]; then
        echo "SKIP: ${plugin} has no performance mode"
        continue
    fi
    db=interleave_${plugin}
    export PGCOPYDB_SOURCE_PGURI=${src_base}/${db}
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/${db}
    export PGCOPYDB_OUTPUT_PLUGIN=${plugin}
    export TMPDIR=/tmp/interleave-${plugin}
    export XDG_DATA_HOME=${TMPDIR}/cdc
    mkdir -p "${TMPDIR}"

    psql -X -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database ${db}"
    psql -X -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database ${db}"
    psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/ddl.sql

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"

    pgcopydb stream setup
    pgcopydb clone

    kill -TERM ${snapshot_pid}
    wait ${snapshot_pid}

    pgcopydb stream sentinel set apply
    seen=0

    # a later transaction commits after the last overlapped one
    workload followed.sql
    drain
    interleaved 3
    compare

    # the overlapped transaction is the last one before endpos
    workload tail.sql
    drain
    interleaved 1
    compare

    pgcopydb stream cleanup
    echo "PASS: ${plugin}"
done
