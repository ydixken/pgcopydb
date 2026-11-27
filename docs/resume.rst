.. _resuming_operations:

Resuming Operations (snaphots)
==============================

An important aspect of pgcopydb design is detailed in the documentation
section :ref:`pgcopydb_concurrency` and has to do with using many concurrent
worker processes to implement parallelism.

Even when using multiple worker processes, it is important that pgcopydb
operations are consistent. It is essential to guarantee that the same source
schema and data set are used by every single worker process throughout the
operations.

Consistency with multiple Postgres sessions is achieved thanks to Postgres'
ability to export and import snapshots. As per Postgres docs about `Snapshot
Synchronization Functions`__:

__ https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION

.. admonition:: From the PostgreSQL documentation

   PostgreSQL allows database sessions to synchronize their snapshots. A
   snapshot determines which data is visible to the transaction that is
   using the snapshot. Synchronized snapshots are necessary when two or more
   sessions need to see identical content in the database. If two sessions
   just start their transactions independently, there is always a
   possibility that some third transaction commits between the executions of
   the two START TRANSACTION commands, so that one session sees the effects
   of that transaction and the other does not.

   To solve this problem, PostgreSQL allows a transaction to export the
   snapshot it is using. As long as the exporting transaction remains open,
   other transactions can import its snapshot, and thereby be guaranteed
   that they see exactly the same view of the database that the first
   transaction sees. But note that any database changes made by any one of
   these transactions remain invisible to the other transactions, as is
   usual for changes made by uncommitted transactions. So the transactions
   are synchronized with respect to pre-existing data, but act normally for
   changes they make themselves.

   Snapshots are exported with the pg_export_snapshot function, shown in
   `Table 9.94`__, and imported with the `SET TRANSACTION`__ command.

   __ https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION-TABLE
   __ https://www.postgresql.org/docs/current/sql-set-transaction.html

Using these Postgres APIs allows pgcopydb to implement consistent operations
even when using multiple worker processes.

Bypassing consistency issues
----------------------------

If you can ensure that no writes happen on the source database for the whole
duration of the pgcopydb operations, which means no schema change (DDL) and
no data change (DML), then consistency issues can't happen: that's because
the database is *static* for our context, probably within a *maintenance
window* setup where the applications are disconnected from the source
database service.

Note that pgcopydb offers the ``--not-consistent`` option that allows
bypassing all the complexity of sharing a snapshot throughout the
operations. In particular, resuming operations after a crash or even
implementing multi-steps operations is made easier when bypassing
consistency aspects altogether.

When you are able to work within a maintenance window where the database is
isolated from any application traffic, consider using ``--not-consistent``.
   
Consistency and concurrency: Postgres snapshots
-----------------------------------------------

As seen above, Postgres offers different APIs to export and import a
snapshot:

 1. Function ``pg_export_snapshot()`` exports the current snapshot.
 2. SQL command ``SET TRANSACTION SNAPSHOT`` imports the given snapshot.
 3. `Replication protocol`__ command ``CREATE_REPLICATION_SLOT`` allows
    exporting its snapshot.

    __ https://www.postgresql.org/docs/16/protocol-replication.html

Exporting a Postgres snapshot can be done either at the *create replication
slot* time, or from a non-replication connection using the SQL function
``pg_export_snapshot()``. This is an either/or situation, Postgres does not
allow mixing these two approaches.

Also remember that a single snapshot must be used throughout pgcopydb
operations, both the initial COPY of the schema and data and also the Change
Data Capture aspects in order to achieve consistency (no data loss, no
duplicates in the data change stream).

To be able to implement multiple worker processes in pgcopydb and have a
consistent view of the same database (schema, data) in every single process,
pgcopydb needs to first export a single common snapshot and then have every
worker process import that snapshot when connecting to the source database.

When implementing Change-Data-Capture thanks to the ``--follow`` option,
then it is also required that there is no gap between the initial snapshot
and the first change received, and also that no changes are sent that were
part of the initial copy. Postgres knows how to offer that guarantee via its
snapshot exporting facility in the ``CREATE_REPLICATION_SLOT`` replication
command.

