/*
 * src/bin/pgcopydb/follow.c
 *     Implementation of a CLI to copy a database between two Postgres instances
 */

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/prctl.h>
#endif

#include "catalog.h"
#include "cli_common.h"
#include "cli_root.h"
#include "file_utils.h"
#include "follow_coordinator.h"
#include "ld_store.h"
#include "ld_stream.h"
#include "log.h"
#include "progress.h"
#include "signals.h"


/*
 * Optional follow coordinator: a TCP server, run inside this (the follow
 * supervisor) process, that serves "pgcopydb stream sentinel" CLI clients over
 * TCP.  It shares the supervisor's open sourceDB catalog and its IPC_PRIVATE
 * write semaphore, so CLI clients never open the SQLite catalog themselves.
 *
 * Initialised to an inactive state (fd = -1); follow_coordinator_handle_messages
 * is a no-op until followDB() starts it (only when --host was given).
 */
static FollowCoordinator followCoord = { .tcp_listen = { .fd = -1 } };

static bool follow_supervise_workers(CopyDataSpec *copySpecs,
									 StreamSpecs *streamSpecs);


/*
 * follow_assert_pipe_fd validates that a pipe file descriptor is positive and
 * ready for use.  A non-positive fd means the pipe was never created, or was
 * already closed and set to -1 by stream_signal_upstream_done — either way
 * the follow pipeline cannot make progress.  We exit immediately with a FATAL
 * so the operator gets a clear diagnostic rather than a confusing EBADF later.
 */
static void
follow_assert_pipe_fd(int fd, const char *label)
{
	if (fd <= 0)
	{
		log_fatal("BUG: pipe fd %s = %d is invalid; "
				  "--follow pipeline is broken and cannot proceed",
				  label, fd);
		exit(EXIT_CODE_INTERNAL_ERROR);
	}
}


/*
 * follow_close_pipe_fd closes a pipe fd when it is still open.
 *
 * stream_signal_upstream_done sets specs->pipe_XX[n] = -1 after it has closed
 * the underlying file descriptor.  Callers that close the fd as a safety net
 * after their main loop use this helper so that the already-handled case is
 * silently skipped rather than calling close(-1) and dying with EBADF.
 */
static void
follow_close_pipe_fd(int fd, const char *label)
{
	if (fd <= 0)
	{
		log_debug("follow_close_pipe_fd: %s already closed (fd=%d), skipping",
				  label, fd);
		return;
	}

	if (close(fd) != 0)
	{
		log_fatal("Failed to close pipe fd %s (%d): %m", label, fd);
		exit(EXIT_CODE_INTERNAL_ERROR);
	}
}


/*
 * follow_export_snapshot opens a snapshot that we're going to re-use in all
 * our connections to the source database. When the --snapshot option has been
 * used, instead of exporting a new snapshot, we can just re-use it.
 */
