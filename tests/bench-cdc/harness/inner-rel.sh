#!/usr/bin/env bash
# pgcopydb steps run inside the runner container, one follow in $W/rel with
# slot and origin bench (bench_w1.. for WAL workers). The variant comes from
# the environment: N workers, WW=1 passes --wal-workers N, HT the hot tables.
# Usage: inner-rel.sh init | endpos LSN | start | wait-receive SECS | apply-on | wait-exit SECS | drain LSN | cleanup
set -euo pipefail

W=${W:-/var/run/pgcopydb}
D=$W/rel
L=$W/logs
FLOG=$L/follow.log
N=${N:?N} WW=${WW:?WW} HT=${HT:-}
# RL=1: the variant drains the slot with pg_recvlogical instead of applying
RL=${RL:-0}
RL_SLOT=bench_rl
cmd=${1:?command}
mkdir -p "$L"

fargs=(--dir "$D" --plugin pgoutput --slot-name bench --origin bench)
((WW)) && fargs+=(--wal-workers "$N")
[[ -n $HT ]] && fargs+=(--wal-high-traffic-tables "$HT")
src() { psql -XAtq -d "$PGCOPYDB_SOURCE_PGURI" -c "$1"; }
dst() { psql -XAtq -d "$PGCOPYDB_TARGET_PGURI" -c "$1"; }
ours="(slot_name = 'bench' or slot_name like 'bench\_w%')"
# a walsender running START_REPLICATION means that worker's receive streams
streaming="from pg_replication_slots s join pg_stat_activity a on a.pid = s.active_pid
  where a.query like 'START_REPLICATION%' and (s.slot_name = 'bench' or s.slot_name like 'bench\_w%')"
# log lines start with 'YYYY-MM-DD HH:MM:SS.mmm PID LEVEL', in the container's UTC
epochs() { while read -r d t _; do TZ=UTC date -d "$d $t" +%s.%N; done; }
last() { grep -F -- "$1" "$FLOG" | epochs | sort -n | tail -1; }
first() { grep -F -- "$1" "$FLOG" | head -1 | epochs; }
count() { grep -cF -- "$1" "$FLOG" || true; }

RECV_CLOSE='streamCloseFile: receive done at'
RECV_END='pipeline_state_end: receive done at'
APPLY_PSE='pipeline_state_end: apply done at'
APPLY_WAKE='The pgcopydb sentinel has enabled applying changes'

