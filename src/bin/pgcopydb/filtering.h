/*
 * src/bin/pgcopydb/filtering.h
 *     Implementation of a CLI which lets you run individual routines
 *     directly
 */

#ifndef FILTERING_H
#define FILTERING_H

#include <errno.h>
#include <getopt.h>
#include <inttypes.h>

#include "pgsql.h"


typedef enum
{
	SOURCE_FILTER_UNKNOWN = 0,
	SOURCE_FILTER_INCLUDE_ONLY_SCHEMA,
	SOURCE_FILTER_EXCLUDE_SCHEMA,
	SOURCE_FILTER_EXCLUDE_TABLE,
	SOURCE_FILTER_EXCLUDE_TABLE_DATA,
	SOURCE_FILTER_EXCLUDE_INDEX,
	SOURCE_FILTER_INCLUDE_ONLY_TABLE,
	SOURCE_FILTER_EXCLUDE_EXTENSION,
	SOURCE_FILTER_INCLUDE_ONLY_EXTENSION
} SourceFilterSection;

typedef struct SourceFilterSchema
{
	char nspname[PG_NAMEDATALEN];        /* bare name from pg_namespace (after normalization) */
	char restoreListName[PG_NAMEDATALEN]; /* quote_ident form for pg_dump/pg_restore args */
} SourceFilterSchema;

typedef struct SourceFilterSchemaList
{
	int count;
	int countOriginal;          /* parsed exact count (0 uses count) */
	SourceFilterSchema *array;  /* malloc'ed area */
} SourceFilterSchemaList;


typedef struct SourceFilterTable
{
	char nspname[PG_NAMEDATALEN];
	char relname[PG_NAMEDATALEN];
} SourceFilterTable;

typedef struct SourceFilterTableList
{
	int count;
	int countOriginal;          /* parsed exact count (0 uses count) */
	SourceFilterTable *array;   /* malloc'ed area */
} SourceFilterTableList;


typedef struct SourceFilterExtension
{
	char extname[PG_NAMEDATALEN];
} SourceFilterExtension;

typedef struct SourceFilterExtensionList
{
	int count;
	SourceFilterExtension *array;   /* malloc'ed area */
} SourceFilterExtensionList;


typedef struct SourceFilterSchemaPattern
{
	char nspname_re[BUFSIZE];   /* POSIX ERE pattern for the schema name */
} SourceFilterSchemaPattern;

typedef struct SourceFilterSchemaPatternList
{
	int count;
	SourceFilterSchemaPattern *array;   /* malloc'ed area */
} SourceFilterSchemaPatternList;


/* Each name uses exactly one of its exact or regex fields. */
typedef struct SourceFilterTablePattern
{
	char nspname[PG_NAMEDATALEN];   /* exact schema name, or empty */
	char nspname_re[BUFSIZE];        /* POSIX ERE for schema, or empty */
	char relname[PG_NAMEDATALEN];   /* exact table name, or empty */
	char relname_re[BUFSIZE];        /* POSIX ERE for table, or empty */
} SourceFilterTablePattern;

typedef struct SourceFilterTablePatternList
{
	int count;
	SourceFilterTablePattern *array;   /* malloc'ed area */
} SourceFilterTablePatternList;


/*
 * Define a Source Filter Type that allows producing the right kind of SQL
 * query. To that end, we need to distinguish if we're going to:
 *
 * - include only some tables (inner join)
 *
 * - exclude some tables (exclude-schema, exclude-table, exclude-table-data all
 *   lead to the same kind of anti-join form based on left join where
 *   right-side is null)
 *
 * - or exclude only some indexes (no filtering on schema queries for tables,
 *   only on the schema queries for indexes).
 *
 * Adding to that, we also need to produce a list of OIDs to skip in the
 * pg_dump catalog when calling into pg_restore. The include-only-table filter
 * is already implemented, see `copydb_objectid_has_been_processed_already'.
 * The exclusion filters need to be implemented as an inner join query if we
 * want to list the OIDs of skipped objects.
 *
 */
typedef enum
{
	SOURCE_FILTER_TYPE_NONE = 0,
	SOURCE_FILTER_TYPE_INCL,
	SOURCE_FILTER_TYPE_EXCL,

	SOURCE_FILTER_TYPE_LIST_NOT_INCL,
	SOURCE_FILTER_TYPE_LIST_EXCL,

	SOURCE_FILTER_TYPE_EXCL_INDEX,
	SOURCE_FILTER_TYPE_LIST_EXCL_INDEX
} SourceFilterType;

typedef struct SourceFilters
{
	bool prepared;
	bool normalized;
	SourceFilterType type;
	SourceFilterSchemaList includeOnlySchemaList;
	SourceFilterSchemaList excludeSchemaList;
	SourceFilterTableList includeOnlyTableList;
	SourceFilterTableList excludeTableList;
	SourceFilterTableList excludeTableDataList;
	SourceFilterTableList excludeIndexList;
	SourceFilterExtensionList excludeExtensionList;
	SourceFilterExtensionList includeOnlyExtensionList;

	/* Keep regex text for PostgreSQL's ~ predicates in discovery queries. */
	SourceFilterSchemaPatternList includeOnlySchemaPatternList;
	SourceFilterSchemaPatternList excludeSchemaPatternList;
	SourceFilterTablePatternList includeOnlyTablePatternList;
	SourceFilterTablePatternList excludeTablePatternList;
	SourceFilterTablePatternList excludeTableDataPatternList;
	SourceFilterTablePatternList excludeIndexPatternList;
} SourceFilters;

char * filterTypeToString(SourceFilterType type);
SourceFilterType filterTypeComplement(SourceFilterType type);
bool parse_filters(const char *filebname, SourceFilters *filters);
bool filters_validate_and_normalize(PGSQL *pgsql, SourceFilters *filters);

bool filters_as_json(SourceFilters *filters, JSON_Value *jsFilter);
bool filters_from_json(SourceFilters *filters, JSON_Value *jsFilter);
void filters_free(SourceFilters *filters);

bool filter_entry_is_pattern(const char *entry);
bool parse_filter_table_pattern(SourceFilterTablePattern *pattern,
								const char *entry);
bool parse_filter_schema_pattern(SourceFilterSchemaPattern *pattern,
								 const char *entry);

#endif  /* FILTERING_H */
