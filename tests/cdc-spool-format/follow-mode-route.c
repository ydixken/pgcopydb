/*
 * stream_uses_raw_spool is the one switch of performance mode. The option
 * parsers refuse a plugin other than pgoutput and more than one worker before
 * a run can reach it, so these checks are the only thing that keeps the other
 * two conditions of the predicate honest.
 */
#include <stdio.h>

#include "ld_stream.h"
#include "log.h"

static bool failed = false;

static StreamSpecs specs = { 0 };


static void
check(bool ok, const char *what)
{
	printf("%s: %s\n", ok ? "ok" : "FAIL", what);
	failed = failed || !ok;
}


int
main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	log_set_level(LOG_DEBUG);

	specs.followMode = FOLLOW_MODE_PERFORMANCE;
	specs.slot.plugin = STREAM_PLUGIN_PGOUTPUT;

	check(stream_uses_raw_spool(&specs),
		  "a pgoutput performance run at one worker takes the raw spool");

	specs.followMode = FOLLOW_MODE_SQLITE;

	check(!stream_uses_raw_spool(&specs),
		  "sqlite mode keeps the SQLite spool, pgoutput included");

	specs.followMode = FOLLOW_MODE_PERFORMANCE;
	specs.slot.plugin = STREAM_PLUGIN_TEST_DECODING;

	check(!stream_uses_raw_spool(&specs),
		  "performance mode with test_decoding keeps the SQLite spool");

	specs.slot.plugin = STREAM_PLUGIN_WAL2JSON;

	check(!stream_uses_raw_spool(&specs),
		  "performance mode with wal2json keeps the SQLite spool");

	specs.slot.plugin = STREAM_PLUGIN_UNKNOWN;

	check(!stream_uses_raw_spool(&specs),
		  "performance mode without a known plugin keeps the SQLite spool");

	specs.slot.plugin = STREAM_PLUGIN_PGOUTPUT;
	specs.walWorker = true;

	check(!stream_uses_raw_spool(&specs),
		  "a WAL worker process of performance mode keeps the SQLite spool");

	if (failed)
	{
		printf("FAIL\n");
		return 1;
	}

	printf("PASS: the route to the raw spool\n");
	return 0;
}
