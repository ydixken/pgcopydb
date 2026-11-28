#!/usr/bin/env bash
# Every run of ORDER (default order-<WORKLOAD>.txt), in that order. A valid full-size run of the
# order line's variant and workload is skipped, so the matrix resumes; any other
# run directory is moved aside to <label>.prev-<epoch> and the run starts again.
# Usage: matrix-rel.sh OUTDIR A|B [ORDER]   (environment: BENCH_LOCK)
set -euo pipefail

out=${1:?usage: matrix-rel.sh OUTDIR A|B [ORDER]}
workload=${2:?usage: matrix-rel.sh OUTDIR A|B [ORDER]}
here=$(cd "$(dirname "$0")" && pwd)
order=${3:-$here/order-$workload.txt}
: "${BENCH_LOCK:?matrix-rel.sh: set BENCH_LOCK to the shared podman lock directory}"
[[ -f $order ]] || { echo "matrix-rel.sh: no $order" >&2; exit 2; }
# IMAGE_V27 and WANT_V27 are inputs of the V27 variants, like the four of BASE-1 and CAND-1
[[ -z ${TXNS:-}${SEED:-}${CLIENTS:-}${LABEL:-}${SRC_CPUS:-}${DST_CPUS:-}${POD_CPUS:-}${PG_IMAGE:-}${IMAGE_V26:-}${STAGE0:-}${BIG_IN:-}${PRE_COMPARE_SQL:-} ]] || {
  echo "matrix-rel.sh: unset TXNS, SEED, CLIENTS, LABEL, SRC_CPUS, DST_CPUS, POD_CPUS, PG_IMAGE, IMAGE_V26, STAGE0, BIG_IN and PRE_COMPARE_SQL; the matrix runs the defaults only" >&2
  exit 2
}
mkdir -p "$out"
failed=0
while read -r label variant; do
  [[ -z $label || $label == \#* ]] && continue
  rd=$out/$label
  if jq -e --arg v "$variant" --arg w "$workload" \
    '.valid == true and .variant == $v and .workload == $w and .full_size == 1' "$rd/result.json" >/dev/null 2>&1; then
    echo "matrix-rel.sh: $label is valid, skipped"
    continue
  fi
  [[ -e $rd ]] && mv "$rd" "$rd.prev-$(date +%s)"
  echo "matrix-rel.sh: $label $variant $workload"
  if ! LABEL=$label "$here/run-rel.sh" "$out" "$variant" "$workload" </dev/null; then
    echo "matrix-rel.sh: $label failed" >&2; failed=$((failed + 1))
  elif ! jq -e '.valid == true' "$rd/result.json" >/dev/null 2>&1; then
    echo "matrix-rel.sh: $label exited 0 but is not valid" >&2; failed=$((failed + 1))
  fi
done <"$order"
echo "matrix-rel.sh: done, $failed runs failed or not valid"
((failed == 0))
