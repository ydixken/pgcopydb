#! /bin/bash

set -euo pipefail

scenario=${1:-${FEEDBACK_CASE:-all}}
case "${scenario}" in
    all)
        for scenario in idle backlog restart empty in-flight bootstrap; do
            bash "$0" "${scenario}"
        done
        exit 0
        ;;
    idle|backlog|restart|empty|in-flight|bootstrap) ;;
    *) echo "Unknown feedback case: ${scenario}" >&2; exit 1 ;;
esac

export TMPDIR=/tmp/pgcopydb-feedback-${scenario}
export XDG_DATA_HOME=${TMPDIR}/cdc
mkdir -p "${TMPDIR}"
sharedir=${XDG_DATA_HOME}/pgcopydb
worker_pid=
snapshot_pid=
lock_pid=
debugger_pid=
pause_deadline=0

source_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 15s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
sentinel() { timeout 15s pgcopydb stream sentinel get "--$1"; }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', true)"; }
sqlite() { timeout 5s sqlite3 -readonly -init /dev/null -batch -noheader -list "$1" "$2"; }

wire_from="from pg_stat_replication r join pg_replication_slots s on s.active_pid = r.pid where s.slot_name = 'pgcopydb'"
digest_sql="select count(*), coalesce(md5(string_agg(row(id, payload)::text, ',' order by id)), 'empty') from feedback_guard"

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        source_sql "select r.pid, r.write_lsn, r.flush_lsn, r.replay_lsn, r.reply_time, s.confirmed_flush_lsn ${wire_from}" || true
        origin || true
        timeout 15s pgcopydb stream sentinel get || true
        target_sql "${digest_sql}" || true
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || cat "${log}"
        done
    fi
    if test -n "${worker_pid}"; then
        kill -CONT -- "-${worker_pid}" 2>/dev/null || true
        kill -KILL -- "-${worker_pid}" 2>/dev/null || true
    fi
    for pid in "${snapshot_pid}" "${lock_pid}" "${debugger_pid}"; do
        test -z "${pid}" || kill -TERM "${pid}" 2>/dev/null || true
    done
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }

poll() {
    local description=$1 deadline=$((SECONDS + 90)) pid
    shift
    while true; do
        for pid in "${worker_pid}" "${snapshot_pid}" "${debugger_pid}"; do
            if test -n "${pid}"; then
                kill -0 "${pid}" 2>/dev/null || fail "process ${pid} exited while waiting for ${description}"
            fi
        done
        if "$@"; then
            return
        fi
        test "${SECONDS}" -lt "${deadline}" || fail "predicate not met: ${description}"
        sleep 0.1
    done
}

wire() {
    test "$(source_sql "select count(*) = 1 and coalesce(bool_and($1), false) ${wire_from}")" = t
}

durable() {
    test "$(sentinel replay-lsn)" = "$1" && test "$(origin)" = "$1"
}

contents_match() { test "$(target_sql "${digest_sql}")" = "${expected}"; }

stream_group() {
    local pgid
    pgid=$(ps -o pgid= -p "${worker_pid}")
    equal "${pgid// /}" "${worker_pid}" 'pgcopydb owns its process group'
}

start_follow() {
    kill -0 "${snapshot_pid}" || fail 'snapshot exporter exited before follow'
    pgcopydb stream sentinel set apply
    pgcopydb follow --resume "$@" >"${TMPDIR}/follow.log" 2>&1 &
    worker_pid=$!
    poll 'one active replication connection' wire 'true'
    stream_group
}

start_prefetch() {
    pgcopydb stream prefetch --resume "$@" >"${TMPDIR}/prefetch.log" 2>&1 &
    worker_pid=$!
    poll 'one active replication connection' wire 'true'
    stream_group
}

gone() { ! kill -0 "$1" 2>/dev/null; }

