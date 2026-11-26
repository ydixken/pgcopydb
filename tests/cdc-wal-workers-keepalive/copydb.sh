#! /bin/bash

set -euo pipefail

# WAL worker 1 applies one insert and then only keepalives, while worker 0
# stays under load. Each keepalive commits a target transaction, and those
# commits must reach the target: one left queued in the libpq pipeline keeps
# its transaction open once the queue fills up, and that xmin holds back
# vacuum on the whole target database. The other transactions reach worker 1
# as empty BEGIN/COMMIT pairs, which receive turns into a keepalive every 10 s.

SRC=${PGCOPYDB_SOURCE_PGURI}
TGT=${PGCOPYDB_TARGET_PGURI}
S=pgcopydb
dir=/tmp/keepalive
log=/tmp/keepalive.log
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

sql() { timeout 120s psql -X -q -At -v ON_ERROR_STOP=1 -d "$@"; }
fail() { tail -n 60 "${log}"; echo "FAIL: $*" >&2; exit 1; }
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}" || fail "${1}"; }
local_lsn() { sql "${TGT}" -c "select local_lsn from pg_replication_origin_status where external_id = '${S}_w1'"; }
progress() { sql "${TGT}" -c "select pg_replication_origin_progress('${S}_w1', true)"; }

pgcopydb ping

sql "${SRC}" <<'SQL'
create schema id;
create table id.hot(id bigserial primary key, n bigint not null);
create table id.idle(id integer primary key, v text);
insert into id.hot(n) select i from generate_series(1, 100) i;
insert into id.idle select i, 'seed' from generate_series(1, 10) i;
SQL

rm -f /tmp/stop
(
    i=0
    while [ ! -e /tmp/stop ]; do
        i=$((i + 1))
        sql "${SRC}" -c "insert into id.hot(n) values (${i})"
        sleep 0.1
    done
) &
writer_pid=$!

pgcopydb clone --follow --dir "${dir}" --wal-workers 2 \
         --wal-high-traffic-tables id.hot > "${log}" 2>&1 &
pid=$!
for _ in $(seq 240); do
    [ "$(grep -c 'Applying CDC changes' "${log}")" -eq 2 ] && break
    kill -0 "${pid}" 2> /dev/null || break
    sleep 0.5
done
[ "$(grep -c 'Applying CDC changes' "${log}")" -eq 2 ] || fail 'apply did not start'

check 'tables of worker 1' 'idle' \
      "$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" \
         "select group_concat(relname, ',') from wal_worker_table where worker = 1")"

# the one insert worker 1 applies, after which it only sees keepalives
sql "${SRC}" -c "insert into id.idle values (100, 'late')"
for _ in $(seq 60); do
    [ "$(sql "${TGT}" -c 'select count(*) from id.idle where id = 100')" = 1 ] && break
    kill -0 "${pid}" 2> /dev/null || fail 'clone --follow exited'
    sleep 1
done
check 'insert applied by worker 1' late "$(sql "${TGT}" -c 'select v from id.idle where id = 100')"

applied=$(local_lsn)
origin=$(progress)
echo "worker 1 committed the insert at target LSN ${applied}, origin ${origin}"

# a keepalive commit moves the target LSN of the origin, not its progress
committed=
for _ in $(seq 60); do
    kill -0 "${pid}" 2> /dev/null || fail 'clone --follow exited'
    now=$(local_lsn)
    if [ "$(sql "${TGT}" -c "select '${now}'::pg_lsn > '${applied}'::pg_lsn")" = t ]; then
        committed=${now}
        break
    fi
    sleep 1
done
test -n "${committed}" || fail "worker 1 committed no keepalive on the target after ${applied}"
echo "worker 1 committed a keepalive at target LSN ${committed}"
check 'origin of worker 1 stays on the insert' "${origin}" "$(progress)"

echo 'PASS: the keepalives of an idle WAL worker commit on the target'
