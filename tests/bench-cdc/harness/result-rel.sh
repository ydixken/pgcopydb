#!/usr/bin/env bash
# One JSON results row for a run directory, from run.env, marks.csv and
# samples.csv. valid is true only for a run whose numbers can be used.
# Usage: result-rel.sh RUNDIR > RUNDIR/result.json
set -euo pipefail

rd=${1:?usage: result-rel.sh RUNDIR}
[[ -f $rd/run.env ]] || { echo "result-rel.sh: no run.env in $rd" >&2; exit 1; }
touch "$rd/marks.csv" "$rd/samples.csv"

derived=$(awk -F, '
  FILENAME ~ /run.env$/ { split($0, kv, "="); k = kv[1]; v = substr($0, length(k) + 2); e[k] = v; next }
  FILENAME ~ /marks.csv$/ {
    if ($5 == "-") m[$2, $3, $4] = $6
    if ($4 == "spool_bytes") sp[$2] += $6
    if ($4 == "spill_bytes") spill[$2] += $6
    # the phase marks count toward the phase peaks too
    if ($3 == "run" && $2 ~ /^(receive|apply)_/) {
      q = $2; sub(/_.*/, "", q)
      if ($4 == "mem_bytes" && $6 > mem[q]) mem[q] = $6
      if ($4 == "anon_bytes" && $6 > anon[q]) anon[q] = $6
    }
    if ($3 == "host" && $2 ~ /^(receive|apply)_/) { q = $2; sub(/_.*/, "", q); hsum[q] += $6; hn[q]++; if ($6 > hmax[q]) hmax[q] = $6 }
    next
  }
  {
    p = $2
    if (p != "receive" && p != "apply") next
    n[p, $1] = 1
    if ($3 == "run" && $4 == "mem_bytes" && $6 > mem[p]) mem[p] = $6
    if ($3 == "run" && $4 == "anon_bytes" && $6 > anon[p]) anon[p] = $6
    if ($4 == "spool_bytes") ss[p, $1] += $6
    if ($4 == "saturated") { sat[p, $3] += $6; satn[p, $3]++ }
    if ($4 == "sem_wait_pct") { sem[p] += $6; semn[p]++ }
    if ($3 == "host" && $4 == "host_cpu_pct") { hsum[p] += $6; hn[p]++; if ($6 > hmax[p]) hmax[p] = $6 }
  }
  $3 == "vm" && $4 == "free_bytes" && (vmin == "" || $6 < vmin) { vmin = $6 }
  function num(x) { return x != "" && x ~ /^[0-9.]+$/ }
  function d(a, b) { return (num(a) && num(b)) ? sprintf("%.3f", a - b) : "" }
  function r(a, b) { return (num(a) && num(b) && b > 0) ? sprintf("%.3f", a / b) : "" }
  function cpu(p, c,   a, b) { a = m[p "_start", c, "cpu_usec"]; b = m[p "_end", c, "cpu_usec"]; return (num(a) && num(b)) ? sprintf("%.2f", (b - a) / 1e6) : "" }
  function delta(a, b, c, k) { return (num(m[a, c, k]) && num(m[b, c, k])) ? m[b, c, k] - m[a, c, k] : "" }
  # mean share of the CPU quota between the phase marks, free of the sampling interval
  function util(p, c, q,   u, t) { u = delta(p "_start", p "_end", c, "cpu_usec"); t = delta(p "_start", p "_end", c, "cpu_t")
    return (u != "" && t > 0 && q > 0) ? sprintf("%.0f", 100 * u / 1e6 / t / q) : "" }
  END {
    fs = e["follow_start"]; on = e["apply_on_t"]
    # RL runs no follow: its receive phase is the window of the drain itself
    if (e["variant"] == "RL") { fs = e["rl_start_t"]; e["recv_close_t"] = e["rl_end_t"] }
    print "receive_s=" d(e["recv_close_t"], fs)
    print "receive_exit_s=" d(e["recv_end_t"], fs)
    print "spool_open_s=" d(e["spool_open_t"], fs)
    print "spool_first_growth_s=" d(e["spool_growth_t"], fs)
    print "apply_s=" d(e["apply_end_t"], on)
    print "apply_pse_s=" d(e["apply_pse_t"], on)
    print "apply_wake_s=" d(e["apply_wake_last_t"], on)
    print "exit_s=" d(e["exit_t"], on)
    wal = num(e["wal_bytes"]) ? e["wal_bytes"] / 1e6 : ""
    print "wal_mb=" (wal == "" ? "" : sprintf("%.1f", wal))
    rows = delta("backlog_start", "backlog_end", "src", "rows")
    applied = delta("apply_start", "apply_end", "dst", "rows")
    print "rows_workload=" rows
    print "rows_applied=" applied
    print "rows_match=" ((rows != "" && rows == applied) ? 1 : 0)
    txns = e["pgbench_txns"]
    print "recv_dst_rows=" delta("receive_start", "receive_end", "dst", "rows")
    split(e["cpus"], cq, /[:,]/); for (i = 1; i < 6; i += 2) quota[cq[i]] = cq[i + 1]
    split("receive apply", ph, " ")
    for (i = 1; i <= 2; i++) {
      p = ph[i]; s = (p == "receive") ? d(e["recv_close_t"], fs) : d(e["apply_end_t"], on)
      print p "_mbps=" r(wal, s)
      print p "_txn_s=" r(txns, s)
      print p "_rows_s=" r(rows, s)
      print p "_cpu_runner_s=" cpu(p, "run")
      print p "_cpu_src_s=" cpu(p, "src")
      print p "_cpu_dst_s=" cpu(p, "dst")
      a = anon[p]; t = mem[p]
      print p "_peak_anon_mb=" (a == "" ? "" : sprintf("%.1f", a / 1048576))
      print p "_peak_mem_mb=" (t == "" ? "" : sprintf("%.1f", t / 1048576))
      mx = sp[p "_end"]; for (k in ss) { split(k, kk, SUBSEP); if (kk[1] == p && ss[k] > mx) mx = ss[k] }
      print p "_peak_spool_mb=" (mx == "" ? "" : sprintf("%.1f", mx / 1048576))
      c = 0; for (k in n) { split(k, kk, SUBSEP); if (kk[1] == p) c++ }
      print p "_samples=" c
      for (j = 1; j <= 3; j++) {
        g = (j == 1) ? "pod" : (j == 2) ? "src" : "dst"
        print p "_sat_" g "_pct=" (satn[p, g] ? sprintf("%.0f", 100 * sat[p, g] / satn[p, g]) : "")
      }
      print p "_sem_wait_pct=" (semn[p] ? sprintf("%.1f", sem[p] / semn[p]) : "")
      print p "_util_pod_pct=" util(p, "run", quota["pod"])
      print p "_util_src_pct=" util(p, "src", quota["src"])
      print p "_util_dst_pct=" util(p, "dst", quota["dst"])
      print p "_host_cpu_pct=" (hn[p] ? sprintf("%.0f", hsum[p] / hn[p]) : "")
      print p "_host_cpu_max_pct=" (hn[p] ? hmax[p] : "")
      ok = 1; split("run src dst", cs, " ")
      for (j = 1; j <= 3; j++) if (!num(m[p "_start", cs[j], "cpu_usec"]) || !num(m[p "_end", cs[j], "cpu_usec"])) ok = 0
      print p "_marks_ok=" ok
    }
    print "vm_free_min_gib=" (num(vmin) ? sprintf("%.1f", vmin / 1073741824) : "")
    print "spill_bytes_receive=" spill["receive_end"]
    print "spool_mb_receive_end=" (num(sp["receive_end"]) ? sprintf("%.1f", sp["receive_end"] / 1048576) : "")
    print "runner_mem_peak_cg_mb=" (num(m["apply_end", "run", "mem_peak"]) ? sprintf("%.1f", m["apply_end", "run", "mem_peak"] / 1048576) : "")
  }' "$rd/run.env" "$rd/marks.csv" "$rd/samples.csv")

{ cat "$rd/run.env"; echo "$derived"; } | jq -Rn '
  def hex: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
  def lsn: split("/") | (.[0] | hex) * 4294967296 + (.[1] | hex);
  def lsns: if type == "string" and . != "" then split(",") | map(lsn) else [] end;
  [inputs | select(test("^[a-z_0-9]+=")) | capture("^(?<k>[a-z_0-9]+)=(?<v>.*)$")]
  | map({(.k): (if .v == "" then null else (.v | tonumber? // .) end)}) | add
  | . as $r
  | (($r.endpos // "") | if test("^[0-9A-Fa-f]+/[0-9A-Fa-f]+$") then lsn else null end) as $end
  | ($r.variant == "RL") as $rl
  | [ (if $r.rc != 0 then "exit status \($r.rc)" else empty end),
      (if $r.receive_marks_ok != 1 then "receive CPU marks missing" else empty end),
      (if $r.sampler == "dead" then "sampler died" else empty end),
      (if $r.disk_abort != null then "disk abort" else empty end),
      (if ($r.wal_bytes | type) != "number" or $r.wal_bytes <= 0 then "WAL bytes \($r.wal_bytes // "missing")" else empty end),
      (if $r.pgbench_txns != $r.txns then "pgbench ran \($r.pgbench_txns // "no") of \($r.txns) transactions" else empty end),
      (if $r.cleanup_rc != 0 then "stream cleanup exited \($r.cleanup_rc // "-")" else empty end),
      (if [$r.slots_left, $r.publications_left, $r.origins_left] != ["0,0", "0,0", "0,0"]
       then "cleanup left slots \($r.slots_left // "-"), publications \($r.publications_left // "-"), origins \($r.origins_left // "-") (source,target)" else empty end),
      (if $rl then
         (if $r.rl_rc != 0 then "pg_recvlogical exited \($r.rl_rc // "-")" else empty end),
         # a drain that read nothing exits 0 in no time and would read as the fastest receive
         (if ($r.rl_bytes | type) != "number" or $r.rl_bytes <= 0 then "the drain wrote \($r.rl_bytes // "no") bytes" else empty end)
       else
         (if $r.compare != "pass" then "compare data: \($r.compare // "not run")" else empty end),
         (if $r.follow_rc != 0 then "follow exited \($r.follow_rc // "-")" else empty end),
         (if $r.recv_close_n != $r.n then "\($r.recv_close_n // 0) of \($r.n) receives reached endpos" else empty end),
         (if ($r.recv_close_n_total // $r.n) != $r.n then "\($r.recv_close_n_total) receive endpos lines, a receive ran again" else empty end),
         (if $r.apply_end_n != $r.n then "\($r.apply_end_n // 0) of \($r.n) applies reached endpos" else empty end),
         (if $r.apply_marks_ok != 1 then "apply CPU marks missing" else empty end),
         (if $r.rows_match != 1 then "rows applied \($r.rows_applied // "-") differ from the workload rows \($r.rows_workload // "-")" else empty end),
         (if $r.recv_dst_rows != 0 then "target rows changed by \($r.recv_dst_rows // "unknown") during receive: apply was not off" else empty end),
         (if ($r.apply_wake_first_t | type) != "number" or ($r.apply_on_t | type) != "number"
          then "apply wake time \($r.apply_wake_first_t // "-") or sentinel time \($r.apply_on_t // "-") missing"
          elif $r.apply_wake_first_t < $r.apply_on_t then "apply woke before sentinel set apply" else empty end),
         # a build that ignores PGCOPYDB_FOLLOW_MODE writes the SQLite layout and no segment
         (if $r.follow_mode == "performance" and ($r.spool_segments // 0) < 1
          then "no cdc/*.seg file after receive: the build did not run performance mode" else empty end),
         (($r.recv_flush_lsns | lsns) as $f
          | (if $end == null or ($f | length) != $r.n or any($f[]; . < $end)
             then "spool flush LSNs \($r.recv_flush_lsns // "-") do not all cover endpos \($r.endpos // "-")" else empty end))
       end) ] as $dq
  | (if $r.host_cpu_limit == "off" then []
     elif $r.receive_host_cpu_pct == null or $r.apply_host_cpu_pct == null then ["no host CPU reading"]
     else [ (["receive", "apply"][] as $p | $r[$p + "_host_cpu_pct"] as $h
       | select($h > ($r.host_cpu_limit // 400)) | "host CPU outside the VM \($h)% during \($p), limit \($r.host_cpu_limit // 400)%") ] end) as $host
  | . + { disqualified: $dq,
          contended_by: ((if .contended == 1 then ["containers \(.others)"] else [] end)
            + (if (.machines // "") != "" then ["podman machines \(.machines)"] else [] end) + $host),
          cleanup_ok: ([.slots_left, .publications_left, .origins_left] == ["0,0", "0,0", "0,0"]),
          # a run.env from before these keys were recorded cannot show its settings were the defaults
          full_size: (if .full_size == 1 and ([.src_cpus, .dst_cpus, .pod_cpus, .image_v26, .image_v27, .stage0, .big_in] | all(. != null))
            then 1 else 0 end) }
  | . + { contended: ((.contended_by | length) > 0) }
  | . + { valid: (($dq | length) == 0 and (.contended | not) and .receive_s != null
                  and ($rl or .apply_s != null)) }'
