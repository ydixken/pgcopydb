/*
 * src/bin/pgcopydb/ld_spool.c
 *	 The raw spool of performance mode: segment files of checksummed frames,
 *	 the index of the transactions they hold, and the relation log.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "postgres_fe.h"
#include "port/pg_crc32c.h"

#include "defaults.h"
#include "file_utils.h"
#include "ld_pgoutput.h"
#include "ld_spool.h"
#include "log.h"
#include "pg_utils.h"


/*
 * spool_crc32c returns the CRC-32C of libpgport over the given bytes.
 */
uint32_t
spool_crc32c(const char *data, size_t length)
{
	pg_crc32c crc;

	INIT_CRC32C(crc);
	COMP_CRC32C(crc, data, length);
	FIN_CRC32C(crc);

	return crc;
}


/*
 * spool_put_u32 and spool_put_u64 write big-endian, as pgout_u32 and
 * pgout_u64 read it, without the memcpy that pg_hton32 would need here.
 */
static void
spool_put_u32(char *buf, uint32_t value)
{
	for (int i = 0; i < 4; i++)
	{
		buf[i] = (char) (value >> (24 - 8 * i));
	}
}


static void
spool_put_u64(char *buf, uint64_t value)
{
	spool_put_u32(buf, (uint32_t) (value >> 32));
	spool_put_u32(buf + 4, (uint32_t) value);
}


/*
 * spool_header_encode writes the 64 bytes of a segment header to buf.
 */
void
spool_header_encode(const SpoolHeader *header, char *buf)
{
	memset(buf, 0, SPOOL_HEADER_SIZE);

	spool_put_u32(buf, SPOOL_MAGIC);
	spool_put_u32(buf + 4, SPOOL_FORMAT_VERSION);
	spool_put_u64(buf + 8, header->firstSeq);
	spool_put_u64(buf + 16, header->systemId);
	spool_put_u32(buf + 24, header->timeline);
	spool_put_u64(buf + 32, header->lastFinalLSN);
	spool_put_u64(buf + 40, header->lastEndLSN);
	spool_put_u32(buf + 60, spool_crc32c(buf, 60));
}


/*
 * spool_header_decode reads a segment header, and returns false when the
 * bytes are short, of another format, or fail the checksum.
 */
bool
spool_header_decode(const char *buf, uint64_t size, SpoolHeader *header)
{
	SpoolHeader read = { 0 };
	int pos = 0;

	if (size < SPOOL_HEADER_SIZE)
	{
		return false;
	}

	uint32_t magic = pgout_u32(buf, &pos, SPOOL_HEADER_SIZE);
	uint32_t version = pgout_u32(buf, &pos, SPOOL_HEADER_SIZE);

	read.firstSeq = pgout_u64(buf, &pos, SPOOL_HEADER_SIZE);
	read.systemId = pgout_u64(buf, &pos, SPOOL_HEADER_SIZE);
	read.timeline = pgout_u32(buf, &pos, SPOOL_HEADER_SIZE);

	pos = 32;
	read.lastFinalLSN = pgout_u64(buf, &pos, SPOOL_HEADER_SIZE);
	read.lastEndLSN = pgout_u64(buf, &pos, SPOOL_HEADER_SIZE);

	pos = 60;
	uint32_t crc = pgout_u32(buf, &pos, SPOOL_HEADER_SIZE);

	if (magic != SPOOL_MAGIC || version != SPOOL_FORMAT_VERSION ||
		crc != spool_crc32c(buf, 60))
	{
		return false;
	}

	*header = read;

	return true;
}


/*
 * spool_message_valid is the rule for the kind and size of a message, shared
 * by the writer and the reader, so that the writer appends only frames that
 * the reader accepts.
 */
static bool
spool_message_valid(const char *message, uint32_t length)
{
	if (length == 0 || length > SPOOL_MESSAGE_MAX)
	{
		return false;
	}

	switch (message[0])
	{
		case SPOOL_KIND_XLOGDATA:
		{
			return length >= SPOOL_XLOGDATA_HEADER_SIZE;
		}

		case SPOOL_KIND_KEEPALIVE:
		{
			return length == SPOOL_KEEPALIVE_SIZE;
		}

		default:
		{
			return false;
		}
	}
}


static uint32_t
spool_frame_crc(const char *lengthBytes, const char *message, uint32_t length)
{
	pg_crc32c crc;

	INIT_CRC32C(crc);
	COMP_CRC32C(crc, lengthBytes, 4);
	COMP_CRC32C(crc, message, length);
	FIN_CRC32C(crc);

	return crc;
}


/*
 * spool_frame_decode reads the frame at the start of buf. On SPOOL_FRAME_OK,
 * message points into buf, and the frame takes SPOOL_FRAME_SIZE(*length).
 */
SpoolFrameStatus
spool_frame_decode(const char *buf, uint64_t size,
				   const char **message, uint32_t *length)
{
	int pos = 0;

	if (size < 4)
	{
		return SPOOL_FRAME_SHORT;
	}

	uint32_t messageLength = pgout_u32(buf, &pos, 4);

	/* a length that no message has is damage, not a frame still arriving */
	if (messageLength == 0 || messageLength > SPOOL_MESSAGE_MAX)
	{
		return SPOOL_FRAME_BAD;
	}

	if (size < SPOOL_FRAME_SIZE(messageLength))
	{
		return SPOOL_FRAME_SHORT;
	}

	pos = 0;
	uint32_t crc = pgout_u32(buf + 4 + messageLength, &pos, 4);

	if (crc != spool_frame_crc(buf, buf + 4, messageLength) ||
		!spool_message_valid(buf + 4, messageLength))
	{
		return SPOOL_FRAME_BAD;
	}

	*message = buf + 4;
	*length = messageLength;

	return SPOOL_FRAME_OK;
}


/*
 * spool_fsync is the only caller of fsync in the spool code. Its debug line
 * comes only after fsync returned 0, because the crash suite cuts each file
 * back to the length of its last such line.
 */
static bool
spool_fsync(int fd, const char *path, bool directory, uint64_t length)
{
	if (fsync(fd) != 0)
	{
		log_error("Failed to sync spool %s \"%s\": %m",
				  directory ? "directory" : "file", path);
		return false;
	}

	if (directory)
	{
		log_debug("Synced spool directory \"%s\"", path);
	}
	else
	{
		log_debug("Synced spool file \"%s\" at %" PRIu64 " bytes",
				  path, length);
	}

	return true;
}


/*
 * spool_fail closes a segment after a failed create, write, sync or truncate.
 * The file may end inside a frame, and Linux reports a failed writeback to one
 * fsync only, so a second sync could log a synced length for lost bytes.
 */
static void
spool_fail(SpoolSegment *segment)
{
	if (segment->fd >= 0)
	{
		(void) close(segment->fd);
	}

	free(segment->block);

	segment->fd = -1;
	segment->block = NULL;
	segment->blockLength = 0;
}


static bool
spool_usable(const SpoolSegment *segment)
{
	if (segment->fd < 0 || segment->block == NULL)
	{
		log_error("BUG: refusing spool file \"%s\", which was not opened, "
				  "or which a failed write, sync or truncate closed",
				  segment->filename);
		return false;
	}

	return true;
}


/*
 * spool_write writes all of buf to the segment file, as write(2) may write
 * less than it was given.
 */
static bool
spool_write(SpoolSegment *segment, const char *buf, size_t length)
{
	while (length > 0)
	{
		errno = 0;
		ssize_t written = write(segment->fd, buf, length);

		if (written < 0 && errno == EINTR)
		{
			continue;
		}

		if (written <= 0)
		{
			/* a write that sets no errno ran out of space, as PostgreSQL has it */
			if (errno == 0)
			{
				errno = ENOSPC;
			}

			log_error("Failed to write to spool file \"%s\": %m",
					  segment->filename);
			return false;
		}

		buf += written;
		length -= written;
		segment->size += written;
	}

	return true;
}


static bool
spool_write_block(SpoolSegment *segment)
{
	if (!spool_write(segment, segment->block, segment->blockLength))
	{
		spool_fail(segment);
		return false;
	}

	segment->blockLength = 0;

	return true;
}


/*
 * spool_put copies bytes to the write block, and writes the block out each
 * time it is full, so that a frame larger than the block passes through it.
 */
static bool
spool_put(SpoolSegment *segment, const char *bytes, size_t length)
{
	while (length > 0)
	{
		size_t n = Min(length, SPOOL_BLOCK_SIZE - segment->blockLength);

		memcpy(segment->block + segment->blockLength, bytes, n); /* IGNORE-BANNED */
		segment->blockLength += n;
		bytes += n;
		length -= n;

		if (segment->blockLength == SPOOL_BLOCK_SIZE &&
			!spool_write_block(segment))
		{
			return false;
		}
	}

	return true;
}


