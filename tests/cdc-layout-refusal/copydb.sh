#! /bin/bash

# A work directory belongs to the mode that started it.  The binary of
# 9d8b660 must resume what this binary writes without a mode, this binary
# without a mode must resume what 9d8b660 wrote, and performance mode must
# refuse that directory before it changes anything in it.
#
# Case refuse reads the refusal that a mode mismatch produces.
# Case perfdir is not in the default list: it leaves the replication slot of
# the case before it in place, and its snapshot --follow then fails on a slot
# that already exists.  Run it alone with CASE=perfdir.

set -euo pipefail

NEW=pgcopydb
OLD=pgcopydb-9d8b660
BAD_ARGS=1
REFUSAL='Refusing the work directory: '
tc=one

on_exit() {
    local status=$?
    trap - EXIT
    pkill -KILL -x pgcopydb 2> /dev/null || true
    pkill -KILL -x "${OLD}" 2> /dev/null || true
    exit "${status}"
}
trap on_exit EXIT

fail() {
    local log
    for log in "/tmp/${tc}"/*.log; do
        test ! -f "${log}" || { echo "==> ${log}"; tail -n 40 "${log}"; }
    done
    echo "FAIL [${tc}]: $*" >&2
    exit 1
}

src() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" "$@"; }
tgt() { timeout 60s psql -X -q -At -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" "$@"; }
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}" || fail "${1}"; }
lite() { timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "$1" "$2"; }

rows() { tgt -c "select coalesce(string_agg(id::text, ',' order by id), 'none') from t"; }
rows_are() { test "$(rows)" = "$1"; }
source_rows() { src -c "select string_agg(id::text, ',' order by id) from t"; }

begin_case() {
    tc=$1
    mkdir -p "/tmp/${tc}"
    echo "=== ${tc}"
}

# record <dir>: the three facts a refused run must leave as they are, which
# are the slot position, the sentinel row and every file of the directory
record() {
    src -c "select slot_name, confirmed_flush_lsn from pg_replication_slots where slot_name = 'pgcopydb'"
    lite "$1/schema/source.db" 'select * from sentinel'
    (cd "$1" && find . -type f ! -name '*.pid' ! -name '*-shm' ! -name '*-wal' | sort |
        while read -r f; do
            case ${f} in
                *.db) echo "${f} $(lite "${f}" .dump | sha256sum | cut -c1-16)" ;;
                *) echo "${f} $(sha256sum < "${f}" | cut -c1-16)" ;;
            esac
        done)
}

segs() { find "$1" -name '*.seg' | wc -l | tr -d ' '; }

# until_true <seconds> <what> <command...>: the loop re-runs the command, and
# the caller expanded every argument once, so the command has to read the
# state again itself.  A comparison of expanded words cannot, and the wait
# would report the deadline instead of the condition, so it is refused here.
until_true() {
    local deadline=$((SECONDS + $1)) what=$2 op=''
    shift 2
    case $1 in test | '[') op=${3-} ;; esac
    case ${op} in
        = | == | != | -eq | -ne | -lt | -le | -gt | -ge)
            fail "until_true got a frozen comparison: $*" ;;
    esac
    until "$@"; do
        test "${SECONDS}" -lt "${deadline}" || fail "${what}"
        sleep 0.5
    done
}

settled() { test "$(src -c 'select count(*) from pg_replication_slots where active')" = 0; }
setup_rows() { lite "$1/schema/source.db" 'select count(*) from wal_worker_setup'; }

# expect <code> <message> <log> <command...>
expect() {
    local want=$1 msg=$2 log=/tmp/${tc}/$3.log rc=0
    shift 3
    timeout -k 5 300 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne "${want}" ] || ! grep -qF -- "${msg}" "${log}"; then
        cat "${log}"
        fail "want exit ${want} and \"${msg}\", got exit ${rc}: $*"
    fi
    echo "OK exit ${rc}: $*"
}

# run <log> <command...>: the command must exit 0 and must not refuse the
# work directory for its mode
run() {
    local log=/tmp/${tc}/$1.log rc=0
    shift
    timeout -k 5 300 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne 0 ]; then
        cat "${log}"
        fail "exit ${rc}: $*"
    fi
    if grep -qF -- "${REFUSAL}" "${log}"; then
        grep -F -- "${REFUSAL}" "${log}"
        fail "refused the work directory: $*"
    fi
    echo "OK exit 0: $*"
}

# seed: a table with three rows before the clone.  The clone restores the
# source publication onto the target, and stream cleanup drops it on the
# source only, so the target keeps the one of the case before.
seed() {
    src -c 'drop publication if exists pgcopydb'
    tgt -c 'drop publication if exists pgcopydb'
    src -c 'drop table if exists t, u'
    tgt -c 'drop table if exists t, u'
    src -c 'create table t (id integer primary key, v text)'
    # two WAL workers need two published tables to assign
    src -c 'create table u (id integer primary key)'
    src -c "insert into t select g, 'before' from generate_series(1, 3) g"
    src -c 'insert into u select generate_series(1, 3)'
}

# prefetch <binary> <dir> [workers]: a clone and a prefetch that acknowledges
# three more transactions without applying them.  The snapshot output is
# removed first: a file left behind would end the wait before this snapshot
# exported anything, and the SIGTERM below would interrupt its setup.
# Only clone --follow and follow take --wal-workers, so the worker count of
# the other commands travels in the environment.
prefetch() {
    local bin=$1 dir=$2 workers=${3:-1} snap_pid deadline endpos
    local w=(env "PGCOPYDB_WAL_WORKERS=${workers}")
    rm -f "/tmp/${tc}/snapshot.out"
    "${w[@]}" "${bin}" snapshot --follow --dir "${dir}" \
        > "/tmp/${tc}/snapshot.out" 2> "/tmp/${tc}/snapshot.log" &
    snap_pid=$!
    deadline=$((SECONDS + 120))
    until test -s "/tmp/${tc}/snapshot.out"; do
        kill -0 "${snap_pid}" 2> /dev/null ||
            { cat "/tmp/${tc}/snapshot.log"; fail 'snapshot --follow exited'; }
        test "${SECONDS}" -lt "${deadline}" || fail 'snapshot --follow printed no snapshot'
        sleep 0.2
    done
    run setup "${w[@]}" "${bin}" stream setup --dir "${dir}"
    # the plain clone refuses a worker count: it takes no --follow
    run clone "${bin}" clone --dir "${dir}"
    kill -TERM "${snap_pid}"
    wait "${snap_pid}" || true

    src -c "insert into t select g, 'after' from generate_series(4, 6) g"
    endpos=$(src -c 'select pg_current_wal_insert_lsn()')
    run prefetch "${w[@]}" "${bin}" stream prefetch --resume --endpos "${endpos}" --dir "${dir}"
    # the clone copied rows 1 to 3; the prefetch acknowledged 4 to 6
    # without applying them
    check 'rows on the target after the prefetch' 1,2,3 "$(rows)"
}

# resume_to_source <binary> <dir> <tag> [workers]: apply what is in the
# directory and
# everything after it, and end equal to the source
resume_to_source() {
    local bin=$1 dir=$2 tag=$3 workers=${4:-1} endpos
    run "${tag}-apply" "${bin}" stream sentinel set apply --dir "${dir}"
    endpos=$(src -c 'select pg_current_wal_insert_lsn()')
    # --dir comes before the position: getopt stops at the first operand
    run "${tag}-endpos" "${bin}" stream sentinel set endpos --dir "${dir}" "${endpos}"
    run "${tag}" "${bin}" clone --follow --resume --not-consistent \
        --dir "${dir}" --wal-workers "${workers}"
    check "${tag}: the target holds the source rows" "$(source_rows)" "$(rows)"
}

#
# one: a 9d8b660 directory at one worker, read and resumed by this binary
#
one() {
    begin_case one
    local dir=/tmp/one/pgcopydb

    seed
    prefetch "${OLD}" "${dir}"
    record "${dir}" > /tmp/one/record.txt
    check 'setup rows of a 9d8b660 directory' 0 "$(setup_rows "${dir}")"
    check 'segments of a 9d8b660 directory' 0 "$(segs "${dir}")"
    cp -a "${dir}" /tmp/one/copy

    # the read commands of this binary answer on that layout.  They are not
    # held to "nothing changed": list progress opens the catalog read write
    # and records its own timing, which is the behaviour of 9d8b660 too.
    run sentinel-get "${NEW}" stream sentinel get --dir "${dir}"
    run list-progress "${NEW}" list progress --dir "${dir}"

    # the Migration in flight: this binary without a mode resumes it
    resume_to_source "${NEW}" "${dir}" resume

    # the remedy of the refusal works on that layout too
    expect 0 'Dropping replication origin' cleanup "${NEW}" stream cleanup --dir /tmp/one/copy
    check 'objects left after the cleanup' '0|0' \
          "$(src -c "select count(*) from pg_replication_slots where slot_name = 'pgcopydb'")|$(src -c "select count(*) from pg_publication where pubname = 'pgcopydb'")"
    echo "PASS [${tc}]"
}

#
# two: the same at two WAL workers, where performance mode is refused for the
# worker count before it reads the layout
#
two() {
    begin_case two
    local dir=/tmp/two/pgcopydb before pid

    # Neither snapshot nor stream setup takes a worker count, so the N slot
    # setup of 9d8b660 is written by its own clone --follow.  It is stopped
    # with a signal and not with an endpos, because one endpos across N
    # workers is what cdc-wal-workers-endpos covers, not this suite.
    seed
    setsid "${OLD}" clone --follow --wal-workers 2 --not-consistent --dir "${dir}" \
        > /tmp/two/clone-follow.log 2>&1 &
    pid=$!
    src -c "insert into t select g, 'after' from generate_series(4, 6) g"
    until_true 240 'the 9d8b660 follow at two workers did not apply the later rows' \
               rows_are 1,2,3,4,5,6
    kill -TERM -- "-${pid}" 2> /dev/null || true
    wait "${pid}" || true
    until_true 120 'the replication slots stayed active after the follow stopped' settled

    check 'the setup row of a two worker directory' 2 \
          "$(lite "${dir}/schema/source.db" 'select workers from wal_worker_setup')"
    before=$(record "${dir}")

    expect "${BAD_ARGS}" 'Option --follow-mode performance requires --wal-workers 1, found --wal-workers 2' \
           two-workers env PGCOPYDB_FOLLOW_MODE=performance "${NEW}" clone --follow \
           --resume --not-consistent --dir "${dir}" --wal-workers 2
    check 'the refused run changed the directory' "${before}" "$(record "${dir}")"
    check 'segments after the refused run' 0 "$(segs "${dir}")"

    src -c "insert into t select g, 'later' from generate_series(7, 9) g"
    resume_to_source "${NEW}" "${dir}" resume 2
    expect 0 'Dropping replication origin' cleanup "${NEW}" stream cleanup --dir "${dir}"
    echo "PASS [${tc}]"
}

#
# nine: the other direction.  A directory this binary wrote without a mode
# carries no tag, so 9d8b660 resumes it.
#
nine() {
    begin_case nine
    local dir=/tmp/nine/pgcopydb

    seed
    prefetch "${NEW}" "${dir}"
    check 'setup rows of a directory written without a mode' 0 "$(setup_rows "${dir}")"
    resume_to_source "${OLD}" "${dir}" resume-old
    expect 0 'Dropping replication origin' cleanup "${OLD}" stream cleanup --dir "${dir}"
    echo "PASS [${tc}]"
}

#
# refuse: performance mode must refuse a 9d8b660 directory, in each of the
# eight commands, with nothing in the directory changed.
#
refuse() {
    begin_case refuse
    local dir=/tmp/refuse/pgcopydb before lsn name args

    seed
    prefetch "${OLD}" "${dir}"
    before=$(record "${dir}")
    lsn=$(src -c 'select pg_current_wal_insert_lsn()')

    while IFS='|' read -r name args; do
        # shellcheck disable=SC2086
        expect 3 "${REFUSAL}" "refused-${name// /-}" \
               env TMPDIR=/tmp/refuse PGCOPYDB_FOLLOW_MODE=performance "${NEW}" ${args} --dir "${dir}"
        check "the refused ${name} changed the directory" "${before}" "$(record "${dir}")"
        check "segments after the refused ${name}" 0 "$(segs "${dir}")"
    done <<LIST
clone --follow|clone --follow --resume --not-consistent --endpos ${lsn}
follow|follow --resume --not-consistent --endpos ${lsn}
snapshot --follow|snapshot --follow
stream receive|stream receive --resume --endpos ${lsn}
stream prefetch|stream prefetch --resume --endpos ${lsn}
stream catchup|stream catchup --resume --endpos ${lsn}
stream replay|stream replay --resume --endpos ${lsn}
stream apply|stream apply --resume
LIST
    echo "PASS [${tc}]"
}

#
# perfdir: a directory that performance mode wrote is refused by this binary
# without a mode, with the mode line and not with the setup line, and
# 9d8b660 refuses it for its stored setup.
#
perfdir() {
    begin_case perfdir
    local dir=/tmp/perfdir/pgcopydb before lsn

    seed
    PGCOPYDB_FOLLOW_MODE=performance prefetch "${NEW}" "${dir}"
    check 'the tag of a performance directory' performance \
          "$(lite "${dir}/schema/source.db" 'select high_traffic from wal_worker_setup')"
    before=$(record "${dir}")
    lsn=$(src -c 'select pg_current_wal_insert_lsn()')
    cp -a "${dir}" /tmp/perfdir/copy

    # the mode check answers first, so the setup check never reports
    expect 3 "${REFUSAL}" sqlite-clone "${NEW}" clone --follow --resume \
           --not-consistent --endpos "${lsn}" --dir "${dir}"
    grep -qF 'an earlier attempt set up' /tmp/perfdir/sqlite-clone.log &&
        fail 'the setup check answered before the mode check'
    expect 3 "${REFUSAL}" sqlite-follow "${NEW}" follow --resume \
           --not-consistent --endpos "${lsn}" --dir "${dir}"
    expect 6 'an earlier attempt set up' old-clone "${OLD}" clone --follow --resume \
           --not-consistent --endpos "${lsn}" --dir "${dir}"
    check 'the refused runs changed the directory' "${before}" "$(record "${dir}")"

    run sentinel-endpos "${NEW}" stream sentinel get --endpos --dir /tmp/perfdir/copy
    expect 0 'Dropping replication origin' cleanup "${NEW}" stream cleanup --dir /tmp/perfdir/copy
    echo "PASS [${tc}]"
}

"${NEW}" --version
"${OLD}" --version
"${NEW}" ping

for c in ${CASE:-one two nine refuse}; do
    case "${c}" in
        one) one ;;
        two) two ;;
        nine) nine ;;
        refuse) refuse ;;
        perfdir) perfdir ;;
        *) fail "unknown case ${c}" ;;
    esac
done
