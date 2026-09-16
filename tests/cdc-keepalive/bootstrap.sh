#! /bin/bash

# Sourced by copydb.sh to reuse the SQL, polling, and process cleanup helpers.
root=${TMPDIR}
source_admin=${PGCOPYDB_SOURCE_PGURI}
target_admin=${PGCOPYDB_TARGET_PGURI}

new_workdir() {
    export TMPDIR=${root}/$1
    export XDG_DATA_HOME=${TMPDIR}/cdc
    export PGCOPYDB_OUTPUT_PLUGIN=${plugin}
    mkdir -p "${TMPDIR}"
    workdir=${TMPDIR}/work
    catalog=${workdir}/schema/source.db
    printf '[include-only-table]\npublic.bootstrap_guard\n' >"${TMPDIR}/filters.ini"
    clone_args=(--dir "${workdir}" --table-jobs 4
        --split-tables-larger-than 536870912 --split-max-parts 8
        --drop-if-exists --use-copy-binary --filters "${TMPDIR}/filters.ini"
        --follow --slot-name pgcopydb --origin pgcopydb --plugin "${plugin}")
}

catalog_write() { timeout 5s sqlite3 -init /dev/null -batch "${catalog}" "$1"; }
sentinel_row() { sqlite "${catalog}" 'select * from sentinel where id = 1'; }
retry_guard() {
    timeout 15s psql -Xq -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
        -f /usr/src/pgcopydb/publication-retry.sql
}
expect_failure() {
    local expected_status=$1 pattern=$2 log=$3 status=0
    shift 3
    timeout 90s "$@" >"${log}" 2>&1 || status=$?
    equal "${status}" "${expected_status}" "failure exit status (${log})"
    grep -Fq "${pattern}" "${log}" || fail "missing diagnostic: ${pattern}"
}
orphan_attempt() {
    source_sql 'create publication pgcopydb'
    orphan_oid=$(source_sql "select oid from pg_publication where pubname = 'pgcopydb'")
    equal "$(source_sql "select count(*) from pg_publication_tables where pubname = 'pgcopydb'")" 0 'empty orphan publication'
    expect_failure 6 'publication "pgcopydb" already exists' "${TMPDIR}/first.log" \
        pgcopydb clone "${clone_args[@]}" --restart
    equal "$(sqlite "${catalog}" 'select count(*) from sentinel')" 0 'no initial sentinel'
    equal "$(sqlite "${catalog}" 'select count(*) from replication_slot')" 0 'no saved slot'
    equal "$(source_sql "select count(*) from pg_replication_slots where slot_name = 'pgcopydb'")" 0 'no source slot'
    test ! -s "${workdir}/snapshot" || fail 'first attempt exported a snapshot'
    retry_guard
}
cleanup_replication() {
    timeout 30s pgcopydb stream cleanup --dir "${workdir}"
}
target_rows() {
    test "$(target_sql "select to_regclass('public.bootstrap_guard') is not null")" = t || return 1
    test "$(target_sql 'select id, payload from bootstrap_guard order by id')" = "$1"
}

pgcopydb ping
# Patched PostgreSQL releases require an allowlist for installed output plugins.
if test "$(source_sql "select current_setting('output_plugin_libraries', true) is not null")" = t; then
    source_sql 'alter system set output_plugin_libraries = pgoutput, test_decoding, wal2json'
    source_sql 'select pg_reload_conf()' >/dev/null
    plugins_ready() { test "$(source_sql "show output_plugin_libraries")" = 'pgoutput, test_decoding, wal2json'; }
    poll 'output plugins enabled' plugins_ready
