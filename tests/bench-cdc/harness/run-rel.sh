#!/usr/bin/env bash
# One run of one variant on one workload, on fresh bench-rel-* containers under
# the shared podman lock: base clone, init, backlog, then the receive phase with
# apply off and the apply phase. Results go to OUTDIR/<label>/ (result.json).
# Usage: run-rel.sh OUTDIR V26-1|V27-1|V27-8|V27-8HT|BASE-1|CAND-1|PERF-1|RL A|B
# (environment: BENCH_LOCK, IMAGE_BASE, WANT_BASE, IMAGE_CAND, WANT_CAND for the
# local-build variants, IMAGE_V27 and WANT_V27 for the V27 variants)
set -euo pipefail

out=${1:?usage: run-rel.sh OUTDIR VARIANT WORKLOAD}
variant=${2:?variant}
workload=${3:?workload}
here=$(cd "$(dirname "$0")" && pwd)
s0=${STAGE0:-$here/../workload-a}
# no default: a default lock would let two users of the podman machine run at once
lock=${BENCH_LOCK:?run-rel.sh: set BENCH_LOCK to the shared podman lock directory}
d_v26=ghcr.io/ydixken/pgcopydb-operator/runner:v0.26.0 d_v27=ghcr.io/ydixken/pgcopydb-operator/runner:v0.27.0
d_pg=docker.io/library/postgres:18.7 d_s0=$here/../workload-a d_big_in=100000
image_v26=${IMAGE_V26:-$d_v26}
image_v27=${IMAGE_V27:-$d_v27}
pg_image=${PG_IMAGE:-$d_pg}
clients=${CLIENTS:-16}
timeout_s=${PHASE_TIMEOUT:-3600}
# the host has 18 cores and the VM 14: past 4 cores of other host work the
# VM's vCPUs wait for a core
host_cpu_limit=${HOST_CPU_LIMIT:-400}
podman machine inspect >/dev/null 2>&1 || host_cpu_limit=off
export SRC_CPUS=${SRC_CPUS:-4} DST_CPUS=${DST_CPUS:-2} POD_CPUS=${POD_CPUS:-8}
big_in=${BIG_IN:-$d_big_in}
# the matrix keeps only runs at the default size, seed, quotas, images and workload source
full_size=1
# IMAGE_V27 is an input of the V27 variants, not an override, so it is left out here
[[ -z ${TXNS:-}${SEED:-}${CLIENTS:-}${PRE_COMPARE_SQL:-} && "$SRC_CPUS $DST_CPUS $POD_CPUS $big_in" == "4 2 8 $d_big_in" &&
  $image_v26 == "$d_v26" && $pg_image == "$d_pg" &&
  $(cd "$s0" 2>/dev/null && pwd -P) == "$(cd "$d_s0" 2>/dev/null && pwd -P)" ]] || full_size=0

case $workload in
  # need_gib: the free space a full-size run needs, measured on the smoke runs
  A) txns=${TXNS:-1280000} seed=${SEED:-4242} need_gib=${NEED_GIB:-12}
     ht_list=public.h1,public.h2,public.h3,public.h4,public.w01 ;;
  B) txns=${TXNS:-88000} seed=${SEED:-4243} need_gib=${NEED_GIB:-16}
     ht_list=public.b1,public.b2 ;;
  *) echo "run-rel.sh: workload must be A or B" >&2; exit 2 ;;
