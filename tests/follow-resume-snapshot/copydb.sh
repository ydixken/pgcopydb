#! /bin/bash

# clone --follow copies table data under the replication slot's snapshot, so
# apply never replays a change the copy already holds. A CHECK constraint
# makes the COPY of gate_a wait on an advisory lock the test holds on the
# target, which keeps pending_b uncopied while rows land behind the slot.

set -euo pipefail

scenario=${1:-all}
case "${scenario}" in
    all)
        status=0
        for scenario in guard fresh; do
            bash "$0" "${scenario}" || status=1
        done
        exit "${status}"
        ;;
    guard|fresh) ;;
    *) echo "Unknown scenario: ${scenario}" >&2; exit 1 ;;
esac

slot=resume_${scenario}
export TMPDIR=/tmp/pgcopydb-resume-snapshot/${scenario}
export XDG_DATA_HOME=${TMPDIR}/cdc
workdir=${TMPDIR}/work
catalog=${workdir}/schema/source.db
mkdir -p "${TMPDIR}"
clone_args=(--dir "${workdir}" --table-jobs 1 --drop-if-exists
    --follow --plugin pgoutput --slot-name "${slot}" --origin "${slot}")
clone_pid='' gate_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'copy_gate'"

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (errors)"
            grep -E ' (ERROR|FATAL) ' "${log}" | tail -n 20 || true
            echo "==> ${log} (tail)"
            tail -n 20 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL [${scenario}]: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