fi
source_sql 'create role bootstrap_app login replication'
source_sql 'create database bootstrap_db owner bootstrap_app'
target_sql 'create role bootstrap_app login'
target_sql 'create database bootstrap_db owner bootstrap_app'
PGCOPYDB_TARGET_PGURI=${target_admin%/*}/bootstrap_db target_sql \
    "do \$\$ declare f oid; begin
       for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'pg_catalog' and p.proname like 'pg_replication_origin%'
       loop execute format('grant execute on function %s to bootstrap_app', f::regprocedure); end loop;
     end \$\$;
     grant set on parameter session_replication_role to bootstrap_app"
export PGCOPYDB_SOURCE_PGURI=postgres://bootstrap_app@source/bootstrap_db
export PGCOPYDB_TARGET_PGURI=postgres://bootstrap_app@target/bootstrap_db
source_sql "create table bootstrap_guard(id integer primary key, payload text);
            insert into bootstrap_guard values (0, 'baseline');
            create publication unrelated_guard for table bootstrap_guard"
unrelated_oid=$(source_sql "select oid from pg_publication where pubname = 'unrelated_guard'")

for plugin in pgoutput test_decoding wal2json; do
    new_workdir "clone-${plugin}"
    if test "${plugin}" = pgoutput; then
        orphan_attempt
    fi
    pgcopydb clone "${clone_args[@]}" --resume --not-consistent >"${TMPDIR}/retry.log" 2>&1 &
    worker_pid=$!
    poll 'retry active slot' wire 'true'
    poll 'retry clone complete' grep -q 'All step are now done' "${TMPDIR}/retry.log"
    poll 'retry baseline copied' target_rows $'0|baseline'
    source_sql "insert into bootstrap_guard values (1, 'after-retry')"
    poll 'retry marker applied' target_rows $'0|baseline\n1|after-retry'
    pgcopydb stream sentinel set endpos --current --dir "${workdir}"
    wait_exit "${worker_pid}"
    worker_pid=
    equal "$(sqlite "${catalog}" 'select count(*) from sentinel where id = 1')" 1 'one initialized sentinel'
    equal "$(sqlite "${catalog}" "select startpos = printf('%X/%X', lsn >> 32, lsn & 4294967295) from sentinel, replication_slot")" 1 'sentinel starts at the newly created slot'
    equal "$(sqlite "${catalog}" "select startpos != '0/0' and endpos != '0/0' and write_lsn != '0/0' and flush_lsn != '0/0' and replay_lsn != '0/0' from sentinel")" 1 'established nonzero sentinel positions'
    if test "${plugin}" = pgoutput; then
        publication_oid=$(source_sql "select oid from pg_publication where pubname = 'pgcopydb'")
        test -n "${publication_oid}" || fail 'replacement publication is missing'
        test "${publication_oid}" != "${orphan_oid}" || fail 'orphan publication not replaced'
        equal "$(source_sql "select schemaname || '.' || tablename from pg_publication_tables where pubname = 'pgcopydb'")" public.bootstrap_guard 'filtered publication membership'
        equal "$(source_sql "select oid from pg_publication where pubname = 'unrelated_guard'")" "${unrelated_oid}" 'unrelated publication preserved'
        retry_guard
    fi

    # Completed endpos lets follow validate setup without advancing any cursor.
    for apply in 0 1; do
        catalog_write "update sentinel set apply = ${apply}, endpos = replay_lsn"
        before=$(sentinel_row)
        timeout 30s pgcopydb stream setup --dir "${workdir}" --resume --not-consistent
        equal "$(sentinel_row)" "${before}" 'stream setup preserves every sentinel field'
        timeout 30s pgcopydb follow --dir "${workdir}" --resume --not-consistent
        equal "$(sentinel_row)" "${before}" 'follow preserves every sentinel field'
    done
    slot_before=$(sqlite "${catalog}" 'select * from replication_slot')
    origin_before=$(origin)
    catalog_write 'delete from sentinel'
    expect_failure 12 'Could not read a valid sentinel' "${TMPDIR}/missing.log" \
        pgcopydb clone "${clone_args[@]}" --resume --not-consistent
    equal "$(sqlite "${catalog}" 'select count(*) from sentinel')" 0 'missing retained-slot sentinel not manufactured'
    equal "$(sqlite "${catalog}" 'select * from replication_slot')" "${slot_before}" 'saved slot preserved'
    equal "$(origin)" "${origin_before}" 'target origin preserved'
    cleanup_replication
    source_sql 'delete from bootstrap_guard where id = 1'
    echo "PASS [bootstrap]: ${plugin} clone retry, preserved progress, retained-slot refusal"
done

plugin=pgoutput
new_workdir fresh-existing
orphan_attempt
catalog_write "insert into sentinel values (1, '0/10', '0/20', 1, '0/40', '0/30', '0/20')"
before=$(sentinel_row)
timeout 30s pgcopydb follow --dir "${workdir}" --filters "${TMPDIR}/filters.ini" \
    --resume --not-consistent
equal "$(sentinel_row)" "${before}" 'fresh slot must not replace an existing sentinel'
cleanup_replication

new_workdir fresh-sql-error
orphan_attempt
catalog_write 'alter table sentinel rename column replay_lsn to broken_lsn'
expect_failure 12 'no column named replay_lsn' "${TMPDIR}/sql-error.log" \
    pgcopydb clone "${clone_args[@]}" --resume --not-consistent
equal "$(sqlite "${catalog}" 'select count(*) from sentinel')" 0 'SQL error must not manufacture sentinel state'
equal "$(sqlite "${catalog}" 'select count(*) from replication_slot')" 1 'SQL error exercised the fresh-slot path'
expect_failure 12 'no such column: replay_lsn' "${TMPDIR}/retained-sql-error.log" \
    pgcopydb clone "${clone_args[@]}" --resume --not-consistent
catalog_write 'alter table sentinel rename column broken_lsn to replay_lsn'
cleanup_replication
echo 'PASS [bootstrap]: existing sentinel preserved with a fresh slot; SQL errors are fatal'

# The lower-level setup command still initializes a separately exported slot.
new_workdir prepared-slot
PGCOPYDB_SOURCE_PGURI=${source_admin} pgcopydb snapshot --follow --plugin pgoutput \
    --dir "${workdir}" >"${TMPDIR}/snapshot.out" 2>"${TMPDIR}/snapshot.log" &
snapshot_pid=$!
poll 'prepared slot snapshot' test -s "${TMPDIR}/snapshot.out"
equal "$(sqlite "${catalog}" 'select count(*) from sentinel')" 0 'snapshot does not create sentinel'
PGCOPYDB_SOURCE_PGURI=${source_admin} timeout 30s pgcopydb stream setup --dir "${workdir}"
equal "$(sqlite "${catalog}" 'select count(*) from sentinel')" 1 'plain stream setup initializes a prepared slot'
kill -TERM "${snapshot_pid}"
wait_exit "${snapshot_pid}"
snapshot_pid=
PGCOPYDB_SOURCE_PGURI=${source_admin} cleanup_replication
echo 'PASS [bootstrap]: prepared-slot initialization contract'
