.. _logical_decoding_internals:

Logical Decoding
================

This document records the detailed understanding of PostgreSQL logical decoding
LSN semantics, the replication protocol, and how pgcopydb exploits that
understanding to track progress and support user-defined ``endpos`` values
safely.

PostgreSQL WAL LSN semantics
-----------------------------

WAL record layout
~~~~~~~~~~~~~~~~~

PostgreSQL WAL is a packed byte stream.  Every record has two canonical
positions:

- **ReadRecPtr** — byte offset of the record's first byte, the "LSN" of that
  record.
- **EndRecPtr** — byte offset of the first byte immediately after the record
  (= ``ReadRecPtr`` of the next record, assuming MAXALIGN padding).

Because records are packed with no gaps (beyond alignment), consecutive WAL
records share a byte boundary::

    Record N starts at ReadRecPtr_N.
    Record N ends   at EndRecPtr_N  = ReadRecPtr_{N+1}.

Reorderbuffer fields for a logical transaction
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The ``ReorderBufferTXN`` struct (``reorderbuffer.h``) tracks three LSN values
per decoded transaction:

.. list-table::
   :header-rows: 1
   :widths: 20 80

   * - Field
     - Meaning
   * - first_lsn
     - ReadRecPtr of the first WAL record belonging to this XID (the BEGIN
       record)
   * - final_lsn
     - ReadRecPtr of the COMMIT record ("beginning of commit record")
   * - end_lsn
     - EndRecPtr of the COMMIT record = ReadRecPtr of the NEXT WAL
       record

The relationship ``end_lsn = final_lsn + sizeof(COMMIT_record)`` always holds.
``end_lsn`` is one byte past the COMMIT, which equals the start of whatever WAL
record follows.

LSN values on the replication protocol wire
--------------------------------------------

When the logical decoding plugin callbacks fire, ``ctx->write_location`` is set
to ``txn->first_lsn`` (the start of the BEGIN record) for BEGIN callbacks and
to ``txn->end_lsn`` (the byte immediately past the end of the COMMIT record)
for COMMIT callbacks.  ``WalSndPrepareWrite`` (``walsender.c``) embeds
``ctx->write_location`` as the ``dataStart`` field of the XLogData protocol
message, which the replication client reads as ``cur_record_lsn``.

pgcopydb does **not** pass ``include-lsn=true`` to wal2json, so wal2json does
not embed an ``"lsn"`` field in its JSON output.  pgcopydb uses the raw
protocol ``dataStart`` value as ``metadata->lsn`` for every message.

For consecutive transactions N and N+1, COMMIT_N is therefore delivered with
``dataStart = txn_N->end_lsn`` and BEGIN_{N+1} with ``dataStart =
txn_{N+1}->first_lsn``.  Because ``txn_N->end_lsn`` equals
``EndRecPtr(COMMIT_N)`` which equals ``ReadRecPtr`` of the next WAL record
which equals ``txn_{N+1}->first_lsn``, the two messages carry the same LSN
value.  This LSN collision is not an edge case but the guaranteed layout
whenever two transactions are consecutive in WAL; the
``ld_store_lookup_output_after_lsn`` cursor handles it by using ``>=`` when
filtering for BEGIN rows (so that the next transaction's BEGIN is included at
exactly that LSN) and strict ``>`` for KEEPALIVE and COMMIT rows (which can
share an LSN with the preceding COMMIT without being the next transaction's
BEGIN).

Replication feedback and safe restart points
---------------------------------------------

The `PostgreSQL streaming replication protocol <https://www.postgresql.org/docs/current/protocol-replication.html>`_ requires periodic standby status updates reporting received, flushed, and applied LSN positions.
For logical replication, PostgreSQL uses the reported flush LSN to advance the slot's ``confirmed_flush_lsn``, which only increases.
On reconnect, streaming starts at the greater of the requested start position and ``confirmed_flush_lsn``.
The receiver must therefore account for changes already stored locally that the server may not send again.