static bool
spool_sync_directory(const char *dirname)
{
	int fd = open(dirname, O_RDONLY);

	if (fd < 0)
	{
		log_error("Failed to open spool directory \"%s\": %m", dirname);
		return false;
	}

	bool synced = spool_fsync(fd, dirname, true, 0);

	(void) close(fd);

	return synced;
}


/* spool_file_open opens segment->filename with flags, and its write block */
static bool
spool_file_open(SpoolSegment *segment, int flags)
{
	segment->block = (char *) malloc(SPOOL_BLOCK_SIZE);

	if (segment->block == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	segment->fd = open(segment->filename, flags, 0644);

	if (segment->fd < 0)
	{
		log_error("Failed to open spool file \"%s\": %m", segment->filename);
		spool_fail(segment);
		return false;
	}

	return true;
}


/*
 * spool_segment_create creates the segment file of header->firstSeq in
 * dirname, then syncs the header and the directory entry, in that order.
 */
bool
spool_segment_create(SpoolSegment *segment, const char *dirname,
					 const SpoolHeader *header)
{
	char buf[SPOOL_HEADER_SIZE];

	*segment = (SpoolSegment) {
		.fd = -1
	};

	if (sformat(segment->filename, sizeof(segment->filename),
				"%s/%016" PRIX64 ".seg",
				dirname, header->firstSeq) >= (int) sizeof(segment->filename))
	{
		log_error("Spool file name \"%s/%016" PRIX64 ".seg\" is too long",
				  dirname, header->firstSeq);
		return false;
	}

	/* a segment that exists may hold acknowledged transactions */
	if (!spool_file_open(segment, O_WRONLY | O_CREAT | O_EXCL | O_APPEND))
	{
		return false;
	}

	spool_header_encode(header, buf);

	if (!spool_put(segment, buf, SPOOL_HEADER_SIZE) ||
		!spool_sync(segment) ||
		!spool_sync_directory(dirname))
	{
		spool_fail(segment);
		return false;
	}

	return true;
}


/*
 * spool_append copies one message as a frame to the write block. The frame
 * is durable only once the next spool_sync returned true.
 */
bool
spool_append(SpoolSegment *segment, const char *message, uint32_t length)
{
	char lengthBytes[4];
	char crcBytes[4];

	if (!spool_usable(segment))
	{
		return false;
	}

	if (!spool_message_valid(message, length))
	{
		log_error("BUG: spool_append got a message of %u bytes and kind %d, "
				  "which the spool format does not hold",
				  length, length > 0 ? message[0] : 0);
		return false;
	}

	spool_put_u32(lengthBytes, length);
	spool_put_u32(crcBytes, spool_frame_crc(lengthBytes, message, length));

	return spool_put(segment, lengthBytes, sizeof(lengthBytes)) &&
		   spool_put(segment, message, length) &&
		   spool_put(segment, crcBytes, sizeof(crcBytes));
}


/*
 * spool_sync writes the write block to the segment file and syncs the file.
 * It syncs with an empty block too, as spool_put writes a full block out
 * without a sync.
 */
bool
spool_sync(SpoolSegment *segment)
{
	if (!spool_usable(segment) || !spool_write_block(segment))
	{
		return false;
	}

	if (!spool_fsync(segment->fd, segment->filename, false, segment->size))
	{
		spool_fail(segment);
		return false;
	}

	segment->synced = segment->size;

	return true;
}


/*
 * spool_index_encode writes the 72 bytes of a transaction index record to buf.
 */
void
spool_index_encode(const SpoolIndexRecord *record, char *buf)
{
	spool_put_u64(buf, record->seq);
	spool_put_u32(buf + 8, record->xid);
	spool_put_u64(buf + 12, record->changes);
	spool_put_u64(buf + 20, record->beginOffset);
	spool_put_u64(buf + 28, record->endOffset);
	spool_put_u64(buf + 36, record->finalLSN);
	spool_put_u64(buf + 44, record->endLSN);
	spool_put_u64(buf + 52, record->commitTime);
	spool_put_u64(buf + 60, record->relationLogEnd);
	spool_put_u32(buf + 68, spool_crc32c(buf, 68));
}


/*
 * spool_index_decode reads a transaction index record, and returns false when
 * the bytes are short or fail the checksum.
 */
bool
spool_index_decode(const char *buf, uint64_t size, SpoolIndexRecord *record)
{
	SpoolIndexRecord read = { 0 };
	int pos = 0;

	if (size < SPOOL_INDEX_RECORD_SIZE)
	{
		return false;
	}

	read.seq = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.xid = pgout_u32(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.changes = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.beginOffset = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.endOffset = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.finalLSN = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.endLSN = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.commitTime = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);
	read.relationLogEnd = pgout_u64(buf, &pos, SPOOL_INDEX_RECORD_SIZE);

	if (pgout_u32(buf, &pos, SPOOL_INDEX_RECORD_SIZE) != spool_crc32c(buf, 68))
	{
		return false;
	}

	*record = read;

	return true;
}


/* the length of a segment, with the bytes that wait in its write block */
static uint64_t
spool_end(const SpoolSegment *segment)
{
	return segment->size + segment->blockLength;
}


/*
 * spool_relation_valid is the rule for a message of the relation log: a
 * RELATION or TYPE message from its type byte, long enough for its OID.
 */
static bool
spool_relation_valid(const char *message, uint32_t length)
{
	return length >= 5 && (message[0] == 'R' || message[0] == 'Y');
}


static uint32_t
spool_relation_crc(const char *head, const char *message, uint32_t length)
{
	pg_crc32c crc;

	INIT_CRC32C(crc);
	COMP_CRC32C(crc, head, SPOOL_RELATION_HEADER_SIZE);
	COMP_CRC32C(crc, message, length);
	FIN_CRC32C(crc);

	return crc;
}


/* the type byte goes above the OID, so that a TYPE and a RELATION differ */
static uint64_t
spool_relation_key(const char *message, uint32_t length)
{
	int pos = 1;

	return ((uint64_t) (unsigned char) message[0] << 32) |
		   pgout_u32(message, &pos, length);
}


/*
 * spool_relation_decode reads the relation log record at the start of buf.
 * On SPOOL_FRAME_OK, record->message points into buf.
 */
SpoolFrameStatus
spool_relation_decode(const char *buf, uint64_t size, SpoolRelationRecord *record)
{
	int pos = 16;

	if (size < SPOOL_RELATION_HEADER_SIZE)
	{
		return SPOOL_FRAME_SHORT;
	}

	uint32_t length = pgout_u32(buf, &pos, SPOOL_RELATION_HEADER_SIZE);

	/* a length that no message has is damage, not a record still arriving */
	if (length > SPOOL_MESSAGE_MAX)
	{
		return SPOOL_FRAME_BAD;
	}

	if (size < SPOOL_RELATION_RECORD_SIZE(length))
	{
		return SPOOL_FRAME_SHORT;
	}

	const char *message = buf + SPOOL_RELATION_HEADER_SIZE;

	pos = 0;
	uint32_t crc = pgout_u32(message + length, &pos, 4);

	if (crc != spool_relation_crc(buf, message, length) ||
		!spool_relation_valid(message, length))
	{
		return SPOOL_FRAME_BAD;
	}

	pos = 0;
	record->seq = pgout_u64(buf, &pos, SPOOL_RELATION_HEADER_SIZE);
	record->changes = pgout_u64(buf, &pos, SPOOL_RELATION_HEADER_SIZE);
	record->message = message;
	record->length = length;

	return SPOOL_FRAME_OK;
}


static bool
spool_position_before(uint64_t seq, uint64_t changes,
					  uint64_t otherSeq, uint64_t otherChanges)
{
	return seq < otherSeq || (seq == otherSeq && changes < otherChanges);
}


static SpoolRelationEntry *
spool_relation_entry(const SpoolRelationCursor *cursor, int i)
{
	return (SpoolRelationEntry *) cursor->entries.data + i;
}


/* the lowest position of a record not applied yet, or the highest of all */
static void
spool_relation_pending(SpoolRelationCursor *cursor)
{
	cursor->pendingSeq = UINT64_MAX;
	cursor->pendingChanges = UINT64_MAX;

	for (int i = 0; i < cursor->count; i++)
	{
		SpoolRelationEntry *entry = spool_relation_entry(cursor, i);

		if (!entry->applied &&
			spool_position_before(entry->seq, entry->changes,
								  cursor->pendingSeq, cursor->pendingChanges))
		{
			cursor->pendingSeq = entry->seq;
			cursor->pendingChanges = entry->changes;
		}
	}
}


/*
 * spool_relation_cursor_open reads the relation log of dirname from its
 * beginning, as the log is not trimmed.
 */
bool
spool_relation_cursor_open(SpoolRelationCursor *cursor, const char *dirname)
{
	*cursor = (SpoolRelationCursor) {
		0
	};

	initPQExpBuffer(&cursor->entries);

	if (sformat(cursor->filename, sizeof(cursor->filename),
				"%s/" SPOOL_RELATION_LOG, dirname) >= (int) sizeof(cursor->filename))
	{
		log_error("Spool file name \"%s/" SPOOL_RELATION_LOG "\" is too long",
				  dirname);
		return false;
	}

	return spool_relation_cursor_read(cursor);
}


/*
 * spool_relation_cursor_read reads the records that receive logged since the
 * last read. A record cut off at the end is read once it is whole.
 */
bool
spool_relation_cursor_read(SpoolRelationCursor *cursor)
{
	char *bytes = NULL;
	long fileSize = 0;

	/*
	 * shortcut: reads the whole log each time; read from cursor->size once a
	 * worker reads the log often.
	 */
	if (!read_file(cursor->filename, &bytes, &fileSize))
	{
		/* errors have already been logged */
		return false;
	}

	/* the records read before point into the bytes up to cursor->size */
	if ((uint64_t) fileSize < cursor->size)
	{
		log_error("Spool file \"%s\" has %" PRIu64 " bytes, and %" PRIu64
				  " were read before", cursor->filename, (uint64_t) fileSize,
				  cursor->size);
		free(bytes);
		return false;
	}

	free(cursor->bytes);
	cursor->bytes = bytes;

	uint64_t offset = cursor->size;
	SpoolFrameStatus status = SPOOL_FRAME_OK;
	bool kept = true;

	while (offset < (uint64_t) fileSize)
	{
		SpoolRelationRecord record = { 0 };

		status = spool_relation_decode(bytes + offset,
									   (uint64_t) fileSize - offset, &record);

		if (status != SPOOL_FRAME_OK)
		{
			break;
		}

		SpoolRelationEntry entry = {
			.seq = record.seq,
			.changes = record.changes,
			.offset = offset + SPOOL_RELATION_HEADER_SIZE,
			.length = record.length
		};

		appendBinaryPQExpBuffer(&cursor->entries, (char *) &entry, sizeof(entry));

		if (PQExpBufferBroken(&cursor->entries))
		{
			/* libpq freed the entries, so count must not walk them */
			log_error(ALLOCATION_FAILED_ERROR);
			cursor->count = 0;
			kept = false;
			break;
		}

		cursor->count++;
		offset += SPOOL_RELATION_RECORD_SIZE(record.length);
	}

	cursor->size = offset;
	cursor->tail = (uint64_t) fileSize - offset;
	spool_relation_pending(cursor);

	if (status == SPOOL_FRAME_BAD)
	{
		log_error("Spool file \"%s\" holds no valid relation log record "
				  "at offset %" PRIu64, cursor->filename, offset);
		return false;
	}

	return kept;
}


/* true when a record after entry i in log order, of its relation, is applied */
static bool
spool_relation_superseded(const SpoolRelationCursor *cursor, int i)
{
	SpoolRelationEntry *entry = spool_relation_entry(cursor, i);
	uint64_t key = spool_relation_key(cursor->bytes + entry->offset,
									  entry->length);

	for (int j = i + 1; j < cursor->count; j++)
	{
		SpoolRelationEntry *later = spool_relation_entry(cursor, j);

		if (later->applied &&
			spool_relation_key(cursor->bytes + later->offset,
							   later->length) == key)
		{
			return true;
		}
	}

	return false;
}


/*
 * spool_relation_cursor_advance applies, before change number changes of
 * transaction seq, every record at or below that position, so that the
 * relation cache of context holds the last such record of each relation.
 */
bool
spool_relation_cursor_advance(SpoolRelationCursor *cursor,
							  uint64_t seq, uint64_t changes,
							  struct StreamContext *context)
{
	/* a read that could not keep the records leaves none to apply */
	if (PQExpBufferBroken(&cursor->entries))
	{
		log_error("Spool file \"%s\" was not read into memory", cursor->filename);
		return false;
	}

	if (spool_position_before(seq, changes,
							  cursor->pendingSeq, cursor->pendingChanges))
	{
		return true;
	}

	for (int i = 0; i < cursor->count; i++)
	{
		SpoolRelationEntry *entry = spool_relation_entry(cursor, i);
		const char *message = cursor->bytes + entry->offset;

		if (entry->applied ||
			spool_position_before(seq, changes, entry->seq, entry->changes))
		{
			continue;
		}

		entry->applied = true;

		/* the decoder of 9d8b660 reads no TYPE message */
		if (message[0] == 'R' && !spool_relation_superseded(cursor, i) &&
			!pgoutput_replace_relation(context, message, (int) entry->length))
		{
			/* errors have already been logged */
			return false;
		}
	}

	spool_relation_pending(cursor);

	return true;
}


void
spool_relation_cursor_close(SpoolRelationCursor *cursor)
{
	free(cursor->bytes);
	termPQExpBuffer(&cursor->entries);

	*cursor = (SpoolRelationCursor) {
		0
	};
}


/*
 * spool_relation_last returns the last message logged for key, or NULL.
 * shortcut: a linear search, as RELATION messages come at a reconnect or a
 * definition change; hash the keys if a source with many tables shows it.
 */
static SpoolRelationLast *
spool_relation_last(const SpoolWriter *writer, uint64_t key)
{
	SpoolRelationLast *lasts = (SpoolRelationLast *) writer->lasts.data;
	int count = (int) (writer->lasts.len / sizeof(SpoolRelationLast));

	for (int i = 0; i < count; i++)
	{
		if (lasts[i].key == key)
		{
			return &lasts[i];
		}
	}

	return NULL;
}


/* spool_relation_remember keeps message as the last one of its relation */
static bool
spool_relation_remember(SpoolWriter *writer, const char *message, uint32_t length)
{
	uint64_t key = spool_relation_key(message, length);
	SpoolRelationLast *last = spool_relation_last(writer, key);

	if (last == NULL)
	{
		SpoolRelationLast added = { .key = key };

		appendBinaryPQExpBuffer(&writer->lasts, (char *) &added, sizeof(added));

		if (PQExpBufferBroken(&writer->lasts))
		{
			log_error(ALLOCATION_FAILED_ERROR);
			return false;
		}

		last = (SpoolRelationLast *) (writer->lasts.data + writer->lasts.len) - 1;
		initPQExpBuffer(&last->message);
	}

	resetPQExpBuffer(&last->message);
	appendBinaryPQExpBuffer(&last->message, message, length);

	if (PQExpBufferBroken(&last->message))
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	return true;
}


static void
spool_writer_free_relations(SpoolWriter *writer)
{
	SpoolRelationLast *lasts = (SpoolRelationLast *) writer->lasts.data;
	int count = (int) (writer->lasts.len / sizeof(SpoolRelationLast));

	for (int i = 0; i < count; i++)
	{
		termPQExpBuffer(&lasts[i].message);
	}

	termPQExpBuffer(&writer->lasts);
	spool_fail(&writer->relationLog);
}


/*
 * spool_writer_open_relations opens the relation log for appending, keeps the
 * last message of each relation and type in it, and syncs the directory, so
 * that the entry of a new log is durable.
 */
static bool
spool_writer_open_relations(SpoolWriter *writer)
{
	SpoolSegment *log = &writer->relationLog;
	SpoolRelationCursor cursor = { 0 };

	/* it fits, as the name of the segment file is longer */
	sformat(log->filename, sizeof(log->filename), "%s/" SPOOL_RELATION_LOG,
			writer->dirname);

	if (!spool_file_open(log, O_WRONLY | O_CREAT | O_APPEND))
	{
		return false;
	}

	bool opened = spool_relation_cursor_open(&cursor, writer->dirname);

	/* a record appended after a cut one would never be read */
	if (opened && cursor.tail > 0)
	{
		log_error("Spool file \"%s\" ends inside a record at offset %" PRIu64,
				  log->filename, cursor.size);
		opened = false;
	}

	for (int i = 0; opened && i < cursor.count; i++)
	{
		SpoolRelationEntry *entry = spool_relation_entry(&cursor, i);

		opened = spool_relation_remember(writer, cursor.bytes + entry->offset,
										 entry->length);
	}

	log->size = cursor.size;
	spool_relation_cursor_close(&cursor);

	return opened && spool_sync_directory(writer->dirname);
}


/*
 * spool_writer_log_relation logs a RELATION or TYPE message at the position
 * of the next change, also inside a transaction sent again, which can carry
 * the definition that a later one needs. A reconnect sends every definition
 * again, so a message equal to the last one of its relation is not logged.
 */
static bool
spool_writer_log_relation(SpoolWriter *writer, const char *message,
						  uint32_t length, char type, uint64_t lsn)
{
	SpoolSegment *log = &writer->relationLog;
	const char *body = message + SPOOL_XLOGDATA_HEADER_SIZE;
	uint32_t bodyLength = length - SPOOL_XLOGDATA_HEADER_SIZE;
	char head[SPOOL_RELATION_HEADER_SIZE];
	char crcBytes[4];

	if (!spool_relation_valid(body, bodyLength))
	{
		log_error("Received a pgoutput message type %c of %u bytes at %X/%X, "
				  "too short for an OID", type, bodyLength, LSN_FORMAT_ARGS(lsn));
		return false;
	}

	SpoolRelationLast *last =
		spool_relation_last(writer, spool_relation_key(body, bodyLength));

	if (last != NULL && last->message.len == bodyLength &&
		memcmp(last->message.data, body, bodyLength) == 0)
	{
		return true;
	}

	if (!spool_usable(log))
	{
		return false;
	}

	/* in a transaction sent again, spool_writer_begin reset the count to 0 */
	spool_put_u64(head, writer->nextSeq);
	spool_put_u64(head + 8, writer->txn.changes);
	spool_put_u32(head + 16, bodyLength);
	spool_put_u32(crcBytes, spool_relation_crc(head, body, bodyLength));

	return spool_put(log, head, sizeof(head)) &&
		   spool_put(log, body, bodyLength) &&
		   spool_put(log, crcBytes, sizeof(crcBytes)) &&
		   spool_relation_remember(writer, body, bodyLength);
}


/*
 * spool_writer_start opens the relation log and the buffers of a writer whose
 * segment is open.
 */
static bool
spool_writer_start(SpoolWriter *writer, const char *dirname)
{
	/* it fits, as the name of the segment file starts with it */
	sformat(writer->dirname, sizeof(writer->dirname), "%s", dirname);

	initPQExpBuffer(&writer->lasts);

	if (!spool_writer_open_relations(writer))
	{
		spool_writer_free_relations(writer);
		spool_fail(&writer->segment);
		return false;
	}

	/* after the create, so that a failed one leaves no buffer to free */
	initPQExpBuffer(&writer->held);
	initPQExpBuffer(&writer->pendingIndex);

	return true;
}


/*
 * spool_writer_create creates the segment of header->firstSeq. The header also
 * gives the last complete transaction, so the rule for transactions sent again
 * holds after cleanup deleted the segments before it.
 */
bool
spool_writer_create(SpoolWriter *writer, const char *dirname,
					const SpoolHeader *header, uint64_t maxSegmentSize)
{
	*writer = (SpoolWriter) {
		.maxSegmentSize = maxSegmentSize,
		.header = *header,
		.segment = { .fd = -1 },
		.relationLog = { .fd = -1 },
		.nextSeq = header->firstSeq,
		.lastFinalLSN = header->lastFinalLSN,
		.lastEndLSN = header->lastEndLSN,
		.completeSize = SPOOL_HEADER_SIZE
	};

	if (!spool_segment_create(&writer->segment, dirname, header))
	{
		return false;
	}

	return spool_writer_start(writer, dirname);
}


static bool
spool_hold(SpoolWriter *writer, const char *message, uint32_t length)
{
	char lengthBytes[4];

	spool_put_u32(lengthBytes, length);
	appendBinaryPQExpBuffer(&writer->held, lengthBytes, sizeof(lengthBytes));
	appendBinaryPQExpBuffer(&writer->held, message, length);

	if (PQExpBufferBroken(&writer->held))
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	return true;
}


/* spool_release appends the held messages, which start the transaction */
static bool
spool_release(SpoolWriter *writer)
{
	PQExpBuffer held = &writer->held;

	writer->txn.beginOffset = spool_end(&writer->segment);
	writer->state = SPOOL_TXN_OPEN;

	for (size_t offset = 0; offset < held->len;)
	{
		int pos = 0;
		uint32_t length = pgout_u32(held->data + offset, &pos, 4);

		if (!spool_append(&writer->segment, held->data + offset + 4, length))
		{
			return false;
		}

		offset += 4 + (size_t) length;
	}

	resetPQExpBuffer(held);

	return true;
}


static bool
spool_writer_begin(SpoolWriter *writer, const char *message, uint32_t length,
				   uint64_t lsn)
{
	if (writer->state != SPOOL_TXN_NONE)
	{
		log_error("Received a BEGIN at %X/%X inside the transaction of xid %u",
				  LSN_FORMAT_ARGS(lsn), writer->txn.xid);
		return false;
	}

	if (length < SPOOL_XLOGDATA_HEADER_SIZE + 21)
	{
		log_error("Received a pgoutput BEGIN of %u bytes at %X/%X",
				  length - SPOOL_XLOGDATA_HEADER_SIZE, LSN_FORMAT_ARGS(lsn));
		return false;
	}

	int pos = SPOOL_XLOGDATA_HEADER_SIZE + 1;
	uint64_t finalLSN = pgout_u64(message, &pos, length);

	pos += 8;                   /* the commit time, which COMMIT carries too */

	writer->txn = (SpoolIndexRecord) {
		.xid = pgout_u32(message, &pos, length),
		.finalLSN = finalLSN
	};

	/* the header LSN of a BEGIN is 0/0 when it has an origin */
	if (finalLSN <= writer->lastFinalLSN)
	{
		writer->state = SPOOL_TXN_SKIP;
		return true;
	}

	writer->state = SPOOL_TXN_HELD;

	return spool_hold(writer, message, length);
}


static bool
spool_writer_commit(SpoolWriter *writer, const char *message, uint32_t length,
					uint64_t lsn)
{
	char record[SPOOL_INDEX_RECORD_SIZE];

	if (length < SPOOL_XLOGDATA_HEADER_SIZE + 26)
	{
		log_error("Received a pgoutput COMMIT of %u bytes at %X/%X",
				  length - SPOOL_XLOGDATA_HEADER_SIZE, LSN_FORMAT_ARGS(lsn));
		return false;
	}

	/* after the type, the flags and the commit LSN, which is final_lsn */
	int pos = SPOOL_XLOGDATA_HEADER_SIZE + 10;
	uint64_t endLSN = pgout_u64(message, &pos, length);
	uint64_t commitTime = pgout_u64(message, &pos, length);

	if (endLSN != lsn)
	{
		log_error("Received a COMMIT of xid %u with end LSN %X/%X "
				  "in a message at %X/%X",
				  writer->txn.xid, LSN_FORMAT_ARGS(endLSN), LSN_FORMAT_ARGS(lsn));
		return false;
	}

	if (endLSN <= writer->lastEndLSN)
	{
		log_error("Received a COMMIT of xid %u at %X/%X, which is not after "
				  "the last complete transaction at %X/%X",
				  writer->txn.xid, LSN_FORMAT_ARGS(endLSN),
				  LSN_FORMAT_ARGS(writer->lastEndLSN));
		return false;
	}

	/* an empty transaction leaves no byte and does not count as a commit */
	if (writer->state == SPOOL_TXN_HELD)
	{
		resetPQExpBuffer(&writer->held);
		writer->state = SPOOL_TXN_NONE;
		return true;
	}

	if (!spool_append(&writer->segment, message, length))
	{
		return false;
	}

	writer->txn.seq = writer->nextSeq;
	writer->txn.endOffset = spool_end(&writer->segment);
	writer->txn.endLSN = endLSN;
	writer->txn.commitTime = commitTime;

	spool_index_encode(&writer->txn, record);
	appendBinaryPQExpBuffer(&writer->pendingIndex, record, sizeof(record));

	if (PQExpBufferBroken(&writer->pendingIndex))
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	writer->nextSeq++;
	writer->lastFinalLSN = writer->txn.finalLSN;
	writer->lastEndLSN = endLSN;
	writer->completeSize = writer->txn.endOffset;
	writer->state = SPOOL_TXN_NONE;

	return true;
}


/*
 * spool_writer_message takes one message of receive: an XLogData message as
 * received, or a keepalive marker. Only the frames of a complete, non-empty
 * transaction that the spool does not hold yet stay in the segment.
 */
bool
spool_writer_message(SpoolWriter *writer, const char *message, uint32_t length)
{
	if (!spool_message_valid(message, length))
	{
		log_error("BUG: spool_writer_message got a message of %u bytes and "
				  "kind %d, which the spool format does not hold",
				  length, length > 0 ? message[0] : 0);
		return false;
	}

	if (message[0] == SPOOL_KIND_KEEPALIVE)
	{
		return spool_append(&writer->segment, message, length);
	}

	int pos = 1;
	uint64_t lsn = pgout_u64(message, &pos, length);

	/* PostgreSQL 13 sends an empty message for an origin it cannot name */
	char type = length > SPOOL_XLOGDATA_HEADER_SIZE ?
				message[SPOOL_XLOGDATA_HEADER_SIZE] : 'O';

	switch (type)
	{
		case 'B':
		{
			return spool_writer_begin(writer, message, length, lsn);
		}

		case 'C':
		case 'I':
		case 'U':
		case 'D':
		case 'T':
		case 'O':
		case 'R':
		case 'Y':
		{
			break;
		}

		default:
		{
			log_error("Received an unknown pgoutput message type 0x%02x "
					  "at %X/%X", (unsigned char) type, LSN_FORMAT_ARGS(lsn));
			return false;
		}
	}

	if (writer->state == SPOOL_TXN_NONE)
	{
		if (length == SPOOL_XLOGDATA_HEADER_SIZE)
		{
			log_error("Received an empty XLogData message at %X/%X "
					  "outside a transaction", LSN_FORMAT_ARGS(lsn));
		}
		else
		{
			log_error("Received pgoutput message type %c at %X/%X "
					  "outside a transaction", type, LSN_FORMAT_ARGS(lsn));
		}

		return false;
	}

	if ((type == 'R' || type == 'Y') &&
		!spool_writer_log_relation(writer, message, length, type, lsn))
	{
		return false;
	}

	if (writer->state == SPOOL_TXN_SKIP)
	{
		if (type == 'C')
		{
			writer->state = SPOOL_TXN_NONE;
		}

		return true;
	}

	if (type == 'C')
	{
		return spool_writer_commit(writer, message, length, lsn);
	}

	if (writer->state == SPOOL_TXN_HELD)
	{
		if (type == 'O')
		{
			return spool_hold(writer, message, length);
		}

		if (!spool_release(writer))
		{
			return false;
		}
	}

	if (type == 'I' || type == 'U' || type == 'D' || type == 'T')
	{
		writer->txn.changes++;
	}

	return spool_append(&writer->segment, message, length);
}


/*
 * spool_writer_rewind is the raw form of the rollback after a lost connection:
 * the segment goes back to the end of the last complete transaction, because
 * the source sends a transaction without COMMIT again in full. The relation
 * log keeps its records, which the cursor orders by position.
 */
bool
spool_writer_rewind(SpoolWriter *writer)
{
	SpoolSegment *segment = &writer->segment;

	resetPQExpBuffer(&writer->held);
	writer->state = SPOOL_TXN_NONE;

	if (!spool_usable(segment))
	{
		return false;
	}

	if (writer->completeSize >= segment->size)
	{
		segment->blockLength = writer->completeSize - segment->size;
		return true;
	}

	if (ftruncate(segment->fd, writer->completeSize) != 0)
	{
		log_error("Failed to truncate spool file \"%s\" to %" PRIu64 " bytes: %m",
				  segment->filename, writer->completeSize);
		spool_fail(segment);
		return false;
	}

	/* the bytes before completeSize may still wait for their sync */
	segment->size = writer->completeSize;
	segment->synced = Min(segment->synced, writer->completeSize);
	segment->blockLength = 0;

	return true;
}


/*
 * spool_writer_rotate_due is true after a COMMIT that took the segment to the
 * limit or past it, as the limit rotates output.db in sqlite mode. A segment
 * is named by its first transaction, so it must hold one.
 */
bool
spool_writer_rotate_due(const SpoolWriter *writer)
{
	return writer->maxSegmentSize > 0 &&
		   writer->state == SPOOL_TXN_NONE &&
		   writer->nextSeq > writer->header.firstSeq &&
		   spool_end(&writer->segment) >= writer->maxSegmentSize;
}


/*
 * spool_writer_rotate creates the next segment, once the flush has synced the
 * frames of the open one and written their index records. The new header
 * carries the last complete transaction for the rule for resends.
 */
bool
spool_writer_rotate(SpoolWriter *writer)
{
	SpoolSegment *segment = &writer->segment;

	if (!spool_usable(segment))
	{
		return false;
	}

	/* an empty block is no proof of a sync: spool_put writes full blocks out */
	if (!spool_writer_rotate_due(writer) ||
		segment->size > segment->synced || segment->blockLength > 0 ||
		writer->pendingIndex.len > 0)
	{
		log_error("BUG: spool file \"%s\" rotates only when due, and after "
				  "the flush of its frames and index records",
				  segment->filename);
		return false;
	}

	SpoolHeader header = writer->header;

	header.firstSeq = writer->nextSeq;
	header.lastFinalLSN = writer->lastFinalLSN;
	header.lastEndLSN = writer->lastEndLSN;

	/* the flush synced the old segment, so only its descriptor is left */
	(void) close(segment->fd);
	free(segment->block);

	if (!spool_segment_create(segment, writer->dirname, &header))
	{
		return false;
	}

	writer->header = header;
	writer->completeSize = SPOOL_HEADER_SIZE;

	return true;
}


/*
 * spool_dirname_fits logs an error when the names of the spool files in
 * dirname do not fit, so that the code after it builds them unchecked.
 */
static bool
spool_dirname_fits(const char *dirname)
{
	if (strlen(dirname) + strlen("/0000000000000000.seg") >= MAXPGPATH)
	{
		log_error("Spool directory name \"%s\" is too long", dirname);
		return false;
	}

	return true;
}


/*
 * spool_name_seq returns the suffix of a segment or index file name, and its
 * sequence number, or NULL for a name that the writer does not make.
 */
static const char *
spool_name_seq(const char *name, uint64_t *seq)
{
	uint64_t value = 0;

	for (int i = 0; i < 16; i++)
	{
		char c = name[i];
		int digit = c >= '0' && c <= '9' ? c - '0' :
					c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;

		if (digit < 0)
		{
			return NULL;
		}

		value = value << 4 | (uint64_t) digit;
	}

	/* sequence numbers start at SPOOL_FIRST_SEQ */
	if (value == 0 ||
		(strcmp(name + 16, ".seg") != 0 && strcmp(name + 16, ".idx") != 0))
	{
		return NULL;
	}

	*seq = value;

	return name + 16;
}


/*
 * spool_scan lists the sequence numbers of the segment files and of the index
 * files in dirname, in directory order.
 */
static bool
spool_scan(const char *dirname, PQExpBuffer segments, PQExpBuffer indexes)
{
	DIR *dir = opendir(dirname);

	if (dir == NULL)
	{
		log_error("Failed to open spool directory \"%s\": %m", dirname);
		return false;
	}

	struct dirent *entry = NULL;

	for (errno = 0; (entry = readdir(dir)) != NULL; errno = 0)
	{
		uint64_t seq = 0;
		const char *suffix = spool_name_seq(entry->d_name, &seq);

		if (suffix != NULL)
		{
			appendBinaryPQExpBuffer(strcmp(suffix, ".seg") == 0 ? segments : indexes,
									(char *) &seq, sizeof(seq));
		}
	}

	bool listed = errno == 0;

	if (!listed)
	{
		log_error("Failed to read spool directory \"%s\": %m", dirname);
	}

	(void) closedir(dir);

	if (listed && (PQExpBufferBroken(segments) || PQExpBufferBroken(indexes)))
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	return listed;
}


static uint64_t *
spool_seqs(PQExpBuffer list, int *count)
{
	*count = (int) (list->len / sizeof(uint64_t));

	return (uint64_t *) list->data;
}


static bool
spool_listed(PQExpBuffer list, uint64_t seq)
{
	int count = 0;
	uint64_t *seqs = spool_seqs(list, &count);

	for (int i = 0; i < count; i++)
	{
		if (seqs[i] == seq)
		{
			return true;
		}
	}

	return false;
}


/* the highest sequence number of the list below bound, 0 for none */
static uint64_t
spool_highest_below(PQExpBuffer list, uint64_t bound)
{
	int count = 0;
	uint64_t *seqs = spool_seqs(list, &count);
	uint64_t highest = 0;

	for (int i = 0; i < count; i++)
	{
		if (seqs[i] < bound && seqs[i] > highest)
		{
			highest = seqs[i];
		}
	}

	return highest;
}


/*
 * spool_pread reads length bytes at offset, fewer only at the end of the
 * file, and sets done to the number read.
 */
static bool
spool_pread(int fd, const char *path, char *buf, uint64_t length,
			uint64_t offset, uint64_t *done)
{
	*done = 0;

	while (*done < length)
	{
		ssize_t n = pread(fd, buf + *done, length - *done, (off_t) (offset + *done));

		if (n < 0)
		{
			log_error("Failed to read spool file \"%s\": %m", path);
			return false;
		}

		if (n == 0)
		{
			break;
		}

		*done += (uint64_t) n;
	}

	return true;
}


/* spool_cut_file cuts the file at length and syncs it */
static bool
spool_cut_file(int fd, const char *path, uint64_t length)
{
	if (ftruncate(fd, (off_t) length) != 0)
	{
		log_error("Failed to truncate spool file \"%s\" to %" PRIu64 " bytes: %m",
				  path, length);
		return false;
	}

	return spool_fsync(fd, path, false, length);
}


static const char *
spool_frames_at(const SpoolFrames *frames)
{
	return frames->buffer.data + (frames->offset - frames->bufferStart);
}


/*
 * spool_frames_fill makes the buffer hold the need bytes at the next frame,
 * and reads the rest of the transaction up to a write block with them, never
 * a byte past its end.
 */
static bool
spool_frames_fill(SpoolFrames *frames, uint64_t need)
{
	PQExpBuffer buffer = &frames->buffer;
	uint64_t done = 0;

	if (frames->offset + need <= frames->bufferStart + buffer->len)
	{
		return true;
	}

	uint64_t want = Max(need, Min(frames->end - frames->offset, SPOOL_BLOCK_SIZE));

	resetPQExpBuffer(buffer);
	frames->bufferStart = frames->offset;

	if (!enlargePQExpBuffer(buffer, want))
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	if (!spool_pread(frames->fd, frames->filename, buffer->data, want,
					 frames->offset, &done))
	{
		return false;
	}

	buffer->len = done;

	if (done < want)
	{
		log_error("Spool file \"%s\" ends at %" PRIu64
				  " bytes, inside the transaction that ends at %" PRIu64,
				  frames->filename, frames->offset + done, frames->end);
		return false;
	}

	return true;
}


/*
 * spool_frames_next returns the next frame of the transaction that is not a
 * keepalive marker or an empty XLogData message, or done after the last one.
 */
static bool
spool_frames_next(SpoolFrames *frames, const char **message, uint32_t *length,
				  bool *done)
{
	*done = false;

	while (frames->offset < frames->end)
	{
		uint64_t left = frames->end - frames->offset;
		int pos = 0;

		if (!spool_frames_fill(frames, Min(left, 4)))
		{
			return false;
		}

		/* a length that ends past the transaction is damage, and is not read */
		uint64_t size = SPOOL_FRAME_SIZE(pgout_u32(spool_frames_at(frames), &pos,
												   (int) Min(left, 4)));

		if (size <= left && !spool_frames_fill(frames, size))
		{
			return false;
		}

		if (size > left ||
			spool_frame_decode(spool_frames_at(frames), size,
							   message, length) != SPOOL_FRAME_OK)
		{
			log_error("Spool file \"%s\" holds no valid frame at offset %" PRIu64,
					  frames->filename, frames->offset);
			return false;
		}

		frames->offset += size;

		/* a keepalive marker has 17 bytes, and an empty XLogData message 25 */
		if (*length > SPOOL_XLOGDATA_HEADER_SIZE)
		{
			return true;
		}
	}

	*done = true;

	return true;
}


/* spool_read_header reads a segment header, and headed is false when torn */
static bool
spool_read_header(int fd, const char *path, SpoolHeader *header, bool *headed)
{
	char buf[SPOOL_HEADER_SIZE];
	uint64_t done = 0;

	if (!spool_pread(fd, path, buf, sizeof(buf), 0, &done))
	{
		return false;
	}

	*headed = spool_header_decode(buf, done, header);

	return true;
}


/*
 * spool_cut_relations cuts the relation log after its last valid record, as
 * receive may have appended a record and not synced it, and syncs the log.
 * The flush synced it up to synced, so damage before that ends the start.
 */
static bool
spool_cut_relations(const char *dirname, uint64_t synced)
{
	char path[MAXPGPATH];
	char *bytes = NULL;
	long size = 0;
	uint64_t end = 0;
	SpoolRelationRecord record = { 0 };

	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, dirname);

	int fd = open(path, O_WRONLY);

	if (fd < 0 && errno == ENOENT && synced == 0)
	{
		/* a new spool, whose writer creates the log */
		return true;
	}

	if (fd < 0)
	{
		log_error("Failed to open spool file \"%s\": %m", path);
		return false;
	}

	bool cut = read_file(path, &bytes, &size);

	while (cut && end < (uint64_t) size &&
		   spool_relation_decode(bytes + end, (uint64_t) size - end,
								 &record) == SPOOL_FRAME_OK)
	{
		end += SPOOL_RELATION_RECORD_SIZE(record.length);
	}

	/* a cut there would decode later rows with an older definition */
	if (cut && end < synced)
	{
		log_error("Spool file \"%s\" ends its valid records at offset %" PRIu64
				  ", before the %" PRIu64 " bytes that its index proves synced",
				  path, end, synced);
		cut = false;
	}

	cut = cut && spool_cut_file(fd, path, end);

	free(bytes);
	(void) close(fd);

	return cut;
}


