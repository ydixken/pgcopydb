/*
 * src/bin/pgcopydb/snapshot.c
 *     Implementation of a CLI to copy a database between two Postgres instances
 */

#include <errno.h>
#include <inttypes.h>

#include "catalog.h"
#include "copydb.h"
#include "ld_stream.h"
#include "log.h"
#include "pgsql_timeline.h"

/*
 * copydb_copy_snapshot initializes a new TransactionSnapshot from another
 * snapshot that's been exported already, copying the connection string and the
 * snapshot identifier.
 */
bool
copydb_copy_snapshot(CopyDataSpec *specs, TransactionSnapshot *snapshot)
{
	PGSQL pgsql = { 0 };
	TransactionSnapshot *source = &(specs->sourceSnapshot);

	/* copy our source snapshot data into the new snapshot instance */
	snapshot->pgsql = pgsql;
	snapshot->connectionType = source->connectionType;

	/* this is set at set/export/CREATE_REPLICATION_SLOT time */
	snapshot->kind = SNAPSHOT_KIND_UNKNOWN;

	/* remember if the replication slot has been created already */
	snapshot->exportedCreateSlotSnapshot = source->exportedCreateSlotSnapshot;
	snapshot->pguri = strdup(source->pguri);
	strlcpy(snapshot->snapshot, source->snapshot, sizeof(snapshot->snapshot));
	snapshot->isReadOnly = source->isReadOnly;

	return true;
}


/*
 * copydb_open_snapshot opens a snapshot on the given connection.
 *
 * This is needed in the main process, so that COPY processes can then re-use
 * the snapshot, and thus we get a consistent view of the database all along.
 */
bool
copydb_export_snapshot(TransactionSnapshot *snapshot)
{
	PGSQL *pgsql = &(snapshot->pgsql);

	log_debug("copydb_export_snapshot");

	snapshot->kind = SNAPSHOT_KIND_SQL;

	if (!pgsql_init(pgsql, snapshot->pguri, snapshot->connectionType))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * As Postgres docs for SET TRANSACTION SNAPSHOT say:
	 *
	 * Furthermore, the transaction must already be set to SERIALIZABLE or
	 * REPEATABLE READ isolation level (otherwise, the snapshot would be
	 * discarded immediately, since READ COMMITTED mode takes a new snapshot
	 * for each command).
	 *
	 * When --filters are used, pgcopydb creates TEMP tables on the source
	 * database to then implement the filtering as JOINs with the Postgres
	 * catalogs. And even TEMP tables need read-write transaction.
	 */
	IsolationLevel level = ISOLATION_REPEATABLE_READ;
	bool deferrable = true;

	if (!pgsql_is_in_recovery(pgsql, &(snapshot->isReadOnly)))
	{
		/* errors have already been logged */
		(void) pgsql_finish(pgsql);
		return false;
	}

	if (!pgsql_begin(pgsql))
	{
		/* errors have already been logged */
		return false;
	}

	if (!pgsql_set_transaction(pgsql, level, snapshot->isReadOnly, deferrable))
	{
		/* errors have already been logged */
		(void) pgsql_finish(pgsql);
		return false;
	}

	if (!pgsql_export_snapshot(pgsql,
							   snapshot->snapshot,
							   sizeof(snapshot->snapshot)))
	{
		/* errors have already been logged */
		(void) pgsql_finish(pgsql);
		return false;
	}

	snapshot->state = SNAPSHOT_STATE_EXPORTED;

	log_info("Exported snapshot \"%s\" from the source database",
			 snapshot->snapshot);

	/* also set our GUC values for the source connection */
	if (!pgsql_server_version(pgsql))
	{
		/* errors have already been logged */
		return false;
	}

	GUC *settings =
		pgsql->pgversion_num < 90600 ? srcSettings95 : srcSettings;

	if (!pgsql_set_gucs(pgsql, settings))
	{
		log_fatal("Failed to set our GUC settings on the source connection, "
				  "see above for details");
		return false;
	}

	if (!pgsql_set_client_encoding_for_server(pgsql))
	{
		log_fatal("Failed to set client_encoding on the source connection, "
				  "see above for details");
		return false;
	}

	return true;
}


/*
 * copydb_set_snapshot opens a transaction and set it to re-use an existing
 * snapshot.
 */
