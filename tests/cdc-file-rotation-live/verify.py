#!/usr/bin/env python3
"""
verify.py <check-name>

Checks for the cdc-file-rotation-live test.  Exit 0 on success, 1 on the
first failure.  Receive may still be running: every SQLite file is opened
read-only.
"""

import os
import sqlite3
import subprocess
import sys

TMPDIR = os.environ.get("TMPDIR", "/tmp")
SOURCE_DB = os.path.join(TMPDIR, "pgcopydb", "schema", "source.db")


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def check(condition, msg):
    if not condition:
        fail(msg)
    print(f"ok: {msg}")


def connect(path):
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=10)


def check_markers_before_commits():
    """A closed output.db before the last spools a KEEPALIVE or SWITCH below
    a COMMIT, so the transform hands apply that marker before the transaction,
    a pass that reports no progress while the file still holds work."""
    con = connect(SOURCE_DB)
    files = con.execute(
        "select id, filename, done_time_epoch is not null"
        "  from cdc_files order by id"
    ).fetchall()
    con.close()

    last_id = max(f[0] for f in files) if files else None
    closed = [f[1] for f in files if f[2] and f[0] != last_id]
    hits = 0

    for path in closed:
        con = connect(path)
        (markers,) = con.execute(
            "select count(*) from output m"
            " where m.action in ('K', 'X')"
            "   and exists (select 1 from output c"
            "                where c.action = 'C' and c.lsn > m.lsn)"
        ).fetchone()
        con.close()
        print(f"  {os.path.basename(path)}: {markers} marker(s) below a COMMIT")
        if markers > 0:
            hits += 1

    print(f"cdc_files: {len(files)} files, {len(closed)} closed before the "
          f"last, {hits} with a marker below a COMMIT")
    check(hits >= 1,
          f"a closed output.db holds a marker below a COMMIT ({hits} files)")


def table_rows(uri):
    result = subprocess.run(
        ["psql", "-AtqX", "-v", "ON_ERROR_STOP=1", "-d", uri, "-c",
         "select id, txn, payload from rotation_live order by id"],
        capture_output=True, text=True, check=True,
    )
    return set(result.stdout.splitlines())


def check_rows():
    """The target holds exactly the source rows."""
    src = table_rows(os.environ["PGCOPYDB_SOURCE_PGURI"])
    tgt = table_rows(os.environ["PGCOPYDB_TARGET_PGURI"])
    missing = src - tgt
    extra = tgt - src
    txns = sorted({int(row.split("|")[1]) for row in missing})

    print(f"rotation_live: source={len(src)} target={len(tgt)} "
          f"missing={len(missing)} extra={len(extra)}")
    if txns:
        print(f"  source transactions missing on the target: {txns}")

    check(len(src) > 0, f"the source has rows ({len(src)})")
    check(not missing and not extra,
          f"source and target rows match ({len(src)} vs {len(tgt)})")


CHECKS = {
    "markers-before-commits": check_markers_before_commits,
    "rows": check_rows,
}

if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in CHECKS:
        names = "\n  ".join(CHECKS)
        print(f"usage: verify.py <check>\n\navailable checks:\n  {names}",
              file=sys.stderr)
        sys.exit(1)

    CHECKS[sys.argv[1]]()
