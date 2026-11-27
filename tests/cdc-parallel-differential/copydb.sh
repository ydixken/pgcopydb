#! /bin/bash

# A seeded mixed workload, applied by one worker, must leave the target equal
# to the source by row hash and by pgcopydb compare data.
#
# CDC_DIFFERENTIAL_CASES picks what runs:
#
#   sqlite       one follow in sqlite mode, the default
#   performance  one follow in performance mode
#   cross        both, over one source history, and their row hashes compared
#
# The cross case is what ties performance mode to the sqlite path for TRUNCATE
# and for every other class of the mix that apply.sql pins nowhere, so it
# leaves out what the two modes differ on by design: the definition change
# during follow.  Both of its follows read the same source history from their
# own slot, which is a stronger input than replaying the workload twice: the
# two runs then differ in the mode and in nothing else.

set -euo pipefail

CASES=${CDC_DIFFERENTIAL_CASES:-sqlite}
CLIENTS=${CDC_DIFFERENTIAL_CLIENTS:-16}
TXNS=${CDC_DIFFERENTIAL_TXNS:-120}

case "${CASES}" in
    sqlite)      modes=(sqlite) ;;
    performance) modes=(performance) ;;
    cross)       modes=(sqlite performance) ;;
    *) echo "FAIL: CDC_DIFFERENTIAL_CASES is ${CASES}, expected sqlite, performance or cross" >&2
       exit 1 ;;
esac
add_column=${CDC_DIFFERENTIAL_ADD_COLUMN:-0}

# A class that an open Track 0 item breaks on the SQLite path belongs here, so
# that the cross case names what it did not cover.  No class is left out today.
skipped_classes='none'

TMPROOT=$(mktemp -d /tmp/pgcopydb-parallel-differential.XXXXXX)
SRC=${PGCOPYDB_SOURCE_PGURI}
ADMIN=${PGCOPYDB_TARGET_PGURI}
TGT_BASE=${PGCOPYDB_TARGET_PGURI%/*}
FILTERS=/usr/src/pgcopydb/filters.ini
snapshot_pid='' follow_pid=''
client_pids=()

cleanup() {
    local status=$? pid
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    for pid in ${client_pids[@]+"${client_pids[@]}"}; do
        kill -TERM "${pid}" 2>/dev/null || true
    done
    if test "${status}" -ne 0; then
        for log in "${TMPROOT}"/*.log "${TMPROOT}"/*/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
q() { timeout 300s psql -AtqX -v ON_ERROR_STOP=1 -d "$1" -c "$2"; }
src_sql() { q "${SRC}" "$1"; }
tgt_uri() { echo "${TGT_BASE}/diff_$1"; }
sums() { timeout 300s psql -AtqX -v ON_ERROR_STOP=1 -d "$1" -f /usr/src/pgcopydb/sums.sql; }
segs() { find "$1" -name '*.seg' -print -quit; }

# case_env <mode>: the environment that every pgcopydb command of a case runs
# under.  The work directory comes from TMPDIR and not from --dir, because
# stream sentinel takes no --dir and still needs one.  The mode is set per
# command, because one script runs both.
case_env() {
    printf '%s\n' "PGCOPYDB_TARGET_PGURI=$(tgt_uri "$1")" \
        "TMPDIR=${TMPROOT}/$1" "XDG_DATA_HOME=${TMPROOT}/$1/cdc"
    test "$1" = sqlite || printf '%s\n' 'PGCOPYDB_FOLLOW_MODE=performance'
}

pgcopydb ping
psql -AtqX -v ON_ERROR_STOP=1 -d "${SRC}" -f /usr/src/pgcopydb/schema.sql \
    > "${TMPROOT}/schema.log" 2>&1 || fail "the source schema failed: $(cat "${TMPROOT}/schema.log")"

for c in $(seq 1 "${CLIENTS}"); do
    psql -AtqX -v ON_ERROR_STOP=1 -d "${SRC}" -v "client=${c}" -v "txns=${TXNS}" \
        -o "${TMPROOT}/client-${c}.sql" -f /usr/src/pgcopydb/generate.sql \
        > "${TMPROOT}/generate-${c}.log" 2>&1 ||
        fail "client ${c}: the generator failed: $(cat "${TMPROOT}/generate-${c}.log")"
    lines=$(grep -c '^begin; ' "${TMPROOT}/client-${c}.sql" || true)
    test "${lines}" = "${TXNS}" ||
        fail "client ${c}: the generator wrote ${lines} transactions, expected ${TXNS}"
done
echo "generated ${CLIENTS} client scripts of ${TXNS} transactions each"

# Both cases take their consistent point before the workload starts, so they
# see the same source history from their own slot.
for mode in "${modes[@]}"; do
    dir=${TMPROOT}/${mode}
    mkdir -p "${dir}"
    mapfile -t e < <(case_env "${mode}")
    q "${ADMIN}" "drop database if exists diff_${mode}"
    q "${ADMIN}" "create database diff_${mode}"
    env "${e[@]}" pgcopydb snapshot --follow --slot-name "s_${mode}" \
        > "${dir}/snapshot.out" 2> "${dir}/snapshot.log" &
    snapshot_pid=$!
    timeout 120s bash -c "until test -s '${dir}/snapshot.out'; do sleep 0.2; done" ||
        fail "${mode}: snapshot exported nothing within 120 s"
    env "${e[@]}" pgcopydb stream setup --slot-name "s_${mode}" \
        > "${dir}/setup.log" 2>&1 || fail "${mode}: stream setup failed"
    env "${e[@]}" pgcopydb clone --filters "${FILTERS}" \
        > "${dir}/clone.log" 2>&1 || fail "${mode}: clone failed"
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}" || true
    snapshot_pid=
    env "${e[@]}" pgcopydb stream sentinel set apply \
        > "${dir}/sentinel.log" 2>&1 || fail "${mode}: stream sentinel set apply failed"
    test "$(q "$(tgt_uri "${mode}")" 'select count(*) from d_excluded')" = 0 ||
        fail "${mode}: the clone copied d_excluded, which the filters exclude from the data"
    echo "${mode}: cloned into diff_${mode} on slot s_${mode}, d_excluded left empty"
