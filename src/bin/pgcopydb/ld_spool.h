/*
 * src/bin/pgcopydb/ld_spool.h
 *	 The raw spool of performance mode: segment files of checksummed frames,
 *	 the index of the transactions they hold, and the relation log.
 *	 Every integer of the format is big-endian.
 */

#ifndef LD_SPOOL_H
#define LD_SPOOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "postgres_fe.h"
#include "pqexpbuffer.h"

#define SPOOL_MAGIC 0x50474353  /* "PGCS" */
#define SPOOL_FORMAT_VERSION 1

/*
 * A segment starts with a header of 64 bytes: magic (offset 0), version (4),
 * firstSeq (8), systemId (16), timeline (24), lastFinalLSN (32), lastEndLSN
 * (40), zeroes, and the CRC-32C of bytes 0 to 59 (60).
 */
#define SPOOL_HEADER_SIZE 64

typedef struct SpoolHeader
{
	uint64_t firstSeq;          /* sequence number of the first transaction */
	uint64_t systemId;          /* of the source, as IDENTIFY_SYSTEM gives it */
	uint32_t timeline;

	/* of the last complete transaction before this segment */
	uint64_t lastFinalLSN;
	uint64_t lastEndLSN;
} SpoolHeader;

/*
 * A frame is the length of its message (4 bytes), the message, and the
 * CRC-32C of length and message (4 bytes). The first byte of the message is
 * its kind.
 */
#define SPOOL_FRAME_SIZE(length) ((uint64_t) (length) + 8)

/* the walsender builds a CopyData message in one MaxAllocSize buffer */
#define SPOOL_MESSAGE_MAX (1024 * 1024 * 1024)

/* the CopyData message as received: dataStart, walEnd, sendTime, pgoutput */
#define SPOOL_KIND_XLOGDATA 'w'
#define SPOOL_XLOGDATA_HEADER_SIZE 25

/* the keepalive marker of receive: position and send time */
#define SPOOL_KIND_KEEPALIVE 'k'
#define SPOOL_KEEPALIVE_SIZE 17

typedef enum
{
	SPOOL_FRAME_OK = 0,
	SPOOL_FRAME_SHORT,          /* the bytes end inside the frame */
	SPOOL_FRAME_BAD             /* wrong checksum, length or kind */
} SpoolFrameStatus;

/* frames wait in one write block, written out when full and by spool_sync */
#define SPOOL_BLOCK_SIZE (1024 * 1024)

/*
 * A spool file open for appending: a segment, or the relation log. A failed
 * create, write, sync, or truncate in a rewind, is final: it closes the file
 * and sets fd to -1, and later calls refuse it, as they refuse one that was
 * never opened. Only the refusal of a message that the format does not hold
 * leaves it open.
 */
typedef struct SpoolSegment
{
	char filename[MAXPGPATH];
	int fd;
	uint64_t size;              /* bytes written to the file */
	uint64_t synced;            /* bytes that the last fsync covered */
	char *block;
	size_t blockLength;
} SpoolSegment;

/*
 * A transaction index record has 64 bytes: seq (offset 0), xid (8), changes
 * (12), beginOffset (20), endOffset (28), finalLSN (36), endLSN (44),
 * commitTime (52), and the CRC-32C of bytes 0 to 59 (60).
 */
#define SPOOL_INDEX_RECORD_SIZE 64

typedef struct SpoolIndexRecord
{
	uint64_t seq;               /* dense, in commit order */
	uint32_t xid;
	uint64_t changes;           /* INSERT, UPDATE, DELETE and TRUNCATE messages */
	uint64_t beginOffset;       /* of the BEGIN frame in the segment */
	uint64_t endOffset;         /* after the COMMIT frame */
	uint64_t finalLSN;          /* from BEGIN, read only by the rule for resends */
	uint64_t endLSN;            /* from COMMIT: c(T) */
	uint64_t commitTime;        /* from COMMIT, a TimestampTz */
} SpoolIndexRecord;

/*
 * A relation log record: the position seq (offset 0) and changes (8), the
 * length of the message (16), the RELATION or TYPE message from its type byte,
 * and the CRC-32C of all the bytes before it.
 */
#define SPOOL_RELATION_LOG "relation.log"
#define SPOOL_RELATION_HEADER_SIZE 20
#define SPOOL_RELATION_RECORD_SIZE(length) ((uint64_t) (length) + 24)

typedef struct SpoolRelationRecord
{
	uint64_t seq;               /* that the open or next transaction gets */
	uint64_t changes;           /* change frames before it in that transaction */
	const char *message;        /* points into the decoded bytes */
	uint32_t length;
} SpoolRelationRecord;

/* the last message logged for one relation or type */
typedef struct SpoolRelationLast
{
	uint64_t key;               /* type byte and OID */
	PQExpBufferData message;
} SpoolRelationLast;

typedef struct SpoolRelationEntry
{
	uint64_t seq;
	uint64_t changes;
	uint64_t offset;            /* of the message in the bytes of the cursor */
	uint32_t length;
	bool applied;
} SpoolRelationEntry;

/*
 * A reader of the relation log. A record can follow one with a higher
 * position, after a transaction was cut off and sent again, so the cursor
 * applies records by position and keeps the last one in log order.
 */
