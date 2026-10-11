/*
 * A statement from catalog_sql_prepare_cached belongs to the cache: an error
 * on its bind or its step must leave it prepared for the next caller.
 */
#include <stdio.h>
#include <stdlib.h>

#include "catalog.h"

static const char *countSQL = "select count(*) from t where a = $1";
static const char *absSQL = "select abs($1)";
static bool failed = false;

static bool
fetch_int(SQLiteQuery *query)
{
	*(int64_t *) query->context = sqlite3_column_int64(query->ppStmt, 0);
	return true;
}


static bool
fetch_fails(SQLiteQuery *query)
{
	return false;
}


/*
 * sqlite3_finalize takes a statement off its connection's list.  Carry on
 * after a failure, so that an ASan build reports the use of the freed one.
 */
static void
check_prepared(DatabaseCatalog *catalog, sqlite3_stmt *stmt, const char *after)
{
	for (sqlite3_stmt *s = sqlite3_next_stmt(catalog->db, NULL);
		 s != NULL;
		 s = sqlite3_next_stmt(catalog->db, s))
	{
		if (s == stmt)
		{
			printf("ok: the cached statement survived %s\n", after);
			return;
		}
	}

	printf("FAIL: %s finalized the cached statement\n", after);
	failed = true;
}


static sqlite3_stmt *
prepare(DatabaseCatalog *catalog, const char *sql, SQLiteQuery *query)
{
	if (!catalog_sql_prepare_cached(catalog, sql, query))
	{
		printf("FAIL: could not prepare %s\n", sql);
		exit(2);
	}
	return query->ppStmt;
}


/* run the cached sql with one int64 argument, expect one int64 back */
static int64_t
run(DatabaseCatalog *catalog, const char *sql, int64_t arg)
{
	int64_t result = -1;
	SQLiteQuery query = { .context = &result, .fetchFunction = &fetch_int };
	BindParam params[1] = {
		{ BIND_PARAMETER_TYPE_INT64, "a", (uint64_t) arg, NULL }
	};

	(void) prepare(catalog, sql, &query);

	if (!catalog_sql_bind(&query, params, 1) || !catalog_sql_execute(&query))
	{
		printf("FAIL: could not run %s\n", sql);
		exit(2);
	}
	return result;
}


int
main(void)
{
	DatabaseCatalog catalog = { 0 };

	setvbuf(stdout, NULL, _IOLBF, 0);

	/* without lookaside, statements are heap memory that ASan tracks */
	if (sqlite3_open(":memory:", &catalog.db) != SQLITE_OK ||
		sqlite3_db_config(catalog.db, SQLITE_DBCONFIG_LOOKASIDE, NULL, 0, 0) !=
		SQLITE_OK ||
		sqlite3_exec(catalog.db, "create table t(a integer); insert into t values (1)",
					 NULL, NULL, NULL) != SQLITE_OK)
	{
		return 2;
	}

	/* cache both statements first, as the second call of a caller would */
	if (run(&catalog, countSQL, 1) != 1 || run(&catalog, absSQL, -5) != 5)
	{
		printf("FAIL: wrong results before any error\n");
		return 2;
	}

	for (int i = 0; i < 3; i++)
	{
		SQLiteQuery query = { 0 };
		sqlite3_stmt *stmt = prepare(&catalog, countSQL, &query);
		BindParam two[2] = {
			{ BIND_PARAMETER_TYPE_INT64, "a", 1, NULL },
			{ BIND_PARAMETER_TYPE_INT64, "extra", 2, NULL }
		};

		/* two values for one placeholder: SQLITE_RANGE */
		if (catalog_sql_bind(&query, two, 2))
		{
			printf("FAIL: a bind with one value too many succeeded\n");
			return 2;
		}
		check_prepared(&catalog, stmt, "a failed bind");

		int64_t unused = 0;
		query = (SQLiteQuery) {
			.context = &unused, .fetchFunction = &fetch_fails
		};
		stmt = prepare(&catalog, countSQL, &query);
		BindParam one[1] = {
			{ BIND_PARAMETER_TYPE_INT64, "a", 1, NULL }
		};

		if (!catalog_sql_bind(&query, one, 1) || catalog_sql_execute(&query))
		{
			printf("FAIL: an execute with a failing fetch succeeded\n");
			return 2;
		}
		check_prepared(&catalog, stmt, "a failed fetch");

		query = (SQLiteQuery) {
			.context = &unused, .fetchFunction = &fetch_int
		};
		stmt = prepare(&catalog, absSQL, &query);
		BindParam min[1] = {
			{ BIND_PARAMETER_TYPE_INT64, "a", (uint64_t) INT64_MIN, NULL }
		};

		/* abs() of the smallest int64 is an integer overflow error */
		if (!catalog_sql_bind(&query, min, 1) || catalog_sql_execute(&query))
		{
			printf("FAIL: abs(%lld) succeeded\n", (long long) INT64_MIN);
			return 2;
		}
		check_prepared(&catalog, stmt, "a failed step");
	}

	if (run(&catalog, countSQL, 1) != 1 || run(&catalog, absSQL, -7) != 7)
	{
		printf("FAIL: wrong results after the errors\n");
		return 1;
	}

	if (!catalog_close(&catalog) || failed)
	{
		printf("FAIL\n");
		return 1;
	}

	printf("PASS: cached statements stay usable after bind, fetch and step errors\n");
	return 0;
}
