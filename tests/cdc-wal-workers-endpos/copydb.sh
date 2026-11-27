#! /bin/bash

set -euo pipefail

# Every WAL worker stops at one endpos: a transaction across two workers lands
# in both or neither, a moved endpos restarts a finished worker, also one that
# stopped inside a COMMIT record, one below applied changes fails, a clean end
# leaves origins and slots at endpos, a signal, a lost session or a commit left
# in the spool moves no unfinished worker there, and the guards stop a lossy run
# but take a new partition. ep.k has no key, so a duplicate shows as a count.

SRC=${PGCOPYDB_SOURCE_PGURI}
TGT=${PGCOPYDB_TARGET_PGURI}
WAL=${SRC%/*}/ep_wal
S=pgcopydb
HT=ep.a,ep.b

sql() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$@"; }
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}"; }

# pgrep exits 1 when nothing matches, and 2 or more when it failed to look
no_pgcopydb() {
    local rc=0
    pgrep -a -x pgcopydb || rc=$?
    if [ "${rc}" -ne 1 ]; then
        echo "FAIL: pgcopydb processes are left after $1, pgrep exit ${rc}" >&2
        exit 1
    fi
}

# settled what: no pgcopydb process is left within 15 s
settled() {
    for _ in $(seq 30); do
        pgrep -x pgcopydb > /dev/null || break
        sleep 0.5
    done
    no_pgcopydb "$1"
}

# fail message: stop the run and show its log
fail() {
    kill "${pid}" 2> /dev/null || true
    pkill -f '^pgcopydb: ' 2> /dev/null || true
    cat "${log}"
    echo "FAIL ${label}: $1" >&2
    exit 1
}

# the walsender of a stopped worker lets go of its slot a little later
wait_slots_inactive() {
    for _ in $(seq 60); do
        [ "$(sql "${SRC}" -c 'select count(*) from pg_replication_slots where active')" -eq 0 ] && return
        sleep 0.5
    done
    echo "FAIL: replication slots still active" >&2
    exit 1
}

flush_lsn() { sql "${SRC}" -c 'select pg_current_wal_flush_lsn()'; }

# quiesce n: the source writes no more WAL and its n walsenders have confirmed
# every byte of it, so no later record can wake a receive that already passed
# endpos. The first poll waits out the one pending running_xacts record of the
# bgwriter, which it writes at most one snapshot interval after important WAL.
quiesce() {
    local l p='' i=0
    for _ in $(seq 150); do
        l=$(flush_lsn)
        if [ "${l}" = "${p}" ]; then
            i=$((i + 1))
            [ "${i}" -ge 16 ] && break
        else
            i=0
            p=${l}
        fi
        sleep 1
    done
    [ "${i}" -ge 16 ] || fail "the WAL of the source still moves, at ${l}"
    for _ in $(seq 120); do
        [ "$(sql "${SRC}" -c 'select count(*) from pg_stat_replication where write_lsn = pg_current_wal_flush_lsn()')" -eq "$1" ] && return
        sleep 0.5
    done
    fail "$1 walsenders have not confirmed the WAL of the source up to $(flush_lsn)"
}

# commit_record lsn xid: start and end of the COMMIT record of xid, after lsn
commit_record() {
    sql "${WAL}" -F ' ' -c "select start_lsn, end_lsn from pg_get_wal_records_info('$1', pg_current_wal_flush_lsn()) where record_type = 'COMMIT' and xid::text = '$2'"
}

slot_lsn() { sql "${SRC}" -c "select confirmed_flush_lsn from pg_replication_slots where slot_name = '$1'"; }

# lsn_cmp a op b: t or f, compared as pg_lsn
lsn_cmp() { sql "${SRC}" -c "select '$1'::pg_lsn $2 '$3'::pg_lsn"; }

worker_sentinel() {
    sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/cdc/w$1/source.db" \
            "select coalesce($2, '0/0') from sentinel"
}

receive_state() {
    sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/cdc/w$1/source.db" \
            "select run_state from pipeline_state where process_name = 'receive'"
}

# origins: name=t|f per worker origin, t when it is at the given LSN
origins_at() {
    sql "${TGT}" -c "select string_agg(roname || '=' || (pg_replication_origin_progress(roname, true) = '$1')::text::char, ' ' order by roname collate \"C\") from pg_replication_origin"
}

slots_at() {
    sql "${SRC}" -c "select string_agg(slot_name || '=' || (confirmed_flush_lsn = '$1')::text::char, ' ' order by slot_name collate \"C\") from pg_replication_slots"
}

rows() {
    local t out=''
    for t in ep.a ep.b; do
        out="${out} $(sql "$1" -c "select count(*) from ${t} where id = $2")"
    done
    echo "${out# }"
}

# wait_log count pattern: the log matches pattern count times within 60 s
wait_log() {
    for _ in $(seq 120); do
        [ "$(grep -cE "$2" "${log}" || true)" -ge "$1" ] && return
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    fail "the log does not match ${1} times: $2"
}

# finish secs: rc is the exit status of the run, 124 while it still runs
finish() {
    rc=124
    for _ in $(seq $(($1 * 2))); do
        if ! kill -0 "${pid}" 2> /dev/null; then
            rc=0
            wait "${pid}" || rc=$?
            return
        fi
        sleep 0.5
    done
}

# hold tables: an open target transaction locks them until release
hold() {
    PGAPPNAME=ep_holder psql -X -q -d "${TGT}" -v ON_ERROR_STOP=1 \
        -c 'begin' -c "lock table $1 in access exclusive mode" \
        -c 'select pg_sleep(600)' > /dev/null 2>&1 &
    holder=$!
    for _ in $(seq 60); do
        [ "$(sql "${TGT}" -c "select count(*) from pg_locks l join pg_stat_activity a using (pid) where a.application_name = 'ep_holder' and l.mode = 'AccessExclusiveLock' and l.granted and l.relation is not null and l.relation::regclass::text in ('ep.a', 'ep.b', 'ep.k')")" -ge 1 ] && return
        sleep 0.5
    done
    fail "no lock held on $1"
}

release() {
    sql "${TGT}" -c "select count(pg_terminate_backend(pid)) from pg_stat_activity where application_name = 'ep_holder'" > /dev/null
    wait "${holder}" || true
}

# waiting n: n apply sessions wait on the held locks within 30 s
waiting() {
    for _ in $(seq 60); do
        [ "$(sql "${TGT}" -c "select count(distinct pid) from pg_locks where not granted and relation in ('ep.a'::regclass, 'ep.b'::regclass, 'ep.k'::regclass)")" -eq "$1" ] && return
        sleep 0.5
    done
    fail "$1 apply sessions do not wait on the held locks"
}

# wait_worker k column lsn: the sentinel of worker k holds lsn within 30 s
wait_worker() {
    for _ in $(seq 60); do
        [ "$(lsn_cmp "$(worker_sentinel "$1" "$2")" '=' "$3")" = t ] && return
        sleep 0.5
    done
    fail "the $2 of WAL worker $1 is not $3"
}

# worker_pids k: sets recv and apply to the pids of WAL worker k
worker_pids() {
    local w
    w=$(pgrep -f "^pgcopydb: follow worker $1 *\$") || fail "no WAL worker $1"
    recv=$(pgrep -P "${w}" -f '^pgcopydb: follow receive *$') || fail "no receive of WAL worker $1"
    apply=$(pgrep -P "${w}" -f '^pgcopydb: follow apply *$') || fail "no apply of WAL worker $1"
}

canary() {
    check "${label} rows of ep.k" "$(sql "${SRC}" -c 'select count(*) from ep.k')" \
          "$(sql "${TGT}" -c 'select count(*) from ep.k')"
}

# start label N list: a fresh clone --follow with N WAL workers, until every
# worker applies
start() {
    label=$1
    dir=/tmp/$1
    log=/tmp/$1.log

    sql "${TGT}" -c 'drop schema if exists ep cascade' > /dev/null

    pgcopydb clone --follow --dir "${dir}" --wal-workers "$2" \
             --wal-high-traffic-tables "$3" > "${log}" 2>&1 &
    pid=$!

    for _ in $(seq 240); do
        [ "$(grep -c 'Applying CDC changes' "${log}" || true)" -eq "$2" ] && break
        kill -0 "${pid}" 2> /dev/null || break
        sleep 0.5
    done
    [ "$(grep -c 'Applying CDC changes' "${log}" || true)" -eq "$2" ] ||
        fail "the apply of $2 WAL workers did not start"
}

# resume: follow --resume of the last run, with its worker options
resume() {
    log=/tmp/${label}-resume.log
    pgcopydb follow --resume --not-consistent --dir "${dir}" \
             --wal-workers 3 --wal-high-traffic-tables "${HT}" > "${log}" 2>&1 &
    pid=$!
}

# cleanup: drop the slots, publications and origins of the last run, whose
# post-data restored no publication on the target
cleanup() {
    settled "${label}"
    wait_slots_inactive
    pgcopydb stream cleanup --dir "${dir}" > "${dir}-cleanup.log" 2>&1 ||
        { cat "${dir}-cleanup.log"; echo "FAIL ${label}: cleanup" >&2; exit 1; }
    check "${label} objects left after cleanup" '0 0 0 0' \
          "$(sql "${SRC}" -c 'select count(*) from pg_replication_slots') $(sql "${SRC}" -c 'select count(*) from pg_publication') $(sql "${TGT}" -c 'select count(*) from pg_replication_origin') $(sql "${TGT}" -c 'select count(*) from pg_publication')"
}

pgcopydb ping

sql "${SRC}" -c 'create database ep_wal'
sql "${WAL}" -c 'create extension pg_walinspect' -c 'create table pad(i int)'

# with 3 workers and ep.a,ep.b high traffic: ep.a on worker 0, ep.b on 1, and
# the others on worker 2, where only some scenarios write
sql "${SRC}" <<'SQL'
create schema ep;
create table ep.a(id bigint primary key, v text);
create table ep.b(id bigint primary key, v text);
create table ep.c(id bigint primary key, v text);
create table ep.r(id bigint primary key, v text) partition by range (id);
create table ep.r1 partition of ep.r for values from (0) to (1000000);
create table ep.x(id bigint primary key, v text);
create table ep.k(id bigint, v text);
insert into ep.a select i, 'seed' from generate_series(1, 10) i;
insert into ep.b select i, 'seed' from generate_series(1, 10) i;
insert into ep.c select i, 'seed' from generate_series(1, 10) i;
insert into ep.r select i, 'seed' from generate_series(1, 10) i;
SQL

#
# a transaction across two workers, with endpos inside it after both spools
# hold its COMMIT, lands in both of their tables or in none
#
start atomic 3 "${HT}"
check 'assignment' '0:ep.a 1:ep.b 2:ep.c 2:ep.k 2:ep.r 2:ep.r1 2:ep.x' \
      "$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" \
         "select group_concat(worker || ':' || nspname || '.' || relname, ' ') from (select * from wal_worker_table order by worker, relname)")"

# apply waits on the locks with a transaction before X, and reads endpos anew
# before X once it got past them
hold 'ep.a, ep.b'
sql "${SRC}" -c "insert into ep.a values (101, 'w')" -c "insert into ep.b values (101, 'w')"
waiting 2

# endpos lies between the changes of X to ep.a and to ep.b, where the BEGIN of
# X is for worker 0 and worker 1, so only the commit LSN cuts both alike
read -r xid mid < <(sql "${SRC}" -F ' ' <<'SQL'
begin;
insert into ep.a values (102, 'x');
select txid_current() % 4294967296, pg_current_wal_insert_lsn();
select from pg_logical_emit_message(false, 'ep', 'pad');
insert into ep.b values (102, 'x');
commit;
SQL
)
echo "X is xid ${xid}, endpos ${mid} lies inside it"

# spooled worker where: rows of the spool of a worker that match where
spooled() {
    local f n=0
    for f in "${dir}"/cdc/w"$1"/*-output.db; do
        n=$((n + $(sqlite3 -readonly -init /dev/null -batch -noheader "${f}" \
                   "select count(*) from output where $2")))
    done
    echo "${n}"
}

for _ in $(seq 60); do
    [ "$(spooled 0 "action = 'C' and xid = ${xid}")$(spooled 1 "action = 'C' and xid = ${xid}")" = 11 ] && break
    sleep 0.5
done
check 'COMMIT of X in the spools of workers 0 and 1' 11 \
      "$(spooled 0 "action = 'C' and xid = ${xid}")$(spooled 1 "action = 'C' and xid = ${xid}")"

# without this the BEGIN rule would cut both workers alike
m=$(( (16#${mid%/*} << 32) + 16#${mid#*/} ))
check 'BEGIN of X at or below endpos for worker 0, above it for worker 1' 11 \
      "$(spooled 0 "action = 'B' and xid = ${xid} and lsn <= ${m}")$(spooled 1 "action = 'B' and xid = ${xid} and lsn > ${m}")"