/* the last segment of a spool at start, and its index file */
typedef struct SpoolTail
{
	SpoolSegment segment;       /* open to read, cut and append */
	char index[MAXPGPATH];
	int indexFd;
	SpoolHeader header;
	bool headed;                /* false when the header is torn */
	SpoolIndexRecord last;      /* the last valid index record */
	uint64_t keep;              /* index length up to the end of last, or 0 */
} SpoolTail;


static void
spool_tail_close(SpoolTail *tail)
{
	spool_fail(&tail->segment);
	(void) close(tail->indexFd);
	tail->indexFd = -1;
}


/*
 * spool_tail_read opens segment seq, reads its header, and the last valid
 * record of its index file, from the end: a torn write leaves invalid records
 * only after the last record that receive synced.
 */
static bool
spool_tail_read(SpoolTail *tail, const char *dirname, uint64_t seq, bool indexed)
{
	struct stat st = { 0 };
	uint64_t done = 0;

	*tail = (SpoolTail) {
		.segment = { .fd = -1 },
		.indexFd = -1
	};

	sformat(tail->segment.filename, MAXPGPATH, "%s/%016" PRIX64 ".seg", dirname, seq);
	sformat(tail->index, MAXPGPATH, "%s/%016" PRIX64 ".idx", dirname, seq);

	if (!spool_file_open(&tail->segment, O_RDWR | O_APPEND) ||
		!spool_read_header(tail->segment.fd, tail->segment.filename,
						   &tail->header, &tail->headed))
	{
		return false;
	}

	if (!indexed)
	{
		return true;
	}

	tail->indexFd = open(tail->index, O_RDWR);

	if (tail->indexFd < 0 || fstat(tail->indexFd, &st) != 0)
	{
		log_error("Failed to open spool file \"%s\": %m", tail->index);
		return false;
	}

	for (uint64_t end = (uint64_t) st.st_size - (uint64_t) st.st_size %
						SPOOL_INDEX_RECORD_SIZE;
		 end >= SPOOL_INDEX_RECORD_SIZE; end -= SPOOL_INDEX_RECORD_SIZE)
	{
		char record[SPOOL_INDEX_RECORD_SIZE];

		if (!spool_pread(tail->indexFd, tail->index, record, sizeof(record),
						 end - sizeof(record), &done))
		{
			return false;
		}

		if (spool_index_decode(record, done, &tail->last))
		{
			tail->keep = end;
			break;
		}
	}

	return true;
}