bool
copydb_set_snapshot(CopyDataSpec *copySpecs)
{
	TransactionSnapshot *snapshot = &(copySpecs->sourceSnapshot);
	PGSQL *pgsql = &(snapshot->pgsql);

	snapshot->kind = SNAPSHOT_KIND_SQL;

	if (!pgsql_init(pgsql, snapshot->pguri, snapshot->connectionType))
	{
		/* errors have already been logged */
		return false;
	}

	if (!pgsql_begin(pgsql))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * Apply replays every change since the slot LSN, so a copy for a slot this
	 * process created reads through its snapshot even under --not-consistent.
	 */
	if (copySpecs->consistent || snapshot->exportedCreateSlotSnapshot)
	{
		/*
		 * As Postgres docs for SET TRANSACTION SNAPSHOT say:
		 *
		 * Furthermore, the transaction must already be set to SERIALIZABLE or
		 * REPEATABLE READ isolation level (otherwise, the snapshot would be
		 * discarded immediately, since READ COMMITTED mode takes a new
		 * snapshot for each command).
		 *
		 * When --filters are used, pgcopydb creates TEMP tables on the source
		 * database to then implement the filtering as JOINs with the Postgres
		 * catalogs. And even TEMP tables need read-write transaction.
		 */
		IsolationLevel level = ISOLATION_REPEATABLE_READ;
		bool deferrable = true;

		if (!pgsql_set_transaction(pgsql, level, snapshot->isReadOnly, deferrable))
		{
			/* errors have already been logged */
			(void) pgsql_finish(pgsql);
			return false;
		}

		if (!pgsql_set_snapshot(pgsql, snapshot->snapshot))
		{
			/* errors have already been logged */
			(void) pgsql_finish(pgsql);
			return false;
		}

		copySpecs->sourceSnapshot.state = SNAPSHOT_STATE_SET;
	}
	else
	{
		copySpecs->sourceSnapshot.state = SNAPSHOT_STATE_NOT_CONSISTENT;
	}

	/* also set our GUC values for the source connection */
	if (!pgsql_server_version(pgsql))
	{
		/* errors have already been logged */
		return false;
	}

	GUC *settings =
		pgsql->pgversion_num < 90600 ? srcSettings95 : srcSettings;

	if (!pgsql_set_gucs(pgsql, settings))
	{
		log_fatal("Failed to set our GUC settings on the source connection, "
				  "see above for details");
		return false;
	}

	if (!pgsql_set_client_encoding_for_server(pgsql))
	{
		log_fatal("Failed to set client_encoding on the source connection, "
				  "see above for details");
		return false;
	}

	return true;
}


/*
 * copydb_close_snapshot closes the snapshot on Postgres by committing the
 * transaction and finishing the connection.
 */
bool
copydb_close_snapshot(CopyDataSpec *copySpecs)
{
	TransactionSnapshot *snapshot = &(copySpecs->sourceSnapshot);
	PGSQL *pgsql = &(snapshot->pgsql);

	if (snapshot->state == SNAPSHOT_STATE_SET ||
		snapshot->state == SNAPSHOT_STATE_EXPORTED ||
		snapshot->state == SNAPSHOT_STATE_NOT_CONSISTENT)
	{
		/* we might need to close our logical stream connection, if any */
		if (snapshot->kind == SNAPSHOT_KIND_LOGICAL)
		{
			(void) pgsql_finish(&(snapshot->stream.pgsql));
		}
		else if (snapshot->kind == SNAPSHOT_KIND_SQL)
		{
			/* only COMMIT sql snapshot kinds, no need for logical rep ones */
			if (!pgsql_commit(pgsql))
			{
				log_fatal("Failed to close snapshot \"%s\" on \"%s\"",
						  snapshot->snapshot,
						  snapshot->safeURI.pguri);
				return false;
			}
		}

		(void) pgsql_finish(pgsql);
	}

	copySpecs->sourceSnapshot.state = SNAPSHOT_STATE_CLOSED;

	return true;
}


/*
 * copydb_prepare_snapshot connects to the source database and either export a
 * new Postgres snapshot, or set the transaction's snapshot to the given
 * already exported snapshot (see --snapshot and PGCOPYDB_SNAPSHOT).
 */