pgcopydb stream sentinel set endpos --dir "${dir}" "${mid}" > /dev/null
for _ in $(seq 60); do
    [ "$(worker_sentinel 0 endpos) $(worker_sentinel 1 endpos)" = "${mid} ${mid}" ] && break
    sleep 0.5
done
check 'endpos of workers 0 and 1' "${mid} ${mid}" "$(worker_sentinel 0 endpos) $(worker_sentinel 1 endpos)"
release

finish 120
check 'rows before X on the target' '1 1' "$(rows "${TGT}" 101)"
check 'rows of X on the source' '1 1' "$(rows "${SRC}" 102)"
check 'rows of X on the target' '0 0' "$(rows "${TGT}" 102)"
[ "${rc}" -eq 0 ] || fail "clone --follow exit ${rc}"
check 'workers reaching endpos' 3 "$(grep -c "has reached endpos ${mid}\$" "${log}")"
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${mid}")"
check 'main replay_lsn' "${mid}" "$(pgcopydb stream sentinel get --dir "${dir}" --replay-lsn)"
cleanup
echo "OK a transaction across workers is cut at its commit LSN"

#
# endpos raised after a worker finished: it starts again, and every origin and
# slot ends at the new endpos, the worker without writes included
#
start raise 3 "${HT}"
hold ep.b
sql "${SRC}" -c "insert into ep.a values (201, 'e1')" -c "insert into ep.b values (201, 'e1')"
waiting 1
e1=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e1}" > /dev/null
wait_log 2 "WAL worker [02] with pid [0-9]+ has reached endpos ${e1}\$"

