# pgoutput durability harness

`apply-error.sh` and `shutdown.sh` capture each source XID inside its explicit transaction.
After prefetch exits, `spool.sh` checks every output file for exactly one BEGIN and COMMIT and the expected DML counts for that XID.
WAL flush positions bound receiving; only the decoded COMMIT supplies expected durable progress.
Before catchup, the harness replaces prefetch's sentinel end position with the tested apply boundary.
The between-transactions case also requires `C2 < endpos < B3` before testing rejection at C1 and recovery to C2.

The shutdown transaction inserts 1,000 rows, updates the existing row 1 as a marker, then updates row 2 with a 16 KiB payload.
The separate large UPDATE makes libpq flush the preceding messages through its ordinary send path.
GDB stops before origin setup and COMMIT, with inferior function calls disabled.
A target row-lock probe MUST block on the uniquely identified apply backend, which MUST have a live transaction, before the harness authorizes SIGKILL.
The probe's sole blocker identifies that backend among the connections sharing the paused process's application name.
This proves the ordered INSERTs executed uncommitted; payload size alone is not evidence.
After the backend disappears and the probe completes, the old digest, origin, and replay position MUST remain unchanged, and apply MUST NOT report done.
Resuming MUST produce all 2,000 rows, the full source digest, and the exact second COMMIT LSN.

Run the checks from the repository root:

1. Check the spool assertions without PostgreSQL (requires Bash and SQLite).

   ```sh
   bash tests/cdc-pgoutput/spool-test.sh
   ```

2. Run the full suite in Docker.

   ```sh
   make tests/cdc-pgoutput
   ```

The build reuses cached base images, so verify both server versions and the test image's PostgreSQL client version before claiming version-specific coverage.