bool
copydb_prepare_snapshot(CopyDataSpec *copySpecs)
{
	/*
	 * Allow this function to be called within a context where a snapshot has
	 * already been prepared. Typically copydb_fetch_schema_and_prepare_specs
	 * needs to prepare the snapshot, but some higher-level functions already
	 * did.
	 */
	if (copySpecs->sourceSnapshot.state != SNAPSHOT_STATE_UNKNOWN &&
		copySpecs->sourceSnapshot.state != SNAPSHOT_STATE_CLOSED)
	{
		log_debug("copydb_prepare_snapshot: snapshot \"%s\" already prepared, "
				  "skipping",
				  copySpecs->sourceSnapshot.snapshot);
		return true;
	}

	/* when --not-consistent is used, we have nothing to do here */
	if (!copySpecs->consistent)
	{
		copySpecs->sourceSnapshot.state = SNAPSHOT_STATE_SKIPPED;
		log_debug("copydb_prepare_snapshot: --not-consistent, skipping");
		return true;
	}

	/*
	 * First, we need to open a snapshot that we're going to re-use in all our
	 * connections to the source database. When the --snapshot option has been
	 * used, instead of exporting a new snapshot, we can just re-use it.
	 */
	TransactionSnapshot *sourceSnapshot = &(copySpecs->sourceSnapshot);

	if (IS_EMPTY_STRING_BUFFER(sourceSnapshot->snapshot))
	{
		if (!copydb_export_snapshot(sourceSnapshot))
		{
			log_fatal("Failed to export a snapshot on \"%s\"",
					  sourceSnapshot->pguri);
			return false;
		}
	}
	else
	{
		if (!copydb_set_snapshot(copySpecs))
		{
			log_fatal("Failed to use given --snapshot \"%s\"",
					  sourceSnapshot->snapshot);
			return false;
		}

		log_info("[SNAPSHOT] Using snapshot \"%s\" on the source database",
				 sourceSnapshot->snapshot);
	}

	/* store the snapshot in a file, to support --resume --snapshot ... */
	if (!file_exists(copySpecs->cfPaths.snfile))
	{
		if (!write_file(sourceSnapshot->snapshot,
						strlen(sourceSnapshot->snapshot),
						copySpecs->cfPaths.snfile))
		{
			log_fatal("Failed to create the snapshot file \"%s\"",
					  copySpecs->cfPaths.snfile);
			return false;
		}

		log_notice("Wrote snapshot \"%s\" to file \"%s\"",
				   sourceSnapshot->snapshot,
				   copySpecs->cfPaths.snfile);
	}

	return true;
}


/*
 * copydb_should_export_snapshot returns true when a snapshot should be
 * exported to be able to implement the command.
 */
bool
copydb_should_export_snapshot(CopyDataSpec *copySpecs)
{
	/* when --not-consistent is used, we have nothing to do here */
	if (!copySpecs->consistent)
	{
		copySpecs->sourceSnapshot.state = SNAPSHOT_STATE_SKIPPED;
		log_debug("copydb_prepare_snapshot: --not-consistent, skipping");
		return false;
	}

	/*
	 * When the --snapshot option has been used, instead of exporting a new
	 * snapshot, we can just re-use it.
	 */
	TransactionSnapshot *sourceSnapshot = &(copySpecs->sourceSnapshot);

	return IS_EMPTY_STRING_BUFFER(sourceSnapshot->snapshot);
}


/*
 * copydb_wal_workers_source connects to the source, which needs Postgres 13:
 * Postgres 12 cannot add a partitioned table to a publication.
 */
static bool
copydb_wal_workers_source(CopyDataSpec *copySpecs, PGSQL *src)
{
	if (!pgsql_init(src, copySpecs->connStrings.source_pguri, PGSQL_CONN_SOURCE) ||
		!pgsql_server_version(src))
	{
		/* errors have already been logged */
		return false;
	}

	if (src->pgversion_num < 130000)
	{
		log_fatal("Option --wal-workers %d requires Postgres 13 or later "
				  "on the source, found Postgres %s",
				  copySpecs->walWorkers, src->pgversion);
		return false;
	}

	return true;
}


/* holds no dot, so no --wal-high-traffic-tables list can equal it */
#define FOLLOW_MODE_PERFORMANCE_TAG "performance"


/*
 * copydb_check_reused_wal_workers refuses a re-used slot set up for other WAL
 * workers, and checks every worker slot without creating or copying one.
 */