sql "${SRC}" -c "insert into ep.a values (202, 'e2')" -c "insert into ep.b values (202, 'e2')"
e2=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e2}" > /dev/null
wait_log 2 "Starting WAL worker [02] again: it finished at ${e1}, endpos is now ${e2}"
release

finish 120
[ "${rc}" -eq 0 ] || fail "clone --follow exit ${rc}"
check 'rows at the first endpos' '1 1' "$(rows "${TGT}" 201)"
check 'rows at the raised endpos' '1 1' "$(rows "${TGT}" 202)"
check 'worker 1 finished once' 1 "$(grep -cE "WAL worker 1 with pid [0-9]+ has reached endpos" "${log}")"
check 'slot creation below the raised endpos' t \
      "$(sql "${SRC}" -c "select '$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" "select printf('%X/%X', lsn >> 32, lsn & 4294967295) from replication_slot")'::pg_lsn < '${e2}'")"
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${e2}")"
check 'slots at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${e2}")"
cleanup
echo "OK a raised endpos starts finished workers again"

#
# endpos inside the COMMIT record of T: the slot and origin of its worker stay
# where that record starts, as the walsender skips a transaction committing
# before it, so T arrives once endpos is raised; with workers 0 and 2 held,
# endpos may first move down to that record start, and worker 1 ends there
#
start straddle 3 "${HT}"
hold 'ep.a, ep.k'
sql "${SRC}" -c "insert into ep.a values (701, 'w')" -c "insert into ep.k values (701, 'w')"
waiting 2

