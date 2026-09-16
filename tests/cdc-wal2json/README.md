Change Data Capture
===================

pgcopydb implements logical decoding through using the wal2json plugin:

  https://github.com/eulerto/wal2json
  
This means that changes made to the source database during the copying of
the data can be replayed to the target database.

This suite uses pagila and SQL scripts to test receive, catchup, idempotency, SQL templates, and floating-point precision.
We compare all message content and actions against the golden file after mapping XIDs to ordinals in first-seen order in each file.
Equal XIDs retain equal ordinals, distinct transactions stay distinct, and messages without XIDs remain unchanged.
Missing or empty input fails the comparison.

Run the focused normalization check with SQLite and jq installed:

1. From the repository root, run:

   ```sh
   bash tests/cdc-wal2json/normalize-test.sh
   ```