typedef struct SpoolRelationCursor
{
	char filename[MAXPGPATH];
	char *bytes;                /* the log as read */
	uint64_t size;              /* up to the end of its last whole record */
	uint64_t tail;              /* bytes read after that, of a record cut off */
	PQExpBufferData entries;    /* SpoolRelationEntry, in log order */
	int count;

	/* the lowest position of a record not applied yet */
	uint64_t pendingSeq;
	uint64_t pendingChanges;
} SpoolRelationCursor;

struct StreamContext;

typedef enum
{
	SPOOL_TXN_NONE = 0,
	SPOOL_TXN_HELD,             /* BEGIN and ORIGIN wait for another message */
	SPOOL_TXN_OPEN,
	SPOOL_TXN_SKIP              /* sent again: the spool holds it already */
} SpoolTxnState;

/*
 * The writer turns the messages of receive into frames and index records. A
 * complete, non-empty transaction gets one record, which waits in
 * pendingIndex until the flush has synced its frames.
 */
typedef struct SpoolWriter
{
	char dirname[MAXPGPATH];
	uint64_t maxSegmentSize;    /* rotate after a COMMIT at or past it, 0 never */
	SpoolHeader header;         /* of the open segment */
	SpoolSegment segment;

	/* the last complete transaction, also while its record is in memory */
	uint64_t nextSeq;
	uint64_t lastFinalLSN;
	uint64_t lastEndLSN;
	uint64_t completeSize;      /* where it ends in the segment */

	SpoolTxnState state;
	SpoolIndexRecord txn;       /* of the open transaction */
	PQExpBufferData held;       /* messages, each after its 4-byte length */
	PQExpBufferData pendingIndex;   /* encoded records */

	SpoolSegment relationLog;
	PQExpBufferData lasts;      /* SpoolRelationLast, one per relation or type */
} SpoolWriter;

/* the sequence number of the first transaction of a new spool */
#define SPOOL_FIRST_SEQ 1

/* the frames of one transaction, read by byte range and never past its end */
typedef struct SpoolFrames
{
	char filename[MAXPGPATH];
	int fd;
	uint64_t offset;            /* of the next frame */
	uint64_t end;               /* after the COMMIT frame */
	PQExpBufferData buffer;     /* the bytes of the file from bufferStart */
	uint64_t bufferStart;
} SpoolFrames;

/* index records that one read of an index file takes */
#define SPOOL_READER_CHUNK 64

/*
 * A read-only cursor over the index records of a spool and their frames. An
 * invalid record at the tail of the last index file is one that receive is
 * still writing, and any other invalid record or frame is an error.
 */
typedef struct SpoolReader
{
	char dirname[MAXPGPATH];
	uint64_t after;             /* records at or below this end LSN are skipped */
	uint64_t segment;           /* first sequence number of the segment read */
	uint64_t nextSeq;           /* of the next record, which names the next segment */
	char indexFilename[MAXPGPATH];
	int indexFd;
	uint64_t indexOffset;       /* of the next record to read from the file */
	SpoolIndexRecord chunk[SPOOL_READER_CHUNK];
	int chunkCount;
	int chunkNext;
	SpoolIndexRecord record;    /* that spool_reader_next returned */
	uint64_t changes;           /* change frames of that record returned so far */
	SpoolFrames frames;
	SpoolRelationCursor relations;
} SpoolReader;

uint32_t spool_crc32c(const char *data, size_t length);

void spool_header_encode(const SpoolHeader *header, char *buf);
bool spool_header_decode(const char *buf, uint64_t size, SpoolHeader *header);

SpoolFrameStatus spool_frame_decode(const char *buf, uint64_t size,
									const char **message, uint32_t *length);

bool spool_segment_create(SpoolSegment *segment, const char *dirname,
						  const SpoolHeader *header);
bool spool_append(SpoolSegment *segment, const char *message, uint32_t length);
bool spool_sync(SpoolSegment *segment);

void spool_index_encode(const SpoolIndexRecord *record, char *buf);
bool spool_index_decode(const char *buf, uint64_t size, SpoolIndexRecord *record);

bool spool_writer_create(SpoolWriter *writer, const char *dirname,
						 const SpoolHeader *header, uint64_t maxSegmentSize);
bool spool_writer_message(SpoolWriter *writer, const char *message,
						  uint32_t length);
bool spool_writer_rewind(SpoolWriter *writer);
bool spool_writer_rotate_due(const SpoolWriter *writer);
bool spool_writer_rotate(SpoolWriter *writer);
bool spool_writer_open(SpoolWriter *writer, const char *dirname,
					   uint64_t systemId, uint32_t timeline,
					   uint64_t maxSegmentSize);

SpoolFrameStatus spool_relation_decode(const char *buf, uint64_t size,
									   SpoolRelationRecord *record);

bool spool_relation_cursor_open(SpoolRelationCursor *cursor, const char *dirname);
bool spool_relation_cursor_read(SpoolRelationCursor *cursor);
bool spool_relation_cursor_advance(SpoolRelationCursor *cursor,
								   uint64_t seq, uint64_t changes,
								   struct StreamContext *context);
void spool_relation_cursor_close(SpoolRelationCursor *cursor);

bool spool_reader_open(SpoolReader *reader, const char *dirname, uint64_t after);
bool spool_reader_next(SpoolReader *reader, bool *found);
bool spool_reader_frame(SpoolReader *reader, struct StreamContext *context,
						const char **message, uint32_t *length, bool *done);
void spool_reader_close(SpoolReader *reader);

#endif /* LD_SPOOL_H */