wait_exit() {
    local pid=$1 deadline=$((SECONDS + 60))
    until gone "${pid}"; do
        test "${SECONDS}" -lt "${deadline}" || fail "process ${pid} did not exit"
        sleep 0.1
    done
    wait "${pid}" || fail "process ${pid} returned nonzero"
}

stop_stream() {
    local pid=${worker_pid}
    test -n "${pid}" || fail 'no streaming process to stop'
    kill -0 "${pid}" || fail 'streaming process already exited'
    stream_group
    kill -TERM -- "-${pid}"
    wait_exit "${pid}"
    worker_pid=
}

filtered_wal() {
    local before
    before=$(source_sql 'select pg_current_wal_flush_lsn()')
    # pgoutput does not request logical messages; this WAL has no published DML.
    source_sql "select pg_logical_emit_message(false, 'feedback-test', repeat('x', 1048576)) from generate_series(1, 32)" >/dev/null
    source_sql 'select pg_switch_wal()' >/dev/null
    head_lsn=$(source_sql 'select pg_current_wal_flush_lsn()')
    equal "$(source_sql "select '${head_lsn}'::pg_lsn - '${before}'::pg_lsn >= 16777216")" t 'filtered WAL gap exceeds 16 MiB'
    echo "Filtered WAL: before=${before} head=${head_lsn} durable=${durable_lsn}"
}

idle_feedback() {
    poll "write_lsn >= filtered head ${head_lsn}" wire "r.write_lsn >= '${head_lsn}'::pg_lsn"
    poll "flush_lsn AND replay_lsn >= filtered head ${head_lsn} (durable=${durable_lsn})" \
        wire "r.flush_lsn >= '${head_lsn}'::pg_lsn and r.replay_lsn >= '${head_lsn}'::pg_lsn"
    equal "$(origin)" "${durable_lsn}" 'keepalive must not advance target origin'
    equal "$(sentinel replay-lsn)" "${durable_lsn}" 'keepalive must not advance sentinel replay'
    equal "$(target_sql "${digest_sql}")" "${expected}" 'target contents'
    source_sql "select r.write_lsn, r.flush_lsn, r.replay_lsn, s.confirmed_flush_lsn ${wire_from}"
}

lock_target() {
    mkfifo "${TMPDIR}/lock-input"
    exec 3<>"${TMPDIR}/lock-input"
    psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" \
        <"${TMPDIR}/lock-input" >"${TMPDIR}/lock.log" 2>&1 &
    lock_pid=$!
    printf 'begin; lock table feedback_guard in share mode;\n\\echo LOCKED\n' >&3
    poll 'target SHARE lock acquired' grep -qx LOCKED "${TMPDIR}/lock.log"
    kill -0 "${lock_pid}" || fail 'target lock holder exited'
}

unlock_target() {
    kill -0 "${lock_pid}" || fail 'target lock holder exited before release'
    printf 'commit;\n\\q\n' >&3
    wait_exit "${lock_pid}"
    lock_pid=
    exec 3>&-
}

apply_blocked() {
    test "$(target_sql "select exists (select 1 from pg_locks where relation = 'feedback_guard'::regclass and mode = 'RowExclusiveLock' and not granted)")" = t
}