static bool
copydb_check_reused_wal_workers(CopyDataSpec *copySpecs,
								StreamSpecs *specs,
								ReplicationSlot *slot)
{
	int walWorkers = copySpecs->walWorkers > 1 ? copySpecs->walWorkers : 1;
	int workers = 1;
	char highTraffic[WAL_HIGH_TRAFFIC_TABLES_BUFSIZE] = { 0 };
	bool found = false;

	if (!catalog_read_wal_worker_setup(&(copySpecs->catalogs.source),
									   &workers,
									   highTraffic,
									   sizeof(highTraffic),
									   &found))
	{
		/* errors have already been logged */
		return false;
	}

	/* copydb_check_cdc_layout already refused a directory of the other mode */
	bool raw = stream_uses_raw_spool(specs);

	if (workers != walWorkers ||
		(!raw && !streq(highTraffic, copySpecs->walHighTrafficTables)))
	{
		log_fatal("Failed to re-use replication slot \"%s\": it was set up "
				  "with --wal-workers %d --wal-high-traffic-tables \"%s\", "
				  "this run uses --wal-workers %d "
				  "--wal-high-traffic-tables \"%s\"",
				  slot->slotName,
				  workers,
				  highTraffic,
				  walWorkers,
				  copySpecs->walHighTrafficTables);
		log_info("Use --restart to drop the replication setup and start over");
		return false;
	}

	if (walWorkers == 1)
	{
		return true;
	}

	PGSQL src = { 0 };

	if (!copydb_wal_workers_source(copySpecs, &src))
	{
		/* errors have already been logged */
		return false;
	}

	for (int k = 0; k < walWorkers; k++)
	{
		char workerSlot[NAMEDATALEN] = { 0 };

		sformat(workerSlot, sizeof(workerSlot), "%s_w%d", slot->slotName, k);

		const char *name = k == 0 ? slot->slotName : workerSlot;

		if (!pgsql_check_wal_worker_slot(&src, name, slot->lsn))
		{
			log_fatal("Failed to re-use replication slot \"%s\" of WAL worker "
					  "%d created at %X/%X, see above for details",
					  name, k, LSN_FORMAT_ARGS(slot->lsn));
			return false;
		}
	}

	return true;
}


/*
 * copydb_check_no_wal_workers refuses a fresh setup over the assignment of an
 * earlier attempt that never recorded its slot: replacing it would hide the
 * worker slots of that attempt from stream cleanup.
 */
static bool
copydb_check_no_wal_workers(CopyDataSpec *copySpecs, ReplicationSlot *slot)
{
	int workers = 0;
	char highTraffic[WAL_HIGH_TRAFFIC_TABLES_BUFSIZE] = { 0 };
	bool found = false;

	if (!catalog_read_wal_worker_setup(&(copySpecs->catalogs.source),
									   &workers,
									   highTraffic,
									   sizeof(highTraffic),
									   &found))
	{
		/* errors have already been logged */
		return false;
	}

	if (found)
	{
		log_fatal("Failed to create replication slot \"%s\": an earlier "
				  "attempt set up --wal-workers %d in catalog \"%s\" and "
				  "stopped before it recorded the slot",
				  slot->slotName,
				  workers,
				  copySpecs->catalogs.source.dbfile);
		log_info("Run pgcopydb stream cleanup with the same --dir, "
				 "--slot-name and --origin as that attempt, then start over "
				 "with --restart");
		return false;
	}

	return true;
}


/*
 * copydb_prepare_wal_workers assigns the tables to publish to WAL workers,
 * stores the assignment, then creates one publication per table.
 */
static bool
copydb_prepare_wal_workers(CopyDataSpec *copySpecs, ReplicationSlot *slot)
{
	PGSQL src = { 0 };
	WalWorkerTable *tables = NULL;
	int count = 0;

	if (!copydb_wal_workers_source(copySpecs, &src) ||
		!pgsql_list_publication_tables(&src, &(copySpecs->filters),
									   &tables, &count))
	{
		/* errors have already been logged */
		return false;
	}

	bool success =
		wal_workers_assign(tables, count,
						   copySpecs->walWorkers,
						   copySpecs->walHighTrafficTables) &&
		catalog_write_wal_workers(&(copySpecs->catalogs.source),
								  copySpecs->walWorkers,
								  copySpecs->walHighTrafficTables,
								  tables, count) &&
		pgsql_create_table_publications(&src, slot->slotName, tables, count);

	free(tables);

	return success;
}