# 10000 subtransactions make the COMMIT record of T about 40 kB long
fifo=/tmp/straddle.fifo
rm -f "${fifo}" && mkfifo "${fifo}"
PGAPPNAME=ep_straddle psql -X -q -At -v ON_ERROR_STOP=1 -d "${SRC}" < "${fifo}" > /tmp/straddle.out 2>&1 &
tx=$!
exec 4> "${fifo}"
cat >&4 <<'SQL'
begin;
do $$ begin for i in 1..10000 loop begin insert into ep.b values (700000 + i, 't'); exception when unique_violation then null; end; end loop; end $$;
SQL
for _ in $(seq 120); do
    [ "$(sql "${SRC}" -c "select state from pg_stat_activity where application_name = 'ep_straddle'")" = 'idle in transaction' ] && break
    sleep 0.5
done
read -r txid p < <(sql "${SRC}" -F ' ' -c "select backend_xid, pg_current_wal_insert_lsn() from pg_stat_activity where application_name = 'ep_straddle' and state = 'idle in transaction'") ||
    fail 'T did not reach its COMMIT'

# endpos goes inside the COMMIT record of T once it is written, so receive of
# worker 1 stays stopped until then, and longer than its 10 s status interval,
# at which it re-reads endpos before it handles another message
worker_pids 1
kill -STOP "${recv}"
stopped=${SECONDS}
echo 'commit;' >&4
exec 4>&-
wait "${tx}" || { cat /tmp/straddle.out; fail 'T failed'; }
read -r c t_end < <(commit_record "${p}" "${txid}") || fail 'no COMMIT record of T'
E=$(sql "${SRC}" -c "select '${c}'::pg_lsn + floor(('${t_end}'::pg_lsn - '${c}'::pg_lsn) / 2)")
check "endpos ${E} inside the COMMIT record ${c} to ${t_end} of T" 't t' \
      "$(lsn_cmp "${c}" '<' "${E}") $(lsn_cmp "${E}" '<' "${t_end}")"
pgcopydb stream sentinel set endpos --dir "${dir}" "${E}" > /dev/null
wait_worker 1 endpos "${E}"
while [ $((SECONDS - stopped)) -le 11 ]; do sleep 0.5; done
kill -CONT "${recv}"
wait_log 1 "WAL worker 1 with pid [0-9]+ has reached endpos ${E}\$"
grep -F "Endpos ${E} lies inside the COMMIT record of xid ${txid} at ${c}" "${log}" ||
    fail 'receive did not see endpos inside the COMMIT record of T'
check 'rows of T on the target at the first endpos' 0 \
      "$(sql "${TGT}" -c 'select count(*) from ep.b where id > 700000')"
for _ in $(seq 60); do
    [ "$(sql "${SRC}" -c "select active from pg_replication_slots where slot_name = '${S}_w1'")" = f ] && break
    sleep 0.5
done
slot1=$(slot_lsn "${S}_w1")
origin1=$(sql "${TGT}" -c "select pg_replication_origin_progress('${S}_w1', true)")

pgcopydb stream sentinel set endpos --dir "${dir}" "${c}" > /dev/null
wait_log 1 "Starting WAL worker 1 again: it finished at ${E}, endpos is now ${c}"
wait_log 1 "WAL worker 1 with pid [0-9]+ has reached endpos ${c}\$"

e2=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e2}" > /dev/null
wait_log 1 "Starting WAL worker 1 again: it finished at ${c}, endpos is now ${e2}"
release

finish 120
[ "${rc}" -eq 0 ] || fail "clone --follow exit ${rc}"
check 'rows of T on the target at the raised endpos' 10000 \
      "$(sql "${TGT}" -c 'select count(*) from ep.b where id > 700000')"
check 'row before T on the target' 1 "$(sql "${TGT}" -c 'select count(*) from ep.a where id = 701')"
canary
check 'slot and origin of worker 1 at the first endpos' 't t' \
      "$(lsn_cmp "${slot1}" '=' "${c}") $(lsn_cmp "${origin1}" '=' "${c}")"
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${e2}")"
check 'slots at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${e2}")"
cleanup
echo "OK an endpos inside a COMMIT record keeps that transaction for a raised endpos"

#
# endpos below what a worker applied: the run fails
#
start lower 3 "${HT}"
l0=$(flush_lsn)
sql "${SRC}" -c "insert into ep.a values (301, 'w')" -c "insert into ep.b values (301, 'w')"
for _ in $(seq 60); do
    [ "$(sql "${SRC}" -c "select '$(worker_sentinel 0 replay_lsn)'::pg_lsn > '${l0}' and '$(worker_sentinel 1 replay_lsn)'::pg_lsn > '${l0}'")" = t ] && break
    sleep 0.5
done
check 'workers 0 and 1 applied past the lower endpos' t \
      "$(sql "${SRC}" -c "select '$(worker_sentinel 0 replay_lsn)'::pg_lsn > '${l0}' and '$(worker_sentinel 1 replay_lsn)'::pg_lsn > '${l0}'")"