/*
 * spool_tail_cut checks that the last indexed transaction ends with its
 * COMMIT, then cuts the segment after it and the index after its record, and
 * syncs both: receive may have written that record and not synced it.
 */
static bool
spool_tail_cut(SpoolTail *tail, const char *dirname, bool removed)
{
	SpoolSegment *segment = &tail->segment;
	SpoolFrames frames = {
		.fd = segment->fd,
		.offset = tail->last.beginOffset,
		.end = tail->last.endOffset,
		.bufferStart = tail->last.beginOffset
	};
	bool cut = true;
	bool done = false;
	char type = 0;

	if (!tail->headed)
	{
		log_error("Spool file \"%s\" has no valid header, and its index file "
				  "holds transactions", segment->filename);
		return false;
	}

	sformat(frames.filename, sizeof(frames.filename), "%s", segment->filename);
	initPQExpBuffer(&frames.buffer);

	while (cut && !done)
	{
		const char *message = NULL;
		uint32_t length = 0;

		cut = spool_frames_next(&frames, &message, &length, &done);

		if (cut && !done)
		{
			type = message[SPOOL_XLOGDATA_HEADER_SIZE];
		}
	}

	termPQExpBuffer(&frames.buffer);

	if (cut && type != 'C')
	{
		log_error("Spool file \"%s\" holds no COMMIT at the end of its last "
				  "indexed transaction, at offset %" PRIu64,
				  segment->filename, tail->last.endOffset);
		return false;
	}

	return cut &&
		   (!removed || spool_sync_directory(dirname)) &&
		   spool_cut_file(segment->fd, segment->filename, tail->last.endOffset) &&
		   spool_cut_file(tail->indexFd, tail->index, tail->keep);
}