bool
follow_export_snapshot(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	/*
	 * When using logical decoding, we need to create our replication slot and
	 * fetch the snapshot from that logical replication command.
	 */
	char *logrep_pguri = streamSpecs->connStrings->logrep_pguri;

	if (!copydb_create_logical_replication_slot(copySpecs,
												logrep_pguri,
												&(streamSpecs->slot),
												streamSpecs->paths.dir))
	{
		/* errors have already been logged */
		return false;
	}

	if (!catalog_write_replication_slot(streamSpecs->sourceDB,
										&(streamSpecs->slot)))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * Also update the setup table's snapshot/plugin/slot_name so that
	 * catalog_register_setup_from_specs() can validate consistency when
	 * later commands (e.g. pgcopydb clone) open the same catalog.
	 */
	if (!catalog_setup_replication(streamSpecs->sourceDB,
								   streamSpecs->slot.snapshot))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * follow_setup_databases ensures that both source and target databases are
 * setup for logical decoding operations (replication slot, replication origin
 * tracking, pgcopydb.sentinel table).
 */
bool
follow_setup_databases(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	/*
	 * We want to make sure to use a private PGSQL client connection
	 * instance when connecting to the source database now, as the main
	 * connection is currently active holding a snapshot for the whole
	 * process.
	 */
	CopyDataSpec setupSpecs = { 0 };
	TransactionSnapshot snapshot = { 0 };

	/* copy our structure wholesale */
	setupSpecs = *copySpecs;

	/* ensure we use a new snapshot and connection in setupSpecs */
	if (!copydb_copy_snapshot(copySpecs, &snapshot))
	{
		/* errors have already been logged */
		return false;
	}

	setupSpecs.sourceSnapshot = snapshot;

	/*
	 * Now create the replication slot and the pgcopydb sentinel table on
	 * the source database, and the origin (replication progress tracking)
	 * on the target database.
	 */
	if (!stream_setup_databases(&setupSpecs, streamSpecs))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * follow_reset_sequences resets the sequences on the target database to match
 * the source database at this very moment (not in any pre-established
 * snapshot). Postgres logical decoding lacks support for syncing sequences.
 *
 * This step is implement as if running the following command:
 *
 *   $ pgcopydb copy sequences --resume --not-consistent
 *
 * The whole idea is to fetch the "new" current values of the sequences, not
 * the ones that were current when the main snapshot was exported.
 */
bool
follow_reset_sequences(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	CopyDataSpec seqSpecs = { 0 };

	/* copy our structure wholesale */
	seqSpecs = *copySpecs;

	/* then force some options such as --resume --not-consistent */
	seqSpecs.restart = false;
	seqSpecs.resume = true;
	seqSpecs.consistent = false;
	seqSpecs.section = DATA_SECTION_SET_SEQUENCES;

	/* we don't want to re-use any snapshot */
	TransactionSnapshot snapshot = { 0 };

	seqSpecs.sourceSnapshot = snapshot;

	/* fetch schema information from source catalogs, including filtering */
	if (!copydb_fetch_schema_and_prepare_specs(&seqSpecs))
	{
		/* errors have already been logged */
		return false;
	}

	bool reset = true;

	if (!copydb_copy_all_sequences(&seqSpecs, reset))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * follow_restore_fkeys creates the foreign keys that WAL workers keep off the
 * target once the run reached endpos, or logs that they are pending. With one
 * worker, post-data created them and it returns followed.
 */
bool
follow_restore_fkeys(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs,
					 bool followed)
{
	if (copySpecs->walWorkers <= 1)
	{
		return followed;
	}

	bool stopped = asked_to_stop || asked_to_stop_fast || asked_to_quit;
	bool done = false;

	if (followed && !stopped &&
		catalog_open_from_specs(copySpecs) &&
		follow_reached_endpos(streamSpecs, &done) &&
		done &&
		copydb_target_restore_fkeys(copySpecs))
	{
		return true;
	}

	log_warn("Foreign keys are pending: they are created once every WAL "
			 "worker reached endpos, run the command again with --resume");

	return false;
}


/*
 * follow_init_sentinel sets the sentinel endpos to the command line --endpos
 * option, when given.
 */
bool
follow_init_sentinel(StreamSpecs *specs, CopyDBSentinel *sentinel)
{
	DatabaseCatalog *sourceDB = specs->sourceDB;

	if (!catalog_open(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	if (specs->endpos != InvalidXLogRecPtr)
	{
		if (!sentinel_update_endpos(sourceDB, specs->endpos))
		{
			/* errors have already been logged */
			return false;
		}
	}

	if (!sentinel_get(sourceDB, sentinel))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * follow_get_sentinel refreshes the given CopyDBSentinel with the current
 * values from the pgcopydb.sentinel table.
 */
bool
follow_get_sentinel(StreamSpecs *specs, CopyDBSentinel *sentinel, bool verbose)
{
	DatabaseCatalog *sourceDB = specs->sourceDB;

	if (!sentinel_get(sourceDB, sentinel))
	{
		/* errors have already been logged */
		return false;
	}

	/* always accept the startpos and apply values from the sentinel */
	specs->startpos = sentinel->startpos;

	/* the endpos might have changed on the sentinel table */
	if (sentinel->endpos != InvalidXLogRecPtr &&
		sentinel->endpos != specs->endpos)
	{
		specs->endpos = sentinel->endpos;

		log_info("Current sentinel replay_lsn is %X/%X, "
				 "endpos has now been set to %X/%X",
				 LSN_FORMAT_ARGS(sentinel->replay_lsn),
				 LSN_FORMAT_ARGS(sentinel->endpos));
	}
	else if (verbose)
	{
		if (sentinel->endpos != InvalidXLogRecPtr)
		{
			log_info("Current sentinel replay_lsn is %X/%X, endpos is %X/%X",
					 LSN_FORMAT_ARGS(sentinel->replay_lsn),
					 LSN_FORMAT_ARGS(sentinel->endpos));
		}
		else if (sentinel->replay_lsn != InvalidXLogRecPtr)
		{
			log_info("Current sentinel replay_lsn is %X/%X",
					 LSN_FORMAT_ARGS(sentinel->replay_lsn));
		}
	}

	return true;
}


/*
 * follow_main_loop implements the main loop for the follow sub-process
 * management. It loops between two modes of operations:
 *
 *  1. prefetch + catchup
 *  2. live replay using Unix pipes between sub-processes
 *
 * When the catchup process needs to read a file on-disk that does not exist
 * yet, it quits with EXIT_CODE_QUIT (success) and the loop terminate the other
 * subprocesses and switch to the live replay mode of operations.
 *
 * When a sub-process ends abnormally then the main process terminates the
 * sibling worker processes and restart in the other mode.
 *
 * Each time we switch from a mode of operations to another, a catchup from
 * disk is done to ensure we don't miss applying what has already been
 * received.
 */
bool
follow_main_loop(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	if (streamSpecs->walWorkers > 1)
	{
		return follow_supervise_workers(copySpecs, streamSpecs);
	}

	DatabaseCatalog *sourceDB = &(copySpecs->catalogs.source);

	if (!catalog_open(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * The SQLite-based CDC pipeline uses a single CATCHUP mode for all
	 * operations: prefetch writes WAL records to the output table, transform
	 * converts them to parameterised SQL in the replay table, and catchup
	 * applies them to the target.  The old CATCHUP↔REPLAY alternation (which
	 * switched to Unix-pipe live streaming once the on-disk files were caught
	 * up) is no longer needed — SQLite provides the inter-process
	 * communication and the three workers can restart in the same mode every
	 * time.
	 */
	while (true)
	{
		if (!followDB(copySpecs, streamSpecs))
		{
			log_error("Failed to follow changes from source, "
					  "see above for details");
			return false;
		}

		if (asked_to_quit)
		{
			log_error("Main follow process received SIGQUIT, exiting");
			return false;
		}

		bool done = false;

		if (!follow_reached_endpos(streamSpecs, &done))
		{
			/* errors have already been logged */
			return false;
		}

		if (done)
		{
			log_info("Follow mode is now done, "
					 "reached endpos %X/%X with replay_lsn %X/%X",
					 LSN_FORMAT_ARGS(streamSpecs->sentinel.endpos),
					 LSN_FORMAT_ARGS(streamSpecs->sentinel.replay_lsn));

			return true;
		}

		/*
		 * On the raw path the done marker is the only finish, and a signal
		 * never writes it. A run that stopped short of endpos therefore
		 * fails, so that the next one resumes and no cutover reads a short
		 * drain as a finished one.
		 */
		if (streamSpecs->sentinel.endpos != InvalidXLogRecPtr &&
			stream_uses_raw_spool(streamSpecs))
		{
			log_error("Subprocesses exited with endpos set at %X/%X and the "
					  "apply recorded no finish there, with replay_lsn at "
					  "%X/%X. Data not fully applied.",
					  LSN_FORMAT_ARGS(streamSpecs->sentinel.endpos),
					  LSN_FORMAT_ARGS(streamSpecs->sentinel.replay_lsn));

			return false;
		}

		if (asked_to_stop || asked_to_stop_fast || asked_to_quit)
		{
			log_warn("Main follow process was asked to terminate, exiting");
			return true;
		}

		/*
		 * With endpos set, subprocesses have exited but follow_reached_endpos
		 * returned done=false — meaning neither the replay_lsn check nor the
		 * pipeline_state 'done' check fired.  This is a genuine pipeline
		 * failure: endpos is set but the data was not fully applied.
		 *
		 * The replay_lsn >= endpos check here is a fallback safety net (the
		 * primary check is inside follow_reached_endpos); if it somehow fires
		 * here, accept it as success rather than returning a spurious error.
		 */
		if (streamSpecs->sentinel.endpos != InvalidXLogRecPtr)
		{
			/* the supervisor starts a WAL worker again, or fails the run */
			if (streamSpecs->walWorker)
			{
				log_info("WAL worker stopped short of endpos %X/%X "
						 "with replay_lsn %X/%X",
						 LSN_FORMAT_ARGS(streamSpecs->sentinel.endpos),
						 LSN_FORMAT_ARGS(streamSpecs->sentinel.replay_lsn));
				return true;
			}

			if (streamSpecs->sentinel.endpos <= streamSpecs->sentinel.replay_lsn)
			{
				log_info("Subprocesses exited with endpos reached at %X/%X "
						 "(replay_lsn: %X/%X). Pipeline complete.",
						 LSN_FORMAT_ARGS(streamSpecs->sentinel.endpos),
						 LSN_FORMAT_ARGS(streamSpecs->sentinel.replay_lsn));
				return true;
			}
			else
			{
				log_error("Subprocesses exited with endpos set at %X/%X "
						  "but replay_lsn only reached %X/%X and pipeline_state "
						  "did not confirm clean completion. "
						  "Data not fully applied.",
						  LSN_FORMAT_ARGS(streamSpecs->sentinel.endpos),
						  LSN_FORMAT_ARGS(streamSpecs->sentinel.replay_lsn));
				return false;
			}
		}

		log_info("Restarting logical decoding follower in %s mode "
				 "(endpos unset, waiting for more data)",
				 LogicalStreamModeToString(streamSpecs->mode));
	}

	/* keep compiler happy */
	log_warn("BUG: follow_main_loop reached out of loop");
	return true;
}


/*
 * follow_reached_endpos sets done to true when endpos has been reached.
 *
 * Two checks are performed:
 *
 * Check (a) — primary: sentinel.replay_lsn >= sentinel.endpos.
 *   Fires when the last applied commit naturally covered endpos (normal case,
 *   Guard 3 mid-txn where the full transaction was committed and its
 *   commitLSN >= endpos).
 *
 * Check (b) — secondary: apply exited with run_state='done'.
 *   Fires when endpos fell between two transactions (Guard 2: endpos < beginLSN)
 *   or inside an uncommitted transaction (mid-txn endpos).  In those cases
 *   apply exits cleanly without advancing replay_lsn past endpos, so check (a)
 *   does not fire.  apply also marks run_state='done' when a signal stopped
 *   it, so check (b) alone does not prove that apply reached endpos.
 *
 * A WAL worker uses check (b) only: its apply records 'done' only at endpos,
 * once its origin and slot are there, and never after a signal.
 *
 * The raw path uses neither: its done marker names the endpos it served, which
 * check (a) cannot read from a cut above endpos and check (b) would read from
 * a run that a signal stopped.
 */
bool
follow_reached_endpos(StreamSpecs *streamSpecs, bool *done)
{
	bool verbose = true;
	CopyDBSentinel *sentinel = &(streamSpecs->sentinel);

	if (!follow_get_sentinel(streamSpecs, sentinel, verbose))
	{
		log_error("Failed to get sentinel values");
		return false;
	}

	if (stream_uses_raw_spool(streamSpecs))
	{
		*done = stream_apply_marker_at_endpos(streamSpecs->sourceDB,
											  sentinel->endpos);

		if (*done)
		{
			log_info("Current endpos %X/%X has been reached: the apply "
					 "recorded its finish there, with replay_lsn %X/%X",
					 LSN_FORMAT_ARGS(sentinel->endpos),
					 LSN_FORMAT_ARGS(sentinel->replay_lsn));
		}

		return true;
	}

	/* Check (a): normal commit-boundary endpos, not proof for a WAL worker */
	if (!streamSpecs->walWorker &&
		sentinel->endpos != InvalidXLogRecPtr &&
		sentinel->endpos <= sentinel->replay_lsn)
	{
		/* follow_get_sentinel logs replay_lsn and endpos already */
		*done = true;

		log_info("Current endpos %X/%X has been reached at replay_lsn %X/%X",
				 LSN_FORMAT_ARGS(sentinel->endpos),
				 LSN_FORMAT_ARGS(sentinel->replay_lsn));

		return true;
	}

	/*
	 * Check (b): endpos fell between or inside transactions.
	 *
	 * replay_lsn is still at the last real commit (< endpos).  The pipeline
	 * signals completion by having apply exit with run_state='done'.
	 */
	if (sentinel->endpos != InvalidXLogRecPtr)
	{
		PipelineStateEntry as = { 0 };
		DatabaseCatalog *sourceDB = streamSpecs->sourceDB;

		bool apply_done =
			pipeline_state_get(sourceDB, "apply", &as) &&
			as.process_name[0] != '\0' &&
			strcmp(as.run_state, "done") == 0;

		if (apply_done)
		{
			*done = true;

			log_info("Current endpos %X/%X reached: apply done at %X/%X "
					 "(replay_lsn %X/%X; endpos was at a transaction boundary)",
					 LSN_FORMAT_ARGS(sentinel->endpos),
					 LSN_FORMAT_ARGS(as.run_end_lsn),
					 LSN_FORMAT_ARGS(sentinel->replay_lsn));
		}
	}

	return true;
}


/*
 * follow_prepare_mode_switch prepares for the next mode of operation. We need
 * to make sure that all that was streamed in our JSON file has been
 * transformed and replayed from file before changing our mode of operations.
 */
bool
follow_prepare_mode_switch(StreamSpecs *streamSpecs,
						   LogicalStreamMode previousMode,
						   LogicalStreamMode currentMode)
{
	log_info("Catching-up from existing on-disk files");

	/*
	 * Catch-up with what has been streamed and transformed into the SQLite
	 * replayDB, applying those changes to the target database.
	 */
	LogicalStreamMode mode = streamSpecs->mode;
	streamSpecs->mode = STREAM_MODE_CATCHUP;

	FollowSubProcess *catchup = &(streamSpecs->catchup);

	if (!follow_start_subprocess(streamSpecs, catchup))
	{
		streamSpecs->mode = mode;
		log_error("Failed to start the %s process", catchup->name);
		return false;
	}

	if (!follow_wait_subprocesses(streamSpecs))
	{
		streamSpecs->mode = mode;
		log_error("Failed to catchup with on-disk files, "
				  "see above for details");
		return false;
	}

	/* re-install the streamSpecs->mode as it was before getting there */
	streamSpecs->mode = mode;

	return true;
}


/*
 * followDB implements a logical decoding client for streaming changes from the
 * source database into the target database.
 *
 * The source database is expected to have been setup already so that the
 * replication slot using wal2json is ready, the pgcopydb.sentinel table
 * exists, and the target database replication origin has been created too.
 */
bool
followDB(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	int errors = 0;

	if (streamSpecs->mode < STREAM_MODE_PREFETCH)
	{
		log_error("BUG: followDB with stream mode %d", streamSpecs->mode);
		return false;
	}

	/*
	 * Before starting sub-processes, make sure to close our SQLite catalogs.
	 * We open the SQLite catalogs again before returning from this function
	 * (if only when reaching the end of it and returning true).
	 */
	if (!catalog_close(streamSpecs->sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * Create the lifecycle signal pipe.
	 *
	 * pipe_rt carries an 8-byte big-endian done-LSN from receive → apply.
	 *
	 * This is always created when both endpoints will run together so that
	 * the downstream process can select() on the read end and wake up
	 * immediately when upstream finishes, without polling SQLite.
	 *
	 * In text-streaming mode (stdOut / stdIn), the same pipe fd is also
	 * used for the JSON data stream; in replayDB mode it carries only the
	 * single lifecycle signal message.
	 */
	if (pipe(streamSpecs->pipe_rt) != 0)
	{
		log_fatal("Failed to create receive→apply pipe: %m");
		return false;
	}

	FollowSubProcess *prefetch = &(streamSpecs->prefetch);
	FollowSubProcess *catchup = &(streamSpecs->catchup);

	/*
	 * When set to prefetch changes, we start the receive (prefetch) process.
	 * Upper modes (catchup, replay) imply prefetching too.
	 */
	if (streamSpecs->mode >= STREAM_MODE_PREFETCH)
	{
		if (!follow_start_subprocess(streamSpecs, prefetch))
		{
			log_error("Failed to start the %s process", prefetch->name);
			return false;
		}
	}

	/*
	 * When set to catchup or replay mode, we also start the catchup process.
	 */
	if (streamSpecs->mode >= STREAM_MODE_CATCHUP)
	{
		if (!follow_start_subprocess(streamSpecs, catchup))
		{
			log_error("Failed to start the %s process", catchup->name);

			(void) follow_exit_early(streamSpecs);
			return false;
		}
	}

	/*
	 * Close pipe ends which follow is not using. Otherwise the apply process
	 * which reads from the pipe during replay will never see EOF.
	 */
	if (streamSpecs->stdOut)
	{
		close_fd_or_exit(streamSpecs->pipe_rt[1]);
		close_fd_or_exit(streamSpecs->pipe_rt[0]);
	}

	/*
	 * Finally wait until the process are finished.
	 *
	 * This happens when the sentinel endpos is set, typically using the
	 * command: pgcopydb stream sentinel set endpos --current.
	 *
	 * When waipid() catches a subprocess termination, we need to update our
	 * sentinel values, and for that we need to catalogs open again. The caller
	 * to this function had the catalogs open, so we let them opened when
	 * returning here.
	 */
	if (!catalog_open(streamSpecs->sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	/*
	 * Start the optional TCP coordinator when --host was given.  It serves
	 * "stream sentinel" CLI clients from inside this supervisor process, using
	 * the sourceDB catalog we just opened (sharing the write semaphore with the
	 * receive/apply children).  init() with a NULL host leaves it inactive.
	 */
	{
		const char *coordHost =
			IS_EMPTY_STRING_BUFFER(streamSpecs->coordHost)
			? NULL
			: streamSpecs->coordHost;

		if (!follow_coordinator_init(&followCoord, coordHost,
									 streamSpecs->coordPort))
		{
			/* errors have already been logged */
			return false;
		}
	}

	if (follow_wait_subprocesses(streamSpecs))
	{
		log_info("Subprocesses for %s and %s have now all exited",
				 prefetch->name,
				 catchup->name);
	}
	else
	{
		++errors;
		log_error("Some sub-process exited with errors, "
				  "see above for details");
	}

	(void) follow_coordinator_shutdown(&followCoord);

	return errors == 0;
}


/*
 * follow_start_prefetch starts a sub-process that prefetches changes from the
 * source database into local files.
 */
bool
follow_start_prefetch(StreamSpecs *specs)
{
	if (specs->mode == STREAM_MODE_REPLAY)
	{
		/* arrange to write to the receive-transform pipe */
		specs->stdIn = false;
		specs->stdOut = true;

		/* validate before use: a bad fd here means follow_start_subprocesses
		 * failed to create the pipe, which is a programming error */
		follow_assert_pipe_fd(specs->pipe_rt[1], "pipe_rt[1]");

		specs->out = fdopen(specs->pipe_rt[1], "a");

		/* close the read end of the pipe: receive only writes */
		close_fd_or_exit(specs->pipe_rt[0]);

		/* switch out stream from block buffered to line buffered mode */
		if (setvbuf(specs->out, NULL, _IOLBF, 0) != 0)
		{
			log_error("Failed to set out stream to line buffered mode: %m");
			return false;
		}

		bool success = startLogicalStreaming(specs);

		/*
		 * Safety net: close pipe_rt[1] if it was not already closed by
		 * stream_signal_upstream_done inside streamCloseFile.  That function
		 * closes the raw fd and sets specs->pipe_rt[1] = -1 to prevent
		 * double-close.  follow_close_pipe_fd skips the close when fd <= 0.
		 */
		follow_close_pipe_fd(specs->pipe_rt[1], "pipe_rt[1]");

		log_info("Prefetch process has terminated");

		return success;
	}
	else
	{
		specs->stdIn = false;
		specs->stdOut = false;

		bool success = startLogicalStreaming(specs);

		log_info("Prefetch process has terminated");

		return success;
	}

	return true;
}


/*
 * follow_start_catchup starts a sub-process that catches-up using the SQL
 * files that have been prepared by the prefetch process.
 */
bool
follow_start_catchup(StreamSpecs *specs)
{
	/*
	 * In replay mode, the SQL command are read from stdin.
	 */
	if (specs->mode == STREAM_MODE_REPLAY)
	{
		/* arrange to read from the receive→apply pipe */
		specs->stdIn = true;
		specs->stdOut = false;

		follow_assert_pipe_fd(specs->pipe_rt[0], "pipe_rt[0]");

		specs->in = fdopen(specs->pipe_rt[0], "r");

		/* close the write end: apply only reads from pipe_rt */
		close_fd_or_exit(specs->pipe_rt[1]);

		bool success = stream_apply_replay(specs);

		log_info("Apply process has terminated");

		/*
		 * pipe_rt[0] is the read end of the receive→apply pipe.  The apply
		 * process only reads from it; receive holds and closes the write end.
		 * This fd is never set to -1 by our code paths, so a plain close is
		 * correct.  Use follow_close_pipe_fd as a defensive measure nonetheless.
		 */
		follow_close_pipe_fd(specs->pipe_rt[0], "pipe_rt[0]");

		return success;
	}
	else
	{
		/*
		 * In other modes of operations (CATCHUP, really, here), we
		 * start the file based catchup mechanism, which follows the
		 * current LSN on the target database origin tracking system to
		 * open the right SQL file and apply statements from there.
		 */
		specs->stdIn = false;
		specs->stdOut = false;

		bool success = stream_apply_catchup(specs);

		log_info("Apply process has terminated");

		return success;
	}

	return true;
}


/*
 * follow_quit_with_parent makes the calling child get SIGQUIT when its parent
 * dies, and exits when the parent died before prctl() took effect.
 */
static void
follow_quit_with_parent(pid_t parent)
{
#if defined(__linux__)
	if (prctl(PR_SET_PDEATHSIG, SIGQUIT) != 0)
	{
		log_fatal("Failed to set the parent death signal: %m");
		exit(EXIT_CODE_INTERNAL_ERROR);
	}
#endif

	if (getppid() != parent)
	{
		log_fatal("Parent process %d has exited, quitting", parent);
		exit(EXIT_CODE_INTERNAL_ERROR);
	}
}


/*
 * follow_start_subprocess forks a subprocess and calls the given function.
 */
bool
follow_start_subprocess(StreamSpecs *specs, FollowSubProcess *subprocess)
{
	/* make sure to re-init the structure dynamic fields */
	subprocess->pid = -1;
	subprocess->exited = false;

	/*
	 * Flush stdio channels just before fork, to avoid double-output
	 * problems.
	 */
	fflush(stdout);
	fflush(stderr);

	pid_t parent = getpid();

	/* now we can fork a sub-process to transform the current file */
	pid_t fpid = fork();

	switch (fpid)
	{
		case -1:
		{
			log_error("Failed to fork %s subprocess: %m", subprocess->name);
			return false;
		}

		case 0:
		{
			/*
			 * shortcut: off Linux a killed WAL worker orphans receive and
			 * apply; add a getppid() poll to them if that ever matters.
			 */
			if (specs->walWorker)
			{
				follow_quit_with_parent(parent);
			}

			/* child process runs the command */
			pid_t pid = getpid();
			char psTitle[BUFSIZE] = { 0 };

			sformat(psTitle, sizeof(psTitle), "pgcopydb: follow %s",
					subprocess->name);

			(void) set_ps_title(psTitle);

			/* also track the process information in our catalogs */
			ProcessInfo ps = {
				.pid = pid,
				.psTitle = ps_buffer
			};

			strlcpy(ps.psType, subprocess->name, sizeof(ps.psType));

			DatabaseCatalog *sourceDB = specs->sourceDB;

			if (!catalog_open(sourceDB))
			{
				/* errors have already been logged */
				return false;
			}

			if (!catalog_upsert_process_info(sourceDB, &ps))
			{
				log_error("Failed to track progress in our catalogs, "
						  "see above for details");
				return false;
			}

			log_notice("Starting the %s sub-process", subprocess->name);

			if (!(subprocess->command)(specs))
			{
				/* errors have already been logged */
				exit(EXIT_CODE_INTERNAL_ERROR);
			}

			exit(EXIT_CODE_QUIT);
		}

		default:
		{
			subprocess->pid = fpid;
			return true;
		}
	}

	return true;
}


/*
 * follow_exit_early exits early, typically used when a process fails to start
 * and other processes where started already.
 */
void
follow_exit_early(StreamSpecs *specs)
{
	log_debug("follow_exit_early");

	if (!follow_terminate_subprocesses(specs))
	{
		log_error("Failed to terminate other subprocesses, "
				  "see above for details");
	}

	if (!follow_wait_subprocesses(specs))
	{
		log_error("Some sub-process exited in error, "
				  "see above for details");
	}
}


/*
 * follow_wait_subprocesses waits until both sub-processes are finished.
 */
bool
follow_wait_subprocesses(StreamSpecs *specs)
{
	FollowSubProcess *processArray[] = {
		&(specs->prefetch),
		&(specs->catchup)
	};

	int count = sizeof(processArray) / sizeof(processArray[0]);

	bool success = true;
	int stillRunning = count;

	/* now the main loop, that waits until all given processes have exited */
	while (stillRunning > 0)
	{
		/* without PR_SET_PDEATHSIG, a WAL worker notices a gone supervisor */
		if (specs->walWorker && !asked_to_quit &&
			getppid() != specs->walSupervisor)
		{
			log_error("WAL worker supervisor %d has exited, quitting",
					  specs->walSupervisor);
			asked_to_quit = 1;
		}

		if (asked_to_quit)
		{
			if (!follow_terminate_subprocesses(specs))
			{
				log_error("Failed to terminate other subprocesses, "
						  "see above for details");
				return false;
			}
		}

		/* re-init stillRunning at each iteration */
		stillRunning = count;

		for (int i = 0; i < count; i++)
		{
			/* skip already exited sub-processes, and not started ones too */
			if (processArray[i]->pid <= 0 || processArray[i]->exited)
			{
				--stillRunning;
				continue;
			}

			/* follow_wait_pid is non-blocking: uses WNOHANG */
			if (!follow_wait_pid(processArray[i]->pid,
								 &(processArray[i]->exited),
								 &(processArray[i]->returnCode),
								 &(processArray[i]->sig)))
			{
				/* errors have already been logged */
				return false;
			}

			if (processArray[i]->exited)
			{
				--stillRunning;

				/*
				 * First, delete the process from our tracking in the catalogs.
				 */
				if (!catalog_delete_process(specs->sourceDB,
											processArray[i]->pid))
				{
					log_notice("Failed to delete process entry for pid %d",
							   processArray[i]->pid);
				}

				int logLevel = LOG_NOTICE;
				char details[BUFSIZE] = { 0 };

				/*
				 * A sub-process exit is considered a "successful" exit when
				 * the return code is zero and the signal for termination is a
				 * signal that pgcopydb knows to handle and expects.
				 */
				bool exitedSuccessfully =
					processArray[i]->returnCode == 0 &&
					signal_is_handled(processArray[i]->sig);

				if (exitedSuccessfully)
				{
					if (processArray[i]->sig == 0)
					{
						sformat(details, sizeof(details), "successfully");
					}
					else
					{
						sformat(details, sizeof(details),
								"successfully after signal %s",
								signal_to_string(processArray[i]->sig));
					}
				}
				else
				{
					logLevel = LOG_ERROR;

					if (processArray[i]->returnCode == 0)
					{
						sformat(details, sizeof(details),
								"with return code %d and signal %s",
								processArray[i]->returnCode,
								signal_to_string(processArray[i]->sig));
					}
					else if (processArray[i]->sig == 0)
					{
						sformat(details, sizeof(details),
								"with error code %d",
								processArray[i]->returnCode);
					}
					else
					{
						sformat(details, sizeof(details),
								"with error code %d and signal %s",
								processArray[i]->returnCode,
								signal_to_string(processArray[i]->sig));
					}
				}

				log_level(logLevel,
						  "Subprocess %s with pid %d has exited %s",
						  processArray[i]->name,
						  processArray[i]->pid,
						  details);

				/*
				 * When one sub-process has exited abnormally, we terminate all
				 * the other sub-processes to handle the problem at the caller.
				 *
				 * When a sub-process exits successfully but endpos is still
				 * unset, that's normal: the process has caught up with available
				 * data and is waiting for more (e.g., the inject service hasn't
				 * set endpos yet). We should NOT terminate the other processes.
				 *
				 * Only if the process exited with an error do we need to
				 * terminate everything.  In the old CATCHUP/REPLAY mode,
				 * processes would continue running; now they exit when caught up,
				 * which is normal behavior.
				 */
				if (!exitedSuccessfully)
				{
					if (!follow_get_sentinel(specs, &(specs->sentinel), false))
					{
						/* continue without updated endpos */
						log_warn("Failed to get sentinel values");
					}

					log_error("Process %s has exited with error code %d, "
							  "terminating other processes",
							  processArray[i]->name,
							  processArray[i]->returnCode);

					if (!follow_terminate_subprocesses(specs))
					{
						log_error("Failed to terminate other subprocesses, "
								  "see above for details");
						return false;
					}
				}

				success = success && exitedSuccessfully;
			}
		}

		/*
		 * Serve any pending follow-coordinator CLI request (no-op unless the
		 * coordinator was started with --host).  The accept() call uses a
		 * 100 ms timeout, which also paces this loop; add a short sleep so the
		 * cadence stays close to the original 150 ms.
		 */
		(void) follow_coordinator_handle_messages(&followCoord, specs);
		(void) follow_coordinator_maybe_cleanup(&followCoord, specs);

		/* avoid busy looping */
		pg_usleep(50 * 1000);
	}

	return success;
}


/*
 * follow_terminate_subprocesses is used in case of errors in one sub-process
 * to signal the other ones to quit early.
 */
bool
follow_terminate_subprocesses(StreamSpecs *specs)
{
	FollowSubProcess *processArray[] = {
		&(specs->prefetch),
		&(specs->catchup)
	};
	int count = sizeof(processArray) / sizeof(processArray[0]);

	/* signal the processes to exit */
	for (int i = 0; i < count; i++)
	{
		if (processArray[i]->pid <= 0 || processArray[i]->exited)
		{
			continue;
		}

		log_notice("kill -TERM %d (%s)",
				   processArray[i]->pid,
				   processArray[i]->name);

		if (kill(processArray[i]->pid, SIGTERM) != 0)
		{
			/* process might have exited on its own already */
			if (errno != ESRCH)
			{
				log_error("Failed to signal %s process %d: %m",
						  processArray[i]->name,
						  processArray[i]->pid);

				return false;
			}
		}
	}

	return true;
}


/*
 * follow_wait_pid waits for a given known sub-process.
 */
bool
follow_wait_pid(pid_t subprocess, bool *exited, int *returnCode, int *sig)
{
	int status = 0;

	if (subprocess <= 0)
	{
		log_error("BUG: follow_wait_pid called with subprocess %d", subprocess);
		return false;
	}

	int pid = waitpid(subprocess, &status, WNOHANG);

	switch (pid)
	{
		case -1:
		{
			if (errno == ECHILD)
			{
				/* no more childrens */
				*sig = 0;
				*exited = true;
				*returnCode = -1;
				return true;
			}
			else
			{
				log_warn("Failed to call waitpid(): %m");
				return false;
			}

			break;
		}

		case 0:
		{
			/*
			 * We're using WNOHANG, 0 means there are no stopped or
			 * exited children, it's all good.
			 */
			*sig = 0;
			*exited = false;
			*returnCode = -1;
			break;
		}

		default:
		{
			/* sub-process has finished now */
			if (pid != subprocess)
			{
				log_error("BUG: waitpid on %d returned %d", subprocess, pid);
				return false;
			}

			*sig = 0;
			*exited = true;
			*returnCode = WEXITSTATUS(status);

			if (WIFSIGNALED(status))
			{
				*sig = WTERMSIG(status);
			}

			break;
		}
	}

	return true;
}


/* a partition family, or a table outside any partition tree */
typedef struct WalWorkerUnit
{
	uint32_t family;
	int64_t weight;
	int64_t bytes;
	int tables;
	int worker;
} WalWorkerUnit;

typedef struct WalWorkerLoad
{
	int64_t weight;
	int64_t bytes;
	int units;
} WalWorkerLoad;


static int
wal_workers_compare_family(const void *a, const void *b)
{
	uint32_t fa = ((const WalWorkerUnit *) a)->family;
	uint32_t fb = ((const WalWorkerUnit *) b)->family;

	return fa < fb ? -1 : fa > fb ? 1 : 0;
}


/* heaviest first; the family oid makes the order total */
static int
wal_workers_compare_weight(const void *a, const void *b)
{
	const WalWorkerUnit *ua = *(WalWorkerUnit *const *) a;
	const WalWorkerUnit *ub = *(WalWorkerUnit *const *) b;

	if (ua->weight != ub->weight)
	{
		return ua->weight > ub->weight ? -1 : 1;
	}

	if (ua->bytes != ub->bytes)
	{
		return ua->bytes > ub->bytes ? -1 : 1;
	}

	if (ua->tables != ub->tables)
	{
		return ua->tables > ub->tables ? -1 : 1;
	}

	return wal_workers_compare_family(ua, ub);
}


/* units are sorted by family and every table's family is among them */
static WalWorkerUnit *
wal_workers_find_unit(WalWorkerUnit *units, int count, uint32_t family)
{
	int lo = 0;
	int hi = count - 1;

	while (lo <= hi)
	{
		int mid = lo + (hi - lo) / 2;

		if (units[mid].family == family)
		{
			return &(units[mid]);
		}

		if (units[mid].family < family)
		{
			lo = mid + 1;
		}
		else
		{
			hi = mid - 1;
		}
	}

	return NULL;
}


static void
wal_workers_add_load(WalWorkerLoad *load, WalWorkerUnit *unit, int worker)
{
	unit->worker = worker;
	load[worker].weight += unit->weight;
	load[worker].bytes += unit->bytes;
	load[worker].units++;
}


/*
 * wal_workers_assign_units places the high-traffic units, then the others
 * greedily. units must be sorted by family, order has room for every unit.
 */
static bool
wal_workers_assign_units(WalWorkerTable *tables, int count,
						 WalWorkerUnit *units, int unitCount,
						 WalWorkerUnit **order,
						 int workers, const char *highTraffic)
{
	WalWorkerLoad load[MAX_WAL_WORKERS] = { 0 };
	const char *entries[MAX_WAL_WORKERS] = { 0 };
	int lengths[MAX_WAL_WORKERS] = { 0 };
	int h = 0;

	bool empty = highTraffic == NULL || *highTraffic == '\0';

	for (const char *entry = empty ? NULL : highTraffic; entry != NULL;)
	{
		const char *comma = strchr(entry, ',');
		int len = comma == NULL ? (int) strlen(entry) : (int) (comma - entry);

		if (h == workers)
		{
			log_error("Option --wal-high-traffic-tables lists more tables "
					  "than --wal-workers %d",
					  workers);
			return false;
		}

		const char *dot = memchr(entry, '.', len);
		size_t nsplen = dot == NULL ? 0 : (size_t) (dot - entry);
		const char *rel = dot == NULL ? NULL : dot + 1;
		size_t rellen = dot == NULL ? 0 : (size_t) (entry + len - rel);
		WalWorkerTable *match = NULL;
		int matches = 0;

		for (int i = 0; dot != NULL && i < count; i++)
		{
			if (strlen(tables[i].nspname) == nsplen &&
				strncmp(tables[i].nspname, entry, nsplen) == 0 &&
				strlen(tables[i].relname) == rellen &&
				strncmp(tables[i].relname, rel, rellen) == 0)
			{
				match = &(tables[i]);
				++matches;
			}
		}

		if (matches != 1)
		{
			log_error("Option --wal-high-traffic-tables entry \"%.*s\" "
					  "matches %d published tables, expected exactly one",
					  len, entry, matches);
			return false;
		}

		WalWorkerUnit *unit = wal_workers_find_unit(units, unitCount,
													match->family);

		if (unit->worker != -1)
		{
			int other = unit->worker;

			if (lengths[other] == len && strncmp(entries[other], entry, len) == 0)
			{
				log_error("Option --wal-high-traffic-tables lists \"%.*s\" "
						  "more than once",
						  len, entry);
				return false;
			}

			log_error("Option --wal-high-traffic-tables entries \"%.*s\" and "
					  "\"%.*s\" are in the same partition family",
					  lengths[other], entries[other], len, entry);
			return false;
		}

		entries[h] = entry;
		lengths[h] = len;
		wal_workers_add_load(load, unit, h);
		++h;

		entry = comma == NULL ? NULL : comma + 1;
	}

	int orderCount = 0;

	for (int i = 0; i < unitCount; i++)
	{
		if (units[i].worker == -1)
		{
			order[orderCount++] = &(units[i]);
		}
	}

	if (orderCount > 1)
	{
		qsort(order, orderCount, sizeof(WalWorkerUnit *), /* IGNORE-BANNED */
			  wal_workers_compare_weight);
	}

	int first = h < workers ? h : 0;

	for (int i = 0; i < orderCount; i++)
	{
		int best = first;

		for (int w = first + 1; w < workers; w++)
		{
			WalWorkerLoad *a = &(load[w]);
			WalWorkerLoad *b = &(load[best]);

			if (a->weight < b->weight ||
				(a->weight == b->weight &&
				 (a->bytes < b->bytes ||
				  (a->bytes == b->bytes && a->units < b->units))))
			{
				best = w;
			}
		}

		wal_workers_add_load(load, order[i], best);
	}

	for (int w = 0; w < workers; w++)
	{
		if (load[w].units == 0)
		{
			log_error("Failed to assign a table to WAL worker %d: "
					  "%d workers for %d published tables in %d partition "
					  "families or single tables",
					  w, workers, count, unitCount);
			return false;
		}
	}

	for (int i = 0; i < count; i++)
	{
		tables[i].worker =
			wal_workers_find_unit(units, unitCount, tables[i].family)->worker;
	}

	return true;
}


/*
 * wal_workers_assign sets the worker of every table, the same way for any
 * input order. A partition family is one unit, high-traffic units go to
 * workers 0 to H-1, the others heaviest first to the least-loaded worker.
 */
bool
wal_workers_assign(WalWorkerTable *tables, int count, int workers,
				   const char *highTraffic)
{
	if (workers < 1 || workers > MAX_WAL_WORKERS || count < 0)
	{
		log_error("BUG: wal_workers_assign called with %d workers "
				  "and %d tables",
				  workers, count);
		return false;
	}

	/* one more slot keeps calloc away from a zero size */
	WalWorkerUnit *units = calloc(count + 1, sizeof(WalWorkerUnit));
	WalWorkerUnit **order = calloc(count + 1, sizeof(WalWorkerUnit *));

	if (units == NULL || order == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		free(units);
		free(order);
		return false;
	}

	for (int i = 0; i < count; i++)
	{
		units[i].family = tables[i].family;
	}

	if (count > 1)
	{
		qsort(units, count, sizeof(WalWorkerUnit), /* IGNORE-BANNED */
			  wal_workers_compare_family);
	}

	int unitCount = 0;

	for (int i = 0; i < count; i++)
	{
		if (unitCount == 0 || units[unitCount - 1].family != units[i].family)
		{
			units[unitCount++] = (WalWorkerUnit) {
				.family = units[i].family, .worker = -1
			};
		}
	}

	for (int i = 0; i < count; i++)
	{
		WalWorkerUnit *unit =
			wal_workers_find_unit(units, unitCount, tables[i].family);

		unit->weight += tables[i].weight;
		unit->bytes += tables[i].bytes;
		unit->tables++;
	}

	bool success = wal_workers_assign_units(tables, count, units, unitCount,
											order, workers, highTraffic);

	free(units);
	free(order);

	return success;
}


/* a WAL worker, as its supervisor tracks it */
typedef struct FollowWalWorker
{
	int index;
	char slotName[NAMEDATALEN];
	char origin[NAMEDATALEN];
	CDCPaths paths;
	DatabaseCatalog catalog;
	FollowSubProcess process;
	bool start;                 /* fork it in the next round */
	uint64_t finishedAt;        /* endpos it last finished at, or 0 */
} FollowWalWorker;


static void
follow_wal_worker_init(StreamSpecs *streamSpecs, int k, FollowWalWorker *worker)
{
	worker->index = k;
	worker->process.name = "WAL worker";
	worker->process.pid = -1;

	if (k == 0)
	{
		strlcpy(worker->slotName, streamSpecs->slot.slotName,
				sizeof(worker->slotName));
		strlcpy(worker->origin, streamSpecs->origin, sizeof(worker->origin));
	}
	else
	{
		sformat(worker->slotName, sizeof(worker->slotName), "%s_w%d",
				streamSpecs->slot.slotName, k);
		sformat(worker->origin, sizeof(worker->origin), "%s_w%d",
				streamSpecs->origin, k);
	}

	worker->paths = streamSpecs->paths;
	sformat(worker->paths.dir, sizeof(worker->paths.dir), "%s/w%d",
			streamSpecs->paths.dir, k);

	/* one SysV semaphore per worker would exhaust SYSV_RES_MAX_COUNT */
	worker->catalog.type = DATABASE_CATALOG_TYPE_SOURCE;
	worker->catalog.sema = streamSpecs->sourceDB->sema;
	sformat(worker->catalog.dbfile, sizeof(worker->catalog.dbfile),
			"%s/source.db", worker->paths.dir);
}


/*
 * follow_wal_worker_slot_unchanged allows building a worker catalog only while
 * the worker slot is where it was created: once it moved, the CDC files the
 * lost catalog listed hold changes the slot will not send again.
 */
static bool
follow_wal_worker_slot_unchanged(CopyDataSpec *copySpecs,
								 StreamSpecs *streamSpecs,
								 FollowWalWorker *worker)
{
	PGSQL src = { 0 };
	bool exists = false;
	uint64_t lsn = InvalidXLogRecPtr;
	uint64_t slotLSN = streamSpecs->slot.lsn;

	bool success =
		pgsql_init(&src, copySpecs->connStrings.source_pguri,
				   PGSQL_CONN_SOURCE) &&
		pgsql_server_version(&src) &&
		pgsql_replication_slot_exists(&src, worker->slotName, &exists, &lsn);

	(void) pgsql_finish(&src);

	if (!success)
	{
		/* errors have already been logged */
		return false;
	}

	if (!exists)
	{
		log_fatal("Failed to prepare the catalog of WAL worker %d: "
				  "replication slot \"%s\" does not exist",
				  worker->index, worker->slotName);
		return false;
	}

	if (lsn != slotLSN)
	{
		log_fatal("Failed to prepare the catalog of WAL worker %d: "
				  "replication slot \"%s\" is at %X/%X, not at %X/%X where "
				  "it was created, and \"%s\" is missing or incomplete",
				  worker->index, worker->slotName,
				  LSN_FORMAT_ARGS(lsn),
				  LSN_FORMAT_ARGS(slotLSN),
				  worker->catalog.dbfile);
		return false;
	}

	return true;
}


/*
 * follow_build_worker_catalog builds the catalog of a WAL worker from the main
 * catalog, only while the slot of that worker is still where it was created.
 */
static bool
follow_build_worker_catalog(CopyDataSpec *copySpecs,
							StreamSpecs *streamSpecs,
							FollowWalWorker *worker)
{
	DatabaseCatalog *catalog = &(worker->catalog);
	char walFile[MAXPGPATH] = { 0 };
	char shmFile[MAXPGPATH] = { 0 };
	ReplicationSlot slot = streamSpecs->slot;

	sformat(walFile, sizeof(walFile), "%s-wal", catalog->dbfile);
	sformat(shmFile, sizeof(shmFile), "%s-shm", catalog->dbfile);
	strlcpy(slot.slotName, worker->slotName, sizeof(slot.slotName));

	log_info("Preparing the catalog of WAL worker %d at \"%s\"",
			 worker->index, catalog->dbfile);

	if (!catalog_close(catalog) ||
		!follow_wal_worker_slot_unchanged(copySpecs, streamSpecs, worker) ||
		!unlink_file(catalog->dbfile) ||
		!unlink_file(walFile) ||
		!unlink_file(shmFile) ||
		!catalog_init(catalog) ||
		!catalog_copy_wal_worker_catalog(catalog,
										 streamSpecs->sourceDB,
										 streamSpecs->paths.dir,
										 worker->paths.dir,
										 &slot))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


/*
 * follow_prepare_worker_catalog opens the catalog of a WAL worker, built from
 * the main catalog when missing or incomplete, and creates its open output.db
 * so that apply never races receive to create it.
 */
static bool
follow_prepare_worker_catalog(CopyDataSpec *copySpecs,
							  StreamSpecs *streamSpecs,
							  FollowWalWorker *worker)
{
	DatabaseCatalog *catalog = &(worker->catalog);
	CopyDBSentinel sentinel = { 0 };

	if (pg_mkdir_p(worker->paths.dir, 0700) == -1)
	{
		log_error("Failed to create directory \"%s\": %m", worker->paths.dir);
		return false;
	}

	bool complete =
		file_exists(catalog->dbfile) &&
		catalog_init(catalog) &&
		sentinel_get(catalog, &sentinel);

	if (!complete && !follow_build_worker_catalog(copySpecs, streamSpecs, worker))
	{
		/* errors have already been logged */
		return false;
	}

	DatabaseCatalog outputDB = { .sema = catalog->sema };
	StreamSpecs specs = { .sourceDB = catalog, .outputDB = &outputDB };

	if (!ld_store_set_current_cdc_filename(&specs))
	{
		/* errors have already been logged */
		return false;
	}

	/* on resume without an open CDC file, receive creates the next one */
	if (IS_EMPTY_STRING_BUFFER(outputDB.dbfile))
	{
		if (complete)
		{
			return true;
		}

		log_error("Failed to find an open output.db in catalog \"%s\"",
				  catalog->dbfile);
		return false;
	}

	/* a crash may leave a complete catalog without its open output.db */
	if (!file_exists(outputDB.dbfile) &&
		(!ld_store_open_outputdb(&specs) || !catalog_close(&outputDB)))
	{
		/* errors have already been logged */
		return false;
	}

	return true;
}


static bool
follow_count_wal_worker_table(void *context, WalWorkerTable *table)
{
	++(*(int *) context);
	return true;
}


/*
 * follow_set_wal_worker_publications subscribes a worker to the publications
 * of its own tables, in a buffer sized for every table of the assignment.
 */
static bool
follow_set_wal_worker_publications(StreamSpecs *specs,
								   const char *slotName,
								   int worker)
{
	int count = 0;

	if (!catalog_iter_wal_worker_table(specs->sourceDB,
									   &count,
									   &follow_count_wal_worker_table))
	{
		/* errors have already been logged */
		return false;
	}

	/* a publication name and its comma fit in NAMEDATALEN bytes */
	size_t size = (size_t) count * NAMEDATALEN + 1;
	char *names = calloc(size, sizeof(char));

	if (names == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	if (!catalog_wal_worker_publications(specs->sourceDB, slotName, worker,
										 names, size))
	{
		/* errors have already been logged */
		free(names);
		return false;
	}

	for (int i = 0; i < specs->pluginOptions.count; i++)
	{
		if (streq(specs->pluginOptions.keywords[i], "publication_names"))
		{
			specs->pluginOptions.values[i] = names;
			return true;
		}
	}

	log_error("BUG: follow_set_wal_worker_publications: "
			  "no publication_names plugin option");
	free(names);
	return false;
}


typedef struct WalWorkerOids
{
	int worker;
	PQExpBuffer oids;
	PQExpBuffer others;
} WalWorkerOids;


static bool
follow_add_wal_worker_oid(void *context, WalWorkerTable *table)
{
	WalWorkerOids *ctx = (WalWorkerOids *) context;
	PQExpBuffer oids = table->worker == ctx->worker ? ctx->oids : ctx->others;

	appendPQExpBuffer(oids, "%s%u", oids->len > 1 ? "," : "", table->oid);

	return true;
}


/*
 * follow_check_wal_worker_publications fails unless the publications of a WAL
 * worker exist and publish its tables, and none of another worker: Postgres 18
 * streams on without a dropped publication, losing the changes of its table.
 */
static bool
follow_check_wal_worker_publications(DatabaseCatalog *catalog,
									 ConnStrings *connStrings,
									 const char *slotName,
									 int worker)
{
	WalWorkerOids ctx = {
		.worker = worker,
		.oids = createPQExpBuffer(),
		.others = createPQExpBuffer()
	};
	char mismatch[BUFSIZE] = { 0 };
	PGSQL src = { 0 };

	if (ctx.oids == NULL || ctx.others == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		destroyPQExpBuffer(ctx.oids);
		destroyPQExpBuffer(ctx.others);
		return false;
	}

	appendPQExpBufferChar(ctx.oids, '{');
	appendPQExpBufferChar(ctx.others, '{');

	bool success =
		catalog_iter_wal_worker_table(catalog, &ctx,
									  &follow_add_wal_worker_oid);

	appendPQExpBufferChar(ctx.oids, '}');
	appendPQExpBufferChar(ctx.others, '}');

	success = success &&
			  !PQExpBufferBroken(ctx.oids) &&
			  !PQExpBufferBroken(ctx.others) &&
			  pgsql_init(&src, connStrings->source_pguri, PGSQL_CONN_SOURCE) &&
			  pgsql_wal_worker_publications_mismatch(&src, slotName,
													 ctx.oids->data,
													 ctx.others->data,
													 mismatch,
													 sizeof(mismatch));

	(void) pgsql_finish(&src);
	destroyPQExpBuffer(ctx.oids);
	destroyPQExpBuffer(ctx.others);

	if (!success)
	{
		log_error("Failed to check the publications of WAL worker %d, "
				  "see above for details",
				  worker);
		return false;
	}

	if (!IS_EMPTY_STRING_BUFFER(mismatch))
	{
		log_fatal("Failed to check the publications of WAL worker %d: %s",
				  worker, mismatch);
		return false;
	}

	return true;
}


/*
 * follow_run_wal_worker runs the existing follow loop in a forked WAL worker,
 * on the worker's own catalog, CDC directory, slot, origin and publications.
 */
static void
follow_run_wal_worker(CopyDataSpec *copySpecs,
					  StreamSpecs *streamSpecs,
					  FollowWalWorker *worker,
					  pid_t supervisor)
{
	char psTitle[BUFSIZE] = { 0 };

	sformat(psTitle, sizeof(psTitle), "pgcopydb: follow worker %d",
			worker->index);
	(void) set_ps_title(psTitle);

	/* SIGQUIT sets asked_to_quit, so receive and apply are stopped first */
	(void) set_signal_handlers(false);
	follow_quit_with_parent(supervisor);

	/* a worker forked again keeps no copy of the supervisor's socket */
	(void) follow_coordinator_shutdown(&followCoord);

	copySpecs->catalogs.source = worker->catalog;
	copySpecs->catalogs.output = (DatabaseCatalog) {
		0
	};
	copySpecs->catalogs.replay = (DatabaseCatalog) {
		0
	};
	copySpecs->cfPaths.cdc = worker->paths;

	ReplicationSlot slot = streamSpecs->slot;
	strlcpy(slot.slotName, worker->slotName, sizeof(slot.slotName));

	StreamSpecs specs = { 0 };

	if (!stream_init_specs(&specs,
						   &(worker->paths),
						   streamSpecs->connStrings,
						   &slot,
						   worker->origin,
						   InvalidXLogRecPtr,
						   streamSpecs->mode,
						   &(copySpecs->catalogs.source),
						   &(copySpecs->catalogs.output),
						   &(copySpecs->catalogs.replay),
						   streamSpecs->stdIn,
						   streamSpecs->stdOut,
						   streamSpecs->logSQL,
						   streamSpecs->replayNoOpUpdates,
						   &(streamSpecs->filters),
						   streamSpecs->targetDB) ||
		!follow_set_wal_worker_publications(&specs,
											streamSpecs->slot.slotName,
											worker->index) ||
		!follow_check_wal_worker_publications(specs.sourceDB,
											  streamSpecs->connStrings,
											  streamSpecs->slot.slotName,
											  worker->index))
	{
		/* errors have already been logged */
		exit(EXIT_CODE_INTERNAL_ERROR);
	}

	specs.maxReplayDBSize = streamSpecs->maxReplayDBSize;
	specs.walWorkers = 1;
	specs.walWorker = true;
	specs.walWorkerIndex = worker->index;
	specs.walSupervisor = supervisor;

	if (!follow_main_loop(copySpecs, &specs))
	{
		/* errors have already been logged */
		exit(EXIT_CODE_INTERNAL_ERROR);
	}

	exit(EXIT_CODE_QUIT);
}


static bool
follow_start_wal_worker(CopyDataSpec *copySpecs,
						StreamSpecs *streamSpecs,
						FollowWalWorker *worker)
{
	pid_t supervisor = getpid();

	/* flush stdio channels just before fork, to avoid double-output */
	fflush(stdout);
	fflush(stderr);

	pid_t fpid = fork();

	switch (fpid)
	{
		case -1:
		{
			log_error("Failed to fork WAL worker %d: %m", worker->index);
			return false;
		}

		case 0:
		{
			(void) follow_run_wal_worker(copySpecs, streamSpecs, worker,
										 supervisor);
			exit(EXIT_CODE_INTERNAL_ERROR);
		}

		default:
		{
			worker->process.pid = fpid;
			worker->process.exited = false;
			worker->process.returnCode = 0;
			worker->process.sig = 0;

			log_info("Started WAL worker %d with pid %d, "
					 "replication slot \"%s\" and origin \"%s\"",
					 worker->index, fpid, worker->slotName, worker->origin);

			return true;
		}
	}
}


/* SIGQUIT, because a WAL worker does not forward a bare SIGTERM */
static void
follow_stop_wal_workers(FollowWalWorker *workers, int count, bool *stopping)
{
	if (*stopping)
	{
		return;
	}

	*stopping = true;

	for (int k = 0; k < count; k++)
	{
		FollowSubProcess *process = &(workers[k].process);

		if (process->pid <= 0 || process->exited)
		{
			continue;
		}

		log_notice("kill -QUIT %d (WAL worker %d)", process->pid, k);

		if (kill(process->pid, SIGQUIT) != 0 && errno != ESRCH)
		{
			log_error("Failed to signal WAL worker %d with pid %d: %m",
					  k, process->pid);
		}
	}
}


static bool
follow_sync_wal_workers(FollowWalWorker *workers, int count,
						CopyDBSentinel *sentinel)
{
	for (int k = 0; k < count; k++)
	{
		if (!sentinel_update_endpos(&(workers[k].catalog), sentinel->endpos) ||
			!sentinel_update_apply(&(workers[k].catalog), sentinel->apply))
		{
			log_error("Failed to update the sentinel of WAL worker %d", k);
			return false;
		}
	}

	return true;
}


/*
 * follow_sync_main_sentinel writes the lowest write, flush and replay LSN of
 * the workers to the main sentinel, the one that commands and humans read. A
 * replay_lsn at endpos tells a resume the run is done, so it waits for done.
 */
static bool
follow_sync_main_sentinel(DatabaseCatalog *sourceDB,
						  FollowWalWorker *workers, int count,
						  uint64_t endpos, bool done,
						  uint64_t *replayLSN)
{
	CopyDBSentinel low = { 0 };

	for (int k = 0; k < count; k++)
	{
		CopyDBSentinel sentinel = { 0 };

		if (!sentinel_get(&(workers[k].catalog), &sentinel))
		{
			log_error("Failed to read the sentinel of WAL worker %d", k);
			return false;
		}

		if (k == 0 || sentinel.write_lsn < low.write_lsn)
		{
			low.write_lsn = sentinel.write_lsn;
		}

		if (k == 0 || sentinel.flush_lsn < low.flush_lsn)
		{
			low.flush_lsn = sentinel.flush_lsn;
		}

		if (k == 0 || sentinel.replay_lsn < low.replay_lsn)
		{
			low.replay_lsn = sentinel.replay_lsn;
		}
	}

	*replayLSN = low.replay_lsn;

	if (!done && endpos != InvalidXLogRecPtr && endpos <= low.replay_lsn)
	{
		return sentinel_update_write_flush_lsn(sourceDB, low.write_lsn,
											   low.flush_lsn);
	}

	return sentinel_update_write_flush_lsn(sourceDB, low.write_lsn,
										   low.flush_lsn) &&
		   sentinel_update_replay_lsn(sourceDB, low.replay_lsn);
}


/*
 * follow_check_wal_workers_endpos fails when endpos is below the replay_lsn of
 * a WAL worker: the target cannot un-apply what that worker committed.
 */
static bool
follow_check_wal_workers_endpos(FollowWalWorker *workers, int count,
								uint64_t endpos)
{
	if (endpos == InvalidXLogRecPtr)
	{
		return true;
	}

	for (int k = 0; k < count; k++)
	{
		CopyDBSentinel sentinel = { 0 };

		if (!sentinel_get(&(workers[k].catalog), &sentinel))
		{
			log_error("Failed to read the sentinel of WAL worker %d", k);
			return false;
		}

		if (endpos < sentinel.replay_lsn)
		{
			log_fatal("Failed to stop at endpos %X/%X: WAL worker %d has "
					  "already applied changes up to replay_lsn %X/%X, "
					  "which the target cannot un-apply",
					  LSN_FORMAT_ARGS(endpos),
					  k,
					  LSN_FORMAT_ARGS(sentinel.replay_lsn));
			return false;
		}
	}

	return true;
}


/*
 * follow_fork_wal_workers forks the WAL workers marked to start, with their
 * apply marked as not finished yet and no SQLite handle open across fork().
 */
static bool
follow_fork_wal_workers(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs,
						FollowWalWorker *workers, int count, int *running)
{
	bool success = true;

	for (int k = 0; success && k < count; k++)
	{
		if (workers[k].start)
		{
			workers[k].finishedAt = InvalidXLogRecPtr;
			success =
				pipeline_state_start(&(workers[k].catalog), "receive",
									 InvalidXLogRecPtr) &&
				pipeline_state_start(&(workers[k].catalog), "apply",
									 InvalidXLogRecPtr);
		}
	}

	success = success &&
			  catalog_close_from_specs(copySpecs) &&
			  catalog_close(&(copySpecs->catalogs.output)) &&
			  catalog_close(&(copySpecs->catalogs.replay));

	for (int k = 0; success && k < count; k++)
	{
		success = catalog_close(&(workers[k].catalog));
	}

	if (!success)
	{
		log_error("Failed to prepare the WAL workers for fork()");
		return false;
	}

	for (int k = 0; success && k < count; k++)
	{
		if (workers[k].start)
		{
			workers[k].start = false;
			success = follow_start_wal_worker(copySpecs, streamSpecs,
											  &(workers[k]));
			*running += success ? 1 : 0;
		}
	}

	bool reopened = catalog_open(streamSpecs->sourceDB);

	for (int k = 0; reopened && k < count; k++)
	{
		reopened = catalog_open(&(workers[k].catalog));
	}

	return success && reopened;
}


/*
 * follow_wal_worker_exited records the endpos at which a WAL worker finished,
 * or marks it to start again when its receive signalled done below endpos, or
 * not at all. It returns false when the worker failed or stopped short.
 */
static bool
follow_wal_worker_exited(FollowWalWorker *worker, uint64_t endpos,
						 bool stopping)
{
	FollowSubProcess *process = &(worker->process);
	int logLevel = stopping ? LOG_WARN : LOG_ERROR;

	if (process->returnCode != 0 || !signal_is_handled(process->sig))
	{
		log_level(logLevel,
				  "WAL worker %d with pid %d has exited with code %d "
				  "and signal %s",
				  worker->index, process->pid, process->returnCode,
				  signal_to_string(process->sig));
		return false;
	}

	PipelineStateEntry apply = { 0 };
	PipelineStateEntry receive = { 0 };

	if (!pipeline_state_get(&(worker->catalog), "apply", &apply) ||
		!pipeline_state_get(&(worker->catalog), "receive", &receive))
	{
		log_error("Failed to read the state of WAL worker %d", worker->index);
		return false;
	}

	/* the apply of a WAL worker records done only at endpos */
	if (streq(apply.run_state, "done") &&
		apply.run_end_lsn != InvalidXLogRecPtr)
	{
		worker->finishedAt = apply.run_end_lsn;

		log_info("WAL worker %d with pid %d has reached endpos %X/%X",
				 worker->index, process->pid,
				 LSN_FORMAT_ARGS(worker->finishedAt));
		return true;
	}

	if (!stopping &&
		endpos != InvalidXLogRecPtr &&
		streq(receive.run_state, "done") &&
		receive.run_end_lsn < endpos)
	{
		log_info("WAL worker %d with pid %d stopped below endpos %X/%X: "
				 "its receive signalled done at %X/%X",
				 worker->index, process->pid,
				 LSN_FORMAT_ARGS(endpos),
				 LSN_FORMAT_ARGS(receive.run_end_lsn));
		worker->start = true;
		return true;
	}

	log_level(logLevel,
			  "WAL worker %d with pid %d has exited before reaching endpos",
			  worker->index, process->pid);

	return false;
}


/*
 * follow_supervise_workers runs one follow pipeline per WAL worker. The main
 * sentinel stays the control surface: endpos and apply flow down to the
 * workers, their lowest LSNs flow back up. A failed worker stops the others.
 */
static bool
follow_supervise_workers(CopyDataSpec *copySpecs, StreamSpecs *streamSpecs)
{
	DatabaseCatalog *sourceDB = streamSpecs->sourceDB;
	int count = streamSpecs->walWorkers;
	FollowWalWorker workers[MAX_WAL_WORKERS] = { 0 };
	CopyDBSentinel sentinel = { 0 };

	if (count > MAX_WAL_WORKERS)
	{
		log_error("BUG: follow_supervise_workers called with %d workers",
				  count);
		return false;
	}

	/* a SIGQUIT must stop the workers below, not exit(0) in the handler */
	(void) set_signal_handlers(false);

	/* clone --follow hands over a connection that crossed fork() */
	if (!catalog_close(sourceDB) || !catalog_open(sourceDB))
	{
		/* errors have already been logged */
		return false;
	}

	for (int k = 0; k < count; k++)
	{
		(void) follow_wal_worker_init(streamSpecs, k, &(workers[k]));

		if (!follow_prepare_worker_catalog(copySpecs, streamSpecs, &(workers[k])))
		{
			log_error("Failed to prepare WAL worker %d, see above for details",
					  k);
			return false;
		}

		workers[k].start = true;
	}

	if (!sentinel_get(sourceDB, &sentinel) ||
		!follow_sync_wal_workers(workers, count, &sentinel) ||
		!pipeline_state_start(sourceDB, "apply", sentinel.replay_lsn))
	{
		/* errors have already been logged */
		return false;
	}

	int running = 0;
	bool failed =
		!follow_fork_wal_workers(copySpecs, streamSpecs, workers, count,
								 &running);

	const char *coordHost =
		IS_EMPTY_STRING_BUFFER(streamSpecs->coordHost)
		? NULL
		: streamSpecs->coordHost;

	failed = failed ||
			 !follow_coordinator_init(&followCoord, coordHost,
									  streamSpecs->coordPort);

	bool stopping = false;

	if (failed)
	{
		(void) follow_stop_wal_workers(workers, count, &stopping);
	}

	uint64_t endpos = sentinel.endpos;
	bool apply = sentinel.apply;
	uint64_t replayLSN = sentinel.replay_lsn;
	time_t lastSync = 0;

	for (;;)
	{
		if (!stopping && (asked_to_stop || asked_to_stop_fast || asked_to_quit))
		{
			log_warn("Follow supervisor was asked to terminate, "
					 "stopping %d WAL workers",
					 running);
			(void) follow_stop_wal_workers(workers, count, &stopping);
		}

		bool synced = sentinel_get(sourceDB, &sentinel);

		if (synced && (sentinel.endpos != endpos || sentinel.apply != apply))
		{
			synced = follow_sync_wal_workers(workers, count, &sentinel);
			endpos = sentinel.endpos;
			apply = sentinel.apply;

			if (synced && !follow_check_wal_workers_endpos(workers, count,
														   endpos))
			{
				failed = true;
				(void) follow_stop_wal_workers(workers, count, &stopping);
			}
		}

		for (int k = 0; k < count; k++)
		{
			FollowSubProcess *process = &(workers[k].process);

			if (process->pid <= 0 || process->exited)
			{
				continue;
			}

			/* follow_wait_pid is non-blocking: uses WNOHANG */
			if (!follow_wait_pid(process->pid,
								 &(process->exited),
								 &(process->returnCode),
								 &(process->sig)))
			{
				/* errors have already been logged, try again next round */
				failed = true;
				(void) follow_stop_wal_workers(workers, count, &stopping);
				continue;
			}

			if (!process->exited)
			{
				continue;
			}

			--running;

			if (!follow_wal_worker_exited(&(workers[k]), endpos, stopping))
			{
				failed = failed || !stopping;
				(void) follow_stop_wal_workers(workers, count, &stopping);
			}
		}

		if (synced && time(NULL) != lastSync)
		{
			lastSync = time(NULL);
			synced = follow_sync_main_sentinel(sourceDB, workers, count,
											   endpos, false, &replayLSN);

			if (synced && !follow_check_wal_workers_endpos(workers, count,
														   endpos))
			{
				failed = true;
				(void) follow_stop_wal_workers(workers, count, &stopping);
			}
		}

		if (!synced && !failed)
		{
			log_error("Failed to sync the main sentinel with the WAL workers, "
					  "see above for details");
			failed = true;
			(void) follow_stop_wal_workers(workers, count, &stopping);
		}

		/* endpos is re-read after the last exit: it may have been raised */
		if (running == 0 && !stopping && !failed)
		{
			CopyDBSentinel last = { 0 };

			if (!sentinel_get(sourceDB, &last))
			{
				log_error("Failed to read the main sentinel");
				failed = true;
				break;
			}

			if (last.endpos != endpos)
			{
				continue;
			}
		}

		/*
		 * An endpos moved since a worker finished starts it again; one below
		 * its replay_lsn failed the run above.
		 */
		bool again = false;

		for (int k = 0; !stopping && !failed && k < count; k++)
		{
			FollowWalWorker *worker = &(workers[k]);

			if (worker->process.exited &&
				endpos != InvalidXLogRecPtr &&
				worker->finishedAt != InvalidXLogRecPtr &&
				worker->finishedAt != endpos)
			{
				log_info("Starting WAL worker %d again: it finished at %X/%X, "
						 "endpos is now %X/%X",
						 k,
						 LSN_FORMAT_ARGS(worker->finishedAt),
						 LSN_FORMAT_ARGS(endpos));
				worker->start = true;
			}

			again = again || worker->start;
		}

		if (again &&
			!follow_fork_wal_workers(copySpecs, streamSpecs, workers, count,
									 &running))
		{
			failed = true;
			(void) follow_stop_wal_workers(workers, count, &stopping);
		}

		if (running == 0)
		{
			break;
		}

		(void) follow_coordinator_handle_messages(&followCoord, streamSpecs);

		/* the coordinator waits 100 ms for a client when it is listening */
		if (followCoord.tcp_listen.fd < 0)
		{
			pg_usleep(100 * 1000);
		}
	}

	/* a signal stops the workers short of endpos, whatever they recorded */
	bool stopped = asked_to_stop || asked_to_stop_fast || asked_to_quit;
	bool allDone = !failed && !stopped && endpos != InvalidXLogRecPtr;

	for (int k = 0; k < count; k++)
	{
		allDone = allDone && workers[k].finishedAt == endpos;
	}

	/* a publication dropped meanwhile lost the changes of its table */
	for (int k = 0; allDone && k < count; k++)
	{
		allDone = follow_check_wal_worker_publications(sourceDB,
													   streamSpecs->connStrings,
													   streamSpecs->slot.slotName,
													   k);
	}

	allDone = allDone &&
			  follow_sync_main_sentinel(sourceDB, workers, count, endpos, true,
										&replayLSN);

	(void) pipeline_state_end(sourceDB, "apply", replayLSN, allDone);
	(void) follow_coordinator_shutdown(&followCoord);

	if (!allDone)
	{
		log_error("Follow mode stopped before every WAL worker reached "
				  "endpos, see above for details");
		return false;
	}

	log_info("Follow mode is now done, %d WAL workers reached endpos %X/%X, "
			 "lowest replay_lsn is %X/%X",
			 count,
			 LSN_FORMAT_ARGS(endpos),
			 LSN_FORMAT_ARGS(replayLSN));

	return true;
}