esac
# mode goes into the runner container's environment; rl replaces follow with a plain drain
mode='' rl=0
case $variant in
  V26-1) image=$image_v26 want=0.18.144.g86bf908 n=1 ww=0 ht='' ;;
  V27-1 | V27-8 | V27-8HT)
    # the V27 variants measure the sqlite mode of a build of this repository, not a
    # published runner, so both settings are required inputs
    for v in IMAGE_V27 WANT_V27; do
      [[ -n ${!v:-} ]] || { echo "run-rel.sh: $variant needs IMAGE_V27 and WANT_V27; $v is unset" >&2; exit 2; }
    done
    image=$IMAGE_V27 want=$WANT_V27 ww=1 ht=''
    case $variant in V27-1) n=1 ;; V27-8) n=8 ;; V27-8HT) n=8 ht=$ht_list ;; esac ;;
  BASE-1 | CAND-1 | PERF-1 | RL)
    # these images are local builds, so all four settings are required inputs
    for v in IMAGE_BASE WANT_BASE IMAGE_CAND WANT_CAND; do
      [[ -n ${!v:-} ]] || { echo "run-rel.sh: $variant needs IMAGE_BASE, WANT_BASE, IMAGE_CAND and WANT_CAND; $v is unset" >&2; exit 2; }
    done
    if [[ $variant == BASE-1 ]]; then image=$IMAGE_BASE want=$WANT_BASE; else image=$IMAGE_CAND want=$WANT_CAND; fi
    n=1 ww=1 ht=''
    # the candidate runs sqlite mode by default, so performance mode is set explicitly
    case $variant in PERF-1) mode=performance ;; RL) rl=1 ;; esac ;;
  *) echo "run-rel.sh: variant must be V26-1, V27-1, V27-8, V27-8HT, BASE-1, CAND-1, PERF-1 or RL" >&2; exit 2 ;;
esac
((txns % clients == 0)) || { echo "run-rel.sh: TXNS must be a multiple of CLIENTS" >&2; exit 2; }
label=${LABEL:-$workload-$variant-$(date +%Y%m%dT%H%M%S)}

rd=$out/$label
[[ -e $rd ]] && { echo "run-rel.sh: $rd exists" >&2; exit 2; }
mkdir -p "$rd"
rd=$(cd "$rd" && pwd)
W=/var/run/pgcopydb
log() { echo "$(date +%T) $*" | tee -a "$rd/run.log"; }
env_() { echo "$1=$2" >>"$rd/run.env"; }

objects() {
  { podman ps -a --format '{{.Names}}'; podman pod ls --format '{{.Name}}'
    podman volume ls --format '{{.Name}}'; podman network ls --format '{{.Name}}'; } | grep '^bench-rel-' || true
}
teardown() {
  podman pod rm -f -t 5 bench-rel-pod >/dev/null 2>&1 || true
  podman rm -f -t 5 bench-rel-src bench-rel-dst >/dev/null 2>&1 || true
  podman volume rm -f bench-rel-src-data bench-rel-dst-data bench-rel-work >/dev/null 2>&1 || true
  podman network rm -f bench-rel-net >/dev/null 2>&1 || true
}
# any other running container shares the CPUs and the disk
others() { podman ps --format '{{.Names}}' | grep -v '^bench-rel-' | sed "s/^/$(date +%s) /" || true; }