pgcopydb stream sentinel set endpos --dir "${dir}" "${l0}" > /dev/null
finish 60
if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 124 ] ||
   ! grep -F "Failed to stop at endpos ${l0}: WAL worker 0 has already applied changes up to replay_lsn" "${log}"; then
    fail "a lowered endpos left exit ${rc}"
fi
cleanup
echo "OK an endpos below applied changes fails the run, exit ${rc}"

#
# a quiet source: endpos at its last record, with the keepalive past endpos
# already confirmed by both receives, stops both workers without a new record
#
start quiet 2 ep.a
sql "${SRC}" -c "insert into ep.b values (1401, 'w')"
quiesce 2
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
wait_log 1 "WAL worker 0 with pid [0-9]+ has reached endpos ${e}\$"
wait_log 1 "WAL worker 1 with pid [0-9]+ has reached endpos ${e}\$"
finish 120
[ "${rc}" -eq 0 ] || fail "a quiet source left exit ${rc}"
check 'rows on the target' '0 1' "$(rows "${TGT}" 1401)"
canary
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t" "$(origins_at "${e}")"
check 'slots at endpos' "${S}=t ${S}_w1=t" "$(slots_at "${e}")"
cleanup
echo "OK a quiet source stops every WAL worker at endpos"

#
# SIGTERM while worker 1 reached endpos by its own commit and waits for its
# receive, stopped before it read endpos, with its walsender gone: its slot
# stays below endpos, and a resume moves every origin and slot there
#
start sigterm 3 "${HT}"
hold ep.b
pre=$(sql "${SRC}" -c 'select pg_current_wal_insert_lsn()')
sql "${SRC}" -c "insert into ep.a values (401, 'w')" -c "insert into ep.k values (401, 'w')"
xid=$(sql "${SRC}" <<'SQL'
begin;
insert into ep.b values (401, 'w');
select txid_current() % 4294967296;
commit;
SQL
)
waiting 1
read -r _ e < <(commit_record "${pre}" "${xid}") || fail 'no COMMIT record of 401 on ep.b'

worker_pids 1
recv1=${recv}
apply1=${apply}
kill -STOP "${recv1}"
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
wait_log 2 "WAL worker [02] with pid [0-9]+ has reached endpos ${e}\$"

# as after a lost connection, only receive knows whether it got to endpos
sql "${SRC}" -c "select count(pg_terminate_backend(active_pid)) from pg_replication_slots where slot_name = '${S}_w1' and active" > /dev/null
for _ in $(seq 60); do
    [ "$(sql "${SRC}" -c "select active from pg_replication_slots where slot_name = '${S}_w1'")" = f ] && break
    sleep 0.5
done
release
for _ in $(seq 60); do
    [ "$(lsn_cmp "$(worker_sentinel 1 replay_lsn)" '=' "${e}")" = t ] && break
    sleep 0.5
done
check 'replay_lsn of worker 1 at endpos by its commit' t "$(lsn_cmp "$(worker_sentinel 1 replay_lsn)" '=' "${e}")"
for _ in $(seq 20); do
    [ "$(lsn_cmp "$(slot_lsn "${S}_w1")" '<' "${e}")" = t ] ||
        fail 'worker 1 moved its slot to endpos before its receive got there'
    sleep 0.5
done

supervisor=$(pgrep -f '^pgcopydb: follow *$') || fail 'no follow supervisor'
kill -TERM "${supervisor}"
for _ in $(seq 60); do
    kill -0 "${apply1}" 2> /dev/null || break
    sleep 0.5
done
kill -0 "${apply1}" 2> /dev/null && fail 'the apply of worker 1 did not stop on SIGTERM'
kill -CONT "${recv1}"
finish 60
[ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] || fail "a SIGTERM left exit ${rc}"
settled 'a SIGTERM'
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${e}")"
check 'slots at endpos' "${S}=t ${S}_w1=f ${S}_w2=t" "$(slots_at "${e}")"
check 'slot of worker 1 below endpos' t "$(lsn_cmp "$(slot_lsn "${S}_w1")" '<' "${e}")"
echo "OK a SIGTERM moved no slot of an unfinished worker to endpos, exit ${rc}"

resume
finish 120
[ "${rc}" -eq 0 ] || fail "follow --resume exit ${rc}"
check 'rows after the resume' '1 1' "$(rows "${TGT}" 401)"
canary
wait_slots_inactive
check 'origins at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${e}")"
check 'slots at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${e}")"
cleanup
echo "OK a resume finished every worker at endpos"

#
# the receive of worker 1 stopped by a signal moves nothing: at endpos it
# signals no LSN, short of endpos it records done without a signal, and either
# way apply stops waiting and the supervisor starts worker 1 again
#
start recv 3 "${HT}"
hold ep.k
sql "${SRC}" -c "insert into ep.k values (801, 'w')"
waiting 1
pre=$(sql "${SRC}" -c 'select pg_current_wal_insert_lsn()')
xid=$(sql "${SRC}" <<'SQL'
begin;
insert into ep.b values (801, 'w');
select txid_current() % 4294967296;
commit;
SQL
)
read -r _ e < <(commit_record "${pre}" "${xid}") || fail 'no COMMIT record of 801 on ep.b'
wait_worker 1 replay_lsn "${e}"
quiesce 3

