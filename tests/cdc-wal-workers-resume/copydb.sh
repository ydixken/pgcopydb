#! /bin/bash

set -euo pipefail

# Three WAL workers resume to endpos after a kill -9 of an apply right after
# its target COMMIT, of a receive, of the supervisor, and of a setup before
# its origins; a setup killed or failed between two slot copies, and every
# resume the catalog or a worker slot cannot honour, is refused. rs.evt and
# st.ev have no key, so a row applied twice shows as a count difference.

src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
S=pgcopydb
BAD_ARGS=1
SOURCE=6
INTERNAL=12
tc=setup
pid=
writer_pid=

on_exit() {
    local status=$?
    trap - EXIT
    touch /tmp/stop
    test -z "${writer_pid}" || wait "${writer_pid}" 2> /dev/null || true
    pkill -KILL -x pgcopydb 2> /dev/null || true
    exit "${status}"
}
trap on_exit EXIT

fail() {
    local log
    for log in /tmp/"${tc}"/*.log; do
        test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
    done
    echo "FAIL [${tc}]: $*" >&2
    exit 1
}

src() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" "$@"; }
tgt() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" "$@"; }
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}" || fail "${1}"; }
lite() { timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "$1" "$2"; }

# expect code "message" log command...: exits with code and logs the message;
# a refusal that regresses into a running follow exits 124
expect() {
    local want=$1 msg=$2 log=/tmp/${tc}/$3.log rc=0
    shift 3
    timeout 120 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne "${want}" ] || ! grep -qF -- "${msg}" "${log}"; then
        cat "${log}"
        fail "want exit ${want} and \"${msg}\", got exit ${rc}: $*"
    fi
    echo "OK exit ${rc}: $*"
}

# pgrep exits 1 when nothing matches, and 2 or more when it failed to look
settled() {
    local rc=0
    for _ in $(seq 30); do
        pgrep -x pgcopydb > /dev/null || break
        sleep 0.5
    done
    pgrep -a -x pgcopydb || rc=$?
    [ "${rc}" -eq 1 ] || fail "pgcopydb processes are left after $1, pgrep exit ${rc}"
}

# the walsender of a stopped worker lets go of its slot a little later
wait_slots_inactive() {
    for _ in $(seq 60); do
        [ "$(src -c 'select count(*) from pg_replication_slots where active')" -eq 0 ] && return
        sleep 0.5
    done
    fail 'replication slots still active'
}

slots() { src -c "select coalesce(string_agg(slot_name, ',' order by slot_name collate \"C\"), '') from pg_replication_slots where slot_name ~ '^${S}(_w[0-9]+)?\$'"; }
pubs() { src -c "select count(*) from pg_publication where pubname ~ '^${S}_t[0-9]+\$'"; }
origins() { tgt -c "select coalesce(string_agg(roname, ',' order by roname collate \"C\"), '') from pg_replication_origin"; }

# the LSN at which the main catalog says the slots were created
slot_lsn() { lite "$1/schema/source.db" "select printf('%X/%X', lsn >> 32, lsn & 4294967295) from replication_slot"; }

assignment() {
    lite "$1/schema/source.db" "select (select workers || '|' || high_traffic from wal_worker_setup) || ' ' || group_concat(oid || ':' || worker, ' ') from (select oid, worker from wal_worker_table order by oid)"
}

begin_case() {
    tc=$1
    local db=r_${tc//-/_}
    export PGCOPYDB_SOURCE_PGURI=${src_base}/${db}
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/${db}
    mkdir -p "/tmp/${tc}"
    echo "=== ${tc}"
    psql -X -q -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database ${db}"
    psql -X -q -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database ${db}"
}

# counts tables: count and md5 of every table, on source and target
counts() {
    local t out=''
    for t in $2; do
        out="${out} ${t}:$($1 -c "select count(*) || ':' || md5(coalesce(string_agg(x::text, ',' order by x::text), '')) from ${t} x")"
    done
    echo "${out# }"
}

start_writer() {
    rm -f /tmp/stop
    (
        i=0
        while [ ! -e /tmp/stop ]; do
            i=$((i + 1))
            round "${i}"
        done
        echo "${i}" > "/tmp/${tc}/rounds"
    ) &
    writer_pid=$!
}

stop_writer() {
    touch /tmp/stop
    wait "${writer_pid}"
    writer_pid=
    echo "writer committed $(cat "/tmp/${tc}/rounds") transactions"
}

# running log count: the run of pid logs count 'Started WAL worker' and runs
# 2 * count receive and apply processes
running() {
    for _ in $(seq 240); do
        [ "$(pgrep -c -f '^pgcopydb: follow (receive|apply)( |$)' || true)" -eq $((2 * $2)) ] &&
            [ "$(grep -c 'Started WAL worker' "$1")" -ge "$2" ] && return
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    fail "$2 WAL workers did not start, see $1"
}

# stopped what: the run of pid exits with an error within 60 s
stopped() {
    local rc=124
    for _ in $(seq 120); do
        if ! kill -0 "${pid}" 2> /dev/null; then
            rc=0
            wait "${pid}" || rc=$?
            break
        fi
        sleep 0.5
    done
    [ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] || fail "$1 left exit ${rc}"
    pid=
    settled "$1"
    wait_slots_inactive
    echo "OK $1 stopped the run, exit ${rc}"
}

# finished log: the run of pid exits 0 within 120 s
finished() {
    local rc=124
    for _ in $(seq 240); do
        if ! kill -0 "${pid}" 2> /dev/null; then
            rc=0
            wait "${pid}" || rc=$?
            break
        fi
        sleep 0.5
    done
    [ "${rc}" -eq 0 ] || { cat "$1"; fail "the run exited ${rc}"; }
    pid=
    settled 'a finished run'
    wait_slots_inactive
}

# gdb_kill pid ignore finish breakpoint: attach to pid and kill it at the
# breakpoint, after the function returned when finish is 1
gdb_kill() {
    timeout 120s sudo -n gdb -q -batch -p "$1" \
        -ex "set \$finish = $3" -ex "break $4" -ex "ignore 1 $2" \
        -x /usr/src/pgcopydb/attach-kill.gdb > "/tmp/${tc}/gdb.log" 2>&1 ||
        { cat "/tmp/${tc}/gdb.log"; fail "gdb exited $?"; }
    grep -q '^KILLED-AT-BREAKPOINT$' "/tmp/${tc}/gdb.log" ||
        { cat "/tmp/${tc}/gdb.log"; fail "pid $1 did not reach $4"; }
}

# gdb_run breakpoint ignore log command...: run command and kill it at the
# breakpoint
gdb_run() {
    local bp=$1 ignore=$2 log=/tmp/${tc}/$3.log
    shift 3
    timeout 120s gdb -q -batch -ex "break ${bp}" -ex "ignore 1 ${ignore}" \
        -x /usr/src/pgcopydb/kill-at.gdb --args "$@" > "${log}" 2>&1 ||
        { cat "${log}"; fail "gdb exited $?"; }
    grep -q '^KILLED-AT-BREAKPOINT$' "${log}" || { cat "${log}"; fail "$* did not reach ${bp}"; }
    settled "a kill at ${bp}"
    wait_slots_inactive
}

pgcopydb ping

#
# kills: clone --follow, then resume after each kill, under a steady load
#
round() {
    src -1 -c "insert into rs.hot(n) values ($1)" \
           -c "update rs.acct set balance = balance + 1 where id = $1 % 50" \
           -c "insert into rs.evt values ($1, 'ins'), ($1, 'ins')" \
           -c "delete from rs.evt where id = $1 - 7" \
           -c "insert into rs.p values ($1, $1 % 2000)"
}

kills() {
    begin_case kills
    local dir=/tmp/kills/run log lsn wpid apid rpid tables
    tables='rs.acct rs.evt rs.hot rs.p1 rs.p2'
    # rs.evt, the keyless canary, gets worker 1, whose apply kill (a) targets
    local ww=(--wal-workers 3 --wal-high-traffic-tables 'rs.hot,rs.evt')

    src <<'SQL'
create schema rs;
create table rs.hot(id bigserial primary key, n bigint not null);
create table rs.acct(id integer primary key, balance bigint not null);
create table rs.evt(id bigint not null, kind text not null);
alter table rs.evt replica identity full;
create table rs.p(id integer not null, k integer not null, primary key (k, id)) partition by range (k);
create table rs.p1 partition of rs.p for values from (0) to (1000);
create table rs.p2 partition of rs.p for values from (1000) to (2000);
insert into rs.hot(n) select i from generate_series(1, 100) i;
insert into rs.acct select i, 0 from generate_series(0, 49) i;
insert into rs.evt select i, 'seed' from generate_series(-10, 0) i;
insert into rs.p select -i, i from generate_series(1, 1999) i;
SQL

    # a slot older than the run, for a worker slot below the recorded LSN
    src -c "select pg_create_logical_replication_slot('rspare', 'pgoutput')" > /dev/null

    start_writer
    log=/tmp/kills/clone.log
    pgcopydb clone --follow --dir "${dir}" "${ww[@]}" > "${log}" 2>&1 &
    pid=$!
    for _ in $(seq 240); do
        [ "$(grep -c 'Applying CDC changes' "${log}")" -eq 3 ] && break
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    [ "$(grep -c 'Applying CDC changes' "${log}")" -eq 3 ] || { cat "${log}"; fail 'apply did not start'; }

    check 'worker of rs.evt' 1 "$(lite "${dir}/schema/source.db" "select worker from wal_worker_table where nspname = 'rs' and relname = 'evt'")"

    # the lost directory refusal needs this: an unmoved slot lets a resume
    # rebuild the catalog, and receive reports at its 10 s status interval
    w2_moved() { src -c "select confirmed_flush_lsn > '$(slot_lsn "${dir}")' from pg_replication_slots where slot_name = '${S}_w2'"; }
    for _ in $(seq 60); do
        [ "$(w2_moved)" = t ] && break
        sleep 0.5
    done

    # (a) apply of worker 1, once its COMMIT returned, before anything else
    wpid=$(pgrep -f '^pgcopydb: follow worker 1( |$)') || fail 'no WAL worker 1'
    apid=$(pgrep -P "${wpid}" -f '^pgcopydb: follow apply( |$)') || fail 'no apply of WAL worker 1'
    gdb_kill "${apid}" 2 1 pgsql_replication_origin_xact_commit
    lsn=$(sed -n 's/^origin_lsn = 0x[0-9a-f]* "\(.*\)"$/\1/p' /tmp/kills/gdb.log)
    test -n "${lsn}" || { cat /tmp/kills/gdb.log; fail 'no origin_lsn at the breakpoint'; }
    stopped 'a killed apply'
    check 'origin of worker 1 at the killed COMMIT' "${lsn}" \
          "$(tgt -c "select pg_replication_origin_progress('${S}_w1', true)")"

    # refusals: another worker count, another list, a lost worker directory
    expect "${SOURCE}" 'this run uses --wal-workers 2 --wal-high-traffic-tables "rs.hot,rs.evt"' other-n \
           pgcopydb follow --resume --not-consistent --dir "${dir}" --wal-workers 2 --wal-high-traffic-tables rs.hot,rs.evt
    expect "${SOURCE}" 'this run uses --wal-workers 3 --wal-high-traffic-tables "rs.acct"' other-list \
           pgcopydb follow --resume --not-consistent --dir "${dir}" --wal-workers 3 --wal-high-traffic-tables rs.acct
    check 'slot of worker 2 moved since its creation' t "$(w2_moved)"
    mv "${dir}/cdc/w2" "${dir}/cdc-w2"
    expect "${INTERNAL}" 'is missing or incomplete' lost-dir \
           pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"
    settled 'a refused resume'
    test ! -e "${dir}/cdc/w2/source.db" || fail 'a refused resume built a worker catalog'
    rm -rf "${dir}/cdc/w2"
    mv "${dir}/cdc-w2" "${dir}/cdc/w2"

    # (b) receive of worker 2, with a batch of messages not yet committed
    log=/tmp/kills/resume-1.log
    pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}" > "${log}" 2>&1 &
    pid=$!
    running "${log}" 3
    wpid=$(pgrep -f '^pgcopydb: follow worker 2( |$)') || fail 'no WAL worker 2'
    rpid=$(pgrep -P "${wpid}" -f '^pgcopydb: follow receive( |$)') || fail 'no receive of WAL worker 2'
    gdb_kill "${rpid}" 3 0 stream_commit_batch
    stopped 'a killed receive'

    # (c) the supervisor, before it writes the lowest worker LSNs up
    log=/tmp/kills/resume-2.log
    pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}" > "${log}" 2>&1 &
    pid=$!
    running "${log}" 3
    gdb_kill "${pid}" 2 0 follow_sync_main_sentinel
    stopped 'a killed supervisor'

    # the last resume reaches endpos with the load stopped
    log=/tmp/kills/resume-3.log
    pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}" > "${log}" 2>&1 &
    pid=$!
    running "${log}" 3
    stop_writer
    pgcopydb stream sentinel set endpos --current --dir "${dir}" > /dev/null
    finished "${log}"
    grep -qF 'Follow mode is now done, 3 WAL workers reached endpos' "${log}" || fail 'not every worker reached endpos'

    check 'per-table counts and contents' "$(counts src "${tables}")" "$(counts tgt "${tables}")"
    check 'keyless rows applied once' 0 \
          "$(tgt -c "select count(*) from (select id from rs.evt where id > 0 group by id having count(*) <> 2) x")"
    check 'rounds replayed' t "$(tgt -c "select count(*) > 120 from rs.hot")"

    # vacuity guard: an unchanged resume passes the slot checks
    expect 0 'was previously reached' finished \
           pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"

    expect_slot() {
        wait_slots_inactive
        src -c "select pg_drop_replication_slot('${S}_w1')" -c "$1" > /dev/null
        expect "${SOURCE}" "$2" "$3" pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"
        check "$3: worker 1 slot kept" "${S},${S}_w1,${S}_w2" "$(slots)"
    }
    expect_slot "select pg_create_logical_replication_slot('${S}_w1', 'test_decoding')" \
                "Replication slot \"${S}_w1\" uses plugin test_decoding" wrong-plugin
    check 'spare slot below the recorded LSN' t \
          "$(src -c "select confirmed_flush_lsn < '$(slot_lsn "${dir}")' from pg_replication_slots where slot_name = 'rspare'")"
    expect_slot "select pg_copy_logical_replication_slot('rspare', '${S}_w1')" \
                ", below $(slot_lsn "${dir}")" below-lsn
    src -c "select pg_drop_replication_slot('rspare')" > /dev/null

    wait_slots_inactive
    src -c "select pg_drop_replication_slot('${S}_w1')" \
        -c "select pg_copy_logical_replication_slot('${S}', '${S}_w1')" > /dev/null
    expect 0 'was previously reached' restored \
           pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"

    # max_slot_wal_keep_size invalidates the slots once their WAL is removed
    wait_slots_inactive
    src -c "alter system set max_slot_wal_keep_size = '1MB'" -c 'select pg_reload_conf()' > /dev/null
    for _ in $(seq 30); do
        [ "$(src -c "select wal_status from pg_replication_slots where slot_name = '${S}_w1'")" = lost ] && break
        src -c 'create table if not exists rs.wal(v text)' \
            -c "insert into rs.wal select repeat('x', 1000) from generate_series(1, 2000)" \
            -c 'select pg_switch_wal()' -c 'checkpoint' > /dev/null
    done
    check 'worker 1 slot invalidated' lost \
          "$(src -c "select wal_status from pg_replication_slots where slot_name = '${S}_w1'")"
    expect "${SOURCE}" 'is invalidated' invalidated \
           pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"
    src -c 'alter system reset max_slot_wal_keep_size' -c 'select pg_reload_conf()' > /dev/null

    expect 0 "Dropping replication slot \"${S}_w2\"" cleanup pgcopydb stream cleanup --dir "${dir}"
    check 'objects left' '|0|' "$(slots)|$(pubs)|$(origins)"
    echo "PASS [${tc}]"
}

#
# setup: kills and failures while the slots are created, on a copied target
#
st_round() {
    src -1 -c "update st.t$(($1 % 11 + 1)) set n = n + 1 where id = $1 % 10" \
           -c "insert into st.t1 values ($1 + 1000, 0)" \
           -c "insert into st.ev values ($1), ($1)"
}

setup_kills() {
    begin_case setup
    local dir=/tmp/setup/run before log lsn t tables=''
    local ww=(--wal-workers 3 --wal-high-traffic-tables st.t1)

    for t in $(seq 1 11); do
        src -c "create schema if not exists st" \
            -c "create table st.t${t}(id integer primary key, n bigint not null)" \
            -c "insert into st.t${t} select i, 0 from generate_series(0, 9) i"
        tables="${tables} st.t${t}"
    done
    src -c 'create table st.ev(id bigint not null)' -c 'alter table st.ev replica identity full' \
        -c 'insert into st.ev values (0)'
    tables="${tables# } st.ev"

    # the target has the data; nothing is written until the slots exist
    pgcopydb clone --dir "${dir}" > /tmp/setup/clone.log 2>&1 || { cat /tmp/setup/clone.log; fail 'clone'; }
    # the snapshot of the finished clone is gone, follow would try to use it
    rm "${dir}/snapshot"

    # (d) a kill between two slot copies leaves an assignment and no slot row
    gdb_run pgsql_copy_logical_replication_slot 1 copy-kill \
            pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"
    check 'slots after a kill between two copies' "${S},${S}_w1" "$(slots)"
    check 'slot rows in the catalog' 0 "$(lite "${dir}/schema/source.db" 'select count(*) from replication_slot')"
    before=$(assignment "${dir}")
    [[ "${before}" == "3|st.t1 "* ]] || fail "stored assignment: ${before}"

    # the state is checked before the message, to catch a rerun that fails later
    expect "${SOURCE}" '' rerun \
           pgcopydb follow --resume --not-consistent --dir "${dir}" --wal-workers 2
    check 'assignment kept by the refused rerun' "${before}" "$(assignment "${dir}")"
    check 'slots kept by the refused rerun' "${S},${S}_w1" "$(slots)"
    grep -qF 'an earlier attempt set up --wal-workers 3' /tmp/setup/rerun.log || fail 'the rerun was not refused'

    # a catalog that cannot be opened stops cleanup before it drops anything
    chmod 000 "${dir}/schema/source.db"
    expect "${INTERNAL}" 'nothing was cleaned up' cleanup-unreadable pgcopydb stream cleanup --dir "${dir}"
    chmod 600 "${dir}/schema/source.db"
    check 'objects kept by the refused cleanup' "${S},${S}_w1|12" "$(slots)|$(pubs)"

    # so does a catalog whose slot row cannot be read: the option check
    # refuses it, and with --restart, which skips that check, so does
    # stream_cleanup_databases, instead of the sweep of ${S}_w<k> by pattern
    cp -a "${dir}" /tmp/setup/broken
    timeout 10s sqlite3 -init /dev/null -batch /tmp/setup/broken/schema/source.db \
        'alter table replication_slot drop column publication_auto_managed' \
        'delete from wal_worker_table' 'delete from wal_worker_setup'
    expect "${BAD_ARGS}" 'no such column: publication_auto_managed' cleanup-broken \
           pgcopydb stream cleanup --dir /tmp/setup/broken
    expect "${INTERNAL}" 'nothing was cleaned up' cleanup-broken-restart \
           pgcopydb stream cleanup --restart --dir /tmp/setup/broken
    check 'objects kept by the cleanup of a broken catalog' "${S},${S}_w1|12" "$(slots)|$(pubs)"
    rm -rf /tmp/setup/broken
    expect 0 "Dropping replication slot \"${S}_w2\"" cleanup-copy-kill pgcopydb stream cleanup --dir "${dir}"
    check 'objects left after the cleanup' '|0|' "$(slots)|$(pubs)|$(origins)"

    # (e) a kill before the origins: the resume creates them and replays all
    pgcopydb clone --dir "${dir}" --restart --drop-if-exists > /tmp/setup/reclone.log 2>&1 ||
        { cat /tmp/setup/reclone.log; fail 'clone --restart'; }
    rm "${dir}/snapshot"
    gdb_run stream_create_origin 0 origin-kill \
            pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}"
    lsn=$(slot_lsn "${dir}")
    check 'slots at the recorded LSN' "${S}:t,${S}_w1:t,${S}_w2:t" \
          "$(src -c "select string_agg(slot_name || ':' || (confirmed_flush_lsn = '${lsn}')::text::char, ',' order by slot_name collate \"C\") from pg_replication_slots where slot_name ~ '^${S}(_w[0-9]+)?\$'")"
    check 'origins before the resume' '' "$(origins)"

    for t in $(seq 1 30); do st_round "${t}"; done
    log=/tmp/setup/resume.log
    pgcopydb follow --resume --not-consistent --dir "${dir}" "${ww[@]}" > "${log}" 2>&1 &
    pid=$!
    running "${log}" 3
    pgcopydb stream sentinel set apply --dir "${dir}" > /dev/null
    for t in $(seq 31 60); do st_round "${t}"; done
    pgcopydb stream sentinel set endpos --current --dir "${dir}" > /dev/null
    finished "${log}"
    lsn=$(pgcopydb stream sentinel get --endpos --dir "${dir}")

    check 'per-table counts and contents' "$(counts src "${tables}")" "$(counts tgt "${tables}")"
    check 'keyless rows applied once' 121 "$(tgt -c 'select count(*) from st.ev')"
    check 'origins at endpos' "${S}:t,${S}_w1:t,${S}_w2:t" \
          "$(tgt -c "select string_agg(roname || ':' || (pg_replication_origin_progress(roname, true) = '${lsn}')::text::char, ',' order by roname collate \"C\") from pg_replication_origin")"
    expect 0 "Dropping replication slot \"${S}_w2\"" cleanup-origin-kill pgcopydb stream cleanup --dir "${dir}"

    # a copy at another LSN than its source slot stops the setup
    local rc=0
    log=/tmp/setup/copy-lsn.log
    timeout 120s gdb -q -batch -x /usr/src/pgcopydb/copy-lsn.gdb \
        --args pgcopydb follow --dir /tmp/setup/lsn "${ww[@]}" > "${log}" 2>&1 || rc=$?
    grep -q '^SHIFTED-COPY-LSN$' "${log}" || { cat "${log}"; fail 'the slot copy was not reached'; }
    lsn=$(sed -n "s/.*Copied replication slot \"${S}\" to \"${S}_w1\" at \(.*\)\$/\1/p" "${log}")
    if [ "${rc}" -ne "${SOURCE}" ] ||
       ! grep -qF "Replication slot \"${S}_w1\" was copied at " "${log}" ||
       ! grep -qF "expected ${lsn} as in replication slot \"${S}\"" "${log}"; then
        cat "${log}"
        fail "a copy at another LSN left exit ${rc}"
    fi
    settled 'a copy at another LSN'
    wait_slots_inactive
    check 'slots after a copy at another LSN' "${S},${S}_w1" "$(slots)"
    expect 0 "Dropping replication slot \"${S}_w1\"" cleanup-copy-lsn pgcopydb stream cleanup --dir /tmp/setup/lsn
    check 'objects left after a copy at another LSN' '|0|' "$(slots)|$(pubs)|$(origins)"

    # max_replication_slots stops the setup at the copy for worker 10, and a
    # rerun keeps the assignment, so cleanup drops every slot the setup made
    expect "${SOURCE}" 'Failed to create the replication slot of WAL worker 10' max-slots \
           pgcopydb follow --dir /tmp/setup/max --wal-workers 12
    wait_slots_inactive
    check 'slots of the failed setup' 10 "$(src -c "select count(*) from pg_replication_slots where slot_name ~ '^${S}(_w[0-9]+)?\$'")"
    expect "${SOURCE}" '' max-rerun \
           pgcopydb follow --resume --not-consistent --dir /tmp/setup/max --wal-workers 3
    expect 0 "Dropping replication slot \"${S}_w11\"" cleanup-max \
           pgcopydb stream cleanup --dir /tmp/setup/max
    check 'objects left after the failed setup' '|0|' "$(slots)|$(pubs)|$(origins)"
    grep -qF 'an earlier attempt set up --wal-workers 12' /tmp/setup/max-rerun.log || fail 'the rerun was not refused'
    echo "PASS [${tc}]"
}

#
# mode: the follow mode options, and the refusal of a directory whose tag
# says performance; the predicate is still false, so the tag is written here
#

# what a refused run must leave as it was: the files, the slot and the origin
mode_state() {
    (cd "$1" && find . -type f ! -name '*.pid' ! -name '*-shm' ! -name '*-wal' | sort |
        while read -r f; do
            case ${f} in
                *.db) echo "${f} $(lite "${f}" .dump | sha256sum | cut -c1-16)" ;;
                *) echo "${f} $(sha256sum < "${f}" | cut -c1-16)" ;;
            esac
        done)
    src -c "select slot_name, confirmed_flush_lsn from pg_replication_slots where slot_name = 'mode_slot'"
    tgt -c "select roname, pg_replication_origin_progress(roname, false) from pg_replication_origin where roname = 'mode_origin'"
}

# mode_expect is expect with a kill after the deadline: a broken refusal can
# turn into a run that a single SIGTERM does not stop
mode_expect() {
    local want=$1 msg=$2 log=/tmp/${tc}/$3.log rc=0
    shift 3
    timeout -k 5 60 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne "${want}" ] || ! grep -qF -- "${msg}" "${log}"; then
        cat "${log}"
        fail "want exit ${want} and \"${msg}\", got exit ${rc}: $*"
    fi
    echo "OK exit ${rc}: $*"
}

modes() {
    begin_case mode
    local dir=/tmp/mode/pgcopydb snap_pid before lsn name
    local tagged='Refusing the work directory: it was started with --follow-mode performance, and this run uses --follow-mode sqlite'
    local plugin='Option --follow-mode performance requires --plugin pgoutput, found --plugin test_decoding'
    local parse='Failed to parse --follow-mode "bogus", expected sqlite or performance'
    local fresh=(--dir /tmp/mode/fresh --plugin pgoutput)
    local args

    # options are checked before any connection, on a directory nobody starts
    mode_expect "${BAD_ARGS}" "${parse}" opt-bogus pgcopydb follow --follow-mode bogus "${fresh[@]}"
    mode_expect "${BAD_ARGS}" "${parse}" env-bogus env PGCOPYDB_FOLLOW_MODE=bogus pgcopydb follow "${fresh[@]}"
    mode_expect "${BAD_ARGS}" "${parse}" stream-opt-bogus pgcopydb stream receive --follow-mode bogus "${fresh[@]}"
    mode_expect "${BAD_ARGS}" "${parse}" snapshot-opt-bogus pgcopydb snapshot --follow --follow-mode bogus "${fresh[@]}"
    mode_expect "${BAD_ARGS}" 'Option --follow-mode performance is not compatible with --wal-high-traffic-tables' high-traffic \
           pgcopydb follow --follow-mode performance --wal-high-traffic-tables public.t "${fresh[@]}"
    # sqlite mode reaches the list check that performance mode refuses before
    mode_expect "${BAD_ARGS}" 'Option --wal-high-traffic-tables requires --wal-workers above 1' high-traffic-sqlite \
           env PGCOPYDB_FOLLOW_MODE=sqlite pgcopydb follow --wal-high-traffic-tables public.t "${fresh[@]}"
    mode_expect "${BAD_ARGS}" 'Option --follow-mode performance requires --wal-workers 1, found --wal-workers 2' two-workers \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb clone --follow --wal-workers 2 "${fresh[@]}"
    mode_expect "${BAD_ARGS}" 'Option --follow-mode performance is not compatible with stream apply -' apply-pipe \
           pgcopydb stream apply --follow-mode performance --dir /tmp/mode/fresh -
    test ! -e /tmp/mode/fresh || fail 'a refused option created /tmp/mode/fresh'

    # a test_decoding directory with a slot and an origin, tagged by hand
    pgcopydb snapshot --follow --plugin test_decoding --dir "${dir}" --slot-name mode_slot \
        > /tmp/mode/snapshot.out 2> /tmp/mode/snapshot.log &
    snap_pid=$!
    for _ in $(seq 120); do
        test -s /tmp/mode/snapshot.out && break
        kill -0 "${snap_pid}" 2> /dev/null || break
        sleep 0.5
    done
    test -s /tmp/mode/snapshot.out || { cat /tmp/mode/snapshot.log; fail 'snapshot --follow printed no snapshot'; }
    pgcopydb stream setup --dir "${dir}" --slot-name mode_slot --origin mode_origin > /tmp/mode/setup.log 2>&1 ||
        { cat /tmp/mode/setup.log; fail 'stream setup'; }
    kill -TERM "${snap_pid}"
    wait "${snap_pid}" || true
    wait_slots_inactive
    check 'setup rows of a sqlite directory' 0 "$(lite "${dir}/schema/source.db" 'select count(*) from wal_worker_setup')"
    timeout 10s sqlite3 -init /dev/null -batch "${dir}/schema/source.db" \
        "insert into wal_worker_setup(id, workers, high_traffic) values (1, 1, 'performance')"
    lsn=$(src -c 'select pg_current_wal_lsn()')

    # every command that receives or applies refuses it in sqlite mode, before
    # it writes; stream replay ignores --dir and reads the default under TMPDIR
    before=$(mode_state "${dir}")
    while IFS='|' read -r name args; do
        # shellcheck disable=SC2086
        mode_expect 3 "${tagged}" "refused-${name// /-}" env TMPDIR=/tmp/mode pgcopydb ${args} --dir "${dir}"
        settled "a refused ${name}"
        check "nothing changed by a refused ${name}" "${before}" "$(mode_state "${dir}")"
    done <<LIST
snapshot --follow|snapshot --follow --slot-name mode_slot
stream receive|stream receive --resume --slot-name mode_slot --endpos ${lsn}
stream prefetch|stream prefetch --resume --slot-name mode_slot --endpos ${lsn}
stream catchup|stream catchup --resume --slot-name mode_slot --origin mode_origin --endpos ${lsn}
stream replay|stream replay --resume --slot-name mode_slot --origin mode_origin --endpos ${lsn}
stream apply|stream apply --resume --origin mode_origin
follow|follow --resume --not-consistent --slot-name mode_slot --origin mode_origin --endpos ${lsn}
clone --follow|clone --follow --resume --not-consistent --slot-name mode_slot --origin mode_origin --endpos ${lsn}
LIST

    # the variable sets the mode, and the option wins over it, in each parser
    mode_expect "${BAD_ARGS}" "${plugin}" env-follow env PGCOPYDB_FOLLOW_MODE=performance pgcopydb follow --resume --dir "${dir}"
    mode_expect 3 "${tagged}" env-sqlite-follow env PGCOPYDB_FOLLOW_MODE=sqlite pgcopydb follow --resume --not-consistent --dir "${dir}"
    mode_expect 3 "${tagged}" opt-wins-follow \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb follow --follow-mode sqlite --resume --not-consistent --dir "${dir}"
    mode_expect "${BAD_ARGS}" "${plugin}" opt-clone pgcopydb clone --follow --follow-mode performance --resume --dir "${dir}"
    mode_expect 3 "${tagged}" opt-wins-receive \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb stream receive --follow-mode sqlite --resume --dir "${dir}"
    mode_expect 3 "${tagged}" opt-wins-snapshot \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb snapshot --follow --follow-mode sqlite --dir "${dir}"
    # each command checks the plugin of performance mode
    mode_expect "${BAD_ARGS}" "${plugin}" plugin-snapshot pgcopydb snapshot --follow --follow-mode performance --dir "${dir}"
    for name in receive prefetch catchup replay apply; do
        mode_expect "${BAD_ARGS}" "${plugin}" "plugin-${name}" pgcopydb stream "${name}" --follow-mode performance --resume --dir "${dir}"
    done
    settled 'the refused runs'
    check 'nothing changed by the refused runs' "${before}" "$(mode_state "${dir}")"

    # stream apply --target - has no mode check: it goes on to open the spool
    mode_expect 0 'Creating replay CDC file' stdout-apply pgcopydb stream apply --target - --dir "${dir}"

    # stream cleanup is the remedy, so no mode stops it
    mode_expect 0 'Dropping replication origin "mode_origin"' cleanup \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb stream cleanup --follow-mode performance \
           --slot-name mode_slot --origin mode_origin --dir "${dir}"
    check 'objects left after the cleanup' '0|0' \
          "$(src -c "select count(*) from pg_replication_slots where slot_name = 'mode_slot'")|$(tgt -c "select count(*) from pg_replication_origin where roname = 'mode_origin'")"
    echo "PASS [${tc}]"
}

for c in ${CASE:-all}; do
    case "${c}" in
        all) kills; setup_kills ;;
        mode) modes ;;
        kills) kills ;;
        setup) setup_kills ;;
        *) fail "unknown case ${c}" ;;
    esac
done

# a full pass also runs the mode case
test "${CASE:-all}" != all || modes