sqlite() { timeout 10s sqlite3 -readonly -init /dev/null -cmd '.timeout 5000' -batch -noheader -list "${catalog}" "$1"; }
origin() { target_sql "select pg_replication_origin_progress('${slot}', true)"; }
source_slots() { source_sql "select count(*) from pg_replication_slots where slot_name = '${slot}' $1"; }
gate_locks() { target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and $1"; }
digest() { echo "select count(*), md5(coalesce(string_agg(t::text, ',' order by id), '')) from $1 t"; }

poll() {
    local what=$1 deadline=$((SECONDS + 120)) rc=''
    shift
    until "$@"; do
        if test -n "${clone_pid}" && ! kill -0 "${clone_pid}" 2>/dev/null; then
            wait "${clone_pid}" || rc=$?
            clone_pid=
            fail "pgcopydb exited ${rc:-0} while waiting for ${what}"
        fi
        test "${SECONDS}" -lt "${deadline}" || fail "timed out waiting for ${what}"
        sleep 0.2
    done
}

gate_held() { test "$(gate_locks "granted and mode = 'ExclusiveLock'")" = 1; }
gate_open() { test "$(gate_locks 'true')" = 0; }
copy_blocked() { test "$(gate_locks 'not granted')" -ge 1; }
copy_ended() { test "$(gate_locks 'not granted')" = 0; }
slot_idle() { test "$(source_slots 'and not active')" = 1; }
steps_done() { grep -q 'All step are now done' "${TMPDIR}/$1.log"; }

# pg_sleep never reads the socket, so only pg_terminate_backend frees the lock
hold_gate() {
    PGAPPNAME=copy_gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
        -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
    gate_pid=$!
    poll 'the copy gate to close' gate_held
}

release_gate() {
    target_sql "${free_gate}" >/dev/null
    wait "${gate_pid}" || true
    gate_pid=
    poll 'the copy gate to open' gate_open
}

start_clone() {
    local name=$1
    shift
    setsid pgcopydb clone "${clone_args[@]}" "$@" >"${TMPDIR}/${name}.log" 2>&1 &
    clone_pid=$!
    equal "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" "${clone_pid}" 'pgcopydb owns its process group'
}

# no new WAL means no message to stop receive at endpos, so emit one that
# pgoutput does not publish while waiting
wait_exit() {
    local name=$1 deadline=$((SECONDS + 120)) rc=0
    while kill -0 "${clone_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "the ${name} clone did not stop at its endpos"
        source_sql "select pg_logical_emit_message(false, 'follow-resume-snapshot', 'past endpos')" >/dev/null
        sleep 0.5
    done
    wait "${clone_pid}" || rc=$?
    clone_pid=
    equal "${rc}" 0 "the ${name} clone exit status"
}

seed() {
    source_sql "drop table if exists gate_a, pending_b;
        drop function if exists copy_gate();
        create function copy_gate() returns boolean language plpgsql
            as \$\$ begin perform pg_advisory_xact_lock_shared(42); return true; end \$\$;
        create table gate_a(id integer primary key, payload text not null check (copy_gate()));
        insert into gate_a select g, repeat(md5(g::text), 4) from generate_series(1, 5000) g;
        create table pending_b(id integer primary key, payload text not null);
        insert into pending_b select g, 'before the slot' from generate_series(1, 10) g;
        analyze gate_a, pending_b"
}

# gate_a is the larger table, so the single COPY worker takes it first and
# pending_b is still waiting when rows land behind the slot
follow_through() {
    local name=$1 first=$2
    shift 2
    hold_gate
    start_clone "${name}" "$@"
    poll "the ${name} COPY of gate_a to wait on the gate" copy_blocked
    equal "$(source_slots '')" 1 "the ${name} run created its slot"
    source_sql "insert into pending_b select g, 'after the slot' from generate_series(${first}, ${first} + 9) g"
    release_gate
    poll "the ${name} clone steps" steps_done "${name}"
    pgcopydb stream sentinel set endpos --current --dir "${workdir}" >>"${TMPDIR}/endpos.log" 2>&1
    wait_exit "${name}"
    for table in gate_a pending_b; do
        equal "$(target_sql "$(digest "${table}")")" "$(source_sql "$(digest "${table}")")" "${name}: ${table} on the target matches the source"
    done
}

cleanup_replication() {
    timeout 60s pgcopydb stream cleanup --dir "${workdir}" --slot-name "${slot}" --origin "${slot}" >>"${TMPDIR}/cleanup.log" 2>&1
    equal "$(source_slots '')" 0 'stream cleanup dropped the slot'
}

pgcopydb ping
seed

if test "${scenario}" = fresh; then
    # a retry whose first attempt died before the slot existed creates it
    follow_through fresh 3001 --resume --not-consistent
    cleanup_replication
    echo 'PASS [fresh]: a resume that creates its slot copies under the slot snapshot'
    exit 0
fi

hold_gate
start_clone attempt --restart
poll 'the first COPY of gate_a to wait on the gate' copy_blocked
kill -KILL -- "-${clone_pid}"
wait "${clone_pid}" || true
clone_pid=
poll 'the killed run to leave the slot' slot_idle
target_sql "select pg_terminate_backend(pid) from pg_locks where locktype = 'advisory' and objid = 42 and not granted" >/dev/null
poll 'the killed COPY to end on the target' copy_ended
equal "$(sqlite 'select slot_name from replication_slot')" "${slot}" 'the work directory kept the slot'
equal "$(sqlite 'select count(*) from summary where tableoid is not null and done_time_epoch is not null')" 0 'no table copy finished before the kill'
equal "$(target_sql 'select count(*) from pending_b')" 0 'pending_b is still empty on the target'

source_sql "insert into pending_b select g, 'after the slot' from generate_series(1001, 1010) g"
release_gate
slot_before=$(sqlite 'select * from replication_slot')
origin_before=$(origin)
status=0
timeout 90s pgcopydb clone "${clone_args[@]}" --resume --not-consistent >"${TMPDIR}/resume.log" 2>&1 || status=$?
equal "$(target_sql 'select count(*) from pending_b')" 0 'the resume copied pending_b without the slot snapshot'
equal "${status}" 3 'the resume exit status'
grep -F 'Refusing to resume the copy: ' "${TMPDIR}/resume.log" || fail 'the resume did not say why it refused'
equal "$(sqlite 'select * from replication_slot')" "${slot_before}" 'the refused resume kept the saved slot'
equal "$(source_slots '')" 1 'the refused resume kept the source slot'
equal "$(origin)" "${origin_before}" 'the refused resume kept the target origin'
echo 'PASS [guard]: a resume on a retained slot refuses to copy without its snapshot'

# the recovery the operator runs: drop the slot, publication, and origin,
# then start over into the populated target
cleanup_replication
follow_through recovery 2001 --restart
cleanup_replication
echo 'PASS [guard]: stream cleanup then clone --restart --drop-if-exists recovers'
