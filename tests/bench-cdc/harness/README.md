# CDC benchmark harness: WAL receive and apply

This harness measures WAL receive and WAL apply of `pgcopydb follow --plugin pgoutput` separately, one run at a time on a local podman machine, under a shared podman lock.
It compares images built from this repository and measured together in one session, a base and a candidate, in either follow mode, against each other and against a plain `pg_recvlogical` drain.
The variant `V26-1` still reads the published runner image of operator release v0.26.0 (pgcopydb 0.18.144.g86bf908), which no rule compares against.

[TOC]

## Structure

`tests/bench-cdc` is a local harness outside CI: it is not a Compose suite, and `tests/Makefile` and the workflows do not know it.

```sh
tests/bench-cdc/
├── harness/           # this harness
│   ├── README.md      # this file
│   ├── run-rel.sh     # one run of one variant on one workload, on fresh bench-rel-* objects
│   ├── inner-rel.sh   # pgcopydb steps inside the runner container
│   ├── sample-rel.sh  # cgroup and catalog sampler, phase marks, VM free space, other podman machines
│   ├── result-rel.sh  # result.json of one run directory
│   ├── matrix-rel.sh  # every run of an order file; skips valid runs, so it resumes
│   ├── report-rel.sh  # medians, ranges, ratios against a reference variant, runs left out
│   ├── order-A.txt    # workload A, 5 runs per release variant
│   ├── order-B.txt    # workload B, 3 runs per release variant
│   ├── order-Q-A.txt  # workload A, 5 alternating pairs of BASE-1 and CAND-1
│   ├── order-Q-B.txt  # workload B, 5 alternating pairs of BASE-1 and CAND-1
│   ├── order-P1-A.txt # workload A, 5 blocks of the 5 Phase 1 gate variants
│   ├── order-P1-B.txt # workload B, 5 blocks of the 5 Phase 1 gate variants
│   ├── schema-b.sql   # workload B: 8 tables of 1.6 kB rows
│   └── gen-b.sh       # workload B pgbench script
├── workload-a/        # workload A: schema.sql and gen.sh, read by the harness, the probe and the profile
├── probe/             # stage 0 probe of a single-slot apply, see probe/README.md
└── profile/           # perf profile of one follow at one worker, see "Profile" below
```

## Variants and workloads

- `V26-1`: runner v0.26.0, no `--wal-workers` (0.18.144 has no such option).
- `V27-1`: the image `IMAGE_V27`, `--wal-workers 1`.
- `V27-8`: the image `IMAGE_V27`, `--wal-workers 8`.
- `V27-8HT`: the image `IMAGE_V27`, `--wal-workers 8 --wal-high-traffic-tables` with the workload's hot tables.
- `BASE-1`: the image `IMAGE_BASE`, `--wal-workers 1`, which must print the version `WANT_BASE`.
- `CAND-1`: the image `IMAGE_CAND`, `--wal-workers 1`, which must print the version `WANT_CAND`.
- `PERF-1`: the image `IMAGE_CAND`, `--wal-workers 1`, with `PGCOPYDB_FOLLOW_MODE=performance` in the runner container, because a build of this repository runs sqlite mode by default.
  `run.env` records the mode as `follow_mode`.
- `RL`: a plain `pg_recvlogical` drain in the runner container of the image `IMAGE_CAND`, the yardstick for the receive rule.
  It has no apply phase, no `compare data` and no `apply_s`.

`BASE-1`, `CAND-1`, `PERF-1` and `RL` need all four of `IMAGE_BASE`, `WANT_BASE`, `IMAGE_CAND` and `WANT_CAND`, and the three `V27` variants need `IMAGE_V27` and `WANT_V27`.
An unset one is a usage error.
The `V27` variants measure the sqlite mode of a build of this repository, so they carry no default image: no rule reads the numbers of a published runner.
`run.env` records every tag and image id.
All variants use `--plugin pgoutput --slot-name bench --origin bench`, and the clone uses `--table-jobs 4 --index-jobs 4`.
`run-rel.sh` refuses an image whose `pgcopydb --version` is not the expected one.