As a result, the ``pgcopydb snapshot --follow`` command is required by the
Postgres API to also create the pgcopydb replication slot, and exports the
replication slot snapshot.

The ``pgcopydb snapshot`` command, when the ``--follow`` option is not used,
simply connects to the Postgres source database using the normal query
protocol and run the command ``select pg_export_snapshot()`` to grab a
snapshot that can be shared by all the worker processes.

Moreover the Postgres API for exporting a snapshot has the following
limitation:

.. admonition:: From the PostgreSQL docs

   The snapshot is available for import only until the end of the
   transaction that exported it.

This means that the ``pgcopydb snapshot`` command must be kept running for
the whole pgcopydb initial copy operations. The replication client only uses
the replication slot to ensure consistency, so when only the follow worker
processes are running, holding on to the snapshot is not required anymore.
  
Resumability of pgcopydb operations
-----------------------------------

The ability to resume operations when using pgcopydb faces three quite
different contexts. Depending on the context and when the previous operation
has been interrupted, then running the same pgcopydb command again with the
``--resume`` option might just work, or might error out because the
situation does not allow a consistent resuming of the operation that was
interrupted.

Bypassing consistency issues
^^^^^^^^^^^^^^^^^^^^^^^^^^^^

When the ``--resume --not-consistent`` options are used, then there is no
restrictions around snapshot re-use when trying to resume interrupted
operations. The exception is ``pgcopydb clone --follow`` on a re-used
replication slot with table data left to copy, see below.

Consistent copy of the data
^^^^^^^^^^^^^^^^^^^^^^^^^^^

When using ``pgcopydb clone --resume`` the snapshot used in the previous
attempts is going to be re-used. For Postgres to be able to import that
snapshot again, the transaction that exported the snapshot must still be
running on the source database system.

Single pgcopydb command
  When using ``pgcopydb clone`` the snapshot holding process is part of that
  single process tree, and any interruption of this command (signal, C-c,
  crash) also terminates the snapshot holding sub-process and the snapshot
  is then lost.

Separate pgcopydb snapshot command
  That's why the ``pgcopydb snapshot`` command can be used separately. Then
  the main ``pgcopydb clone`` command re-uses the snapshot automatically and
  can be left holding the snapshot even in case of an interruption of the
  ``pgcopydb clone`` command.

External snapshot
  It is also possible to use another command or software to export and
  maintain the snapshot that pgcopydb uses and then use ``pgcopydb
  clone --snapshot ...`` to share the snapshot with pgcopydb.

Consistent copy of the data with CDC
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

When using Change Data Capture with the ``--follow`` option resuming
operations consistently requires the following situation:

  1. The initial COPY of the data needs to still have access to the exported
     snapshot.

     Even when the snapshot has been exported with a replication protocol
     command, Postgres still requires the session to be maintained opened
     here.
     
  2. The logical replication on the client side is not concerned with the
     snapshot operations, that's done server-side when creating the
     replication slot; from there on, all the client has to do is consume
     from the replication slot.

When it re-uses an existing replication slot, ``pgcopydb clone --follow --not-consistent`` refuses to copy the tables that are left, because apply replays every change since the slot LSN and rows copied without the slot snapshot would then be applied twice.
That includes a slot whose snapshot a ``pgcopydb snapshot --follow`` process still holds, because ``--not-consistent`` imports no snapshot.
The command exits with code 3, and its error starts with ``Refusing to resume the copy:``.
While the ``pgcopydb snapshot --follow`` process runs, resume without ``--not-consistent`` to copy under its snapshot.
Otherwise run ``pgcopydb stream cleanup`` with the same ``--dir``, ``--slot-name`` and ``--origin`` as the failed run, and start over with ``--restart``, adding ``--drop-if-exists`` when the target already has the schema.

A retry that creates a new replication slot copies under that slot's
snapshot, even with ``--not-consistent``.