/*
 * spool_tail_append hands the cut segment to the writer, which appends after
 * its last indexed transaction.
 */
static bool
spool_tail_append(SpoolTail *tail, SpoolWriter *writer, const char *dirname,
				  uint64_t maxSegmentSize)
{
	*writer = (SpoolWriter) {
		.maxSegmentSize = maxSegmentSize,
		.header = tail->header,
		.segment = tail->segment,
		.relationLog = { .fd = -1 },
		.nextSeq = tail->last.seq + 1,
		.lastFinalLSN = tail->last.finalLSN,
		.lastEndLSN = tail->last.endLSN,
		.completeSize = tail->last.endOffset
	};

	/* the cut synced the segment at that length */
	writer->segment.size = tail->last.endOffset;
	writer->segment.synced = tail->last.endOffset;

	/* the writer owns the descriptor and the write block now */
	tail->segment.fd = -1;
	tail->segment.block = NULL;
	spool_tail_close(tail);

	return spool_writer_start(writer, dirname);
}


/*
 * spool_synced_before reads the relation log length that the last index
 * record before segment seq holds, or 0 when no segment comes before it.
 */
static bool
spool_synced_before(const char *dirname, PQExpBuffer indexes, uint64_t seq,
					uint64_t *synced)
{
	uint64_t before = spool_highest_below(indexes, seq);
	SpoolTail tail = { 0 };

	*synced = 0;

	if (before == 0)
	{
		return true;
	}

	bool read = spool_tail_read(&tail, dirname, before, true);

	*synced = tail.last.relationLogEnd;
	spool_tail_close(&tail);

	return read;
}