/*
 * copydb_copy_wal_worker_slots copies slot S to S_w<k>, so that every worker
 * starts at the consistent point of the snapshot the base copy uses.
 */
static bool
copydb_copy_wal_worker_slots(CopyDataSpec *copySpecs, ReplicationSlot *slot)
{
	PGSQL src = { 0 };

	if (!pgsql_init(&src, copySpecs->connStrings.source_pguri, PGSQL_CONN_SOURCE))
	{
		/* errors have already been logged */
		return false;
	}

	for (int k = 1; k < copySpecs->walWorkers; k++)
	{
		char workerSlot[NAMEDATALEN] = { 0 };
		uint64_t lsn = InvalidXLogRecPtr;

		sformat(workerSlot, sizeof(workerSlot), "%s_w%d", slot->slotName, k);

		if (!pgsql_copy_logical_replication_slot(&src, slot->slotName,
												 workerSlot, &lsn))
		{
			log_fatal("Failed to create the replication slot of WAL worker %d, "
					  "see above for details",
					  k);
			return false;
		}

		if (lsn != slot->lsn)
		{
			log_fatal("Replication slot \"%s\" was copied at %X/%X, "
					  "expected %X/%X as in replication slot \"%s\"",
					  workerSlot,
					  LSN_FORMAT_ARGS(lsn),
					  LSN_FORMAT_ARGS(slot->lsn),
					  slot->slotName);
			return false;
		}
	}

	return true;
}


/*
 * copydb_create_logical_replication_slot uses Postgres logical replication
 * protocol command CREATE_REPLICATION_SLOT to create a replication slot on the
 * source database, and exports a snapshot while doing so.
 */