blocked_feedback() {
    local previous= replies=0 reply deadline previous_head insert_lsn
    poll 'apply waiting for the target lock' apply_blocked
    poll "received filtered head ${head_lsn}" wire "r.write_lsn >= '${head_lsn}'::pg_lsn and r.flush_lsn is not null and r.replay_lsn is not null"
    deadline=$((SECONDS + 90))
    while test "${replies}" -lt 3; do
        kill -0 "${worker_pid}" || fail 'stream exited with unapplied data'
        kill -0 "${lock_pid}" || fail 'target lock holder exited'
        wire "r.flush_lsn < '${commit_lsn}'::pg_lsn and r.replay_lsn < '${commit_lsn}'::pg_lsn" \
            || fail "feedback acknowledged unapplied COMMIT ${commit_lsn}"
        reply=$(source_sql "select r.reply_time ${wire_from}")
        test -n "${reply}" || fail 'missing wire feedback timestamp'
        if test "${reply}" != "${previous}" && wire "r.write_lsn >= '${head_lsn}'::pg_lsn"; then
            replies=$((replies + 1))
            previous=${reply}
            if test "${replies}" -lt 3; then
                previous_head=${head_lsn}
                insert_lsn=$(source_sql "select pg_logical_emit_message(false, 'feedback-test', 'next keepalive')")
                # pg_switch_wal forces a durable flush past insert_lsn; the message
                # alone can leave flush_lsn unchanged if the WAL writer hasn't run yet.
                source_sql 'select pg_switch_wal()' >/dev/null
                head_lsn=$(source_sql 'select pg_current_wal_flush_lsn()')
                equal "$(source_sql "select '${head_lsn}'::pg_lsn >= '${insert_lsn}'::pg_lsn")" t 'filtered WAL head reaches inserted message'
                equal "$(source_sql "select '${head_lsn}'::pg_lsn > '${previous_head}'::pg_lsn")" t 'next filtered WAL head'
            fi
        fi
        test "${SECONDS}" -lt "${deadline}" || fail 'did not observe three feedback replies with apply blocked'
        sleep 0.1
    done
    equal "$(origin)" "${durable_lsn}" 'blocked target origin'
    equal "$(sentinel replay-lsn)" "${durable_lsn}" 'blocked sentinel replay'
    equal "$(target_sql "${digest_sql}")" "${expected}" 'blocked target contents'
    echo "Blocked apply: COMMIT=${commit_lsn}, durable=${durable_lsn}, replies=${replies}"
}

stopped() {
    local pid state
    for pid in "${stopped_pids[@]}"; do
        state=$(ps -o stat= -p "${pid}") || return 1
        test "${state:0:1}" = T || return 1
    done
}

pause_stream() {
    local pids
    stream_group
    pids=$(pgrep -g "${worker_pid}" -x pgcopydb) || fail 'no streaming processes to pause'
    readarray -t stopped_pids <<<"${pids}"
    pause_deadline=$((SECONDS + 20))
    kill -STOP -- "-${worker_pid}"
    until stopped; do
        test "${SECONDS}" -lt "${pause_deadline}" || fail 'streaming processes did not stop'
        sleep 0.1
    done
}

resume_stream() {
    test "${SECONDS}" -lt "${pause_deadline}" || fail 'spool inspection exceeded the 20-second pause budget'
    kill -CONT -- "-${worker_pid}"
    pause_deadline=0
}