me="bench-rel $label $$ $(date +%s)"
locked=0 sampler=''
finish() {
  local rc=$?
  [[ -n $sampler ]] && { kill "$sampler"; wait "$sampler"; } 2>/dev/null || true
  if ((locked)); then
    podman cp bench-rel-runner:$W/logs "$rd/" >/dev/null 2>&1 || true
    others >>"$rd/others.log"
    seen=$(awk '{ print $2 }' "$rd/others.log" | sort -u | paste -sd, -)
    env_ others "$seen"
    env_ contended "$([[ -n $seen ]] && echo 1 || echo 0)"
    [[ -z $seen ]] || log "other containers ran during this run: $seen; run contended"
    vms=$(awk '{ print $2 }' "$rd/machines.log" 2>/dev/null | sort -u | paste -sd, -)
    env_ machines "$vms"
    [[ -z $vms ]] || log "other podman machines ran during this run: $vms; run contended"
    teardown
    left=$(objects | grep -c . || true)
    env_ leftover_objects "$left"
    ((left == 0)) || { log "left behind: $(objects | paste -sd, -)"; ((rc)) || rc=4; }
    if [[ $(cat "$lock/owner" 2>/dev/null) == "$me" ]]; then rm -rf "$lock"; else log "lock owner changed, left in place"; fi
    env_ rc "$rc"
    "$here/result-rel.sh" "$rd" >"$rd/result.json" 2>>"$rd/run.log" || log "result-rel.sh failed"
    log "exit $rc, valid=$(jq -r .valid "$rd/result.json" 2>/dev/null)"
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT TERM

warned=0
until mkdir "$lock" 2>/dev/null; do
  # the runbook: report a lock older than 3 hours, never break it
  if ((!warned)) && (($(date +%s) - $(stat -f %m "$lock" 2>/dev/null || date +%s) > 10800)); then
    echo "run-rel.sh: $lock is older than 3 hours (owner: $(cat "$lock/owner" 2>/dev/null)); report it, still waiting" >&2
    warned=1
  fi
  sleep 20
done
echo "$me" >"$lock/owner"
locked=1
: >"$rd/others.log"
: >"$rd/machines.log"
{
  echo "label=$label"; echo "variant=$variant"; echo "workload=$workload"; echo "n=$n"; echo "wal_workers_flag=$ww"
  echo "high_traffic=$ht"; echo "txns=$txns"; echo "full_size=$full_size"; echo "clients=$clients"; echo "seed=$seed"; echo "image=$image"
  # a flag, not the text: the SQL may hold '=' or a newline, which run.env cannot carry
  echo "follow_mode=$mode"; echo "pre_compare_sql=$([[ -n ${PRE_COMPARE_SQL:-} ]] && echo 1 || echo 0)"
  echo "image_id=$(podman image inspect -f '{{.Id}}' "$image" 2>/dev/null)"; echo "pg_image=$pg_image"
  echo "cpus=src:$SRC_CPUS,dst:$DST_CPUS,pod:$POD_CPUS"; echo "started=$(date +%s)"
  echo "host_cpu_limit=$host_cpu_limit"
  echo "src_cpus=$SRC_CPUS"; echo "dst_cpus=$DST_CPUS"; echo "pod_cpus=$POD_CPUS"
  echo "image_v26=$image_v26"; echo "image_v27=$image_v27"; echo "stage0=$s0"; echo "big_in=$big_in"
  echo "image_base=${IMAGE_BASE:-}"; echo "image_cand=${IMAGE_CAND:-}"
  echo "image_base_id=$([[ -n ${IMAGE_BASE:-} ]] && podman image inspect -f '{{.Id}}' "$IMAGE_BASE" 2>/dev/null)"
  echo "image_cand_id=$([[ -n ${IMAGE_CAND:-} ]] && podman image inspect -f '{{.Id}}' "$IMAGE_CAND" 2>/dev/null)"
} >"$rd/run.env"
[[ -z $(objects) ]] || { log "bench-rel objects exist before the run: $(objects | paste -sd, -)"; exit 1; }
free=$("$here/sample-rel.sh" --free)
env_ free_gib_before $((free >> 30))
((free >= need_gib << 30)) || { log "only $((free >> 30)) GiB free in the podman machine, need $need_gib"; exit 1; }
others >>"$rd/others.log"
vms=$("$here/sample-rel.sh" --machines)
[[ -z $vms ]] || { awk -v t="$(date +%s)" '{ print t, $0 }' <<<"$vms" >>"$rd/machines.log"; log "other podman machines run: $(paste -sd, - <<<"$vms")"; exit 1; }

log "run $label: $variant on workload $workload, txns=$txns image=$image"
mkdir -p "$rd/gen"
if [[ $workload == A ]]; then
  "$s0/gen.sh" "$rd/gen" 1 >"$rd/gen.log"
  schema=$s0/schema.sql
else
  "$here/gen-b.sh" "$rd/gen" >"$rd/gen.log"
  schema=$here/schema-b.sql
fi
cp "$here/inner-rel.sh" "$rd/gen/"

podman network create bench-rel-net >/dev/null
for v in bench-rel-src-data bench-rel-dst-data bench-rel-work; do podman volume create "$v" >/dev/null; done
pg=(-e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=bench --shm-size 1g
  --memory 6g --memory-swap 6g --network bench-rel-net)
# bench-ww's server settings; autovacuum off keeps its timing out of the CPU windows,
# and the checkpoint limits keep checkpoints, so the share of full-page writes, out of the backlog
conf=(-c shared_buffers=1GB -c fsync=on -c synchronous_commit=on -c max_connections=300 -c max_wal_size=16GB
  -c checkpoint_timeout=1h -c autovacuum=off)
podman run -d --name bench-rel-src "${pg[@]}" --cpus "$SRC_CPUS" -v bench-rel-src-data:/var/lib/postgresql "$pg_image" \
  "${conf[@]}" -c wal_level=logical -c max_replication_slots=48 -c max_wal_senders=48 >/dev/null
podman run -d --name bench-rel-dst "${pg[@]}" --cpus "$DST_CPUS" -v bench-rel-dst-data:/var/lib/postgresql "$pg_image" \
  "${conf[@]}" -c max_active_replication_origins=48 >/dev/null
podman pod create --name bench-rel-pod --infra-name bench-rel-infra --network bench-rel-net \
  --cpus "$POD_CPUS" --memory 8g --memory-swap 8g >/dev/null
uris=(-e PGCOPYDB_SOURCE_PGURI=postgres://postgres@bench-rel-src:5432/bench
  -e PGCOPYDB_TARGET_PGURI=postgres://postgres@bench-rel-dst:5432/bench)
runner_env=("${uris[@]}")
# in the container, so that every exec of this run sees the same mode
[[ -n $mode ]] && runner_env+=(-e "PGCOPYDB_FOLLOW_MODE=$mode")
podman run -d --name bench-rel-runner --pod bench-rel-pod -v bench-rel-work:$W "${runner_env[@]}" \
  "$image" sleep infinity >/dev/null
podman run -d --name bench-rel-load --pod bench-rel-pod -v bench-rel-work:$W:ro "${uris[@]}" \
  "$pg_image" sleep infinity >/dev/null
# the work volume goes to the image's own user, after the load container's
# mount of the still empty volume reset its owner
owner=$(podman exec bench-rel-runner sh -c 'echo "$(id -u):$(id -g)"')
podman exec -u root bench-rel-runner chown "$owner" $W
env_ runner_user "$owner"
got=$(podman exec bench-rel-runner pgcopydb --version 2>/dev/null | sed -n 's/^pgcopydb version //p' | head -1)
env_ pgcopydb "$got"
[[ $got == "$want" ]] || { log "image $image runs pgcopydb $got, expected $want"; exit 1; }

rx() { podman exec -e "N=$n" -e "WW=$ww" -e "HT=$ht" -e "RL=$rl" bench-rel-runner "$@"; }
srcq() { podman exec bench-rel-src psql -U postgres -d bench -XAtq -c "$1"; }
dstq() { podman exec bench-rel-dst psql -U postgres -d bench -XAtq -c "$1"; }
for uri in PGCOPYDB_SOURCE_PGURI PGCOPYDB_TARGET_PGURI; do
  deadline=$((SECONDS + 120))
  # over TCP, because the entrypoint's init server listens on the socket only
  until rx sh -c "psql -XAtqc 'select 1' \"\$$uri\"" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || { log "$uri not ready"; exit 1; }
    sleep 1
  done
done

log "schema and seed"
podman exec -i bench-rel-src psql -U postgres -d bench -Xq -f - <"$schema" >"$rd/schema.log" 2>&1
podman cp "$rd/gen" bench-rel-runner:$W/gen

log "base clone (source quiesced)"
rx pgcopydb clone --dir $W/base --table-jobs 4 --index-jobs 4 >"$rd/clone.log" 2>&1

log "init: follow until all $n receives stream, then prefetch mode"
rx $W/gen/inner-rel.sh init
ours="(slot_name = 'bench' or slot_name like 'bench\_w%')"
env_ slots "$(srcq "select count(*) from pg_replication_slots where $ours")"
env_ publications "$(srcq "select count(*) from pg_publication where pubname = 'bench' or pubname like 'bench\_%'")"
env_ start_lsn "$(srcq "select min(confirmed_flush_lsn) from pg_replication_slots where $ours")"
env_ start_lsn_max "$(srcq "select max(confirmed_flush_lsn) from pg_replication_slots where $ours")"

echo idle >"$rd/phase"
"$here/sample-rel.sh" "$rd" 2>>"$rd/sample.err" &
sampler=$!
mark() { "$here/sample-rel.sh" --once "$rd" "$1" || log "mark $1 failed"; }
# pg_stat counters reach the view after the backend flushes them: wait until
# two reads a second apart agree
settle() {
  local q="select coalesce(sum(n_tup_ins + n_tup_upd + n_tup_del), 0) from pg_stat_user_tables" a b
  a=$($1 "$q")
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; b=$($1 "$q"); [[ $a == "$b" ]] && return 0; a=$b; done
  log "$1: pg_stat_user_tables still moving after 10 s"
}

pgbench_args=$(tr '\n' ' ' <"$rd/gen/pgbench.args")
# a checkpoint first, so every run's backlog starts with the same full-page writes
srcq checkpoint >/dev/null
echo backlog >"$rd/phase"
mark backlog_start
log "backlog: $txns transactions, no consumer attached"
# shellcheck disable=SC2086 # pgbench_args is a word list
podman exec -w $W/gen bench-rel-load sh -c \
  "pgbench -n -c $clients -j 4 --random-seed=$seed -t $((txns / clients)) $pgbench_args \"\$PGCOPYDB_SOURCE_PGURI\"" \
  >"$rd/pgbench.log" 2>&1
endpos=$(srcq 'select pg_current_wal_flush_lsn()')
settle srcq
mark backlog_end
env_ endpos "$endpos"
env_ wal_bytes "$(srcq "select pg_wal_lsn_diff('$endpos', '$(grep '^start_lsn=' "$rd/run.env" | cut -d= -f2)')::bigint")"
env_ pgbench_txns "$(awk '/^number of transactions actually processed/ { print $NF }' "$rd/pgbench.log" | cut -d/ -f1)"
rx $W/gen/inner-rel.sh endpos "$endpos"
# WAL past endpos, so every receive meets a record or keepalive beyond it
srcq vacuum >/dev/null && srcq checkpoint >/dev/null

echo receive >"$rd/phase"
mark receive_start
if ((rl)); then
  # the drain's own failure is a validity rule, not a reason to skip cleanup
  log "receive phase: pg_recvlogical drains slot bench_rl to endpos $endpos"
  rx $W/gen/inner-rel.sh drain "$endpos" >>"$rd/run.env" || log "drain failed"
  mark receive_end
else
  log "receive phase: follow --resume with apply off, endpos $endpos"
  podman exec -d -e "N=$n" -e "WW=$ww" -e "HT=$ht" bench-rel-runner $W/gen/inner-rel.sh start >/dev/null
  rx $W/gen/inner-rel.sh wait-receive "$timeout_s" >>"$rd/run.env" || { log "receive phase failed"; exit 1; }
  mark receive_end

  echo apply >"$rd/phase"
  mark apply_start
  log "apply phase: sentinel set apply"
  # set -e ignores a failure inside an argument's command substitution
  on=$(rx $W/gen/inner-rel.sh apply-on) || { log "sentinel set apply failed"; exit 1; }
  env_ apply_on_t "$(head -1 <<<"$on")"
  rx $W/gen/inner-rel.sh wait-exit "$timeout_s" >>"$rd/run.env" || { log "apply phase failed"; exit 1; }
  settle dstq
  mark apply_end
  grep -q '^follow_rc=0$' "$rd/run.env" || { log "follow exited $(sed -n 's/^follow_rc=//p' "$rd/run.env")"; exit 1; }

  echo compare >"$rd/phase"
  # the control of F23: a target that no longer matches the source must fail compare
  [[ -n ${PRE_COMPARE_SQL:-} ]] && { log "PRE_COMPARE_SQL on the target"; dstq "$PRE_COMPARE_SQL" >"$rd/pre-compare.log"; }
  log "compare data"
  if rx pgcopydb compare data --dir $W/cmp >"$rd/compare.log" 2>&1; then env_ compare pass; else env_ compare fail; fi
fi
if kill "$sampler" 2>/dev/null; then wait "$sampler" || true; else env_ sampler dead; fi
sampler=''

log "stream cleanup"
cleanup_rc=0
rx $W/gen/inner-rel.sh cleanup || { cleanup_rc=$?; log "stream cleanup failed"; }
env_ cleanup_rc "$cleanup_rc"
both() { echo "$(srcq "$1"),$(dstq "$1")"; }
env_ slots_left "$(both 'select count(*) from pg_replication_slots')"
env_ publications_left "$(both 'select count(*) from pg_publication')"
env_ origins_left "$(both 'select count(*) from pg_replication_origin')"
# RL has no apply and no compare, so its validity list stands on the drain alone
((rl)) || grep -q '^compare=pass' "$rd/run.env" ||
  { log "compare data reported a difference: run disqualified"; exit 3; }
log "done"