worker_pids 1
kill -STOP "${recv}"
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
wait_log 1 "WAL worker 0 with pid [0-9]+ has reached endpos ${e}\$"
wait_worker 1 endpos "${e}"
kill -TERM "${recv}"
kill -CONT "${recv}"
wait_log 1 "Receive stopped at 0/0, before endpos ${e}: not moving origin \"${S}_w1\""
wait_log 1 "WAL worker 1 with pid [0-9]+ stopped below endpos ${e}: its receive signalled done at 0/0\$"
wait_log 1 "WAL worker 1 with pid [0-9]+ has reached endpos ${e}\$"

# an endpos past the end of WAL, which segment switches in another database
# pass only once receive is stopped in its streaming loop
F=$(sql "${SRC}" -c 'select pg_current_wal_insert_lsn() + 33554432')
pgcopydb stream sentinel set endpos --dir "${dir}" "${F}" > /dev/null
wait_log 1 "Starting WAL worker 1 again: it finished at ${e}, endpos is now ${F}"
streaming="select count(*) from pg_stat_replication r join pg_replication_slots s on s.active_pid = r.pid where s.slot_name = '${S}_w1' and r.reply_time is not null"
for _ in $(seq 60); do
    [ "$(sql "${SRC}" -c "${streaming}")" -eq 1 ] && break
    sleep 0.5
done
check 'receive of worker 1 replies on its stream' 1 "$(sql "${SRC}" -c "${streaming}")"
worker_pids 1
kill -STOP "${recv}"
for _ in $(seq 8); do
    [ "$(lsn_cmp "$(flush_lsn)" '>=' "${F}")" = t ] && break
    sql "${WAL}" -c 'insert into pad values (1)' -c 'select pg_switch_wal()' > /dev/null
done
check "WAL past endpos ${F}" t "$(lsn_cmp "$(flush_lsn)" '>=' "${F}")"
wait_log 1 "WAL worker 0 with pid [0-9]+ has reached endpos ${F}\$"
kill -TERM "${recv}"
kill -CONT "${recv}"
wait_log 2 "Receive stopped at 0/0, before endpos [0-9A-F/]+: not moving origin \"${S}_w1\""
grep -F "Receive stopped at 0/0, before endpos ${F}: not moving origin \"${S}_w1\"" "${log}" ||
    fail 'apply waited on a receive that stopped short of endpos'
wait_log 1 "WAL worker 1 with pid [0-9]+ stopped below endpos ${F}: its receive signalled done at 0/0\$"
release

finish 120
[ "${rc}" -eq 0 ] || fail "clone --follow exit ${rc}"
check 'rows on the target' '0 1' "$(rows "${TGT}" 801)"
canary
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${F}")"
check 'slots at endpos' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${F}")"
cleanup
echo "OK a receive stopped by a signal moves nothing, and its worker starts again"

#
# the target session of apply lost while it waits for receive: moving the
# origin to endpos fails the run instead of reporting done, and a resume ends
#
start lost 3 "${HT}"
sql "${SRC}" -c "insert into ep.k values (901, 'w')"
for _ in $(seq 60); do
    [ "$(sql "${TGT}" -c 'select count(*) from ep.k where id = 901')" -eq 1 ] && break
    sleep 0.5
done
check 'row of worker 2 on the target' 1 "$(sql "${TGT}" -c 'select count(*) from ep.k where id = 901')"

worker_pids 2
kill -STOP "${recv}"
sql "${SRC}" -c "insert into ep.a values (901, 'w')"
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
wait_log 2 "WAL worker [01] with pid [0-9]+ has reached endpos ${e}\$"
wait_worker 2 endpos "${e}"
session="application_name like 'pgcopydb[${apply}]%'"
check 'target sessions of the apply of worker 2 terminated' t \
      "$(sql "${TGT}" -c "select count(pg_terminate_backend(pid)) > 0 from pg_stat_activity where ${session}")"
for _ in $(seq 60); do
    [ "$(sql "${TGT}" -c "select count(*) from pg_stat_activity where ${session}")" -eq 0 ] && break
    sleep 0.5
done
kill -CONT "${recv}"
finish 60
[ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] || fail "a lost target session left exit ${rc}"
grep -F "Failed to move replication origin \"${S}_w2\" to ${e}" "${log}" ||
    fail 'no failed origin move'
settled 'a lost target session'
wait_slots_inactive
check 'origins at endpos' "${S}=t ${S}_w1=t ${S}_w2=f" "$(origins_at "${e}")"
echo "OK a lost target session fails the run, exit ${rc}"

resume
finish 120
[ "${rc}" -eq 0 ] || fail "follow --resume exit ${rc}"
check 'rows after the resume' '1 0' "$(rows "${TGT}" 901)"
canary
wait_slots_inactive
check 'origins at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${e}")"
check 'slots at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${e}")"
cleanup
echo "OK a resume moved the origin of the lost session to endpos"