``sentinel.replay_lsn`` records durable target progress.
The SQLite apply path uses ``synchronous_commit=on`` and checks the pipelined COMMIT result before publishing the source COMMIT LSN.
Before any data commit, apply can publish the initialized replication-origin position without a user write.
On restart, ``setupReplicationOrigin`` reads ``pg_replication_origin_progress()`` and sets ``context->previousLSN`` from that authoritative target position.
KEEPALIVE rows have a separate cursor and never advance ``previousLSN``, the target origin, or ``sentinel.replay_lsn``.

The receiver tracks three positions for feedback:

* ``P`` is the durable apply position from ``sentinel.replay_lsn``, zero until initialized.
* ``C`` is the highest actual COMMIT LSN durably stored in the output spool and still relevant to apply.
  It uses the same ``metadata->lsn`` representation as output and apply, and excludes skipped empty or filtered transactions.
* ``K`` is the highest genuine primary keepalive LSN received on this replication connection, whether or not the server requested a reply.
  Raw XLogData positions and synthetic KEEPALIVE rows do not set ``K``.

Before receiving, pgcopydb scans the COMMIT rows in every relevant ``cdc_files`` entry, including rotated output files.
It excludes only closed files whose endpos is strictly below durable apply progress, using the same rule as CDC cleanup.
A source-catalog write transaction freezes ``P`` during the scan; it does not lock filesystem unlink operations.
Cleanup using an already captured horizon ``R <= P`` can remove only closed files with ``endpos < R``, which the scan excludes.
Holding ``P`` fixed prevents other scan candidates from becoming eligible for cleanup.
An empty spool is valid only after these reads succeed.
During streaming, ``C`` increases only after the output SQLite transaction containing a non-skipped COMMIT has committed.

.. warning::

   Invalid filenames, missing or unreadable required spool files, and failed catalog queries stop receiver startup.
   Required files may contain acknowledged transactions that PostgreSQL will not resend, so disabling keepalive promotion is not a safe fallback.
   Cleanup-orphaned catalog entries do not block startup when the closed-file ``endpos < P`` rule proves they are already applied.

With initialized ``P > 0``, feedback normally reports ``P``.
It may also advance the network flush and replay positions to ``K`` when startup accounting is complete, ``C <= P``, no transaction is being received, and endpos is unset.
This lets feedback cover WAL with no pending replicated changes without claiming that a target data transaction committed at ``K``.
Once ``P`` is initialized, the receiver retains its last certified replay position as a monotonic floor for the lifetime of the receiver process, including connection retries.
It never advances that certified position from raw spool flush progress.
The receiver refreshes the sentinel before constructing a feedback packet.
A failed sync stops the send because the current flush value may still be raw spool progress rather than certified target progress.
A failed keepalive spool write also aborts the streaming attempt; existing error handling rolls back any open output batch before retrying or exiting.

Before ``P`` is initialized, receive and prefetch keep their spool-only flush acknowledgements and report no target replay progress.
A prefetch acknowledgement ``W`` can exceed the later applied ``P``, so wire flush reports may decrease when switching to certified replay feedback.
This is why startup cannot initialize ``C`` to zero without checking old spool files: PostgreSQL may already have acknowledged those COMMITs while apply was still disabled.
On a connection retry, the receiver clears ``K`` but retains ``C`` and its certified feedback floor.
A process restart reconstructs ``C`` from the retained catalogs and requires a new primary keepalive before promoting feedback beyond ``P``.

Why pgcopydb supports endpos mid-transaction
---------------------------------------------

The user-supplied ``--endpos`` LSN is a raw WAL position snapshotted with
``pg_current_wal_lsn()``.  PostgreSQL makes no guarantee that this snapshot
lands at a transaction boundary; it can fall:

- **Before any open transaction** (between consecutive committed transactions)
- **Inside an uncommitted transaction** (past a BEGIN but before its COMMIT)
- **Exactly at a COMMIT boundary** (rarest case; ``COMMIT.end_lsn``)