Workload A is the stage 0 OLTP workload from `../workload-a` (override with `STAGE0`), 1280000 transactions, seed 4242, hot tables `public.h1,public.h2,public.h3,public.h4,public.w01`.
Workload B is 8 tables of rows with about 1.6 kB of base64 text from sha512, below the TOAST threshold, and transactions of 10 inserts and 2 updates on tables drawn Zipf s = 1.1, seed 4243, hot tables `public.b1,public.b2`.
We size B at 88000 transactions for about 2 GB of WAL, extrapolated from the smoke run (8000 transactions wrote 257 MB, of which full-page images were a large share); check `wal_mb` of the first B run.

## Images for BASE-1 and CAND-1

Both images come from the fork's own `Dockerfile` and get tags of their own, so that no suite image is replaced.
We build the base from an archive of its commit, because the shared checkout is not switched for it.
Run this from the top of the repository, with a `docker` command on the PATH (podman works through a two-line shim, `#!/bin/sh` and `exec podman "$@"`).

```sh
tmp=$(mktemp -d)
git archive 9d8b660 | tar -x -C "$tmp"
VERSION=0.18.159.g9d8b660 make -C "$tmp" version
docker build --build-arg PGVERSION=18 -t pgcopydb-bench:base "$tmp"
rm -f version GIT-VERSION-FILE && make version
docker build --build-arg PGVERSION=18 -t pgcopydb-bench:cand .
```

The archive holds neither `version` nor `GIT-VERSION-FILE`, which the `Dockerfile` copies, and `GIT-VERSION-GEN` takes `VERSION` when there is no `version` file.
Each `docker build` line is the command that `make force-build` runs, with another tag.
`WANT_CAND` is the content of the file `version` after the second `make version`; a `-dirty` suffix is expected while tracked files are modified.
No rule compares with the numbers of a published runner image: build the base right before the measurement, with the same recipe.

## Run procedure

1. Fresh source and target `postgres:18.7` (`SRC_CPUS` 4, `DST_CPUS` 2, `max_wal_size=16GB`, `checkpoint_timeout=1h`, so no checkpoint lands inside the backlog) and a pod (`POD_CPUS` 8) with the runner and a pgbench container; the work volume is chowned to the runner image's user.
2. Schema and seed, then `pgcopydb clone` with the source quiesced.
3. `pgcopydb follow` until every receive's walsender streams, TERM to its process group, then `stream sentinel set prefetch`; the sentinel must read `apply: false`.
4. A `CHECKPOINT`, then the pgbench backlog with no consumer.
   The start LSN is the lowest slot `confirmed_flush_lsn`, endpos is `pg_current_wal_flush_lsn()` after the load, and WAL bytes are the difference.
   endpos goes into the sentinel, then `VACUUM` and `CHECKPOINT` put WAL past it.
5. Receive phase: `follow --resume --not-consistent` with apply off, until every receive logged that it reached endpos.
6. Apply phase: `stream sentinel set apply`, until every apply reached endpos and follow exited 0.
7. `compare data`, then `stream cleanup`; slots, publications and origins are counted on both sides.

`RL` replaces steps 5 to 7 with one drain.
Step 3 creates the slot `bench_rl` with pgoutput where the other variants let follow create theirs, before the backlog, so both retain WAL from the same point.
The drain is `pg_recvlogical --start --no-loop --endpos <endpos> -o proto_version=1 -o publication_names=bench -f <work volume>/rl.out`, the plugin options that follow passes, and `receive_s` is its wall time from start to exit.
`stream cleanup` does not know that slot, so step 7 drops it.

`PRE_COMPARE_SQL` runs on the target right before `compare data`.
It exists to break a run on purpose, so a run that sets it is never full size, and the matrix refuses to start with it set.

## Phase boundaries