#
# a commit below endpos left in the spool when the apply loop stops: the drain
# gate moves neither the slot nor the origin of its worker to endpos and fails
# the run, and a resume applies it; gdb makes the loop miss that commit once
#
start drain 3 "${HT}"
E=$(sql "${SRC}" -c 'select pg_current_wal_insert_lsn() + 1048576')
e=$(( (16#${E%/*} << 32) + 16#${E#*/} ))
pgcopydb stream sentinel set endpos --dir "${dir}" "${E}" > /dev/null
wait_worker 1 endpos "${E}"
worker_pids 1

# hold apply where its loop asks what is left below endpos, then answer nothing
rm -f /tmp/drain.held /tmp/drain.go
timeout 300 sudo -n gdb -q -nx -batch -p "${apply}" \
    -ex 'set pagination off' -ex 'set confirm off' \
    -ex "break ld_store_lookup_output_complete_txn if endpos == ${e}" \
    -ex continue -ex 'print endpos' \
    -ex 'shell touch /tmp/drain.held; for i in $(seq 600); do [ -e /tmp/drain.go ] && break; sleep 0.2; done' \
    -ex 'return 1' -ex delete -ex detach > /tmp/drain-gdb.log 2>&1 &
gdb=$!
for _ in $(seq 120); do
    [ -e /tmp/drain.held ] && break
    sleep 0.5
done
[ -e /tmp/drain.held ] || { cat /tmp/drain-gdb.log; fail 'gdb did not hold the apply of worker 1'; }

pre=$(sql "${SRC}" -c 'select pg_current_wal_insert_lsn()')
xid=$(sql "${SRC}" <<'SQL'
begin;
insert into ep.b values (1001, 'spooled');
select txid_current() % 4294967296;
commit;
SQL
)
read -r _ c < <(commit_record "${pre}" "${xid}") || fail 'no COMMIT record of 1001 on ep.b'
check 'COMMIT of 1001 below endpos' t "$(lsn_cmp "${c}" '<' "${E}")"
quiesce 3
for _ in $(seq 8); do
    [ "$(lsn_cmp "$(flush_lsn)" '>=' "${E}")" = t ] && break
    sql "${WAL}" -c 'insert into pad values (1)' -c 'select pg_switch_wal()' > /dev/null
done
check "WAL past endpos ${E}" t "$(lsn_cmp "$(flush_lsn)" '>=' "${E}")"
for _ in $(seq 60); do
    [ "$(receive_state 1)" = 'done' ] && break
    sleep 0.5
done
check 'receive of worker 1 done while its apply is held' 'done' "$(receive_state 1)"
check 'COMMIT of 1001 in the spool of worker 1' 1 "$(spooled 1 "action = 'C' and xid = ${xid}")"
check 'row 1001 on the target while apply is held' 0 "$(sql "${TGT}" -c 'select count(*) from ep.b where id = 1001')"
touch /tmp/drain.go
wait "${gdb}" || { cat /tmp/drain-gdb.log; fail 'gdb failed'; }
grep -F " = ${e}" /tmp/drain-gdb.log || { cat /tmp/drain-gdb.log; fail "gdb held the apply before it read endpos ${E}"; }

finish 120
[ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] || fail "a commit left in the spool left exit ${rc}"
grep -E "Apply stopped at [0-9A-F]+/[0-9A-F]+ while outputDB still holds xid ${xid} committing at" "${log}" ||
    fail 'the drain gate did not stop worker 1'
settled 'a commit left in the spool'
wait_slots_inactive
check 'row 1001 on the target' 0 "$(sql "${TGT}" -c 'select count(*) from ep.b where id = 1001')"
check 'origin and slot of worker 1 below endpos' 't t' \
      "$(lsn_cmp "$(sql "${TGT}" -c "select pg_replication_origin_progress('${S}_w1', true)")" '<' "${E}") $(lsn_cmp "$(slot_lsn "${S}_w1")" '<' "${E}")"
echo "OK a commit left in the spool moved nothing to endpos, exit ${rc}"

resume
finish 120
[ "${rc}" -eq 0 ] || fail "follow --resume exit ${rc}"
check 'row 1001 after the resume' 1 "$(sql "${TGT}" -c 'select count(*) from ep.b where id = 1001')"
canary
wait_slots_inactive
check 'origins at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(origins_at "${E}")"
check 'slots at endpos after the resume' "${S}=t ${S}_w1=t ${S}_w2=t" "$(slots_at "${E}")"
cleanup
echo "OK a resume applied the commit that the drain gate kept"

#
# a publication dropped during the run: its changes do not reach the worker,
# so the run fails instead of finishing, and so does a resume at its start
#
start publication 3 "${HT}"
pub=${S}_t$(sql "${SRC}" -c "select 'ep.b'::regclass::oid")
sql "${SRC}" -c "drop publication ${pub}" \
             -c "insert into ep.a values (501, 'w')" -c "insert into ep.b values (501, 'w')"
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
finish 120
[ "${rc}" -ne 0 ] && [ "${rc}" -ne 124 ] || fail "a dropped publication left exit ${rc}"

# Postgres 18 skips a missing publication with a warning, older versions fail
if [ "$(sql "${SRC}" -c 'show server_version_num')" -ge 180000 ]; then
    grep -F "Failed to check the publications of WAL worker 1: publication \"${pub}\" does not exist" "${log}" ||
        fail 'no publication check message'
    check 'workers reaching endpos' 3 "$(grep -c "has reached endpos ${e}\$" "${log}")"
    check 'row of the dropped publication on the target' '1 0' "$(rows "${TGT}" 501)"

    settled 'a dropped publication'
    wait_slots_inactive
    resume
    finish 120
    if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 124 ] ||
       ! grep -F "Failed to check the publications of WAL worker 1: publication \"${pub}\" does not exist" "${log}"; then
        fail "a resume without the publication left exit ${rc}"
    fi
else
    grep -F "publication \"${pub}\" does not exist" "${log}" ||
        fail 'no missing publication error'
fi
cleanup
echo "OK a dropped publication fails the run"

#
# a publication of worker 2 that also publishes ep.a of worker 0, with no
# change of ep.a after it: the check before done fails the run
#
start pubother 3 "${HT}"
check 'workers of ep.a and ep.c' '0 2' \
      "$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" \
         "select group_concat(worker, ' ') from (select worker from wal_worker_table where relname in ('a', 'c') order by relname)")"
pub=${S}_t$(sql "${SRC}" -c "select 'ep.c'::regclass::oid")
sql "${SRC}" -c "alter publication ${pub} add table ep.a" \
             -c "insert into ep.b values (1201, 'w')" -c "insert into ep.c values (1201, 'w')"
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
finish 120
if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 124 ] ||
   ! grep -F "Failed to check the publications of WAL worker 2: publication \"${pub}\" publishes table ep.a, which is assigned to another worker" "${log}"; then
    fail "a publication of a table of another worker left exit ${rc}"
