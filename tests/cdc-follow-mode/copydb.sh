#! /bin/bash

# The follow mode comes from the variable, and the option wins over it.  A
# value that is neither mode stops the command, and performance mode refuses
# the plugin and the worker count it cannot serve before it touches the
# source.  Two commands must stay out of that refusal: a receive that takes
# its plugin from the previous run, and the cleanup that is the remedy of the
# work directory refusal.
#
# The predicate that routes a run to the raw spool is still false, so no run
# writes the mode tag yet.  The case that reads a tag the code wrote is not in
# the default list; CASE=tag runs it once the predicate holds.

set -euo pipefail

BAD_ARGS=1
PERF_PREFIX='Option --follow-mode performance '
NOWHERE='postgres://nobody@127.0.0.1:1/nowhere'
tc=options

on_exit() {
    local status=$?
    trap - EXIT
    pkill -KILL -x pgcopydb 2> /dev/null || true
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
check() { echo "${1}: want [${2}] got [${3}]"; test "${2}" = "${3}" || fail "${1}"; }
lite() { timeout 10s sqlite3 -readonly -init /dev/null -batch -noheader "$1" "$2"; }

slots() { src -c 'select count(*) from pg_replication_slots'; }
pubs() { src -c 'select count(*) from pg_publication'; }

# what a work directory records about its mode: the setup row, its tag, and
# the raw spool segments, which live under the work directory
setup_rows() { lite "$1/schema/source.db" 'select count(*) from wal_worker_setup'; }
mode_tag() { lite "$1/schema/source.db" 'select high_traffic from wal_worker_setup'; }
segs() { find "$1" -name '*.seg' | wc -l | tr -d ' '; }

begin_case() {
    tc=$1
    mkdir -p "/tmp/${tc}"
    echo "=== ${tc}"
}

# expect <code> <message> <log> <command...>: the command exits with code and
# logs the message; a refusal that regresses into a running command exits 124
expect() {
    local want=$1 msg=$2 log=/tmp/${tc}/$3.log rc=0
    shift 3
    timeout -k 5 120 "$@" > "${log}" 2>&1 || rc=$?
    if [ "${rc}" -ne "${want}" ] || ! grep -qF -- "${msg}" "${log}"; then
        cat "${log}"
        fail "want exit ${want} and \"${msg}\", got exit ${rc}: $*"
    fi
    echo "OK exit ${rc}: $*"
}

# no_refusal <log> <command...>: whatever else the command does, it is not
# refused for its follow mode.  The exit code is free: these commands fail
# for reasons of their own, and the absence of the line is the assertion.
no_refusal() {
    local log=/tmp/${tc}/$1.log rc=0
    shift
    timeout -k 5 120 "$@" > "${log}" 2>&1 || rc=$?
    if grep -qF -- "${PERF_PREFIX}" "${log}"; then
        grep -F -- "${PERF_PREFIX}" "${log}"
        fail "refused for its follow mode: $*"
    fi
    echo "OK exit ${rc}, no mode refusal: $*"
}

# spool_dir <dir> <variable mode|-> <option mode|-> <slot>: a work directory
# with a pgoutput slot and an origin, started with that variable and that
# option.  Each fixture takes its own slot name, which also names its
# publication and its origin, so no case inherits another one's objects.
# The output file is named after the directory and removed first: a file
# that an earlier call left behind would end the wait before this snapshot
# exported anything, and the SIGTERM below would then interrupt its
# CREATE PUBLICATION and leave the publication on the source.
spool_dir() {
    local dir=$1 env_mode=$2 opt_mode=$3 slot=$4 snap_pid deadline base
    local opt=()
    base=/tmp/${tc}/$(basename "${dir}")
    test "${opt_mode}" = - || opt=(--follow-mode "${opt_mode}")
    if test "${env_mode}" = -; then
        unset PGCOPYDB_FOLLOW_MODE
    else
        export PGCOPYDB_FOLLOW_MODE=${env_mode}
    fi

    rm -f "${base}-snapshot.out"
    pgcopydb snapshot --follow --plugin pgoutput "${opt[@]}" --dir "${dir}" \
        --slot-name "${slot}" > "${base}-snapshot.out" 2> "${base}-snapshot.log" &
    snap_pid=$!
    deadline=$((SECONDS + 60))
    until test -s "${base}-snapshot.out"; do
        kill -0 "${snap_pid}" 2> /dev/null ||
            { cat "${base}-snapshot.log"; fail 'snapshot --follow exited'; }
        test "${SECONDS}" -lt "${deadline}" || fail 'snapshot --follow printed no snapshot'
        sleep 0.2
    done
    pgcopydb stream setup "${opt[@]}" --dir "${dir}" --slot-name "${slot}" \
        --origin "${slot}_origin" > "${base}-setup.log" 2>&1 ||
        { cat "${base}-setup.log"; fail 'stream setup'; }
    kill -TERM "${snap_pid}"
    wait "${snap_pid}" || true
    unset PGCOPYDB_FOLLOW_MODE
}

# cleanup_dir <dir> <log> <slot>: the slot, publication and origin of spool_dir
cleanup_dir() {
    expect 0 "Dropping replication origin \"$3_origin\"" "$2" \
           pgcopydb stream cleanup --slot-name "$3" --origin "$3_origin" --dir "$1"
    check "objects left after the cleanup of $3" '0|0' \
          "$(src -c "select count(*) from pg_replication_slots where slot_name = '$3'")|$(src -c "select count(*) from pg_publication where pubname = '$3'")"
}

#
# options: every refusal that happens before the first connection, on a
# directory nobody creates
#
options() {
    begin_case options
    local fresh=(--dir /tmp/options/fresh)
    local parse='Failed to parse --follow-mode "bogus", expected sqlite or performance'
    local wal2json="${PERF_PREFIX}requires --plugin pgoutput, found --plugin wal2json"
    local before_slots before_pubs
    before_slots=$(slots)
    before_pubs=$(pubs)

    expect "${BAD_ARGS}" "${parse}" follow-bogus \
           pgcopydb follow --follow-mode bogus "${fresh[@]}"
    expect "${BAD_ARGS}" "${parse}" env-bogus \
           env PGCOPYDB_FOLLOW_MODE=bogus pgcopydb follow "${fresh[@]}"
    expect "${BAD_ARGS}" "${parse}" receive-bogus \
           pgcopydb stream receive --follow-mode bogus "${fresh[@]}"
    expect "${BAD_ARGS}" "${parse}" snapshot-bogus \
           pgcopydb snapshot --follow --follow-mode bogus "${fresh[@]}"

    # the plugin that the raw spool cannot decode, on each command that runs
    # the check
    expect "${BAD_ARGS}" "${wal2json}" clone-wal2json \
           pgcopydb clone --follow --follow-mode performance --plugin wal2json "${fresh[@]}"
    expect "${BAD_ARGS}" "${wal2json}" follow-wal2json \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb follow --plugin wal2json "${fresh[@]}"
    expect "${BAD_ARGS}" "${wal2json}" receive-wal2json \
           pgcopydb stream receive --follow-mode performance --plugin wal2json "${fresh[@]}"
    expect "${BAD_ARGS}" "${wal2json}" snapshot-wal2json \
           pgcopydb snapshot --follow --follow-mode performance --plugin wal2json "${fresh[@]}"

    expect "${BAD_ARGS}" "${PERF_PREFIX}is not compatible with --wal-high-traffic-tables" high-traffic \
           pgcopydb follow --follow-mode performance --wal-high-traffic-tables public.t "${fresh[@]}"
    expect "${BAD_ARGS}" "${PERF_PREFIX}requires --wal-workers 1, found --wal-workers 2" two-workers \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb clone --follow --wal-workers 2 "${fresh[@]}"
    expect "${BAD_ARGS}" "${PERF_PREFIX}is not compatible with stream apply -" apply-pipe \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb stream apply "${fresh[@]}" -

    test ! -e /tmp/options/fresh || fail 'a refused option created the work directory'
    check 'slots after the refused options' "${before_slots}" "$(slots)"
    check 'publications after the refused options' "${before_pubs}" "$(pubs)"

    # the option wins over the variable, in both directions; the source URI
    # points nowhere, so these two stop at the connection and not before it
    no_refusal opt-sqlite-wins \
           env PGCOPYDB_SOURCE_PGURI="${NOWHERE}" PGCOPYDB_FOLLOW_MODE=performance \
           pgcopydb follow --follow-mode sqlite --plugin wal2json --resume --not-consistent "${fresh[@]}"
    expect "${BAD_ARGS}" "${wal2json}" opt-performance-wins \
           env PGCOPYDB_SOURCE_PGURI="${NOWHERE}" PGCOPYDB_FOLLOW_MODE=sqlite \
           pgcopydb follow --follow-mode performance --plugin wal2json --resume --not-consistent "${fresh[@]}"

    # performance mode at one explicit worker passes the worker refusal
    no_refusal one-worker \
           env PGCOPYDB_SOURCE_PGURI="${NOWHERE}" PGCOPYDB_FOLLOW_MODE=performance \
           pgcopydb follow --wal-workers 1 --plugin pgoutput --resume --not-consistent \
           --dir /tmp/options/one
    echo "PASS [${tc}]"
}

#
# plugin: the two commands that a refusal placed before the plugin merge
# would stop, because the plugin is still unknown there
#
plugin() {
    begin_case plugin
    local dir=/tmp/plugin/pgcopydb copy=/tmp/plugin/copy

    # a receive takes the plugin of the previous run, so it must not be
    # refused for having none on its own command line
    no_refusal receive-no-plugin \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb stream receive \
           --resume --dir /tmp/plugin/fresh

    spool_dir "${dir}" - - plugin_slot
    timeout 10s sqlite3 -init /dev/null -batch "${dir}/schema/source.db" \
        "insert into wal_worker_setup(id, workers, high_traffic) values (1, 1, 'performance')"
    check 'the hand written tag' performance "$(mode_tag "${dir}")"

    # cleanup is the remedy of the work directory refusal, so neither the
    # mode nor a missing plugin may stop it
    cp -a "${dir}" "${copy}"
    expect 0 'Dropping replication origin "plugin_slot_origin"' cleanup \
           env PGCOPYDB_FOLLOW_MODE=performance pgcopydb stream cleanup \
           --slot-name plugin_slot --origin plugin_slot_origin --dir "${copy}"
    check 'objects left after the cleanup of plugin_slot' '0|0' \
          "$(src -c "select count(*) from pg_replication_slots where slot_name = 'plugin_slot'")|$(src -c "select count(*) from pg_publication where pubname = 'plugin_slot'")"
    echo "PASS [${tc}]"
}

#
# modes: what a fresh directory records when no option and no variable name
# a mode
#
modes() {
    begin_case modes

    # no option and no variable is sqlite mode
    spool_dir /tmp/modes/none - - none_slot
    check 'setup rows of a directory started without a mode' 0 "$(setup_rows /tmp/modes/none)"
    check 'segments of a directory started without a mode' 0 "$(segs /tmp/modes/none)"
    cleanup_dir /tmp/modes/none cleanup-none none_slot

    # the option names sqlite while the variable names performance, so the
    # directory must come out the same way
    spool_dir /tmp/modes/opt performance sqlite opt_slot
    check 'setup rows when the option names sqlite' 0 "$(setup_rows /tmp/modes/opt)"
    check 'segments when the option names sqlite' 0 "$(segs /tmp/modes/opt)"
    cleanup_dir /tmp/modes/opt cleanup-opt opt_slot
    echo "PASS [${tc}]"
}

#
# tag: the directory that performance mode writes itself.  Deferred until the
# routing predicate holds, which is package F12.  Run with CASE=tag.
#
tag_case() {
    begin_case tag

    spool_dir /tmp/tag/pgcopydb performance - tag_slot
    check 'the setup row of a performance directory' 1 "$(setup_rows /tmp/tag/pgcopydb)"
    check 'the tag of a performance directory' performance "$(mode_tag /tmp/tag/pgcopydb)"
    cleanup_dir /tmp/tag/pgcopydb cleanup-tag tag_slot
    echo "PASS [${tc}]"
}

pgcopydb ping

for c in ${CASE:-options plugin modes}; do
    case "${c}" in
        options) options ;;
        plugin) plugin ;;
        modes) modes ;;
        tag) tag_case ;;
        *) fail "unknown case ${c}" ;;
    esac
done