The receive phase starts at the in-container clock read just before `follow --resume` starts.
It ends at the last `streamCloseFile: receive done at` line, which receive logs once it met a record or keepalive past endpos and flushed its spool (86bf908 `ld_stream.c:1336`, 9d8b660 `ld_stream.c:1387`).
`receive_exit_s` uses the later `pipeline_state_end: receive done at` line (`sentinel.c:856`).

The apply phase starts at the clock read just before `stream sentinel set apply`.
With one worker it ends at `pipeline_state_end: apply done at` from the apply process (`sentinel.c:856`, called from 86bf908 `ld_apply.c:160`, 9d8b660 `ld_apply.c:177`).
With 8 workers it ends at the last `WAL worker K with pid P has reached endpos` line of the supervisor (9d8b660 `follow.c:2347`), which it logs after that worker exits, within its 100 ms poll.
`apply_pse_s` is the last per-worker `pipeline_state_end: apply done` line instead, which compares like for like with one worker.
`exit_s` runs until follow exits, which with 8 workers includes the foreign key pass at endpos.

> [!note]
> Apply polls the sentinel once a second (`CATCHINGUP_SLEEP_MS`), so `apply_s` holds up to a second before apply starts; `apply_wake_s` shows how much.

## Metrics

`result.json` holds per phase: seconds, WAL MB (10^6 bytes) and MB/s, transactions (pgbench) and rows (source `pg_stat_user_tables` over the backlog) per second, CPU seconds of the runner, source and target cgroups between the phase marks, mean use of each CPU quota between the marks (`util_*_pct`), peak anonymous and total memory of the runner, peak spool, saturated sample shares, semaphore waits and the host's CPU outside the VM.
`rows_applied` is the target's row count over the apply phase and must equal `rows_workload` (`rows_match`).
CPU marks are taken by `podman exec` around the phase.
The receive window holds up to a second of idle time either side of `receive_s`.
The apply window runs until follow exits plus the target's counter settle (1 to 10 s), so with 8 workers it includes the foreign key pass at endpos; `exit_s` is the duration that matches apply CPU, not `apply_s`.
`util_*_pct` comes from the marks, so it does not depend on the 5 s sample interval that the saturated shares use.
`host.log` holds the five busiest host processes of each host reading, the evidence behind a host CPU flag.
The total memory of the runner includes the page cache of the spool it writes, so read `peak_anon_mb` for process memory.

A run is valid when all of these hold:

- it exited 0, follow exited 0 and `compare data` passed;
- every receive and every apply logged endpos once, and every receive's final flush LSN is at or past endpos;
- the target's row counters did not move during the receive phase, and the apply wake time is logged and comes after `sentinel set apply`;
- WAL bytes are positive, pgbench ran every transaction, and `rows_applied` equals `rows_workload`;
- the CPU marks exist, the sampler lived and the disk check did not abort;
- `stream cleanup` exited 0 and left no slot, publication or replication origin on either side;
- in performance mode, the work directory holds a `cdc/*.seg` file after receive, so a build that ignores `PGCOPYDB_FOLLOW_MODE` cannot pass as performance mode.

`RL` has no follow and no compare, so it keeps the rules it can answer and drops the rest: it exited 0, `pg_recvlogical` exited 0 and wrote a positive number of bytes, the receive CPU marks exist, WAL bytes are positive, pgbench ran every transaction, the run is not contended, and cleanup left no slot, publication or origin.
We read the bytes the drain wrote, because a drain that found nothing to read also exits 0, in no time, and would otherwise read as the fastest receive of the session.

A run is contended, and left out, when another container ran in the VM, another podman machine than `podman-machine-default` was running or starting at the start check, a phase mark or a sample (`machines.log`), or the mean CPU of host processes outside the VM exceeded `HOST_CPU_LIMIT` (400%, the 4 host cores the 14 vCPUs leave free) in either phase.
`host_cpu()` leaves VM processes out by name, so a second machine's vCPUs would not show in the host CPU; `run-rel.sh` refuses to start while one runs, and a failed `podman machine list` counts as one.
The report lists every run left out with its reasons, including the attempts the matrix superseded, and prints the attempts per variant next to the valid runs.