done
test "$(src_sql 'select count(*) from d_excluded')" = 50 ||
    fail "the source lost d_excluded rows, so the filter check above is vacuous"

for c in $(seq 1 "${CLIENTS}"); do
    psql -AtqX -d "${SRC}" -f "${TMPROOT}/client-${c}.sql" \
        > "${TMPROOT}/client-${c}.log" 2>&1 &
    client_pids+=($!)
done

if test "${add_column}" = 1; then
    # mid-stream, so apply meets a RELATION message whose column list grew
    half=$(( CLIENTS * TXNS / 2 ))
    deadline=$((SECONDS + 600))
    until test "$(src_sql 'select count(*) from d_oplog')" -ge "${half}"; do
        test "${SECONDS}" -lt "${deadline}" || fail "the workload did not reach ${half} transactions in 600 s"
        sleep 0.5
    done
    for mode in "${modes[@]}"; do
        q "$(tgt_uri "${mode}")" 'alter table d_altered add column extra int'
    done
    src_sql 'alter table d_altered add column extra int'
    src_sql "insert into d_altered (id, v, extra) values (nextval('d_seq'), 0, 42)"
    echo "added d_altered.extra on the source and on every target, mid-workload"
fi

for pid in "${client_pids[@]}"; do wait "${pid}" || true; done
client_pids=()

bad=$(grep -h '^ERROR' "${TMPROOT}"/client-*.log | sort -u | head -n 5 || true)
test -z "${bad}" || fail "a workload client failed: ${bad}"

committed=$(src_sql 'select count(*) from d_oplog')
test "${committed}" = "$(( CLIENTS * TXNS ))" ||
    fail "the source holds ${committed} workload transactions, expected $(( CLIENTS * TXNS ))"
