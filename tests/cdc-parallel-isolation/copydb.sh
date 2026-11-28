#! /bin/bash

# The apply session of performance mode pins its settings before the first
# BEGIN, whatever the target role defaults to, and an idle apply session keeps
# itself alive.  A trigger enabled ALWAYS records the settings of the session
# that applies each row; a third session holds a row lock past lock_timeout.

set -euo pipefail

TMPDIR=$(mktemp -d /tmp/pgcopydb-parallel-isolation.XXXXXX)
export TMPDIR
export XDG_DATA_HOME=${TMPDIR}/cdc
snapshot_pid='' follow_pid='' holder_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    test -z "${holder_pid}" || kill -TERM "${holder_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }
recorded() { target_sql "select coalesce(string_agg(format('%s:%s', id, pid), ',' order by id), '') from rec_settings"; }

pgcopydb ping
source_sql 'drop table if exists rec, l;
    create table rec (id integer primary key, note text);
    create table l (id integer primary key, n integer not null);
    insert into l values (1, 0)'

pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
snapshot_pid=$!
timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
kill -TERM "${snapshot_pid}"
wait "${snapshot_pid}"
snapshot_pid=
pgcopydb stream sentinel set apply

# transaction_isolation, not its default: a SET after BEGIN changes the default
# but leaves the open transaction at REPEATABLE READ
target_sql "create table rec_settings (id integer, pid integer, isolation text,
        sync_commit text, lock_timeout text, idle_in_txn text, idle_session text,
        txn_timeout text);
    create function rec_record() returns trigger language plpgsql as \$\$
    begin
        insert into rec_settings values (new.id, pg_backend_pid(),
            current_setting('transaction_isolation'),
            current_setting('synchronous_commit'),
            current_setting('lock_timeout'),
            current_setting('idle_in_transaction_session_timeout'),
            current_setting('idle_session_timeout'),
            current_setting('transaction_timeout', true));
        return new;
    end \$\$;
    create trigger rec_record after insert on rec for each row execute function rec_record();
    alter table rec enable always trigger rec_record"

# Every default is shorter than the quiet period or the lock hold below.
# transaction_timeout stays above the lock hold, so the holder keeps its lock.
target_version=$(target_sql 'show server_version_num')
target_sql "alter role postgres set default_transaction_isolation = 'repeatable read'"
target_sql "alter role postgres set synchronous_commit = off"
target_sql "alter role postgres set lock_timeout = '2s'"
target_sql "alter role postgres set idle_in_transaction_session_timeout = '3s'"
target_sql "alter role postgres set idle_session_timeout = '3s'"
if test "${target_version}" -ge 170000; then
    target_sql "alter role postgres set transaction_timeout = '12s'"
fi

# Without this the suite is vacuous: a plain new session must come up with the
# role settings, so that a pinned value in rec_settings can only be a pin.
want='repeatable read off 2s 3s 3s'
test "${target_version}" -lt 170000 || want="${want} 12s"
inherited=$(target_sql "select concat_ws(' ', current_setting('transaction_isolation'),
    current_setting('synchronous_commit'), current_setting('lock_timeout'),
    current_setting('idle_in_transaction_session_timeout'),
    current_setting('idle_session_timeout'), current_setting('transaction_timeout', true))")
test "${inherited}" = "${want}" ||
    fail "a new target session shows '${inherited}', expected '${want}' from the role settings"

# The first source transaction crosses a row that a third session holds on
# the target for four times the lock_timeout default.
source_sql "begin; insert into rec values (1, 'first'); update l set n = n + 1 where id = 1; commit"
psql -AtqX -d "${PGCOPYDB_TARGET_PGURI}" \
    -c 'begin' -c 'select id from l where id = 1 for update' -c 'select pg_sleep(8)' -c 'commit' \
    > "${TMPDIR}/holder.log" 2>&1 &