Rejecting non-boundary endpos values would force operators to coordinate
with source workload — impractical.  Instead pgcopydb handles all three cases:

.. list-table::
   :header-rows: 1
   :widths: 20 30 30 20

   * - Case
     - Condition
     - apply action
     - ``replay_lsn``
   * - At boundary
     - ``endpos = COMMIT.end_lsn``
     - stop after that commit
     - ``= endpos`` ✓
   * - Between txns (Guard 2)
     - ``endpos < beginLSN_next``
     - stop before next txn
     - stays at ``last_commit``
   * - Mid-transaction
     - ``beginLSN < endpos < commitLSN``
     - apply full txn, stop
     - stays at ``commitLSN`` (> endpos)

If receive stops before a transaction's COMMIT reaches the spool, apply leaves that transaction unapplied.
If the complete transaction is already in the spool, apply can commit it in full before stopping.
Neither path fabricates applied progress at endpos.

Internal model for endpos tracking
------------------------------------

pgcopydb tracks two separate concerns:

PostgreSQL-facing feedback
~~~~~~~~~~~~~~~~~~~~~~~~~~

Setting endpos disables new keepalive-based feedback advancement.
The receiver continues to report durable apply progress with its previous certified feedback position as a floor.
That network position does not change the target origin or prove that endpos has drained.

Internal endpos-reached signal
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Indicates that the pipeline has processed everything it should process up to
the user's ``endpos``, regardless of where ``endpos`` fell relative to
transaction boundaries.

This signal flows through two mechanisms:

**a.** ``sentinel.replay_lsn >= sentinel.endpos`` is the primary check.
It fires when the last durable applied commit covers endpos.

**b.** ``pipeline_state["apply"].run_state = 'done'`` with ``sentinel.endpos != 0`` is the secondary check.
It covers a clean drain when endpos falls between or inside transactions without an applied COMMIT at endpos.
Apply marks itself ``'done'`` only after a successful, intentional exit; interrupted work is not a successful drain.

``follow_reached_endpos`` checks (a) first; if (a) misses, it checks (b).

Transform exit for mid-transaction endpos
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When inline transform detects that receive has finished but the current XID's COMMIT has never arrived (``pending_xid != 0`` after receive-done):

1. ``ld_store_iter_output`` sets ``specs->private.midTxnEndpos = true``.
2. The apply driver sees the flag and stops without advancing ``previousLSN`` to endpos.
3. Apply publishes its last durable COMMIT position and records a clean exit in ``pipeline_state``.

Receive signals completion over the receive-to-apply lifecycle pipe, or through its durable pipeline state when no pipe is available (see :ref:`pipe_protocol`).

Apply exit for mid-transaction and between-transaction endpos
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

**Guard 2** (``endpos < beginLSN``): endpos lies before the next transaction's BEGIN.

- ``context->previousLSN`` is not advanced to ``endpos``.
- ``stream_apply_sync_sentinel()`` is called with ``previousLSN = last_commit``.
- ``sentinel.replay_lsn = last_commit_lsn``.
- ``context->reachedEndPos = true``; loop exits.
- ``pipeline_state_end("apply", last_commit_lsn, true)`` records the clean exit.

**No rows after receive finishes**: the straddling transaction has no COMMIT in the output table.

- Same as Guard 2: ``previousLSN`` not modified, ``replay_lsn = last_commit``.
- ``pipeline_state_end("apply", last_commit_lsn, true)``.

In both cases ``follow_reached_endpos`` catches completion via the secondary
pipeline_state check, not via ``replay_lsn >= endpos``.

Apply driver loop
~~~~~~~~~~~~~~~~~

The apply process runs a single driver loop.  Each iteration:

1. snapshots the in-memory ``pipeline_state`` for the ``apply`` process;
2. dispatches the **transform stage** (``outputDB`` → ``replayDB``), which
   updates that in-memory state for every complete transaction it writes;
3. dispatches the **replay stage** (``replayDB`` → target), which updates the
   state for every transaction it commits; then
4. compares the post-iteration state against the snapshot.

