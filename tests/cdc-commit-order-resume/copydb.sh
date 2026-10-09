#! /bin/bash

# Each case leaves the apply in a state where only commit order is right: an
# open newest BEGIN, a KEEPALIVE inside a transaction, a restart between two
# overlapping transactions, a kill while replay.db is written, a replay.db
# backlog above the target origin, a partial copy an older build left in
# replay.db, an output.db without o_begin, a replay.db that lost its last
# commits, and a replay.db without the partial indexes.

set -euo pipefail

src_base=${PGCOPYDB_SOURCE_PGURI%/*}
tgt_base=${PGCOPYDB_TARGET_PGURI%/*}
tc=setup
follow_pid= snapshot_pid=

cleanup() {
    local status=$? log
    trap - EXIT
    test -z "${follow_pid}" || kill -KILL -- "-${follow_pid}" 2>/dev/null || true
    test -z "${snapshot_pid}" || kill -TERM "${snapshot_pid}" 2>/dev/null || true
    if test "${status}" -ne 0; then
        for log in "${TMPDIR:-/nonexistent}"/*.log; do
            test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
        done
    fi
    exit "${status}"
}
trap cleanup EXIT

fail() { echo "FAIL [${tc}]: $*" >&2; exit 1; }
source_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "$1"; }
target_sql() { timeout 60s psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "$1"; }

pgcopydb ping

# one ctl session holds the dblink connections a and b across steps
psql -X -q -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c 'create database ctl'
psql -X -q -v ON_ERROR_STOP=1 -d "${src_base}/ctl" -c 'create extension dblink'
coproc CTL { psql -AtqX -v ON_ERROR_STOP=1 -d "${src_base}/ctl" 2>&1; }

ctl() {
    local marker="--done-${RANDOM}-${SECONDS}--" line out=
    printf '%s;\n\\echo %s\n' "$1" "${marker}" >&"${CTL[1]}"
    while IFS= read -r -t 60 line <&"${CTL[0]}"; do
        if test "${line}" = "${marker}"; then
            test -z "${out}" || echo "${out}"
            return 0
        fi
        out=${out:+${out}$'\n'}${line}
    done
    fail "ctl session ended or timed out on: $1${out:+ (${out})}"
}
on() { ctl "select dblink_exec('$1', \$q\$$2\$q\$)" > /dev/null; }
xid_of() { ctl "select x from dblink('$1', 'select txid_current()') t(x bigint)"; }
wal_lsn() { ctl "select pg_current_wal_flush_lsn()"; }

outdb() {
    local files=("${XDG_DATA_HOME}"/pgcopydb/*-"$1".db)
    test "${#files[@]}" -eq 1 -a -f "${files[0]}" || fail "expected one $1.db, found: ${files[*]}"
    echo "${files[0]}"
}
lite() { timeout 10s sqlite3 -init /dev/null -batch -noheader -list "$(outdb "$1")" "$2"; }
lsn_txt="printf('%X/%X', lsn >> 32, lsn & 4294967295)"
commit_of() { lite output "select ${lsn_txt} from output where action = 'C' and xid = $1"; }
last_commit() { lite output "select ${lsn_txt} from output where action = 'C' order by lsn desc limit 1"; }

count() { target_sql "select count(*) from $1"; }
origin() { target_sql "select pg_replication_origin_progress('pgcopydb', true)"; }

prefetch() {
    timeout 120s pgcopydb stream prefetch --resume --endpos "$1" --notice \
            >> "${TMPDIR}/prefetch.log" 2>&1 || fail "prefetch exited $?"
}

catchup() {
    local rc=0
    timeout 120s pgcopydb stream catchup --resume --endpos "$1" --notice \
            >> "${TMPDIR}/catchup.log" 2>&1 || rc=$?
    test "${rc}" -eq 0 || fail "catchup to $1 exited ${rc}"
}

drain() {
    pgcopydb stream sentinel set endpos --current
    timeout 120s pgcopydb follow --resume --not-consistent --notice \
            >> "${TMPDIR}/follow.log" 2>&1 || fail "follow exited $?"
}

# run catchup under gdb and kill it at the breakpoint given in $1
kill_catchup_at() {
    timeout 120s gdb -q -batch -ex "break $1" -ex "ignore 1 $2" \
        -x /usr/src/pgcopydb/kill-at.gdb \
        --args pgcopydb stream catchup --resume --endpos "$3" --notice \
        > "${TMPDIR}/gdb.log" 2>&1 || fail "gdb exited $?"
    grep -q '^KILLED-AT-BREAKPOINT$' "${TMPDIR}/gdb.log" || fail 'apply did not reach the breakpoint'
    local deadline=$((SECONDS + 60))
    until test "$(target_sql "select count(*) from pg_stat_activity
                               where datname = current_database() and pid <> pg_backend_pid()
                                 and backend_type = 'client backend'")" = 0; do
        test "${SECONDS}" -lt "${deadline}" || fail 'the killed apply session is still on the target'
        sleep 0.2
    done
}

compare() {
    local t sql
    for t in ta tb; do
        sql="copy (select * from ${t} order by id) to stdout"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" -c "${sql}" > "${TMPDIR}/src_${t}.txt"
        psql -X -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" -c "${sql}" > "${TMPDIR}/tgt_${t}.txt"
        test -s "${TMPDIR}/src_${t}.txt"
        diff "${TMPDIR}/src_${t}.txt" "${TMPDIR}/tgt_${t}.txt" || fail "table ${t} differs"
    done
}

begin_case() {
    tc=$1
    local db=co_${tc//-/_}
    export PGCOPYDB_SOURCE_PGURI=${src_base}/${db}
    export PGCOPYDB_TARGET_PGURI=${tgt_base}/${db}
    export TMPDIR=/tmp/co-${tc}
    export XDG_DATA_HOME=${TMPDIR}/cdc
    mkdir -p "${TMPDIR}"
    echo "=== ${tc}"

    psql -X -q -v ON_ERROR_STOP=1 -d "${src_base}/postgres" -c "create database ${db}"
    psql -X -q -v ON_ERROR_STOP=1 -d "${tgt_base}/postgres" -c "create database ${db}"
    source_sql 'create table ta (id integer primary key, v text); create table tb (id integer primary key, v text)'

    pgcopydb snapshot --follow > "${TMPDIR}/snapshot.out" 2> "${TMPDIR}/snapshot.log" &
    snapshot_pid=$!
    timeout 60s bash -c "until test -s '${TMPDIR}/snapshot.out'; do sleep 0.2; done"
    pgcopydb stream setup > "${TMPDIR}/setup.log" 2>&1
    pgcopydb clone > "${TMPDIR}/clone.log" 2>&1
    kill -TERM "${snapshot_pid}"
    wait "${snapshot_pid}"
    snapshot_pid=
    pgcopydb stream sentinel set apply

    ctl "select dblink_connect('a', 'dbname=${db}'), dblink_connect('b', 'dbname=${db}')" > /dev/null
}

end_case() {
    ctl "select dblink_disconnect('a'), dblink_disconnect('b')" > /dev/null
    compare
    # apply writes replay_lsn once a second, but at once when it exits
    local replay
    replay=$(timeout 15s pgcopydb stream sentinel get --replay-lsn)
    test "${replay}" = "$(origin)" || fail "sentinel replay_lsn ${replay} is not the origin $(origin)"
    pgcopydb stream cleanup > "${TMPDIR}/cleanup.log" 2>&1
    echo "PASS [${tc}]"
}

# A is open when receive stops at endpos, B committed inside A: the apply
# must apply B, leave A for later, and stop.
open_begin() {
    begin_case open-begin
    on a begin
    on a "insert into ta values (301, 'A first')"
    local xid_a xid_b endpos row
    xid_a=$(xid_of a)
    on b begin
    on b "insert into tb values (31, 'B')"
    xid_b=$(xid_of b)
    on b commit
    on a "insert into ta values (302, 'A at endpos')"
    endpos=$(ctl "select pg_current_wal_insert_lsn()")
    on a "insert into ta values (303, 'A after endpos')"
    on a "insert into ta values (304, 'A last')"
    on a commit

    prefetch "${endpos}"
    row=$(lite output "select
        (select max(id) from output where action = 'B') =
        (select max(id) from output where action = 'B' and xid = ${xid_a}),
        (select count(*) from output where action = 'C' and xid = ${xid_a}),
        (select lsn from output where action = 'B' and xid = ${xid_a}) <
        (select lsn from output where action = 'C' and xid = ${xid_b})")
    test "${row}" = '1|0|1' || fail "output.db does not hold A open, newest, below B's COMMIT: ${row}"

    catchup "${endpos}"
    test "$(count 'tb where id = 31')" = 1 || fail 'B, committed below endpos, was not applied'
    test "$(count 'ta where id > 300')" = 0 || fail 'part of the open A was applied'
    test "$(origin)" = "$(commit_of "${xid_b}")" || fail "origin $(origin) is not B's COMMIT"

    drain
    end_case
}

# A KEEPALIVE lands between A's BEGIN and COMMIT while B commits inside A.
keepalive_in_txn() {
    begin_case keepalive-in-txn
    setsid pgcopydb follow --resume --not-consistent --notice >> "${TMPDIR}/follow.log" 2>&1 &
    follow_pid=$!
    local xid_a xid_b deadline inside
    on a begin
    on a "insert into ta values (401, 'A first')"
    xid_a=$(xid_of a)
    on b begin
    on b "insert into tb values (41, 'B')"
    xid_b=$(xid_of b)
    on b commit

    # with A open, the walsender's keepalives carry an LSN above A's BEGIN
    ctl "select pg_logical_emit_message(false, 'co', 'wal past B')" > /dev/null
    deadline=$((SECONDS + 90))
    until test "$(lite output "select count(*) from output k
                    join output c on c.action = 'C' and c.xid = ${xid_b}
                   where k.action = 'K' and k.lsn > c.lsn" 2>/dev/null || echo 0)" -ge 1; do
        kill -0 "${follow_pid}" || fail 'follow exited while A was open'
        test "${SECONDS}" -lt "${deadline}" || fail 'no KEEPALIVE above B while A was open'
        sleep 0.5
    done
    on a "insert into ta values (402, 'A last')"
    on a commit
    on b "insert into tb values (42, 'after A')"

    pgcopydb stream sentinel set endpos --current
    deadline=$((SECONDS + 120))
    while kill -0 "${follow_pid}" 2>/dev/null; do
        test "${SECONDS}" -lt "${deadline}" || fail 'follow did not reach endpos'
        sleep 0.5
    done
    wait "${follow_pid}" || fail "follow exited $?"
    follow_pid=

    inside=$(lite output "select count(*) from output k
                join output b on b.action = 'B' and b.xid = ${xid_a}
                join output c on c.action = 'C' and c.xid = ${xid_a}
               where k.action = 'K' and k.lsn > b.lsn and k.lsn < c.lsn")
    test "${inside}" -ge 1 || fail 'no KEEPALIVE between A BEGIN and COMMIT'
    end_case
}

# The apply is killed after B, before A's COMMIT; A began below B's COMMIT,
# which is the origin on restart.  Grouped, B, A and the last transaction
# share one COMMIT, so a kill before it leaves none of them applied.
restart_interleaved() {
    begin_case restart-interleaved
    local xid_a xid_b end origin0
    on a begin
    on a "insert into ta values (501, 'A first')"
    xid_a=$(xid_of a)
    on b begin
    on b "insert into tb values (51, 'B')"
    xid_b=$(xid_of b)
    on b commit
    on a "insert into ta values (502, 'A last')"
    on a commit
    on b "insert into tb values (52, 'after A')"

    prefetch "$(wal_lsn)"
    end=$(last_commit)
    origin0=$(origin)
    PGCOPYDB_APPLY_GROUP_MS=60000 \
        kill_catchup_at "pgsql_replication_origin_xact_commit if \$_streq(origin_lsn, \"${end}\")" 0 "${end}"
    test "$(count 'tb where id > 50')" = 0 || fail 'part of the group was applied before the kill'
    test "$(count 'ta where id > 500')" = 0 || fail 'A was applied before the group kill'
    test "$(origin)" = "${origin0}" || fail "origin $(origin) moved before the group COMMIT"

    PGCOPYDB_APPLY_GROUP_TXNS=1 \
        kill_catchup_at "pgsql_replication_origin_xact_commit if \$_streq(origin_lsn, \"$(commit_of "${xid_a}")\")" 0 "${end}"
    test "$(count 'tb where id = 51')" = 1 || fail 'B was not applied before the kill'
    test "$(count 'ta where id > 500')" = 0 || fail 'A was applied before the kill'
    test "$(origin)" = "$(commit_of "${xid_b}")" || fail "origin $(origin) is not B's COMMIT"

    catchup "${end}"
    end_case
}

# The apply is killed while it writes T's rows to replay.db; the resumed run
# must apply T once.
replay_kill() {
    begin_case replay-kill
    local xid_t end rows
    on a begin
    on a "insert into ta values (601, 'T1')"
    xid_t=$(xid_of a)
    on a "insert into ta values (602, 'T2')"
    on a "insert into tb values (61, 'T3')"
    on a "insert into ta values (603, 'T4')"
    on a commit
    on b "insert into tb values (62, 'after T')"

    prefetch "$(wal_lsn)"
    end=$(last_commit)
    # BEGIN and T1 are written, T2 is next
    kill_catchup_at "ld_store_insert_replay_stmt if replayStmt->xid == ${xid_t}" 2 "${end}"
    rows=$(lite replay "select group_concat(action, '') from replay where xid = ${xid_t}")
    test -z "${rows}" || fail "a partial copy of T stayed in replay.db: ${rows}"
    test "$(count ta)" = 0 || fail 'T was applied before the kill'

    catchup "${end}"
    end_case
}

# replay.db holds overlapping transactions above an origin moved back, as
# after a target that lost its last commits.
replay_backlog() {
    begin_case replay-backlog
    local origin0 r end inverted
    origin0=$(origin)
    for r in 1 2; do
        on a begin
        on a "insert into ta values (70${r}, 'A${r} first')"
        on b begin
        on b "insert into tb values (70${r}, 'B${r}')"
        on b commit
        on a "insert into ta values (71${r}, 'A${r} last')"
        on a commit
    done
    on b "insert into tb values (799, 'last')"

    prefetch "$(wal_lsn)"
    end=$(last_commit)
    catchup "${end}"
    compare

    target_sql "select pg_replication_origin_advance('pgcopydb', '${origin0}')" > /dev/null
    target_sql 'delete from ta where id >= 700; delete from tb where id >= 700'
    inverted=$(lite replay "select count(*) from replay x join replay y
                             on x.action = 'B' and y.action = 'B'
                            and x.lsn < y.lsn and x.endlsn > y.endlsn")
    test "${inverted}" -eq 2 || fail "replay.db holds ${inverted} overlapping pairs, expected 2"

    catchup "${end}"
    end_case
}

# An older build wrote replay.db rows one statement at a time, so a kill could
# leave a partial copy of T after a full one.  The apply must wait for the
# transform to write T again, and read that copy alone.
old_partial() {
    begin_case old-partial
    local origin0 xid_t end rows
    origin0=$(origin)
    on a begin
    on a "insert into ta values (901, 'T1')"
    xid_t=$(xid_of a)
    on a "insert into tb values (92, 'T2')"
    on a commit
    on b "insert into tb values (91, 'after T')"

    prefetch "$(wal_lsn)"
    end=$(last_commit)
    catchup "${end}"
    compare

    target_sql "select pg_replication_origin_advance('pgcopydb', '${origin0}')" > /dev/null
    target_sql 'delete from ta where id >= 900; delete from tb where id >= 90'
    lite replay "insert into replay (action, xid, lsn, endlsn, timestamp, nspname, relname, stmt_hash, stmt_args)
                 select action, xid, lsn, endlsn, timestamp, nspname, relname, stmt_hash, stmt_args
                   from replay
                  where xid = ${xid_t}
                    and id <= (select min(id) from replay where xid = ${xid_t} and action = 'I')
               order by id"
    rows=$(lite replay "select group_concat(action, '') from (select action from replay where xid = ${xid_t} order by id)")
    test "${rows}" = BIICBI || fail "replay.db rows of T are ${rows}, expected BIICBI"

    catchup "${end}"
    rows=$(lite replay "select group_concat(action, '') from (select action from replay where xid = ${xid_t} order by id)")
    test "${rows}" = BIICBIBIIC || fail "the apply did not wait for a new copy of T: ${rows}"
    end_case
}

# An output.db written before o_begin existed gets it when receive opens it.
obegin_upgrade() {
    begin_case obegin-upgrade
    local plan
    on a "insert into ta values (801, 'one')"
    prefetch "$(wal_lsn)"
    lite output 'drop index if exists o_begin'
    plan=$(lite output "explain query plan select max(id) from output where action = 'B'")
    echo "plan without o_begin: ${plan}"
    ! grep -q 'INDEX o_begin' <<<"${plan}" || fail 'o_begin is still there before receive opens the file'
    on b "insert into tb values (82, 'two')"
    prefetch "$(wal_lsn)"
    plan=$(lite output "explain query plan select max(id) from output where action = 'B'")
    echo "plan after receive opened the file: ${plan}"
    grep -q 'INDEX o_begin' <<<"${plan}" || fail 'receive did not create o_begin'
    catchup "$(last_commit)"
    end_case
}

# byte offset just past the first commit frame of the SQLite WAL file $1
wal_first_commit_end() {
    local page off size
    page=$(od -An -tu1 -j8 -N4 "$1" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
    size=$(stat -c %s "$1")
    off=32
    while test $((off + 24 + page)) -le "${size}"; do
        off=$((off + 24 + page))
        if test "$(od -An -tu1 -j$((off - 24 - page + 4)) -N4 "$1" | tr -d ' \n')" != 0000; then
            echo "${off}"
            return 0
        fi
    done
    return 1
}

# replay.db runs with synchronous=NORMAL, so power loss can drop its last
# commits.  Apply is killed before T5's COMMIT, then replay.db keeps only the
# first commit of its WAL (truncate) or none (delete).  The resumed apply must
# transform T5 and T6 again.
# T1 to T4 must each commit alone for the kill to fall between them and T5.
replay_wal_loss() {
    begin_case "replay-wal-$1"
    local i xid end db
    on a "insert into ta values (1000, 'checkpointed')"
    on b "insert into tb values (1000, 'compare needs a row')"
    prefetch "$(wal_lsn)"
    catchup "$(last_commit)"
    # pgcopydb commits the schema with a full sync: only later commits may go
    lite replay 'pragma wal_checkpoint(truncate)' > /dev/null
    for i in 1 2 3 4 5 6; do
        on a begin
        on a "insert into ta values (100${i}, 'T${i}')"
        test "${i}" != 5 || xid=$(xid_of a)
        on a commit
    done

    prefetch "$(wal_lsn)"
    end=$(last_commit)
    PGCOPYDB_APPLY_GROUP_TXNS=1 \
        kill_catchup_at "pgsql_replication_origin_xact_commit if \$_streq(origin_lsn, \"$(commit_of "${xid}")\")" 0 "${end}"
    test "$(count 'ta where id > 1000')" = 4 || fail 'T1 to T4 were not applied before the kill'

    db=$(outdb replay)
    test -s "${db}-wal" || fail 'the killed apply left no replay.db WAL'
    rm -f "${db}-shm"
    case "$1" in
        truncate) truncate -s "$(wal_first_commit_end "${db}-wal")" "${db}-wal" ;;
        delete) rm "${db}-wal" ;;
    esac
    test "$(lite replay "select count(*) from replay where xid = ${xid}")" = 0 ||
        fail 'T5 is still in replay.db'

    catchup "${end}"
    test "$(origin)" = "${end}" || fail "origin $(origin) is not the last COMMIT ${end}"
    end_case
}

# A replay.db written before the partial indexes existed gets them when apply
# opens it, and the next-event lookups use them.
replay_index_upgrade() {
    begin_case replay-index-upgrade
    local plan i
    on a "insert into ta values (1101, 'one')"
    prefetch "$(wal_lsn)"
    catchup "$(last_commit)"
    lite replay 'drop index r_end; drop index r_k; drop index r_begin; drop index r_end_xid'
    on b "insert into tb values (111, 'two')"
    prefetch "$(wal_lsn)"
    catchup "$(last_commit)"
    plan=$(lite replay "explain query plan select max(id) from replay where action = 'B' and xid = 1;
                        explain query plan select id from replay where action in ('C', 'R') and lsn > 1 order by lsn limit 1;
                        explain query plan select id from replay where action = 'K' and lsn > 1 order by lsn limit 1;
                        explain query plan select min(id) from replay where xid = 1 and action in ('C', 'R') and id > 1")
    echo "plans after apply opened the file: ${plan}"
    for i in r_begin r_end r_k r_end_xid; do
        grep -q "INDEX ${i} " <<<"${plan}" || fail "apply did not create or use ${i}"
    done
    end_case
}

for c in ${CASE:-all}; do
    case "${c}" in
        all) open_begin; keepalive_in_txn; restart_interleaved; replay_kill; replay_backlog; old_partial; obegin_upgrade
             replay_wal_loss truncate; replay_wal_loss delete; replay_index_upgrade ;;
        open-begin) open_begin ;;
        keepalive-in-txn) keepalive_in_txn ;;
        restart-interleaved) restart_interleaved ;;
        replay-kill) replay_kill ;;
        replay-backlog) replay_backlog ;;
        old-partial) old_partial ;;
        obegin-upgrade) obegin_upgrade ;;
        replay-wal-truncate) replay_wal_loss truncate ;;
        replay-wal-delete) replay_wal_loss delete ;;
        replay-index-upgrade) replay_index_upgrade ;;
        *) fail "unknown case ${c}" ;;
    esac
done