holder_pid=$!
timeout 30s bash -c "until test \"\$(psql -AtqX -d '${PGCOPYDB_TARGET_PGURI}' \
    -c \"select count(*) from pg_stat_activity where query = 'select pg_sleep(8)'\")\" = 1; do sleep 0.1; done" ||
    fail "the lock holder did not start within 30 s"

setsid pgcopydb follow --resume --not-consistent --notice > "${TMPDIR}/follow.log" 2>&1 &
follow_pid=$!

# the trigger row commits with the update behind the lock, so it shows after the wait
waited=0
deadline=$((SECONDS + 60))
until test -n "$(recorded)"; do
    kill -0 "${follow_pid}" 2>/dev/null || fail "follow exited before it applied the first transaction"
    test "${SECONDS}" -lt "${deadline}" || fail "the first transaction was not applied within 60 s"
    test "$(target_sql "select count(*) from pg_stat_activity
        where wait_event_type = 'Lock' and application_name like 'pgcopydb%'")" = 0 || waited=1
    sleep 0.2
done
wait "${holder_pid}" || fail "the lock holder failed: $(cat "${TMPDIR}/holder.log")"
holder_pid=
test "${waited}" = 1 || fail "apply never waited on the held lock, so lock_timeout went untested"
test "$(target_sql 'select n from l')" = 1 || fail "the update behind the held lock is missing"
apply_pid=$(target_sql 'select pid from rec_settings where id = 1')
echo "first transaction applied by backend ${apply_pid} after a lock wait"

# Quiet period: no source change for 40 s, every 15 s the apply session must
# show a new state_change.
last=$(target_sql "select state_change from pg_stat_activity where pid = ${apply_pid}")
moved=${SECONDS} moves=0
quiet_end=$((SECONDS + 40))
while test "${SECONDS}" -lt "${quiet_end}"; do
    kill -0 "${follow_pid}" 2>/dev/null || fail "follow exited during the quiet period"
    now=$(target_sql "select state_change from pg_stat_activity where pid = ${apply_pid}")
    test -n "${now}" || fail "apply session ${apply_pid} ended during the quiet period"
    if test "${now}" != "${last}"; then
        last=${now} moved=${SECONDS} moves=$((moves + 1))
    fi
    test $((SECONDS - moved)) -le 15 ||
        fail "apply session ${apply_pid} showed no activity for $((SECONDS - moved)) s, state_change ${last}"
    sleep 1
done
echo "quiet period: apply session ${apply_pid} moved state_change ${moves} times in 40 s"

source_sql "insert into rec values (2, 'after the quiet period')"
pgcopydb stream sentinel set endpos "$(source_sql 'select pg_current_wal_flush_lsn()')"
deadline=$((SECONDS + 120))
while kill -0 "${follow_pid}" 2>/dev/null; do
    test "${SECONDS}" -lt "${deadline}" || fail "follow did not exit at endpos within 120 s"
    sleep 0.2
done
rc=0
wait "${follow_pid}" || rc=$?
follow_pid=
test "${rc}" = 0 || fail "follow exited ${rc}"

target_sql 'table rec_settings'
test "$(recorded)" = "1:${apply_pid},2:${apply_pid}" ||
    fail "recorded rows $(recorded), expected 1:${apply_pid},2:${apply_pid}"
for col in isolation sync_commit lock_timeout idle_in_txn idle_session txn_timeout; do
    case "${col}" in
        isolation) want='read committed' ;;
        sync_commit) want=on ;;
        *) want=0 ;;
    esac
    bad=$(target_sql "select string_agg(format('row %s has %s', id, ${col}), ', ' order by id)
        from rec_settings where ${col} is distinct from '${want}'
        and not ('${col}' = 'txn_timeout' and ${target_version} < 170000)")
    test -z "${bad}" || fail "${col}: ${bad}, expected ${want}"
done

# names a run that took the SQLite path
test -n "$(find "${TMPDIR}" -name '*.seg' -print -quit)" ||
    fail "the work directory holds no .seg file: follow did not take the raw path"

pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
echo "PASS: apply pinned its session settings before the first BEGIN and kept backend ${apply_pid} alive through 40 s of quiet"
