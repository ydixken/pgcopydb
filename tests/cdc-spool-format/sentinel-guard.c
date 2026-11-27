/*
 * The guarded writer of the sentinel replay_lsn, which the raw path uses: W
 * feeds the slot and decides which segments cleanup deletes, so it never
 * falls. The unguarded writer of the SQLite path takes any value.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "catalog.h"
#include "copydb.h"
#include "log.h"

static bool failed = false;


static void
check(bool ok, const char *what)
{
	printf("%s: %s\n", ok ? "ok" : "FAIL", what);
	failed = failed || !ok;
}


/* the stored replay_lsn, as sentinel_get parses it */
static uint64_t
stored(DatabaseCatalog *catalog)
{
	CopyDBSentinel sentinel = { 0 };

	if (!sentinel_get(catalog, &sentinel))
	{
		printf("FAIL: could not read the sentinel\n");
		exit(2);
	}

	return sentinel.replay_lsn;
}


int
main(void)
{
	char dir[] = "/tmp/sentinel-guard.XXXXXX";
	DatabaseCatalog catalog = { .type = DATABASE_CATALOG_TYPE_SOURCE };

	setvbuf(stdout, NULL, _IOLBF, 0);
	log_set_level(LOG_DEBUG);

	if (mkdtemp(dir) == NULL)
	{
		printf("FAIL: mkdtemp\n");
		return 2;
	}

	sformat(catalog.dbfile, sizeof(catalog.dbfile), "%s/source.db", dir);

	if (!catalog_init(&catalog) ||
		!sentinel_setup(&catalog, 0, InvalidXLogRecPtr, false) ||
		!sentinel_update_replay_lsn_guarded(&catalog, 0x200))
	{
		printf("FAIL: could not set up the sentinel\n");
		return 2;
	}

	check(stored(&catalog) == 0x200,
		  "the guarded writer stores a value above the stored one");

	check(!sentinel_update_replay_lsn_guarded(&catalog, 0x100) &&
		  stored(&catalog) == 0x200,
		  "the guarded writer refuses a value below the stored one, which stays");

	check(sentinel_update_replay_lsn_guarded(&catalog, 0x200) &&
		  stored(&catalog) == 0x200,
		  "the guarded writer stores the value it holds again");

	/* the SQLite path and the N-slot supervisor keep the writer of 9d8b660 */
	check(sentinel_update_replay_lsn(&catalog, 0x100) &&
		  stored(&catalog) == 0x100,
		  "the unguarded writer of the SQLite path takes a lower value");

	if (!catalog_close(&catalog) || failed)
	{
		printf("FAIL\n");
		return 1;
	}

	(void) semaphore_finish(&(catalog.sema));
	(void) unlink(catalog.dbfile);
	(void) rmdir(dir);

	printf("PASS: the guarded writer of the sentinel replay_lsn\n");
	return 0;
}
