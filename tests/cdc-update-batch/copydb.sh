#! /bin/bash

# Runs of single-row UPDATEs on a table whose only unique index is its
# identity index are applied as one UPDATE ... FROM (VALUES ...) per chunk.
# The target data must match the source, and tables that are not safe to
# batch must keep one statement per row.

set -euo pipefail

src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
snapshot_pid= follow_pid=

cleanup() {
    local status=$?
    trap - EXIT
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

# sums the result of query $1 over each replay.db
replay() {
    local f
    for f in "${XDG_DATA_HOME}"/pgcopydb/*-replay.db; do
        timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader -list "${f}" "$1"
    done | awk '{ s += $1 } END { print s + 0 }'
}

# UPDATE replay rows of table $1 whose statement batches rows, filtered by $2
batched() {
    replay "select count(*) from replay r join stmt s on s.hash = r.stmt_hash
             where r.action = 'U' and trim(r.relname, '\"') = '$1'
               and s.sql like '%FROM (VALUES %' $2"
}

# number of VALUES rows of a batched statement
rows_sql="(length(s.sql) - length(replace(s.sql, '), (', ''))) / 4 + 1"

slot_active() {
    test "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb' and active")" = 1
}

compare() {
    local t sql
    for t in "$@"; do
        sql="copy (select * from ${t} order by 1, 2) to stdout"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src_${t}.txt"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt_${t}.txt"
        test -s "${TMPDIR}/src_${t}.txt"
        if ! diff "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" > "${TMPDIR}/diff_${t}.txt"; then
            head -n 10 "${TMPDIR}/diff_${t}.txt"
            fail "table ${t} differs"
        fi
    done
}

# creates database $1 on both sides and clones it, for output plugin $2
prepare() {
    export PGCOPYDB_SOURCE_PGURI=${src_base}/$1
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/$1
    export PGCOPYDB_OUTPUT_PLUGIN=$2
    export TMPDIR=/tmp/$1
    export XDG_DATA_HOME=${TMPDIR}/cdc
    mkdir -p "${TMPDIR}"

    psql -X -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database $1"
    psql -X -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database $1"
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

    # the source table is flat, the target one moves rows between partitions
    target_sql "begin;
        create table t_part_new (id integer not null, bucket integer not null, v integer,
                                 primary key (id, bucket)) partition by list (bucket);
        create table t_part_0 partition of t_part_new for values in (0);
        create table t_part_1 partition of t_part_new for values in (1);
        insert into t_part_new select * from t_part;
        drop table t_part;
        alter table t_part_new rename to t_part;
        commit"
}

start_follow() {
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    local deadline=$((SECONDS + 60))
    until slot_active; do
        kill -0 "${follow_pid}" 2>/dev/null || fail 'follow exited before streaming'
        test "${SECONDS}" -lt "${deadline}" || fail 'timed out waiting for the slot'
        sleep 0.2
    done
}

stop_follow() {
    local deadline=$((SECONDS + 300))
    pgcopydb stream sentinel set endpos --current
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
        sleep 1
    done
    wait "${follow_pid}" || fail "follow exited with $?"
    follow_pid=
}

pgcopydb ping

for plugin in pgoutput test_decoding wal2json; do
    prepare "update_batch_${plugin}" "${plugin}"
    start_follow

    xid=$(source_sql "begin; select txid_current();
                      update t_main set n = n + 1, s = s || 'x' where id <= 1000; commit")
    psql -X -q -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -f /usr/src/pgcopydb/dml.sql
    stop_follow

    compare t_main t_comp t_ci t_riidx t_toast t_part t_uniq t_excl t_rifull t_keyless
    test "$(target_sql "select count(*) from t_part_1 where id % 2 = 0")" = 300 ||
        fail 't_part rows did not move partitions'

    # 1000 rows go in chunks of 512, 256, 128, 64, 32 and 8 rows
    chunks="$(batched t_main "and r.xid = ${xid}")/$(replay "select sum(${rows_sql}) from replay r join stmt s on s.hash = r.stmt_hash
                                                          where r.xid = ${xid} and s.sql like '%FROM (VALUES %'")"
    echo "${plugin}: t_main xid ${xid}: ${chunks} chunks/rows"
    test "${chunks}" = 6/1000 || fail "t_main xid ${xid}: ${chunks} chunks/rows, expected 6/1000"

    for t in t_main t_comp t_ci t_riidx t_toast t_part; do
        n=$(batched "${t}" '')
        echo "${plugin}: ${t}: ${n} batched UPDATE statements"
        test "${n}" -gt 0 || fail "${t}: no UPDATE was batched"
    done
    for t in t_uniq t_excl t_rifull t_keyless; do
        n=$(batched "${t}" '')
        test "${n}" = 0 || fail "${t}: ${n} UPDATE statements were batched"
    done

    # t_rifull is in the set, its rows are not: their old row has every column
    grep -q 'Batching UPDATE rows on 7 tables' "${TMPDIR}/follow.log" ||
        fail "$(grep -o 'Batching UPDATE rows on [0-9]* tables' "${TMPDIR}/follow.log" | head -1), expected 7"

    # chunk sizes bound the number of prepared statements per table shape
    odd=$(replay "select count(*) from stmt s where s.sql like '%FROM (VALUES %'
                    and ((${rows_sql}) & ((${rows_sql}) - 1) <> 0 or (${rows_sql}) > 1024)")
    test "${odd}" = 0 || fail "${odd} batched statements hold a row count that is not a power of two up to 1024"

    test "$(grep -c ' ERROR ' "${TMPDIR}/follow.log")" = 0 || fail 'follow logged errors'
    pgcopydb stream cleanup
    echo "PASS: ${plugin}"
done
