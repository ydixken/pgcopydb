# Keepalive feedback regressions

This suite distinguishes network feedback from durable target apply progress using `pgoutput`.
Its self-contained Compose configuration follows `cdc-pgoutput-resume`, with the same debugger capabilities, isolated databases, and no external volumes.

## Run

Run these commands from the repository root, one build or suite at a time.

1. Rebuild both base images after changing source or switching PostgreSQL versions, because `make tests/...` reuses cached images.

   ```sh
   PGVERSION=18 make force-build
   docker build --build-arg PGVERSION=18 -t pagila -f tests/Dockerfile.pagila tests
   ```

2. Run the focused suite.

   ```sh
   PGVERSION=18 make tests/cdc-keepalive
   ```

3. Run the existing shutdown, apply-error, receive-resume, rotation, and endpos coverage separately.

   ```sh
   PGVERSION=18 make tests/cdc-pgoutput
   PGVERSION=18 make tests/cdc-pgoutput-resume
   PGVERSION=18 make tests/cdc-file-rotation
   PGVERSION=18 make tests/cdc-endpos-mid-txn
   PGVERSION=18 make tests/cdc-endpos-in-multi-wal-txn
   ```

The focused suite removes its Compose resources on success or failure.
If interrupted, run `make -C tests/cdc-keepalive down`.

## Cases and evidence

Use `FEEDBACK_CASE` to run one case against baseline and fixed images with the same test files.
For example, run the idle reproduction with:

```sh
FEEDBACK_CASE=idle PGVERSION=18 make tests/cdc-keepalive
```

- **`idle`**: apply one published transaction, then emit 32 MiB of nontransactional logical messages and switch WAL without published writes.
  Require wire write, flush, and replay to reach the captured head while target origin and sentinel replay remain at the actual COMMIT.
  Baseline `aadc4bf7a60f3030c569a10c5da2eeb4e531e6ad` is expected to fail the explicit `flush_lsn AND replay_lsn >= filtered head` predicate after write has reached that head, not an outer process timeout.
- **`backlog`**: hold a target SHARE lock, publish a row, and inspect the complete durable spool with pgcopydb processes stopped.
  Observe wire feedback reaching three successive filtered WAL heads while flush and replay remain below the unapplied COMMIT, then release the lock and verify exact contents and progress.
- **`restart`**: prefetch before apply publishes its initialized origin, with sentinel replay at `0/0` and 1 KiB output rotation.
  Require confirmed flush beyond the unapplied COMMIT, prove that COMMIT resides in an older file and the latest file contains no COMMIT, then restart receive/apply with the target locked and only filtered WAL arriving.
  Require conservative wire feedback after apply initializes sentinel replay from the target origin, then release and apply the retained transaction.
  This checks actual wire, spool, and target state without altering catalog data or receiver variables.
- **`empty`**: clone an empty table and publish no transactions.
  Wait for apply to publish the nonzero initialized origin, then require idle feedback progress without changing that origin or sentinel replay.
- **`in-flight`**: use existing C symbols in GDB to stop after BEGIN, force the next timed flush and feedback, and hold a barrier after the reply reaches libpq.
  Require the receive transaction flag to remain set through the flush-generated keepalive and wire flush/replay not to advance beyond durable progress or previously sent feedback.
  Previously acknowledged keepalives remain valid, so this check permits monotonic feedback rather than requiring it to retreat.
  Release the barrier and verify all 10,001 rows by count and ordered digest.
  This case exercises a synthetic flush keepalive inside a transaction; the other cases exercise genuine server keepalives.

All cases run without endpos.
Keep the original snapshot exporter alive through every `follow --resume`, including the initial-zero prefetch restart; follow imports the stored snapshot during setup.
Streaming shutdown and pause target the owned pgcopydb process group, leaving the exporter alive until final cleanup.
Capture each published transaction's XID and read its unique COMMIT LSN from the stopped spool, checking one BEGIN and the exact INSERT count.
Use `pg_current_wal_flush_lsn()` only as a receive bound or filtered head, never as an assumed transaction COMMIT.
Paused inspection uses one query per file, a five-second query timeout, and a 20-second pause budget below the source's 60-second sender timeout.
Each in-flight attempt creates a fresh barrier directory shared explicitly with GDB.
Polls have deadlines and reject absent replication rows, missing spool files, and unknown processes.
Live sentinel reads use the existing CLI; direct SQLite reads occur only with receive/apply stopped.
Failures print wire feedback, origin, sentinel, target contents, and process logs.

Baseline/fixed runtime results must be captured before using these tests as public issue evidence.
Rebuild both base images for each source revision and retain the same test files; do not infer a baseline failure from a fixed-only run.