# Call only with receive/apply stopped, never contend with their SQLite writers.
spool_commit() {
    local expected_inserts=$1 file row count nbegin ninsert lsn all_commits
    local commits=0 inserts=0 begin=0 commit_file= last_file=
    local files=("${sharedir}"/*-output.db)
    commit_lsn=
    test -f "${files[0]}" || fail 'no output spool files'
    for file in "${files[@]}"; do
        if test "${pause_deadline}" -ne 0; then
            test "${SECONDS}" -lt "${pause_deadline}" || fail 'spool inspection exceeded the 20-second pause budget'
        fi
        row=$(sqlite "${file}" "select
            count(*) filter (where action = 'C'),
            count(*) filter (where action = 'B'),
            count(*) filter (where action = 'I'),
            coalesce(max(case when action = 'C' then printf('%X/%X', lsn >> 32, lsn & 4294967295) end), '-'),
            (select count(*) from output where action = 'C')
            from output where xid = ${xid}")
        [[ ${row} =~ ^[0-9]+\|[0-9]+\|[0-9]+\|([-]|[0-9A-F]+/[0-9A-F]+)\|[0-9]+$ ]] \
            || fail "invalid spool result for xid=${xid}: ${row}"
        IFS='|' read -r count nbegin ninsert lsn all_commits <<<"${row}"
        commits=$((commits + count))
        inserts=$((inserts + ninsert))
        begin=$((begin + nbegin))
        if test "${count}" -gt 0; then
            commit_file=${file}
            commit_lsn=${lsn}
        fi
        last_file=${file}
    done
    equal "${commits}" 1 'spooled COMMIT count'
    equal "${begin}" 1 'spooled BEGIN count'
    equal "${inserts}" "${expected_inserts}" 'spooled INSERT count'
    [[ ${commit_lsn} =~ ^[0-9A-F]+/[0-9A-F]+$ ]] || fail 'missing transaction COMMIT LSN'
    if test "${scenario}" = restart; then
        test "${#files[@]}" -ge 2 || fail 'output spool did not rotate'
        test "${commit_file}" != "${last_file}" || fail 'COMMIT was not retained in a prior rotated file'
        equal "${all_commits}" 0 'latest spool has no COMMIT'
    fi
    echo "Durable spool: xid=${xid}, COMMIT=${commit_lsn}, file=${commit_file}, files=${#files[@]}"
}

if test "${scenario}" = bootstrap; then
    source /usr/src/pgcopydb/bootstrap.sh
    exit 0
fi

pgcopydb ping
source_sql 'drop table if exists feedback_guard; create table feedback_guard(id integer primary key, payload text)'
target_sql 'drop table if exists feedback_guard'
pgcopydb snapshot --follow --plugin pgoutput >"${TMPDIR}/snapshot.out" 2>"${TMPDIR}/snapshot.log" &
snapshot_pid=$!
poll 'exported snapshot' test -s "${TMPDIR}/snapshot.out"
pgcopydb stream setup
pgcopydb clone --drop-if-exists
equal "$(sentinel endpos)" 0/0 'no endpos configured'
durable_lsn=$(origin)
equal "$(source_sql "select '${durable_lsn}'::pg_lsn > '0/0'::pg_lsn")" t 'initialized target origin is nonzero'
expected=$(target_sql "${digest_sql}")
equal "${expected}" '0|empty' 'empty clone'

if test "${scenario}" = restart; then
    equal "$(sentinel replay-lsn)" 0/0 'prefetch starts before apply publishes origin'
    xid=$(source_sql "begin; select pg_current_xact_id(); insert into feedback_guard values (1, 'prefetched'); commit")
    test "${xid}" -gt 0
    start_prefetch --max-replaydb-size 1kB
    filtered_wal
    poll "initial-zero prefetch confirmed_flush_lsn >= ${head_lsn}" wire "s.confirmed_flush_lsn >= '${head_lsn}'::pg_lsn"
    equal "$(sentinel replay-lsn)" 0/0 'prefetch must not publish replay'
    stop_stream
    spool_commit 1
    equal "$(source_sql "select count(*) = 1 and bool_and(confirmed_flush_lsn > '${commit_lsn}'::pg_lsn) from pg_replication_slots where slot_name = 'pgcopydb'")" t 'COMMIT is below confirmed flush before restart'
    equal "$(target_sql "${digest_sql}")" "${expected}" 'prefetch leaves target empty'
    lock_target
    start_follow
    poll 'apply initializes sentinel from target origin' durable "${durable_lsn}"
    filtered_wal
    blocked_feedback
    unlock_target
    durable_lsn=${commit_lsn}
    poll 'retained transaction applied after restart' durable "${durable_lsn}"
    expected=$(source_sql "${digest_sql}")
    idle_feedback
else
    start_follow
    poll 'apply publishes initialized origin' durable "${durable_lsn}"
    if test "${scenario}" != empty; then
        xid=$(source_sql "begin; select pg_current_xact_id(); insert into feedback_guard values (1, 'applied'); commit")
        test "${xid}" -gt 0
        expected=$(source_sql "${digest_sql}")
        poll 'first published transaction visible on target' contents_match
        pause_stream
        spool_commit 1
        resume_stream
        durable_lsn=${commit_lsn}
        poll 'first published transaction durably applied' durable "${durable_lsn}"
    fi
    case "${scenario}" in
        idle|empty)
            filtered_wal
            idle_feedback
            ;;
        backlog)
            lock_target
            xid=$(source_sql "begin; select pg_current_xact_id(); insert into feedback_guard values (2, 'blocked'); commit")
            test "${xid}" -gt 0
            filtered_wal
            poll 'receiver has passed the COMMIT' wire "r.write_lsn >= '${head_lsn}'::pg_lsn"
            pause_stream
            spool_commit 1
            resume_stream
            blocked_feedback
            unlock_target
            durable_lsn=${commit_lsn}
            poll 'backlog durably applied' durable "${durable_lsn}"
            expected=$(source_sql "${digest_sql}")
            idle_feedback
            ;;
        in-flight)
            stop_stream
            start_prefetch
            receive_pid=$(source_sql "select substring(r.application_name from '\[([0-9]+)\]') ${wire_from}")
            [[ ${receive_pid} =~ ^[0-9]+$ ]] || fail 'could not identify receiver PID'
            kill -0 "${receive_pid}" || fail 'receiver PID is not running'
            barrier_dir=$(mktemp -d "${TMPDIR}/barrier.XXXXXX")
            sudo timeout 90s gdb -q -batch -ex "set \$barrier_dir = \"${barrier_dir}\"" \
                -x /usr/src/pgcopydb/in-flight.gdb \
                -p "${receive_pid}" >"${TMPDIR}/gdb.log" 2>&1 &
            debugger_pid=$!
            poll 'receiver breakpoint armed' test -f "${barrier_dir}/armed"
            xid=$(source_sql "begin; select pg_current_xact_id(); insert into feedback_guard select i, md5(i::text) from generate_series(2, 10001) i; commit")
            test "${xid}" -gt 0
            receive_bound=$(source_sql 'select pg_current_wal_flush_lsn()')
            poll 'feedback sent inside an open receive transaction' test -s "${barrier_dir}/paused"
            kill -0 "${debugger_pid}" || fail 'debugger exited before the barrier'
            read -r in_flight_lsn old_flush old_replay <"${barrier_dir}/paused"
            poll 'in-flight feedback reaches the source' wire "r.write_lsn = '${in_flight_lsn}'::pg_lsn"
            wire "r.flush_lsn <= greatest('${durable_lsn}'::pg_lsn, '${old_flush}'::pg_lsn) and r.replay_lsn <= greatest('${durable_lsn}'::pg_lsn, '${old_replay}'::pg_lsn)" \
                || fail 'in-flight feedback advanced beyond durable progress or prior feedback'
            equal "$(origin)" "${durable_lsn}" 'in-flight target origin'
            equal "$(target_sql "${digest_sql}")" "${expected}" 'in-flight target contents'
            touch "${barrier_dir}/release"
            wait "${debugger_pid}" || fail 'in-flight debugger assertions failed'
            debugger_pid=
            cat "${TMPDIR}/gdb.log"
            poll 'receiver reaches the post-transaction WAL bound' wire "r.write_lsn >= '${receive_bound}'::pg_lsn"
            stop_stream
            spool_commit 10000
            start_follow
            durable_lsn=${commit_lsn}
            poll 'large transaction durably applied' durable "${durable_lsn}"
            expected=$(source_sql "${digest_sql}")
            equal "${expected%%|*}" 10001 'large transaction row count'
            filtered_wal
            idle_feedback
            ;;
    esac
fi

stop_stream
equal "$(sentinel replay-lsn)" "${durable_lsn}" 'final sentinel replay'
equal "$(origin)" "${durable_lsn}" 'final durable origin'
equal "$(target_sql "${digest_sql}")" "${expected}" 'final exact target contents'
kill -TERM "${snapshot_pid}"
wait_exit "${snapshot_pid}"
snapshot_pid=
pgcopydb stream cleanup
trap - EXIT
echo "PASS [${scenario}]: wire feedback and durable target progress remain distinct"