## Commands

Set `BENCH_LOCK` to the shared lock directory (see "Rules for local runs"), take an empty results directory outside the repository, and run a matrix, then the report.
Run the commands of this section from `tests/bench-cdc/harness`.

```sh
export IMAGE_V27=pgcopydb-bench:cand WANT_V27=$(cat ../../../version)
./matrix-rel.sh "$OUT" A
./matrix-rel.sh "$OUT" B
./report-rel.sh "$OUT"
```

Compare a base and a candidate image with the Q order files, in a new results directory each time, and read every ratio against the base.

```sh
export IMAGE_BASE=pgcopydb-bench:base WANT_BASE=0.18.159.g9d8b660
export IMAGE_CAND=pgcopydb-bench:cand WANT_CAND=$(cat ../../../version)
./matrix-rel.sh "$OUT" A order-Q-A.txt
REF_VARIANT=BASE-1 ./report-rel.sh "$OUT"
```

Run the Phase 1 gate with the P1 order files, five blocks of `BASE-1`, `PERF-1`, `V27-8`, `V27-8HT` and `RL`.
The first report serves the apply and recommendation rules, the second the receive rule.

```sh
export IMAGE_BASE=pgcopydb-bench:base WANT_BASE=<the version of the Q1 build>
export IMAGE_CAND=pgcopydb-bench:cand WANT_CAND=<the version of the Phase 1 build>
export IMAGE_V27=pgcopydb-bench:cand WANT_V27=$WANT_CAND
./matrix-rel.sh "$OUT" A order-P1-A.txt
./matrix-rel.sh "$OUT" B order-P1-B.txt
REF_VARIANT=BASE-1 ./report-rel.sh "$OUT"
REF_VARIANT=RL ./report-rel.sh "$OUT"
```

`matrix-rel.sh` takes an order file as its optional third argument, `order-<WORKLOAD>.txt` by default.
`report-rel.sh` lists every variant its results hold, and prints each one against `REF_VARIANT` (default `V26-1`): the ratio of the medians, the conservative ratio, and min and max of both variants.

Run the matrix again to resume it: valid runs are skipped and the others start over, the old directory kept as `<label>.prev-<epoch>`.
A skipped run is not checked against the current images, so each comparison takes a new results directory.
The matrix refuses to start with `TXNS`, `SEED`, `CLIENTS`, `LABEL`, `SRC_CPUS`, `DST_CPUS`, `POD_CPUS`, `PG_IMAGE`, `IMAGE_V26`, `STAGE0`, `BIG_IN` or `PRE_COMPARE_SQL` set, and skips only a run whose `result.json` is valid, full size and of the order line's variant and workload.
A run is full size only when all of those settings have their defaults; `run.env` records each of them, and a `run.env` without them reads as not full size.
`IMAGE_BASE`, `WANT_BASE`, `IMAGE_CAND`, `WANT_CAND`, `IMAGE_V27` and `WANT_V27` are inputs of the variants that need them, not overrides, so they do not change the full size.
The report groups runs that are not full size apart from the full-size ones and labels them.
`matrix-rel.sh` exits 1 when any run failed or ended not valid.

> [!important]
> `run-rel.sh` and `matrix-rel.sh` stop with a usage error when `BENCH_LOCK` is unset, before they touch podman: a default lock would let two users of the podman machine run at once.
> `run-rel.sh` refuses to start while any `bench-rel-*` object exists or the podman machine has less than `NEED_GIB` free (12 for A, 16 for B), and the sampler removes the pod below `MIN_FREE_GIB` (6).
> It frees no space itself.

## Rules for local runs

The harness, the probe and the profile share one podman machine with other benchmarks and with the Compose suites.

