Change Data Capture
===================

pgcopydb implements logical decoding through using the wal2json plugin:

  https://github.com/eulerto/wal2json
  
This means that changes made to the source database during the copying of
the data can be replayed to the target database.

This suite runs `pgcopydb clone --follow --plugin wal2json --wal2json-numeric-as-string` against pagila.
It requires wal2json 2.6 or later for `numeric-data-types-as-string`.
We opt in because the payment tables use numeric columns in full replica identities: rounding `5.99` through a JSON number can make a replayed DELETE miss its row.
This fixture does not change the default mode, which remains compatible with wal2json 2.5.
The source explicitly allows the wal2json output plugin.
The inject service waits for the follow coordinator, runs two DML batches across WAL switches, writes a persistent actor marker, and sets endpos over TCP.
It exits after the coordinator acknowledges endpos; it does not poll a coordinator that follow closes during normal shutdown.
The test MUST fail on clone or SQL errors, missing CDC databases, or empty output, statement, or replay tables.
After follow exits, it checks the marker and compares nonempty actor, rental, and payment data on source and target before cleanup.
The `test`, `run`, and `up` Makefile targets use `docker compose run` so the main test controls completion, not the injector's exit.

Run the harness failure checks without PostgreSQL:

1. From the repository root, run:

   ```sh
   bash tests/follow-wal2json/copydb-test.sh
   ```
