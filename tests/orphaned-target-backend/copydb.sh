#! /bin/bash

# A run that dies mid-COPY without its FIN or RST reaching the target leaves
# the target backend in ClientRead with gate_a locked, until server-side TCP
# keepalives notice. The next run's DROP TABLE waits behind it. OUTPUT DROP
# rules on the run's own target connections make the loss deterministic, and
# a CHECK constraint holds its COPY on an advisory lock the test owns.

set -euo pipefail

export TMPDIR=/tmp/pgcopydb-orphaned-target
workdir=${TMPDIR}/work
mkdir -p "${TMPDIR}"
clone_args=(--dir "${workdir}" --table-jobs 1 --index-jobs 1 --drop-if-exists)

# 70 s of server keepalives plus the clone itself, far below the kernel's 2 h
bound=180
clone_pid='' gate_pid='' copy_pid=''
free_gate="select pg_terminate_backend(pid) from pg_stat_activity where application_name = 'copy_gate'"
sessions="select pid, state, wait_event_type, wait_event, pg_blocking_pids(pid), left(query, 50)
    from pg_stat_activity where backend_type = 'client backend' and pid <> pg_backend_pid() order by pid"

cleanup() {
    local status=$?
    trap - EXIT
    if test "${status}" -ne 0; then
        # through a pipe: timeout runs psql in a background group, a TTY stops it
        echo '==> target sessions: pid|state|wait_event_type|wait_event|blocked by|query'
        target_sql "${sessions}" 2>&1 | sed 's/^/target: /' || true
    fi
    test -z "${clone_pid}" || kill -KILL -- "-${clone_pid}" 2>/dev/null || true
    test -z "${gate_pid}" || target_sql "${free_gate}" >/dev/null 2>&1 || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test -f "${log}" || continue
            echo "==> ${log} (tail)"
            tail -n 20 "${log}"
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
equal() { test "$1" = "$2" || fail "$3: expected=$2 actual=$1"; }
source_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 30s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
digest="select count(*), md5(string_agg(t::text, ',' order by id)) from gate_a t"

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

gate_held() {
    test "$(target_sql "select count(*) from pg_locks where locktype = 'advisory' and objid = 42 and granted and mode = 'ExclusiveLock'")" = 1
}

copy_blocked() {
    test "$(target_sql "select count(*) from pg_stat_progress_copy p join pg_locks l on l.pid = p.pid
        where p.relid = to_regclass('public.gate_a') and l.locktype = 'advisory' and l.objid = 42 and not l.granted")" = 1
}

copy_orphaned() {
    test "$(target_sql "select wait_event from pg_stat_activity where pid = ${copy_pid}")" = ClientRead
}

own_group() {
    test "$(ps -o pgid= -p "${clone_pid}" | tr -d ' ')" = "${clone_pid}"
}

start_clone() {
    local name=$1
    shift
    setsid pgcopydb clone "${clone_args[@]}" "$@" >"${TMPDIR}/${name}.log" 2>&1 &
    clone_pid=$!
    # $! is known before the child has called setsid()
    poll 'pgcopydb to own its process group' own_group
}

# well beyond the socket buffers, so the run is still sending when it dies
seed() {
    source_sql "drop table if exists gate_a;
        drop function if exists copy_gate();
        create function copy_gate() returns boolean language plpgsql
            as \$\$ begin perform pg_advisory_xact_lock_shared(42); return true; end \$\$;
        create table gate_a(id integer primary key, payload text not null check (copy_gate()));
        insert into gate_a select g, repeat(md5(g::text), 8) from generate_series(1, 100000) g;
        analyze gate_a"
}

# drop what the run sends on its target connections, FIN and RST included;
# connections opened later use other ports and stay untouched
cut_off_run() {
    local tuples caddr cport saddr sport copy_port
    tuples=$(target_sql "select host(client_addr), client_port, host(inet_server_addr()), inet_server_port()
        from pg_stat_activity where application_name like 'pgcopydb%' and client_addr = inet_client_addr()")
    copy_port=$(target_sql "select client_port from pg_stat_activity where pid = ${copy_pid}")
    while IFS='|' read -r caddr cport saddr sport; do
        sudo iptables -A OUTPUT -p tcp -s "${caddr}" --sport "${cport}" -d "${saddr}" --dport "${sport}" -j DROP
    done <<<"${tuples}"
    sudo iptables -S OUTPUT | grep -- "--sport ${copy_port} " >/dev/null || fail "no DROP rule for the COPY connection port '${copy_port}'"
    echo "dropping the run's packets on $(wc -l <<<"${tuples}") target connections"
}

pgcopydb ping
seed
want=$(source_sql "${digest}")
[[ ${want} == 100000\|* ]] || fail "the source digest is '${want}'"

PGAPPNAME=copy_gate psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
    -c 'select pg_advisory_lock(42)' -c 'select pg_sleep(600)' >"${TMPDIR}/gate.out" 2>&1 &
gate_pid=$!
poll 'the copy gate to close' gate_held

start_clone attempt
poll 'the COPY of gate_a to wait on the gate' copy_blocked
copy_pid=$(target_sql "select pid from pg_stat_progress_copy where relid = to_regclass('public.gate_a')")
[[ ${copy_pid} =~ ^[0-9]+$ ]] || fail "the COPY backend pid is '${copy_pid}'"

cut_off_run
kill -KILL -- "-${clone_pid}"
wait "${clone_pid}" || true
clone_pid=
target_sql "${free_gate}" >/dev/null
wait "${gate_pid}" || true
gate_pid=
poll 'the COPY backend to wait on its dead client' copy_orphaned

locks=$(target_sql "select string_agg(mode, ',' order by mode) from pg_locks
    where pid = ${copy_pid} and relation = to_regclass('public.gate_a') and granted")
[[ ,${locks}, == *,RowExclusiveLock,* ]] || fail "the orphaned COPY backend holds '${locks}' on gate_a"
echo "orphaned COPY backend ${copy_pid} waits in ClientRead holding ${locks} on gate_a"

# the recovery the operator runs: start over and drop the half-copied table
start=${SECONDS}
start_clone recovery --restart
while kill -0 "${clone_pid}" 2>/dev/null; do
    test $((SECONDS - start)) -lt "${bound}" || fail "the recovery clone did not finish within ${bound} s"
    sleep 0.5
done
rc=0
wait "${clone_pid}" || rc=$?
clone_pid=
equal "${rc}" 0 'the recovery clone exit status'
echo "the recovery clone finished in $((SECONDS - start)) s"

equal "$(target_sql "select count(*) from pg_stat_activity where pid = ${copy_pid}")" 0 'the orphaned COPY backend is gone'
got=$(target_sql "${digest}")
equal "${got}" "${want}" 'gate_a on the target matches the source'
echo 'PASS: a start-over finishes once the target drops the orphaned COPY backend'