/*
 * spool_writer_resume continues the spool from its last segment. A last
 * segment without an indexed transaction is removed, and its header, or the
 * segment before it, gives where the spool continues.
 */
static bool
spool_writer_resume(SpoolWriter *writer, const char *dirname,
					PQExpBuffer segments, PQExpBuffer indexes,
					const SpoolHeader *fresh, uint64_t maxSegmentSize)
{
	uint64_t seq = spool_highest_below(segments, UINT64_MAX);
	bool removed = false;
	int count = 0;
	uint64_t *seqs = spool_seqs(indexes, &count);

	/* cleanup unlinks the index file first, so every index has its segment */
	for (int i = 0; i < count; i++)
	{
		if (!spool_listed(segments, seqs[i]))
		{
			log_error("Spool index file \"%s/%016" PRIX64
					  ".idx\" has no segment file", dirname, seqs[i]);
			return false;
		}
	}

	/* and a segment without its index file, but the last one, is its leftover */
	seqs = spool_seqs(segments, &count);

	for (int i = 0; i < count; i++)
	{
		if (seqs[i] != seq && !spool_listed(indexes, seqs[i]))
		{
			char path[MAXPGPATH];

			sformat(path, sizeof(path), "%s/%016" PRIX64 ".seg", dirname, seqs[i]);

			if (!unlink_file(path))
			{
				return false;
			}

			removed = true;
		}
	}

	for (int round = 0; seq > 0; round++)
	{
		SpoolTail tail = { 0 };

		if (!spool_tail_read(&tail, dirname, seq, spool_listed(indexes, seq)))
		{
			spool_tail_close(&tail);
			return false;
		}

		/* frames of another source would be applied as if the slot sent them */
		if (tail.headed && tail.header.systemId != fresh->systemId)
		{
			log_error("Spool file \"%s\" holds the changes of source system %" PRIu64
					  ", and the source is system %" PRIu64,
					  tail.segment.filename, tail.header.systemId, fresh->systemId);
			spool_tail_close(&tail);
			return false;
		}

		if (tail.keep > 0)
		{
			bool resumed =
				spool_cut_relations(dirname, tail.last.relationLogEnd) &&
				spool_tail_cut(&tail, dirname, removed) &&
				spool_tail_append(&tail, writer, dirname, maxSegmentSize);

			spool_tail_close(&tail);

			return resumed;
		}

		spool_tail_close(&tail);

		/* a later segment exists only once the flush indexed this one */
		if (round > 0)
		{
			log_error("Spool file \"%s\" holds no indexed transaction, but a "
					  "segment after it was created", tail.segment.filename);
			return false;
		}

		/* a torn header hides where the spool goes on: only a new one restarts */
		if (!tail.headed && seq != SPOOL_FIRST_SEQ &&
			spool_highest_below(indexes, seq) == 0)
		{
			log_error("Spool file \"%s\" has no valid header, and no segment "
					  "before it to continue from", tail.segment.filename);
			return false;
		}

		/* the index file first, as cleanup does */
		if (!unlink_file(tail.index) || !unlink_file(tail.segment.filename))
		{
			return false;
		}

		removed = true;

		/* the header gives the last transaction before it, also after cleanup */
		if (tail.headed)
		{
			uint64_t synced = 0;

			return spool_sync_directory(dirname) &&
				   spool_synced_before(dirname, indexes, seq, &synced) &&
				   spool_cut_relations(dirname, synced) &&
				   spool_writer_create(writer, dirname, &tail.header, maxSegmentSize);
		}

		seq = spool_highest_below(indexes, seq);
	}

	return (!removed || spool_sync_directory(dirname)) &&
		   spool_cut_relations(dirname, 0) &&
		   spool_writer_create(writer, dirname, fresh, maxSegmentSize);
}


