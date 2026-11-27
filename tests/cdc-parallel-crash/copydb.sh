#! /bin/bash

set -euo pipefail

# A kill at a durability point of the raw spool of performance mode leaves a
# spool that the next run reads whole. Receive, segment cleanup and the one
# apply worker are each killed where the sync order decides what survives, a
# power loss cuts every file back to its last sync, and every start rule of
# the one worker is checked. cr.evt has no key, so a transaction applied
# twice shows as a row count difference.

tc=${1:-${CASE:-all}}

case "${tc}" in
    all)
        for one in cleanup receive worker start power; do
            bash "$0" "${one}"
        done
        exit 0
        ;;
    cleanup | receive | worker | start | power) ;;
    *)
        echo "Unknown crash case: ${tc}" >&2
        exit 1
        ;;
esac

export TMPDIR=/tmp/crash-${tc}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"

S=pgcopydb
db=c_${tc}
spool=${XDG_DATA_HOME}/${S}
src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
SOURCE=6
TARGET=7
FAR=FFFFFFFF/FFFFFFFF
pid=
snapshot_pid=
writer_pid=
gdb_pid=
tables='cr.acct cr.evt cr.hot'

on_exit() {
    local status=$?
    trap - EXIT
    touch "${TMPDIR}/stop"
    test -z "${writer_pid}" || wait "${writer_pid}" 2> /dev/null || true
    for p in "${gdb_pid}" "${snapshot_pid}"; do
        test -z "${p}" || kill -TERM "${p}" 2> /dev/null || true
    done
    pkill -KILL -x pgcopydb 2> /dev/null || true
    exit "${status}"
}
trap on_exit EXIT