missing=$(src_sql "select coalesce(string_agg(c, ',' order by c), '') from
    (values ('keyed-upsert'), ('keyed-update'), ('keyed-keychange'), ('keyed-del-ins'),
            ('full-key-update'), ('nokey-dup-insert'), ('nokey-update'), ('nokey-delete'),
            ('deferrable'), ('using-index'), ('ts-key'), ('secondary'), ('partition-move'),
            ('toast'), ('hot'), ('multi-table'), ('large'), ('truncate'), ('altered')) v(c)
    where not exists (select 1 from d_oplog o where o.cls = v.c)")
test -z "${missing}" || fail "the workload never reached these classes: ${missing}"
echo "workload committed ${committed} transactions over every class of the mix"

endpos=$(src_sql 'select pg_current_wal_flush_lsn()')
echo "endpos ${endpos}, set after the last client committed"

for mode in "${modes[@]}"; do
    dir=${TMPROOT}/${mode}
    mapfile -t e < <(case_env "${mode}")
    env "${e[@]}" pgcopydb stream sentinel set endpos "${endpos}" \
        > "${dir}/endpos.log" 2>&1 || fail "${mode}: stream sentinel set endpos failed"
    setsid env "${e[@]}" pgcopydb follow --resume --not-consistent --slot-name "s_${mode}" --notice > "${dir}/follow.log" 2>&1 &
    follow_pid=$!
    deadline=$((SECONDS + 600))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail "${mode}: follow did not exit at endpos within 600 s"
        sleep 0.5
    done
    rc=0
    wait "${follow_pid}" || rc=$?
    follow_pid=
    test "${rc}" = 0 || fail "${mode}: follow exited ${rc}"

    if test "${mode}" = sqlite; then
        test -z "$(segs "${dir}")" ||
            fail "sqlite: the work directory holds $(segs "${dir}"), so the run took the raw path"
    else
        test -n "$(segs "${dir}")" ||
            fail "performance: the work directory holds no .seg file, so the run took the SQLite path"
    fi

    sums "${SRC}" > "${TMPROOT}/sums-source-${mode}.txt"
    sums "$(tgt_uri "${mode}")" > "${TMPROOT}/sums-${mode}.txt"
    diff -u "${TMPROOT}/sums-source-${mode}.txt" "${TMPROOT}/sums-${mode}.txt" ||
        fail "${mode}: the target differs from the source, see the table names above"
    test -s "${TMPROOT}/sums-${mode}.txt" || fail "${mode}: the row hash list is empty"
    # compare data reads the stored filters but still compares a table whose
    # data exclude-table-data kept off the target, so d_excluded differs and
    # nothing is allowed to join it
    env "${e[@]}" pgcopydb compare data > "${dir}/compare.log" 2>&1 || true
    # the pattern needs the qualified name, or it counts the table header too
    marked='^ *[a-z_][a-z_0-9]*\.[a-z_0-9]*\.[a-z_0-9]* | ! | '
    differing=$(grep -c "${marked}" "${dir}/compare.log" || true)
    test "${differing}" = 1 ||
        { grep "${marked}" "${dir}/compare.log" || true
          fail "${mode}: pgcopydb compare data found ${differing} differing tables, expected only d_excluded"; }
    grep -q '\.d_excluded | ! | ' "${dir}/compare.log" ||
        fail "${mode}: pgcopydb compare data differs on another table than d_excluded"
    echo "${mode}: $(wc -l < "${TMPROOT}/sums-${mode}.txt") tables equal to the source, compare data differs on d_excluded alone"
done

if test "${CASES}" = cross; then
    diff -u "${TMPROOT}/sums-sqlite.txt" "${TMPROOT}/sums-performance.txt" ||
        fail "the two modes left different target data, see the table names above"
    echo "cross-mode check: the two modes left the same target data, classes left out: ${skipped_classes}"
fi

for mode in "${modes[@]}"; do
    mapfile -t e < <(case_env "${mode}")
    env "${e[@]}" pgcopydb stream cleanup --slot-name "s_${mode}" \
        > "${TMPROOT}/${mode}/cleanup.log" 2>&1 || fail "${mode}: stream cleanup failed"
done

echo "PASS: ${CASES} on ${committed} transactions, modes ${modes[*]}"