Resuming with a follow mode
^^^^^^^^^^^^^^^^^^^^^^^^^^^

A work directory records its follow mode, and every command that receives or applies refuses one of the other mode before it writes anything.
The command exits with code 3, and its error starts with ``Refusing the work directory:``.
Do not confuse it with ``Refusing to resume the copy:`` above, which is about a re-used slot and not about the mode.
A directory that a pgcopydb without follow modes wrote has no record, so it reads as ``sqlite`` and resumes unchanged.
The remedy is to resume with the mode the directory was started with.
To change the mode, run ``pgcopydb stream cleanup`` with the same ``--dir``, ``--slot-name`` and ``--origin``, then start over with ``--restart``: the two modes share no spool, so there is nothing to convert.

Resuming with WAL workers
^^^^^^^^^^^^^^^^^^^^^^^^^

With ``--wal-workers`` above 1, the catalog stores the worker count, the ``--wal-high-traffic-tables`` list and the worker of every table, and a resume must use the same two options.
Each worker keeps its own catalog and CDC files in ``cdc/w<k>`` of the work directory, and resumes from its own replication origin, so a worker killed right after a COMMIT on the target does not apply that transaction again.
A resume never creates or copies a worker slot.
It refuses to run when a worker slot is missing, uses another plugin than pgoutput, is invalidated, or has a confirmed flush LSN below the LSN the catalog recorded when the slots were created.
When ``cdc/w<k>`` is lost, the resume builds it again from the main catalog only while the slot of that worker is still where it was created, because the lost files held changes that a moved slot does not send again.

The setup creates the slot of worker 0 with the exported snapshot, then copies it once per other worker, and records the slot in the catalog only after the last copy.
A setup that stops before that, killed or failed on a copy, for instance with too few ``max_replication_slots``, leaves its worker assignment in the catalog and no slot.
A rerun refuses to set up WAL workers over that assignment, whatever ``--wal-workers`` it uses.
Run ``pgcopydb stream cleanup`` with the same ``--dir``, ``--slot-name`` and ``--origin``, which drops every worker slot and publication of that setup, then start over with ``--restart``.
A ``pgcopydb follow``, or a ``pgcopydb clone --follow`` whose copy finished, that stops after the setup recorded the slots, for instance before it created the replication origins, resumes with ``--resume``.
A ``pgcopydb clone --follow`` that stops there before its copy finished has lost the exported snapshot, so its resume is refused with ``Refusing to resume the copy:``.
Run ``pgcopydb stream cleanup`` and start over with ``--restart``.

Foreign keys with WAL workers
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

With ``--wal-workers`` above 1, the foreign keys are created only once every WAL worker reached endpos.
A command that stops before that exits with an error and logs ``Foreign keys are pending``.
Run it again with ``--resume``, and it creates the foreign keys once every worker reached endpos.
The file ``schema/fkeys.done`` in the work directory records that they exist, so a rerun skips them.
A command that stops while it creates them leaves no such file, and the next run drops the foreign keys it finds before it creates them all again.

Snapshot and catalogs (cache invalidation)
------------------------------------------

The source catalog table ``setup`` registers information about the current
pgcopydb command. The information is checked at start-up in order to avoid
re-using data in a different context.

The information registered is the following, and also contains the
*snapshot* information. In case of a mismatch, consider using ``--resume
--not-consistent`` when that's relevant to your operations.

Here's how to inspect the current ``setup`` information that pgcopydb
maintains in its local catalog cache:

::

   $ sqlite3 /tmp/pgcopydb/schema/source.db
   sqlite> .mode line
   sqlite> select * from setup;
                         id = 1
              source_pg_uri = postgres:///pagila
              target_pg_uri = postgres:///plop
                   snapshot = 00000003-00000048-1
   split_tables_larger_than = 0
                    filters = {"type":"SOURCE_FILTER_TYPE_NONE"}
                     plugin =
                  slot_name =

The source and target connection strings only contain the Postgres servers
hostname, port, database name and connecting role name. In particular,
authentication credentials are not stored in the catalogs.