fi
check 'workers reaching endpos' 3 "$(grep -c "has reached endpos ${e}\$" "${log}")"
cleanup
echo "OK a publication of a table of another worker fails the run, exit ${rc}"

#
# a table of worker 0 attached as a partition of a table of worker 1 reaches
# both: receive of worker 1 stops on its RELATION message
#
start relation 2 ep.x
check 'assignment' '0:ep.x 1:ep.a 1:ep.b 1:ep.c 1:ep.k 1:ep.r 1:ep.r1' \
      "$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" \
         "select group_concat(worker || ':' || nspname || '.' || relname, ' ') from (select * from wal_worker_table order by worker, relname)")"
sql "${SRC}" -c 'alter table ep.r attach partition ep.x for values from (1000000) to (2000000)' \
             -c "insert into ep.x values (1000001, 'attached')"
finish 60
x=$(sql "${SRC}" -c "select 'ep.x'::regclass::oid")
if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 124 ] ||
   ! grep -F "WAL worker 1 receives changes of table ep.x (oid ${x}), which is assigned to WAL worker 0" "${log}"; then
    fail "a table reaching two workers left exit ${rc}"
fi
sql "${SRC}" -c 'alter table ep.r detach partition ep.x'
cleanup
echo "OK a table that reaches two workers stops the run, exit ${rc}"

#
# a worker catalog that lost its assignment during the run: receive of worker
# 2 stops on its next RELATION message instead of taking every table
#
start norows 3 "${HT}"
sqlite3 -init /dev/null -batch -cmd '.timeout 10000' "${dir}/cdc/w2/source.db" \
        'delete from wal_worker_table'
sql "${SRC}" -c "insert into ep.c values (1301, 'w')"
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
finish 120
c=$(sql "${SRC}" -c "select 'ep.c'::regclass::oid")
if [ "${rc}" -eq 0 ] || [ "${rc}" -eq 124 ] ||
   ! grep -E "WAL worker 2 receives changes of table ep\.c \(oid ${c}\), and its catalog \".*/w2/source\.db\" assigns no table to any WAL worker" "${log}"; then
    fail "a worker catalog without assignment left exit ${rc}"
fi
cleanup
echo "OK a worker catalog without assignment stops the run, exit ${rc}"

#
# a partition created during the run is assigned to no worker: the worker of
# its partitioned table applies it, as one worker would
#
start partition 3 "${HT}"
part='create table ep.r2 partition of ep.r for values from (2000000) to (3000000)'
sql "${TGT}" -c "${part}"
sql "${SRC}" -c "${part}" \
             -c "insert into ep.r select i, 'new' from generate_series(2000001, 2000100) i" \
             -c "update ep.r set v = 'updated' where id between 2000001 and 2000010" \
             -c "delete from ep.r where id between 2000091 and 2000100" \
             -c "insert into ep.a values (1101, 'w')" -c "insert into ep.k values (1101, 'w')"
check 'worker of ep.r, and rows of ep.r2 in the assignment' '2:0' \
      "$(sqlite3 -readonly -init /dev/null -batch -noheader "${dir}/schema/source.db" \
         "select (select worker from wal_worker_table where relname = 'r') || ':' || (select count(*) from wal_worker_table where relname = 'r2')")"
e=$(flush_lsn)
pgcopydb stream sentinel set endpos --dir "${dir}" "${e}" > /dev/null
finish 120
[ "${rc}" -eq 0 ] || fail "a partition created during the run left exit ${rc}"
check 'rows of ep.r2 on the target' '90 10' \
      "$(sql "${TGT}" -F ' ' -c "select count(*), count(*) filter (where v = 'updated') from ep.r2")"
canary
pgcopydb compare data --dir /tmp/partition-compare > /tmp/partition-compare.log 2>&1 ||
    { cat /tmp/partition-compare.log; fail 'compare data after a new partition'; }
cleanup
echo "OK a partition created during the run reaches the worker of its partitioned table"

no_pgcopydb 'the suite'