/*
 * spool_writer_open starts receive on the spool of dirname, which a kill or a
 * power loss may have left with a torn tail. The spool then ends at its last
 * indexed transaction, every cut is synced, and the writer appends after it,
 * with that transaction in lastFinalLSN and lastEndLSN.
 */
bool
spool_writer_open(SpoolWriter *writer, const char *dirname,
				  uint64_t systemId, uint32_t timeline,
				  uint64_t maxSegmentSize)
{
	PQExpBufferData segments;
	PQExpBufferData indexes;

	/* a new spool skips no transaction, so a commit at the consistent point stays */
	SpoolHeader fresh = {
		.firstSeq = SPOOL_FIRST_SEQ,
		.systemId = systemId,
		.timeline = timeline
	};

	*writer = (SpoolWriter) {
		.segment = { .fd = -1 },
		.relationLog = { .fd = -1 }
	};

	initPQExpBuffer(&segments);
	initPQExpBuffer(&indexes);

	bool opened = spool_dirname_fits(dirname) &&
				  spool_scan(dirname, &segments, &indexes) &&
				  spool_writer_resume(writer, dirname, &segments, &indexes,
									  &fresh, maxSegmentSize);

	termPQExpBuffer(&segments);
	termPQExpBuffer(&indexes);

	return opened;
}


/* spool_reader_switch reads segment seq and its index file from their start */
static bool
spool_reader_switch(SpoolReader *reader, uint64_t seq)
{
	SpoolFrames *frames = &reader->frames;

	(void) close(reader->indexFd);
	(void) close(frames->fd);

	sformat(reader->indexFilename, MAXPGPATH, "%s/%016" PRIX64 ".idx",
			reader->dirname, seq);
	sformat(frames->filename, MAXPGPATH, "%s/%016" PRIX64 ".seg",
			reader->dirname, seq);

	reader->indexFd = open(reader->indexFilename, O_RDONLY);
	frames->fd = reader->indexFd < 0 ? -1 : open(frames->filename, O_RDONLY);

	if (reader->indexFd < 0 || frames->fd < 0)
	{
		log_error("Failed to open spool file \"%s\": %m",
				  reader->indexFd < 0 ? reader->indexFilename : frames->filename);
		return false;
	}

	reader->segment = seq;
	reader->nextSeq = seq;
	reader->indexOffset = 0;

	return true;
}