The loop only evaluates its terminal conditions (endpos reached,
mid-transaction endpos, or receive done) when an iteration makes **no**
progress.  This guarantees that a transaction the transform stage has just
produced is always consumed by the replay stage before the loop can declare
itself done — in particular when ``endpos`` lands exactly on a ``COMMIT``
boundary, which is the value ``pg_current_wal_flush_lsn()`` returns right
after a committed batch.

The in-memory ``pipeline_state`` is checkpointed to ``sourceDB`` periodically
and once more at end of processing, rather than once per transaction.

Restart safety
~~~~~~~~~~~~~~

Apply restarts from the target replication origin, not a keepalive or endpos marker.
Receive accounts for every relevant retained output file before certifying new keepalive feedback.
Transactions already acknowledged during prefetch remain available in that spool even when PostgreSQL does not redeliver them.
The BEGIN cursor uses ``>=`` so it includes a next transaction beginning exactly at the previous COMMIT LSN.
An incomplete transaction can be completed by redelivery without advancing the apply cursor past its missing COMMIT.

.. _pipe_protocol:

The receive→apply lifecycle pipe
--------------------------------

Alongside the LSN bookkeeping above, the ``receive`` and ``apply`` workers need
one small piece of direct coordination: ``apply`` must learn, with minimal
latency, that ``receive`` has reached the end position and will produce no
further changes. Like the rest of the pipeline this is a deliberate design
choice worth recording.

In the SQLite CDC model the change data itself never travels between the two
workers directly. ``receive`` records decoded changes into the *output* store
and ``apply`` reads from there, transforms the rows inline, and writes them to
the target; concurrent access to those stores is serialised by a shared write
semaphore. The only thing the workers exchange directly is the *"I am done"*
signal.

That single fact is delivered over a one-way pipe from ``receive`` to ``apply``.
The pipe carries exactly one message for its whole lifetime: the final LSN that
``receive`` stopped at — in effect, *"I am done, at position X"*. ``apply`` waits
on the pipe while it drains the store, so it wakes immediately when the signal
arrives instead of discovering completion by polling.

This follows the pattern PostgreSQL uses for postmaster-death detection — the
"death watch" pipe behind ``PostmasterIsAlive()``. The upstream process holds
the write end open for its entire run and closes it on exit, while the
downstream process watches the read end for readiness:

- a readable pipe **with data** is the normal *"done at LSN X"* hand-off;
- a closed pipe **with no data** (end-of-file) means the upstream went away
  unexpectedly.

pgcopydb layers the final-LSN payload on top of that bare death-watch so that
``apply`` can also drain cleanly up to the right transaction boundary, rather
than merely learning *that* the upstream is gone.

The pipe is purely a latency optimisation, and it exists only when ``receive``
and ``apply`` run together under the same follow supervisor. When ``apply`` (or
``stream catchup``) runs on its own, there is no live pipe; it instead consults
the durable ``pipeline_state`` record that ``receive`` leaves behind in the
source catalog to decide when the upstream has finished. Unexpected upstream
death is, in the live case, ultimately caught by the supervisor monitoring its
children, with the pipe end-of-file serving as a belt-and-suspenders fallback.

Invariant summary
-----------------

.. list-table::
   :header-rows: 1
   :widths: 30 25 25 20

   * - Value
     - Advances at
     - Never set to
     - Drives
   * - Network flush/replay LSN (``P > 0``)
     - durable apply or certified primary keepalive
     - uncertified raw receive position as replay
     - source slot feedback
   * - ``sentinel.replay_lsn``
     - origin initialization or confirmed target COMMIT
     - keepalive or fabricated endpos
     - ``follow_reached_endpos`` check (a)
   * - ``pipeline_state["apply"].run_state``
     - process exit (``'done'``/``'error'``)
     - success after interruption
     - ``follow_reached_endpos`` check (b)
   * - ``context->previousLSN``
     - target Postgres COMMIT confirmed
     - mid-txn or between-txn endpos
     - apply replay cursor; origin restart