fail() {
    local log
    for log in "${TMPDIR}"/*.log; do
        test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
    done
    echo "FAIL [${tc}]: $*" >&2
    exit 1
}

src() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" "$@"; }
tgt() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" "$@"; }
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}" || fail "${1}"; }

# expect code "message" log command...: exits with code and logs the message
expect() {
    local want=$1 msg=$2 log=${TMPDIR}/$3.log rc=0
    shift 3
    timeout 180 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne "${want}" ] || ! grep -qF -- "${msg}" "${log}"; then
        cat "${log}"
        fail "want exit ${want} and \"${msg}\", got exit ${rc}: $*"
    fi
    echo "OK exit ${rc}: $*"
}

# pgrep exits 1 when nothing matches, and 2 or more when it failed to look
settled() {
    local rc=0
    for _ in $(seq 60); do
        pgrep -x pgcopydb > /dev/null || break
        sleep 0.5
    done
    pgrep -a -x pgcopydb || rc=$?
    [ "${rc}" -eq 1 ] || fail "pgcopydb processes are left after $1, pgrep exit ${rc}"
}

# the walsender of a stopped run lets go of its slot a little later
wait_slots_inactive() {
    for _ in $(seq 60); do
        [ "$(src -c 'select count(*) from pg_replication_slots where active')" -eq 0 ] && return
        sleep 0.5
    done
    fail 'replication slots still active'
}

slots() { src -c "select coalesce(string_agg(slot_name || ':' || plugin, ',' order by slot_name), '') from pg_replication_slots where slot_name = '${S}'"; }
origin() { tgt -c "select pg_replication_origin_progress('${S}', true)"; }
lsn_ge() { [ "$(src -c "select '${1}'::pg_lsn >= '${2}'::pg_lsn")" = t ]; }

# counts tables: count and md5 of every table, on source and target
counts() {
    local t out=''
    for t in $2; do
        out="${out} ${t}:$($1 -c "select count(*) || ':' || md5(coalesce(string_agg(x::text, ',' order by x::text), '')) from ${t} x")"
    done
    echo "${out# }"
}

# the spool files, and the transactions its index records name
segments() { ls "${spool}"/*.seg 2> /dev/null | wc -l | tr -d ' '; }
indexes() { ls "${spool}"/*.idx 2> /dev/null | wc -l | tr -d ' '; }
lowest_seg() { ls "${spool}"/*.seg 2> /dev/null | sort | head -1; }
spool_list() { timeout 60s pgcopydb list spool --json; }
spool_txns() { spool_list | jq -r '[.[].end_lsn] | join(",")'; }
spool_txns_without() { spool_list | jq -r --arg s "$1" '[.[] | select(.segment != $s) | .end_lsn] | join(",")'; }
spool_last() { spool_list | jq -r 'if length == 0 then "0/0" else .[-1].end_lsn end'; }
replay() { timeout 60s pgcopydb stream sentinel get --replay-lsn; }

# the raw spool must be the layout under test: an inactive routing predicate
# leaves the SQLite store, where every check below would read an empty spool
raw_spool() {
    test "$(segments)" -ge 1 ||
        fail "no spool segment in ${spool}, so performance mode did not route this run"
    test -f "${spool}/relation.log" || fail "no relation log in ${spool}"
    echo "OK the run wrote $(segments) segment(s), $(indexes) index file(s) and a relation log"
}

round() {
    src -1 -c "insert into cr.hot(n) values ($1)" \
        -c "update cr.acct set balance = balance + 1 where id = $1 % 50" \
        -c "insert into cr.evt values ($1, 'ins'), ($1, 'ins')" \
        -c "delete from cr.evt where id = $1 - 7" > /dev/null
}

rounds() {
    local i
    for i in $(seq "$1" "$2"); do
        round "${i}"
    done
}

start_writer() {
    rm -f "${TMPDIR}/stop"
    (
        i=${1:-0}
        while [ ! -e "${TMPDIR}/stop" ]; do
            i=$((i + 1))
            round "${i}"
        done
        echo "${i}" > "${TMPDIR}/rounds"
    ) &
    writer_pid=$!
}

stop_writer() {
    touch "${TMPDIR}/stop"
    wait "${writer_pid}"
    writer_pid=
    echo "the writer committed $(cat "${TMPDIR}/rounds") transactions"
}

# running log: the apply of the run of pid reads the raw spool. Its receive
# may already have reached endpos, so only the apply line is waited for.
running() {
    for _ in $(seq 240); do
        grep -q 'Applying CDC changes from the raw spool' "$1" && return
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    cat "$1"
    fail "the run did not reach the raw spool apply, see $1"
}

# drained: the worker applied every indexed transaction of the spool
drained() {
    local want got=0/0
    for _ in $(seq 240); do
        want=$(spool_last)
        got=$(replay)
        lsn_ge "${got}" "${want}" && { echo "OK the worker applied the spool up to ${want}"; return; }
        test -z "${pid}" || kill -0 "${pid}" 2> /dev/null ||
            fail "the run ended before it applied the spool up to ${want}, at ${got}"
        sleep 0.5
    done
    fail "the worker did not apply the spool up to ${want}, at ${got}"
}

# ended log [done line]: the run of pid ends by itself, with its done line, or
# on a signal once it has applied everything, which is where a build without
# the cut at endpos leaves it
ended() {
    local rc=0 log=$1 marker=${2:-}
    for _ in $(seq 60); do
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    if kill -0 "${pid}" 2> /dev/null; then
        echo "NOTE the run had to be signalled: this build has no cut at endpos"
        # pgcopydb owns its process group, and the supervisor passes a signal
        # on only to the children it started itself
        kill -TERM -- "-${pid}" 2> /dev/null || kill -TERM "${pid}"
    elif [ -n "${marker}" ]; then
        grep -qF -- "${marker}" "${log}" || fail "the run ended without \"${marker}\", see ${log}"
    fi
    wait "${pid}" || rc=$?
    pid=
    echo "the run ended with exit ${rc}"
    settled 'a finished run'
    wait_slots_inactive
}

# prefetch endpos log: receive alone, from where it left off up to endpos
prefetch() {
    timeout 300 pgcopydb stream prefetch --resume --endpos "$1" \
            --max-replaydb-size 8kB > "${TMPDIR}/$2.log" 2>&1 ||
        { cat "${TMPDIR}/$2.log"; return 1; }
    echo "OK receive reached $1"
}

# receive_to endpos log: receive alone without the follow supervisor, so that
# no cleanup pass of its own can remove what the start of the spool leaves
receive_to() {
    timeout 300 pgcopydb stream receive --resume --endpos "$1" \
            --max-replaydb-size 8kB > "${TMPDIR}/$2.log" 2>&1 ||
        { cat "${TMPDIR}/$2.log"; return 1; }
    if grep -q 'Removed spool segment' "${TMPDIR}/$2.log"; then
        fail "a cleanup pass ran inside the receive of $2, which no check may rely on"
    fi
    echo "OK receive reached $1"
}

# catchup endpos log: the apply alone, until it has applied the whole spool
catchup() {
    local log=${TMPDIR}/$2.log
    pgcopydb stream catchup --resume --endpos "$1" > "${log}" 2>&1 &
    pid=$!
    drained
    ended "${log}"
}

# endpos_after n: one more source transaction, and the position after it, so
# that the next start has work to do and does not stop at a reached endpos
endpos_after() {
    round "$1"
    src -c 'select pg_current_wal_flush_lsn()'
}

# kill_cmd ignore finish breakpoint log what command...: run the command
# under gdb and kill it at the breakpoint, after the function returned when
# finish is 1
kill_cmd() {
    local ignore=$1 finish=$2 bp=$3 log=${TMPDIR}/$4.log what=$5 rc=0
    shift 5
    timeout 240s gdb -q -batch -ex "set \$finish = ${finish}" -ex "break ${bp}" \
            -ex "ignore 1 ${ignore}" -x /usr/src/pgcopydb/kill-at.gdb \
            --args "$@" > "${log}" 2>&1 || rc=$?
    [ "${rc}" -eq 0 ] || { cat "${log}"; fail "gdb exited ${rc} for ${what}"; }
    grep -q '^KILLED-AT-BREAKPOINT$' "${log}" ||
        { cat "${log}"; fail "${what}: the process did not reach ${bp}"; }
    settled "${what}"
    wait_slots_inactive
    echo "OK ${what}"
}

# kill_flush_sync ignore log what command...: the same, killed at the sync of
# the relation log of a flush, which is after the segment sync and before the
# index records of that flush are written
kill_flush_sync() {
    local ignore=$1 log=${TMPDIR}/$2.log what=$3 rc=0
    shift 3
    timeout 240s gdb -q -batch -ex 'break spool_writer_flush' \
            -ex "ignore 1 ${ignore}" -x /usr/src/pgcopydb/flush-sync.gdb \
            --args "$@" > "${log}" 2>&1 || rc=$?
    [ "${rc}" -eq 0 ] || { cat "${log}"; fail "gdb exited ${rc} for ${what}"; }
    grep -q '^KILLED-AT-BREAKPOINT$' "${log}" ||
        { cat "${log}"; fail "${what}: the flush did not reach its relation log sync"; }
    settled "${what}"
    wait_slots_inactive
    echo "OK ${what}"
}

# kill_receive ignore finish breakpoint log what: a receive of its own, under
# gdb from its first instruction, so that no attach can miss the point
kill_receive() {
    kill_cmd "$1" "$2" "$3" "$4" "$5" \
             pgcopydb stream receive --resume --endpos "${FAR}" --max-replaydb-size 8kB
}

# the three waits of the start case, as commands, because poll runs them again
gate_held() {
    [ "$(tgt -c "select count(*) from pg_locks where relation = 'cr.gate'::regclass
                 and mode = 'RowShareLock'")" -ge 1 ]
}
commit_waiting() {
    [ "$(tgt -c "select count(*) from pg_stat_activity where wait_event_type = 'Lock'")" -ge 1 ]
}
origin_held() {
    [ "$(tgt -c "select count(*) from pg_stat_activity where query like '%pg_sleep(45)%'
                 and pid <> pg_backend_pid()")" -ge 1 ]
}

# poll what command...: the command must succeed within two minutes
poll() {
    local what=$1
    shift
    for _ in $(seq 240); do
        "$@" > /dev/null 2>&1 && return
        sleep 0.5
    done
    fail "timed out waiting for ${what}"
}

# the transactions of the spool, one per line, and how many there are
txn_lines() { tr ',' '\n' <<< "$1" | grep -c . | tr -d ' '; }

# grown old: the spool still lists every transaction it listed before, in
# order, because a start cuts only the frames that no index record names
grown() {
    local now
    now=$(spool_txns)
    case "${now}" in
        "$1"*)
            echo "OK the spool kept its $(txn_lines "$1") indexed transactions and holds $(txn_lines "${now}")"
            ;;
        *)
            printf 'before: %s\nafter:  %s\n' "$1" "${now}"
            fail 'the spool lost or reordered an indexed transaction'
            ;;
    esac
}

# the origin only ever stands at the commit of an indexed transaction
origin_indexed() {
    spool_txns | tr ',' '\n' | grep -qxF "$(origin)" ||
        fail "the origin $(origin) is at no indexed commit of the spool"
    echo "OK the origin $(origin) is at an indexed commit"
}

# equal: the target holds what the source holds, once
equal_target() {
    check 'the target holds the whole workload' "$(counts src "${tables}")" "$(counts tgt "${tables}")"
    check 'no transaction was applied twice' 0 \
          "$(tgt -c 'select count(*) from (select id from cr.evt where id > 0 group by id having count(*) <> 2) x')"
    check 'the origin is at the last applied commit' "$(replay)" "$(origin)"
    check 'the slot of the run' "${S}:pgoutput" "$(slots)"
}

#
# the fixture: one keyed table, one keyless canary, one serial table, and one
# table whose first change comes mid-run, for a relation record of its own
#
setup() {
    psql -X -q -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database ${db}"
    psql -X -q -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database ${db}"
    export PGCOPYDB_SOURCE_PGURI=${src_base}/${db}
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/${db}
    echo "=== ${tc}"

    src <<'SQL' > /dev/null
create schema cr;
create table cr.hot(id bigserial primary key, n bigint not null);
create table cr.acct(id integer primary key, balance bigint not null);
create table cr.evt(id bigint not null, kind text not null);
alter table cr.evt replica identity full;
create table cr.late(id integer primary key, v text not null);
create table cr.stop(id integer primary key, v integer not null);
insert into cr.hot(n) select i from generate_series(1, 100) i;
insert into cr.acct select i, 0 from generate_series(0, 49) i;
insert into cr.evt select i, 'seed' from generate_series(-10, 0) i;
SQL

    pgcopydb snapshot --follow --plugin pgoutput > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    for _ in $(seq 120); do
        test -s "${TMPDIR}/snapshot.out" && break
        kill -0 "${snapshot_pid}" || fail 'the snapshot ended before it exported one'
        sleep 0.5
    done
    test -s "${TMPDIR}/snapshot.out" || fail 'no exported snapshot'

    pgcopydb stream setup
    pgcopydb clone
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}" || true
    snapshot_pid=
    check 'the work directory records performance mode' performance \
          "$(timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader \
                 "${TMPDIR}/${S}/schema/source.db" 'select high_traffic from wal_worker_setup')"
}

pgcopydb ping

#
# cleanup: what segment cleanup deletes, what a kill between its two unlinks
# leaves, and the stored low-water mark that both rules read
#
case_cleanup() {
    local endpos saved lowest before kept w last at

    setup
    # the apply stops at this row, so that the stored W stays inside the
    # lowest segment while receive spools far past it
    tgt -c 'alter table cr.stop add constraint cr_stop_low check (v < 500)' > /dev/null

    rounds 1 9
    src -1 -c 'insert into cr.stop values (1, 999)' > /dev/null
    rounds 10 80
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')

    # receive alone, so that the spool holds every transaction before any is applied
    prefetch "${endpos}" prefetch || fail 'the receive of the whole workload failed'
    raw_spool
    test "$(segments)" -ge 3 || fail "the workload left $(segments) segment(s), fewer than 3"
    check 'every segment is indexed' "$(segments)" "$(indexes)"

    # the apply stops at the row the target refuses, below the end of the spool
    pgcopydb stream sentinel set apply > /dev/null
    expect "${TARGET}" 'cr_stop_low' catchup-poison \
           pgcopydb stream catchup --resume --endpos "${endpos}"
    settled 'the apply that the target refused'

    w=$(replay)
    last=$(spool_last)
    lsn_ge "${last}" "${w}" || fail "the stored W ${w} is above the end of the spool ${last}"
    at=$(spool_list | jq -r --arg s "$(basename "$(lowest_seg)" .seg)" \
        '[.[] | select(.segment == $s)] | .[-1].end_lsn')
    check 'the stored W is inside the lowest segment' t \
          "$(src -c "select '${w}'::pg_lsn < '${at}'::pg_lsn")"

    # cleanup deletes nothing while the target is behind the oldest segment
    before=$(segments)
    pgcopydb stream prune > "${TMPDIR}/prune-behind.log" 2>&1 ||
        { cat "${TMPDIR}/prune-behind.log"; fail 'the cleanup pass failed'; }
    check 'cleanup keeps every segment the target has not applied' "${before}" "$(segments)"

    # the stored W reaches the start of receive: a leftover of cleanup whose
    # next segment ends above W is damage, and the start refuses it
    lowest=$(lowest_seg)
    saved=${TMPDIR}/saved.idx
    cp "${lowest%.seg}.idx" "${saved}"
    kept=$(spool_txns)
    rm "${lowest%.seg}.idx"
    expect "${SOURCE}" 'above the stored replay LSN' leftover-above-w \
           pgcopydb stream receive --resume --endpos "$(endpos_after 81)"
    test -f "${lowest}" ||
        fail "the refused start removed \"${lowest}\", whose transactions the target has not applied"
    cp "${saved}" "${lowest%.seg}.idx"
    check 'the refused start kept every transaction of the spool' "${kept}" "$(spool_txns)"

    # with the target caught up, the same shape is a leftover that goes
    tgt -c 'alter table cr.stop drop constraint cr_stop_low' > /dev/null
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')
    prefetch "${endpos}" prefetch-rest || fail 'the receive of the rest failed'
    catchup "${endpos}" catchup
    check 'the target holds the whole workload' "$(counts src "${tables}")" "$(counts tgt "${tables}")"
    check 'the row the target refused is applied' '1|999' \
          "$(tgt -c "select id || '|' || v from cr.stop")"

    # the kill between the two unlinks of a cleanup pass
    before=$(segments)
    kill_cmd 0 0 spool_sync_directory prune-kill \
             'a cleanup killed between its two unlinks' pgcopydb stream prune
    check 'the killed cleanup left its segment' "${before}" "$(segments)"
    check 'the killed cleanup unlinked one index file' $((before - 1)) "$(indexes)"
    lowest=$(lowest_seg)
    test ! -f "${lowest%.seg}.idx" ||
        fail 'the killed cleanup left an index file for its lowest segment'

    # the start removes that leftover, because W is above the segment after it
    kept=$(spool_txns_without "$(basename "${lowest}" .seg)")
    receive_to "$(endpos_after 82)" receive-leftover ||
        fail 'the start refused the leftover of a killed cleanup'
    test ! -f "${lowest}" || fail "the start kept the leftover \"${lowest}\""
    case "$(spool_txns)" in
        "${kept}"*) echo "OK the start kept the transactions of every other segment" ;;
        *) fail 'the start lost an indexed transaction of a segment it keeps' ;;
    esac
    catchup "$(spool_last)" catchup-after-leftover
    equal_target
}

#
# receive: a kill at every durability point of the flush, inside a
# transaction, inside a rotation and after a relation record, each followed by
# a resume that must keep every indexed transaction
#
case_receive() {
    local before endpos

    setup
    rounds 1 20
    prefetch "$(src -c 'select pg_current_wal_flush_lsn()')" prefetch-seed ||
        fail 'the first receive failed'
    raw_spool
    start_writer 20

    before=$(spool_txns)
    kill_receive 3 0 spool_writer_flush k1-segment \
                 'a receive killed after a segment write and before its sync'
    grown "${before}"

    before=$(spool_txns)
    kill_flush_sync 3 k2-index \
                    'a receive killed after a segment sync and before its index write' \
                    pgcopydb stream receive --resume --endpos "${FAR}" --max-replaydb-size 8kB
    grown "${before}"

    before=$(spool_txns)
    kill_receive 3 1 spool_writer_flush k3-feedback \
                 'a receive killed after an index sync and before its feedback'
    grown "${before}"

    before=$(spool_txns)
    kill_receive 5 1 spool_writer_begin k4-in-txn \
                 'a receive killed inside a transaction'
    grown "${before}"

    before=$(spool_txns)
    kill_receive 0 0 spool_segment_create k5-rotation \
                 'a receive killed inside a rotation'
    grown "${before}"

    before=$(spool_txns)
    kill_receive 0 1 spool_writer_log_relation k6-relation \
                 'a receive killed after a relation record'
    grown "${before}"

    stop_writer
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')
    pgcopydb stream sentinel set apply > /dev/null

    # one run of both processes under their supervisor, to the end of the load
    pgcopydb follow --resume --not-consistent --endpos "${endpos}" \
            > "${TMPDIR}/follow.log" 2>&1 &
    pid=$!
    running "${TMPDIR}/follow.log"
    drained
    ended "${TMPDIR}/follow.log" 'Follow mode is now done, reached endpos'
    equal_target
}

#
# worker: a kill of the one apply worker before its group COMMIT and after the
# COMMIT returned, where the stored W is still behind the origin
#
case_worker() {
    local endpos before

    setup
    rounds 1 40
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')
    prefetch "${endpos}" prefetch || fail 'the receive of the workload failed'
    raw_spool
    pgcopydb stream sentinel set apply > /dev/null

    # one source transaction per target transaction, so that a kill at a group
    # commit is a kill at one source transaction
    export PGCOPYDB_APPLY_GROUP_TXNS=1

    before=$(origin)
    kill_cmd 2 0 pgsql_replication_origin_xact_commit w1-before-commit \
             'an apply killed after a group was sent and before its COMMIT' \
             pgcopydb stream catchup --resume --endpos "${endpos}"
    origin_indexed
    check 'the group that was not committed left the target behind the source' t \
          "$(src -c "select '$(origin)'::pg_lsn < '$(spool_last)'::pg_lsn")"
    check 'the origin moved only with a COMMIT that returned' t \
          "$(src -c "select '$(origin)'::pg_lsn >= '${before}'::pg_lsn")"

    before=$(origin)
    kill_cmd 0 1 pgsql_replication_origin_xact_commit w2-after-commit \
             'an apply killed after its group COMMIT and before the sentinel write' \
             pgcopydb stream catchup --resume --endpos "${endpos}"
    origin_indexed
    check 'the COMMIT that returned moved the origin' t \
          "$(src -c "select '$(origin)'::pg_lsn > '${before}'::pg_lsn")"
    check 'the stored W is at or behind the origin' t \
          "$(src -c "select '$(replay)'::pg_lsn <= '$(origin)'::pg_lsn")"

    catchup "${endpos}" catchup
    equal_target
}

#
# power: a kill, then every spool file cut back to the length of its last
# sync and every segment whose directory entry no sync followed removed. The
# start may refuse what that leaves, and it may never drop a transaction that
# the slot reported as flushed.
#
case_power() {
    local endpos confirmed before

    setup
    rounds 1 40
    prefetch "$(src -c 'select pg_current_wal_flush_lsn()')" prefetch-seed ||
        fail 'the first receive failed'
    raw_spool
    rounds 41 100
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')

    # --debug prints the length of every sync, which the model below reads.
    # The kill comes right after a block of frames reached the file, where the
    # bytes past the last sync are the ones a power loss drops.
    kill_cmd 4 1 spool_write_block p-kill \
             'a receive killed after a block of frames reached the file' \
             pgcopydb stream receive --resume --endpos "${endpos}" \
             --max-replaydb-size 8kB --debug
    before=$(spool_txns)
    confirmed=$(src -c "select confirmed_flush_lsn from pg_replication_slots where slot_name = '${S}'")
    echo "the slot confirmed ${confirmed} as flushed, the spool holds $(txn_lines "${before}") transactions"

    cut_to_last_sync "${TMPDIR}/p-kill.log"

    if receive_to "${endpos}" receive-after-loss; then
        lost_above_confirmed "${before}" "${confirmed}"
        pgcopydb stream sentinel set apply > /dev/null
        catchup "${endpos}" catchup
        equal_target
    else
        grep -qF 'below the' "${TMPDIR}/receive-after-loss.log" ||
            fail 'the start refused the power loss without naming both positions'
        echo 'NOTE the start refused what the power loss left, which the model allows'
        lost_above_confirmed "${before}" "${confirmed}"
    fi
}

# cut_to_last_sync log: the power loss. A file goes back to the length of its
# last sync, and a segment whose header sync no directory sync followed never
# reached the disk. A file that this run never synced is left alone: it was
# durable before the run started.
cut_to_last_sync() {
    local f synced size changed=0

    for f in "${spool}"/*.seg "${spool}"/*.idx "${spool}/relation.log"; do
        test -f "${f}" || continue
        synced=$(sed -n "s|.*Synced spool file \"${f}\" at \([0-9]*\) bytes.*|\1|p" "$1" | tail -1)
        test -n "${synced}" || continue
        size=$(stat -c %s "${f}")
        test "${size}" -gt "${synced}" || continue
        echo "cut \"${f}\" from ${size} to ${synced} bytes"
        truncate -s "${synced}" "${f}"
        changed=$((changed + 1))
    done

    for f in "${spool}"/*.seg; do
        test -f "${f}" || continue
        grep -qF "Synced spool file \"${f}\"" "$1" || continue
        sed -n "\\|Synced spool file \"${f}\"|,\$p" "$1" |
            grep -q 'Synced spool directory' && continue
        echo "removed \"${f}\", whose directory entry no sync followed"
        rm -f "${f}" "${f%.seg}.idx"
        changed=$((changed + 1))
    done

    test "${changed}" -gt 0 ||
        fail 'the power loss cut no byte and removed no file, so it proves nothing'
}

# lost_above_confirmed old confirmed: every transaction the spool no longer
# lists is above the position the slot reported as flushed, so the source
# sends it again
lost_above_confirmed() {
    local now lost
    now=$(spool_txns 2> /dev/null || true)
    lost=$(comm -23 <(tr ',' '\n' <<< "$1" | sort) <(tr ',' '\n' <<< "${now}" | sort) |
        paste -sd, -)
    if [ -z "${lost}" ]; then
        echo 'OK the power loss cut no indexed transaction'
        return
    fi
    check "the $(txn_lines "${lost}") transaction(s) the power loss cut are above ${2}" t \
          "$(src -c "select bool_and(x::pg_lsn > '$2'::pg_lsn) from
                     unnest(string_to_array('${lost}', ',')) as t(x) where x <> ''")"
}

#
# start: the three start rules of one worker. A group that commits late keeps
# the origin, the wait for it is bounded, and a target that lost commits is
# refused.
#
case_start() {
    local endpos apply1 hold before

    setup
    rounds 1 30
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')
    prefetch "${endpos}" prefetch || fail 'the receive of the workload failed'
    raw_spool
    pgcopydb stream sentinel set apply > /dev/null
    export PGCOPYDB_APPLY_GROUP_TXNS=1

    # a deferred constraint trigger on the target takes a row lock at COMMIT,
    # so that a third session delays the COMMIT of a group and nothing else
    tgt <<'SQL' > /dev/null
create table cr.gate(id integer primary key);
insert into cr.gate values (1);
create function cr.gate_wait() returns trigger language plpgsql as $$
begin
    perform id from cr.gate where id = 1 for update;
    return null;
end $$;
create constraint trigger cr_gate after insert or update or delete on cr.acct
    deferrable initially deferred for each row execute function cr.gate_wait();
-- the apply session runs as a replica, where only an ALWAYS trigger fires
alter table cr.acct enable always trigger cr_gate;
SQL

    # the third session holds the gate, and lets go after 20 s
    timeout 120s psql -X -q -At -d "${PGCOPYDB_TARGET_PGURI}" -c 'begin' \
            -c 'select id from cr.gate where id = 1 for update' \
            -c 'select pg_sleep(20)' -c 'commit' > /dev/null 2>&1 &
    hold=$!
    poll 'the third session to hold the gate' gate_held

    pgcopydb stream catchup --resume --endpos "${endpos}" > "${TMPDIR}/apply-blocked.log" 2>&1 &
    apply1=$!
    poll 'a group COMMIT to block on the gate' commit_waiting
    kill -KILL "${apply1}"
    wait "${apply1}" 2> /dev/null || true
    echo 'OK the apply was killed while its group COMMIT waited on the gate'

    # the next run starts at once: the backend of the killed one still holds
    # the origin, and its group commits only when the gate opens
    pgcopydb stream catchup --resume --endpos "${endpos}" > "${TMPDIR}/apply-late.log" 2>&1 &
    pid=$!
    poll 'the start to wait for the origin' \
         grep -qF 'Waiting for the session that still holds replication origin' \
         "${TMPDIR}/apply-late.log"
    echo 'OK the start waits for the origin that the late commit still holds'
    wait "${hold}" 2> /dev/null || true
    drained
    ended "${TMPDIR}/apply-late.log"
    origin_indexed
    equal_target

    # the bound on that wait: an origin held for longer fails the start, and
    # the target shows no statement of it
    tgt -c 'drop trigger cr_gate on cr.acct' > /dev/null
    rounds 31 40
    endpos=$(src -c 'select pg_current_wal_flush_lsn()')
    prefetch "${endpos}" prefetch-bound || fail 'the receive of the second workload failed'
    before=$(counts tgt "${tables}")
    timeout 120s psql -X -q -At -d "${PGCOPYDB_TARGET_PGURI}" \
            -c "select pg_replication_origin_session_setup('${S}')" \
            -c 'select pg_sleep(45)' > /dev/null 2>&1 &
    hold=$!
    poll 'the third session to hold the origin' origin_held
    expect "${TARGET}" 'Failed to take replication origin' acquire-bound \
           pgcopydb stream catchup --resume --endpos "${endpos}"
    check 'the start that could not take the origin applied nothing' \
          "${before}" "$(counts tgt "${tables}")"
    kill -TERM "${hold}" 2> /dev/null || true
    wait "${hold}" 2> /dev/null || true

    # the target put back before its last commits: the origin is then below
    # the stored position, and the start is refused with nothing applied
    catchup "${endpos}" catchup-before-restore
    equal_target
    local back
    back=$(spool_list | jq -r '.[-6].end_lsn')
    tgt -c "delete from cr.hot where n > 34" > /dev/null
    tgt -c "select pg_replication_origin_advance('${S}', '${back}')" > /dev/null
    before=$(counts tgt "${tables}")
    expect "${TARGET}" 'below the stored replay position' lost-commits \
           pgcopydb stream catchup --resume --endpos "${endpos}"
    check 'the start that found lost commits applied nothing' \
          "${before}" "$(counts tgt "${tables}")"
}

case_"${tc//-/_}"
echo "PASS [${tc}]"