case $cmd in
  init)
    # follow creates the foreign keys at endpos from the clone's schema dump
    mkdir -p "$D/schema"
    cp "$W/base/schema/schema.dump" "$D/schema/"
    # job control gives follow a process group of its own, as setsid would
    set -m
    pgcopydb follow "${fargs[@]}" >"$L/init.log" 2>&1 &
    pid=$!
    set +m
    deadline=$((SECONDS + 600))
    # a failing query stops the wait instead of reading as zero
    while got=$(src "select count(*) $streaming") && ((got != N)); do
      ((SECONDS < deadline)) || { echo "inner-rel.sh: timeout waiting for $N receives to stream" >&2; exit 1; }
      kill -0 "$pid" 2>/dev/null || { echo "inner-rel.sh: follow exited early" >&2; exit 1; }
      sleep 1
    done
    [[ $got == "$N" ]] || { echo "inner-rel.sh: walsender query failed" >&2; exit 1; }
    kill -TERM -- "-$pid"
    rc=0
    wait "$pid" || rc=$?
    # with WAL workers the supervisor exits non-zero, foreign keys pending
    if ((rc != 0)) && ! grep -q 'Foreign keys are pending' "$L/init.log"; then
      echo "inner-rel.sh: follow exited $rc on TERM" >&2
      exit 1
    fi
    slots=$(src "select count(*) from pg_replication_slots where $ours")
    origins=$(dst "select count(*) from pg_replication_origin where roname = 'bench' or roname like 'bench\_w%'")
    ((slots == N && origins == N)) || { echo "inner-rel.sh: $slots slots, $origins origins, expected $N" >&2; exit 1; }
    # prefetch: receive runs, apply waits for the sentinel
    pgcopydb stream sentinel set prefetch --dir "$D" 2>>"$L/sentinel.log"
    pgcopydb stream sentinel get --dir "$D" --json 2>>"$L/sentinel.log" | tee "$L/sentinel-init.json" |
      grep -Eq '"apply": *false' || { echo "inner-rel.sh: sentinel apply is not off" >&2; exit 1; }
    # the drain's slot is created where follow created its own, before the backlog,
    # so both variants retain WAL from the same point
    if ((RL)); then src "select pg_create_logical_replication_slot('$RL_SLOT', 'pgoutput')" >/dev/null; fi
    ;;
  endpos)
    pgcopydb stream sentinel set endpos --dir "$D" "${2:?LSN}" >/dev/null 2>>"$L/sentinel.log"
    ;;
  start)
    # run by 'podman exec -d': follow outlives the exec, its exit lands in follow.rc
    rm -f "$L/follow.rc"
    spool() { echo "$(date +%s.%N) $(du -sb "$D/cdc" 2>/dev/null | cut -f1)"; }
    spool >"$L/spool.tsv"
    date +%s.%N >"$L/follow.start"
    (
      rc=0
      pgcopydb follow --resume --not-consistent "${fargs[@]}" >"$FLOG" 2>&1 || rc=$?
      echo "$rc $(date +%s.%N)" >"$L/follow.rc"
    ) &
    # the spool size every 0.5 s gives when the first changes landed
    while [[ ! -f $L/follow.rc ]]; do spool >>"$L/spool.tsv"; sleep 0.5; done
    wait
    ;;
  wait-receive)
    deadline=$((SECONDS + ${2:?SECS}))
    until [[ -f $L/follow.start && -f $FLOG ]] && (($(count "$RECV_CLOSE") >= N)); do
      [[ -f $L/follow.rc ]] && { echo "inner-rel.sh: follow exited during receive: $(cat "$L/follow.rc")" >&2; exit 1; }
      ((SECONDS < deadline)) || { echo "inner-rel.sh: receive timeout" >&2; exit 1; }
      sleep 0.5
    done
    # the receive's own exit follows its close within milliseconds
    until (($(count "$RECV_END") >= N)) || ((SECONDS >= deadline)); do sleep 0.2; done
    s0=$(head -1 "$L/spool.tsv" | cut -d' ' -f2)
    echo "follow_start=$(cat "$L/follow.start")"
    echo "recv_close_n=$(count "$RECV_CLOSE")"
    echo "recv_end_n=$(count "$RECV_END")"
    echo "recv_close_t=$(last "$RECV_CLOSE")"
    echo "recv_end_t=$(last "$RECV_END")"
    echo "spool_open_t=$(first 'output CDC file')"
    echo "spool_growth_t=$(awk -v s0="${s0:-0}" '$2 > s0 { print $1; exit }' "$L/spool.tsv")"
    echo "spool_bytes_recv=$(du -sb "$D/cdc" | cut -f1)"
    # a build that ignores PGCOPYDB_FOLLOW_MODE writes no segment, so PERF-1 reads this
    echo "spool_segments=$(find "$D/cdc" -maxdepth 1 -name '*.seg' | grep -c . || true)"
    # each receive's last word on what it wrote and flushed to the spool
    fin=$(grep -E 'Streamed up to write_lsn .* stopping: endpos is' "$FLOG" || true)
    echo "recv_write_lsns=$(sed -n 's/.*write_lsn \([0-9A-F/]*\),.*/\1/p' <<<"$fin" | paste -sd, -)"
    echo "recv_flush_lsns=$(sed -n 's/.*flush_lsn \([0-9A-F/]*\),.*/\1/p' <<<"$fin" | paste -sd, -)"
    ;;
  apply-on)
    date +%s.%N
    pgcopydb stream sentinel set apply --dir "$D" 2>>"$L/sentinel.log"
    ;;
  wait-exit)
    deadline=$((SECONDS + ${2:?SECS}))
    until [[ -f $L/follow.rc ]]; do
      ((SECONDS < deadline)) || { echo "inner-rel.sh: apply timeout" >&2; exit 1; }
      sleep 0.5
    done
    read -r rc t <"$L/follow.rc"
    echo "follow_rc=$rc"
    echo "exit_t=$t"
    echo "apply_wake_first_t=$(first "$APPLY_WAKE")"
    echo "apply_wake_last_t=$(last "$APPLY_WAKE")"
    echo "recv_close_n_total=$(count "$RECV_CLOSE")"
    if ((N > 1)); then
      # the supervisor logs each worker at endpos; its own pid also logs the
      # final apply pipeline_state_end, which the per-worker count leaves out
      sup=$(sed -n 's/^[^ ]* [^ ]* \([0-9]*\) .*Running pgcopydb version.*/\1/p' "$FLOG" | head -1)
      reached=$(grep -E 'WAL worker [0-9]+ with pid [0-9]+ has reached endpos' "$FLOG" |
        while read -r d t _ _ _ _ _ k _; do echo "$k $(TZ=UTC date -d "$d $t" +%s.%N)"; done |
        sort -k1,1n -k2,2n | awk '{ last[$1] = $2 } END { for (k in last) print last[k] }' | sort -n)
      echo "apply_end_n=$(grep -c . <<<"$reached" || true)"
      echo "apply_end_t=$(tail -1 <<<"$reached")"
      pse=$(grep -F -- "$APPLY_PSE" "$FLOG" | awk -v s="$sup" '$3 != s')
      echo "apply_pse_n=$(grep -c . <<<"$pse" || true)"
      echo "apply_pse_t=$(epochs <<<"$pse" | sort -n | tail -1)"
    else
      echo "apply_end_n=$(count "$APPLY_PSE")"
      echo "apply_end_t=$(last "$APPLY_PSE")"
      echo "apply_pse_n=$(count "$APPLY_PSE")"
      echo "apply_pse_t=$(last "$APPLY_PSE")"
    fi
    echo "spool_bytes_exit=$(du -sb "$D/cdc" | cut -f1)"
    ;;
  drain)
    # the pgoutput options that follow passes (cli_common.c), and the endpos of the run
    endpos=${2:?LSN}
    start=$(date +%s.%N)
    rc=0
    pg_recvlogical -d "$PGCOPYDB_SOURCE_PGURI" --slot "$RL_SLOT" --start --no-loop \
      --endpos "$endpos" -o proto_version=1 -o publication_names=bench \
      -f "$W/rl.out" >"$L/rl.log" 2>&1 || rc=$?
    echo "rl_start_t=$start"
    echo "rl_end_t=$(date +%s.%N)"
    echo "rl_rc=$rc"
    echo "rl_bytes=$(stat -c %s "$W/rl.out" 2>/dev/null || echo 0)"
    ;;
  cleanup)
    pgcopydb stream cleanup --dir "$D" --slot-name bench --origin bench >>"$L/cleanup.log" 2>&1
    # the drain's slot is not pgcopydb's, so stream cleanup leaves it behind
    if ((RL)); then src "select pg_drop_replication_slot('$RL_SLOT')" >/dev/null; fi
    ;;
  *)
    echo "inner-rel.sh: unknown command $cmd" >&2
    exit 2
    ;;
esac