bool
copydb_create_logical_replication_slot(CopyDataSpec *copySpecs,
									   const char *logrep_pguri,
									   ReplicationSlot *slot,
									   char *cdcPathDir)
{
	TransactionSnapshot *sourceSnapshot = &(copySpecs->sourceSnapshot);
	StreamSpecs specs = { 0 };

	specs.slot.plugin = slot->plugin;
	specs.followMode = copySpecs->followMode;

	/*
	 * Now is the time to check if a previous command such as
	 *
	 *   pgcopydb snapshot --follow --plugin ... --slot-name ...
	 *
	 * did create the replication slot for us while exporting the snapshot. we
	 * can then re-use the replication slot and the exported snapshot here.
	 *
	 * On the other hand, if a snapshot was exported without the --follow
	 * option then we can't re-use that snapshot.
	 */
	if (slot->lsn != InvalidXLogRecPtr &&
		!IS_EMPTY_STRING_BUFFER(slot->snapshot))
	{
		if (!copydb_check_reused_wal_workers(copySpecs, &specs, slot))
		{
			/* errors have already been logged */
			return false;
		}

		log_info("Re-using replication slot \"%s\" "
				 "created at %X/%X with snapshot \"%s\"",
				 slot->slotName,
				 LSN_FORMAT_ARGS(slot->lsn),
				 slot->snapshot);
		return true;
	}
	else if (!IS_EMPTY_STRING_BUFFER(sourceSnapshot->snapshot))
	{
		log_fatal("Failed to use --snapshot \"%s\" which was not created by "
				  "the replication protocol command CREATE_REPLICATION_SLOT",
				  sourceSnapshot->snapshot);
		log_info("Consider using pgcopydb snapshot --follow");
		return false;
	}

	if (!copydb_check_no_wal_workers(copySpecs, slot))
	{
		/* errors have already been logged */
		return false;
	}

	sourceSnapshot->kind = SNAPSHOT_KIND_LOGICAL;

	LogicalStreamClient *stream = &(sourceSnapshot->stream);

	if (!pgsql_init_stream(stream,
						   logrep_pguri,
						   cdcPathDir,
						   slot->plugin,
						   slot->slotName,
						   InvalidXLogRecPtr,
						   InvalidXLogRecPtr))
	{
		/* errors have already been logged */
		return false;
	}

	/* tagged before the slot, so a crash in between meets the check above */
	if (stream_uses_raw_spool(&specs) &&
		!catalog_write_wal_workers(&(copySpecs->catalogs.source),
								   copySpecs->walWorkers,
								   FOLLOW_MODE_PERFORMANCE_TAG,
								   NULL, 0))
	{
		/* errors have already been logged */
		return false;
	}

	/* for pgoutput, create publication before the slot */
	if (copySpecs->walWorkers > 1)
	{
		if (!copydb_prepare_wal_workers(copySpecs, slot))
		{
			log_fatal("Failed to set up %d WAL workers, see above for details",
					  copySpecs->walWorkers);
			return false;
		}
	}
	else if (slot->plugin == STREAM_PLUGIN_PGOUTPUT &&
			 slot->publicationAutoManaged)
	{
		PGSQL src = { 0 };

		if (!pgsql_init(&src,
						copySpecs->connStrings.source_pguri,
						PGSQL_CONN_SOURCE))
		{
			/* errors have already been logged */
			return false;
		}

		if (!pgsql_create_publication(&src, slot->publicationName,
									  &copySpecs->filters))
		{
			log_error("Failed to create publication \"%s\"",
					  slot->publicationName);
			pgsql_finish(&src);
			return false;
		}

		pgsql_finish(&src);
	}

	/* now create the replication slot, exporting the snapshot */
	if (!pgsql_create_logical_replication_slot(stream, slot))
	{
		log_error("Failed to create a logical replication slot "
				  "and export a snapshot, see above for details");
		return false;
	}

	if (copySpecs->walWorkers > 1 &&
		!copydb_copy_wal_worker_slots(copySpecs, slot))
	{
		/* errors have already been logged */
		return false;
	}

	/* expose the replication slot snapshot as the main transaction snapshot */
	strlcpy(sourceSnapshot->snapshot,
			slot->snapshot,
			sizeof(sourceSnapshot->snapshot));

	sourceSnapshot->state = SNAPSHOT_STATE_EXPORTED;
	sourceSnapshot->exportedCreateSlotSnapshot = true;

	/* store the snapshot in a file, to support --resume --snapshot ... */
	if (!write_file(sourceSnapshot->snapshot,
					strlen(sourceSnapshot->snapshot),
					copySpecs->cfPaths.snfile))
	{
		log_fatal("Failed to create the snapshot file \"%s\"",
				  copySpecs->cfPaths.snfile);
		return false;
	}

	/* store the replication slot information in the SQLite source catalog */
	if (!catalog_write_replication_slot(&(copySpecs->catalogs.source), slot))
	{
		log_fatal("Failed to store replication slot in catalog \"%s\"",
				  copySpecs->catalogs.source.dbfile);
		return false;
	}

	/* initialize catalog timeline history and create the output.db SQLite file */
	specs.paths = copySpecs->cfPaths.cdc;
	specs.sourceDB = &(copySpecs->catalogs.source);
	specs.outputDB = &(copySpecs->catalogs.output);
	specs.replayDB = &(copySpecs->catalogs.replay);
	specs.private.startpos = slot->lsn;

	if (!stream_init_timeline(&specs, stream))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * copydb_check_cdc_layout refuses a work directory that another follow mode
 * started. A slot or a setup row records a mode, performance when the row
 * holds the tag; a directory with neither takes the mode of this run.
 */
bool
copydb_check_cdc_layout(StreamSpecs *specs)
{
	ReplicationSlot slot = { 0 };
	int workers = 0;
	char highTraffic[WAL_HIGH_TRAFFIC_TABLES_BUFSIZE] = { 0 };
	bool found = false;

	if (!catalog_read_replication_slot(specs->sourceDB, &slot) ||
		!catalog_read_wal_worker_setup(specs->sourceDB,
									   &workers,
									   highTraffic,
									   sizeof(highTraffic),
									   &found))
	{
		/* errors have already been logged */
		return false;
	}

	if (!found && IS_EMPTY_STRING_BUFFER(slot.slotName))
	{
		return true;
	}

	bool tagged = found && streq(highTraffic, FOLLOW_MODE_PERFORMANCE_TAG);
	bool raw = stream_uses_raw_spool(specs);

	if (tagged != raw)
	{
		const char *recorded = tagged ? "performance" : "sqlite";

		log_fatal("Refusing the work directory: it was started with "
				  "--follow-mode %s, and this run uses --follow-mode %s; "
				  "resume with --follow-mode %s, or run pgcopydb stream "
				  "cleanup and start over with --restart",
				  recorded,
				  raw ? "performance" : "sqlite",
				  recorded);
		return false;
	}

	return true;
}
