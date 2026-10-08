#! /bin/bash

# COPY writes one multi-insert WAL record per heap page, and logical decoding
# gives every tuple of that record the same change lsn.  Each tuple must reach
# the target, also when receive sends the transaction again after a reconnect.

set -euo pipefail

rows=${MULTI_INSERT_ROWS:-5000}
src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
snapshot_pid= follow_pid= lock_pid=

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${lock_pid}" || kill "${lock_pid}" 2>/dev/null || true
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        tail -n 40 "${TMPDIR}/follow.log" 2>/dev/null || true
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: ${plugin}: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

# runs $1 on each output.db; a query that matches nothing prints nothing
spool() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-output.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" "$1"
    done
}

# for xid $1: "COMMIT id|newest BEGIN id|INSERT rows|lsns shared by INSERT rows"
txn() {
    spool "select coalesce(max(id) filter (where action = 'C'), '') || '|' ||
                  max(id) filter (where action = 'B') || '|' ||
                  count(*) filter (where action = 'I') || '|' ||
                  (select count(*) from (select 1 from output
                                          where action = 'I' and xid = $1
                                          group by lsn having count(*) > 1))
             from output where xid = $1 having count(*) > 0"
}

poll() {
    local what=$1 deadline=$((SECONDS + $2))
    shift 2
    until "$@"; do
        kill -0 "${follow_pid}" 2>/dev/null || fail "follow exited while waiting for ${what}"
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

# prints the xid of a transaction that copies rows $2 to $3 into table $1
copy_rows() {
    {
        echo 'begin;'
        echo 'select txid_current();'
        echo "copy $1 from stdin;"
        seq "$2" "$3" | awk -v OFS='\t' '{ print $1, "copy-" $1 }'
        echo '\.'
        echo 'commit;'
    } | timeout 120s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}"
}

committed() { IFS='|' read -r commit _ <<<"$(txn "$1")" && test -n "${commit}"; }
slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}
tx_lock() {
    test "$(target_sql "select count(*) from pg_locks l join pg_class c on c.oid = l.relation where c.relname = 'tx' and $1")" -ge 1
}

# output.db must hold every row of xid $2 (table $1); $3 says whether the
# rows share lsns, which shows that the source wrote a multi-insert record
check_spool() {
    local commit begin inserted shared
    IFS='|' read -r commit begin inserted shared <<<"$(txn "$2")"
    echo "$1: xid $2, ${inserted} INSERT rows in output.db, ${shared} lsns shared"
    test "${inserted}" = "${rows}" || fail "$1: output.db holds ${inserted} INSERT rows of ${rows}"
    if test "$3" = shared; then
        test "${shared}" -ge 1 || fail "$1: no INSERT rows share an lsn, so COPY wrote no multi-insert"
    else
        test "${shared}" = 0 || fail "$1: INSERT rows share an lsn"
    fi
}

# a row in pgoutput_col whose output row was replaced is left over
check_orphans() {
    local n
    n=$(spool "select count(*) from pgoutput_col where output_id not in (select id from output)" |
        awk '{ s += $1 } END { print s + 0 }')
    test "${n}" = 0 || fail "pgoutput_col holds ${n} rows of replaced output rows"
}

compare() {
    local t sql
    for t in tx t_copy t_ins t_resend p_copy; do
        sql="copy (select * from ${t} order by id) to stdout"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src_${t}.txt"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt_${t}.txt"
        test -s "${TMPDIR}/src_${t}.txt"
        if ! diff -q "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" > /dev/null; then
            echo "target ${t}: $(target_sql "select count(*) from ${t}") rows, source: $(source_sql "select count(*) from ${t}")"
            fail "table ${t} differs"
        fi
    done
}

pgcopydb ping

for plugin in pgoutput test_decoding wal2json; do
    db=multi_insert_${plugin}
    export PGCOPYDB_SOURCE_PGURI=${src_base}/${db}
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/${db}
    export PGCOPYDB_OUTPUT_PLUGIN=${plugin}
    export TMPDIR=/tmp/multi-insert-${plugin}
    export XDG_DATA_HOME=${TMPDIR}/cdc
    mkdir -p "${TMPDIR}"

    psql -X -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database ${db}"
    psql -X -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database ${db}"
    psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/ddl.sql

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
    pgcopydb stream setup
    pgcopydb clone
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}"
    snapshot_pid=

    pgcopydb stream sentinel set apply
    setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    poll 'the slot to be streamed' 60 slot_active

    # COPY into a table and into a partitioned table; INSERT ... SELECT
    # writes one WAL record per row and is the control
    xid_copy=$(copy_rows t_copy 1 "${rows}")
    xid_part=$(copy_rows p_copy 1 "${rows}")
    xid_ins=$(source_sql "begin; select txid_current(); insert into t_ins select g, 'ins-' || g from generate_series(1, ${rows}) g; commit")
    for x in "${xid_copy}" "${xid_part}" "${xid_ins}"; do
        poll "xid ${x} in output.db" 120 committed "${x}"
    done
    check_spool t_copy "${xid_copy}" shared
    check_spool p_copy "${xid_part}" shared
    check_spool t_ins "${xid_ins}" distinct

    # Hold the apply on X, so confirmed_flush stays below the COPY A, then
    # make receive reconnect: it sends A again and replaces each of its rows.
    psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
         -c 'begin; lock table tx in access exclusive mode; select pg_sleep(3600)' > /dev/null 2>&1 &
    lock_pid=$!
    poll 'the target lock' 30 tx_lock "l.mode = 'AccessExclusiveLock' and l.granted"
    source_sql 'insert into tx values (1)'
    xid_a=$(copy_rows t_resend 1 "${rows}")
    poll "xid ${xid_a} in output.db" 120 committed "${xid_a}"
    poll 'apply to block on X' 60 tx_lock "not l.granted"

    IFS='|' read -r commit_before _ <<<"$(txn "${xid_a}")"
    poll 'an active walsender' 60 slot_active
    source_sql "select pg_terminate_backend(active_pid) from pg_replication_slots where slot_name = 'pgcopydb'" > /dev/null
    resent() {
        local commit begin
        IFS='|' read -r commit begin _ <<<"$(txn "${xid_a}")"
        test -n "${commit}" && test "${commit}" -gt "${commit_before}" && test "${begin}" -lt "${commit}"
    }
    poll "receive to send xid ${xid_a} again" 120 resent
    check_spool t_resend "${xid_a}" shared
    check_orphans

    kill "${lock_pid}"
    lock_pid=
    target_sql "select pg_terminate_backend(pid) from pg_stat_activity where query like '%pg_sleep(3600)%' and pid <> pg_backend_pid()" > /dev/null

    source_sql 'insert into tx values (2)'
    pgcopydb stream sentinel set endpos --current
    deadline=$((SECONDS + 300))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
        sleep 1
    done
    wait "${follow_pid}" || fail "follow exited with $?"
    follow_pid=

    compare
    pgcopydb stream cleanup
    echo "PASS: ${plugin}"
done