1. Set the environment: a `docker` command that runs podman on the PATH, `PGVERSION` exported, and `BENCH_LOCK` set to the lock directory that every user of this podman machine shares.
   Run builds and `make` targets from the top of the repository, the harness commands from `tests/bench-cdc/harness` (see "Commands"), and the profile from `tests/bench-cdc` (see "Profile").
2. Hold the lock for every command that builds an image or runs a container, and release it right after.
   The harness scripts take it themselves; around a build or a suite, put acquire, command and release in one shell call.

    ```sh
    L="$BENCH_LOCK"
    ME="<your label> $$"
    until mkdir "$L" 2>/dev/null; do sleep 20; done
    echo "$ME" > "$L/owner"
    release() { [ "$(cat "$L/owner" 2>/dev/null)" = "$ME" ] && rm -rf "$L"; }
    trap release EXIT
    # build or run here
    release; trap - EXIT
    ```

3. Never delete, recreate or overwrite a lock directory that you did not create.
   Report a lock directory older than 3 hours and do not break it.
4. Never hold the lock while you edit or think.
   A measurement taken while other containers run is invalid.
5. The image tags of the suites are not per version: a switch between PostgreSQL 16 and 18 needs both force-builds again (`make force-build` and `make -C tests force-build`).
   A `-dirty` version suffix is expected while tracked files are modified.
6. `make tests/<suite>` leaves its containers, so run `docker compose down --volumes --remove-orphans` in the suite's directory after it.
7. Check the disk before a matrix, and stop below 6 GiB free in the podman machine.

    ```sh
    podman system df && podman machine ssh 'df -h /'
    ```

8. Never remove named volumes or tagged images that you did not create, and clean up by recorded tag or id only.

Ten suites build their source at PostgreSQL 16 whatever `PGVERSION` says, because their compose file passes no build argument: `cdc-endpos-in-multi-wal-txn`, `cdc-endpos-mid-txn`, `cdc-file-rotation`, `cdc-filtering-pgoutput`, `cdc-pgoutput`, `cdc-wal2json`, `follow-data-only`, `follow-filtering`, `follow-pgoutput`, `follow-wal2json`.

## Profile

Run these from `tests/bench-cdc`.
`profile/run.sh OUT [TXNS]` runs one follow at one worker on workload A under `perf`, receive and apply each, and `profile/analyze.sh OUT` turns the samples into the groups of `classify.py`.
Both use the probe's `lib.sh`, so they need `BENCH_LOCK` too.
`run.sh` lowers `kernel.perf_event_paranoid` in the podman machine for the run and sets it back at the end.
The image `probe-pgcopydb-prof` builds pgcopydb with debug info and frame pointers from a context directory `ctx/` with `GIT-VERSION-GEN`, `Makefile`, `version` and `src/` of the commit to profile.
Build it outside the repository, under the lock.

```sh
tmp=$(mktemp -d)
mkdir "$tmp/ctx"
git archive 9d8b660 GIT-VERSION-GEN Makefile src | tar -x -C "$tmp/ctx"
echo 0.18.159.g9d8b660 > "$tmp/ctx/version"
podman build -t probe-pgcopydb-prof -f tests/bench-cdc/profile/Containerfile "$tmp"
```

## Caveats

- The harness adds CPU to the runner cgroup: the sampler's spool `du` and 1 s `/proc` scan every 5 s, the 0.5 s `du` loop of `inner-rel.sh start` and the log greps of `wait-receive` and `wait-exit`.
  The sampler alone cost about 0.8% of a core on a smoke backlog, and the polling grows with the worker count and the log size.
- Samples come every 5 s, so a phase of a few seconds gets one or two saturation samples, and host processes that start and exit between two `ps` snapshots are never counted.
- The per-phase memory peaks are peaks of the 5 s samples and the marks, so short spikes are missed.
  `runner_mem_peak_cg_mb` is the cgroup's `memory.peak` at `apply_end`, which covers the container's whole life including the clone, not one phase.