/* the next segment exists, which proves the index file read complete */
static bool
spool_reader_closed(SpoolReader *reader, uint64_t seq)
{
	char path[MAXPGPATH];

	sformat(path, sizeof(path), "%s/%016" PRIX64 ".idx", reader->dirname, seq);

	return seq != reader->segment && file_exists(path);
}


/* spool_reader_last_segment lists the spool, for its highest segment or 0 */
static bool
spool_reader_last_segment(SpoolReader *reader, uint64_t *last)
{
	PQExpBufferData segments;
	PQExpBufferData indexes;

	initPQExpBuffer(&segments);
	initPQExpBuffer(&indexes);

	bool listed = spool_scan(reader->dirname, &segments, &indexes);

	*last = spool_highest_below(&segments, UINT64_MAX);

	termPQExpBuffer(&segments);
	termPQExpBuffer(&indexes);

	return listed;
}


/*
 * spool_reader_read reads the next index records of the segment. It stops at
 * an invalid record at the tail of the file, which receive is still writing,
 * and fails on any other.
 */
static bool
spool_reader_read(SpoolReader *reader)
{
	char bytes[SPOOL_READER_CHUNK * SPOOL_INDEX_RECORD_SIZE];
	struct stat st = { 0 };
	uint64_t done = 0;

	reader->chunkCount = 0;
	reader->chunkNext = 0;

	/* the size first: receive appends, so every byte below it is written */
	if (fstat(reader->indexFd, &st) != 0)
	{
		log_error("Failed to read spool file \"%s\": %m", reader->indexFilename);
		return false;
	}

	uint64_t size = (uint64_t) st.st_size;

	if (size < reader->indexOffset)
	{
		log_error("Spool file \"%s\" has %" PRIu64 " bytes, and %" PRIu64
				  " were read before", reader->indexFilename, size,
				  reader->indexOffset);
		return false;
	}

	if (!spool_pread(reader->indexFd, reader->indexFilename, bytes,
					 Min(sizeof(bytes), size - reader->indexOffset),
					 reader->indexOffset, &done))
	{
		return false;
	}

	for (uint64_t at = 0; at < done; at += SPOOL_INDEX_RECORD_SIZE)
	{
		SpoolIndexRecord *record = &reader->chunk[reader->chunkCount];

		if (!spool_index_decode(bytes + at, done - at, record))
		{
			uint64_t offset = reader->indexOffset + at;
			uint64_t next = reader->chunkCount > 0 ?
							reader->chunk[reader->chunkCount - 1].seq + 1 :
							reader->nextSeq;

			if (offset + SPOOL_INDEX_RECORD_SIZE < size ||
				spool_reader_closed(reader, next))
			{
				log_error("Spool file \"%s\" holds no valid index record at "
						  "offset %" PRIu64, reader->indexFilename, offset);
				return false;
			}

			break;
		}

		reader->chunkCount++;
	}

	reader->indexOffset += (uint64_t) reader->chunkCount * SPOOL_INDEX_RECORD_SIZE;

	/* receive synced the definitions of these records before it wrote them */
	return reader->chunkCount == 0 ||
		   spool_relation_cursor_read(&reader->relations);
}


/*
 * spool_reader_open opens a reader of the spool of dirname that returns the
 * index records whose end LSN is above after, and never writes.
 */
bool
spool_reader_open(SpoolReader *reader, const char *dirname, uint64_t after)
{
	PQExpBufferData segments;
	PQExpBufferData indexes;
	uint64_t start = 0;
	uint64_t first = UINT64_MAX;
	int count = 0;

	*reader = (SpoolReader) {
		.after = after,
		.nextSeq = SPOOL_FIRST_SEQ,
		.indexFd = -1,
		.frames = { .fd = -1 }
	};

	initPQExpBuffer(&reader->frames.buffer);
	initPQExpBuffer(&segments);
	initPQExpBuffer(&indexes);

	bool opened = spool_dirname_fits(dirname) &&
				  spool_relation_cursor_open(&reader->relations, dirname) &&
				  spool_scan(dirname, &segments, &indexes);
	uint64_t *seqs = spool_seqs(&indexes, &count);

	sformat(reader->dirname, sizeof(reader->dirname), "%s", dirname);

	/* the last segment whose header is at or below after holds the next record */
	for (int i = 0; opened && i < count; i++)
	{
		char path[MAXPGPATH];
		SpoolHeader header = { 0 };
		bool headed = false;

		sformat(path, sizeof(path), "%s/%016" PRIX64 ".seg", dirname, seqs[i]);

		int fd = open(path, O_RDONLY);

		if (fd < 0)
		{
			log_error("Failed to open spool file \"%s\": %m", path);
			opened = false;
			break;
		}

		opened = spool_read_header(fd, path, &header, &headed);
		(void) close(fd);

		if (opened && !headed)
		{
			log_error("Spool file \"%s\" has no valid header", path);
			opened = false;
		}

		if (opened && header.lastEndLSN <= after && seqs[i] > start)
		{
			start = seqs[i];
		}

		first = Min(first, seqs[i]);
	}

	termPQExpBuffer(&segments);
	termPQExpBuffer(&indexes);

	/* below the header of every segment, as after cleanup: the first one */
	return opened &&
		   (count == 0 || spool_reader_switch(reader, start > 0 ? start : first));
}


/*
 * spool_reader_next returns the next index record above the end LSN of the
 * open, and found false when receive has not written it yet.
 */
bool
spool_reader_next(SpoolReader *reader, bool *found)
{
	uint64_t later = 0;         /* the highest segment, at the last scan */

	*found = false;

	for (;;)
	{
		while (reader->chunkNext < reader->chunkCount)
		{
			SpoolIndexRecord *record = &reader->chunk[reader->chunkNext++];

			reader->nextSeq = record->seq + 1;

			if (record->endLSN > reader->after)
			{
				reader->record = *record;
				reader->changes = 0;
				reader->frames.offset = record->beginOffset;
				reader->frames.end = record->endOffset;

				/* the buffer may hold the bytes of another segment */
				resetPQExpBuffer(&reader->frames.buffer);
				reader->frames.bufferStart = record->beginOffset;

				*found = true;
				return true;
			}
		}

		if (reader->segment > 0 && !spool_reader_read(reader))
		{
			return false;
		}

		if (reader->chunkCount > 0)
		{
			continue;
		}

		/* the next segment has its index file once this one is complete */
		if (!spool_reader_closed(reader, reader->nextSeq))
		{
			/* receive creates a later segment only after it wrote the record */
			if (later > reader->nextSeq)
			{
				log_error("Spool directory \"%s\" holds no index record of "
						  "sequence number %" PRIu64 ", and segment %016" PRIX64
						  " after it exists",
						  reader->dirname, reader->nextSeq, later);
				return false;
			}

			if (!spool_reader_last_segment(reader, &later))
			{
				return false;
			}

			/* with one, read again: receive may have written it since the read */
			if (later <= reader->nextSeq)
			{
				return true;
			}

			continue;
		}

		if (!spool_reader_switch(reader, reader->nextSeq))
		{
			return false;
		}
	}
}


/*
 * spool_reader_frame returns the next frame of the record that
 * spool_reader_next returned, after the relation cache of context took the
 * definitions logged before it, and done after its COMMIT.
 */
bool
spool_reader_frame(SpoolReader *reader, struct StreamContext *context,
				   const char **message, uint32_t *length, bool *done)
{
	if (!spool_frames_next(&reader->frames, message, length, done))
	{
		return false;
	}

	if (*done)
	{
		return true;
	}

	char type = (*message)[SPOOL_XLOGDATA_HEADER_SIZE];

	if (type == 'I' || type == 'U' || type == 'D' || type == 'T')
	{
		if (!spool_relation_cursor_advance(&reader->relations, reader->record.seq,
										   reader->changes, context))
		{
			/* errors have already been logged */
			return false;
		}

		reader->changes++;
	}

	return true;
}


void
spool_reader_close(SpoolReader *reader)
{
	(void) close(reader->indexFd);
	(void) close(reader->frames.fd);
	termPQExpBuffer(&reader->frames.buffer);
	spool_relation_cursor_close(&reader->relations);
}
