/*
 * src/bin/pgcopydb/ld_spool.c
 *	 The raw spool of performance mode: segment files of checksummed frames,
 *	 and the index of the transactions they hold.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <string.h>
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
 * spool_fail closes a segment after a failed write or sync. The file may end
 * inside a frame, and Linux reports a failed writeback to one fsync only, so a
 * second sync could log a synced length for bytes that are not on disk.
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
	if (segment->fd < 0)
	{
		log_error("BUG: refusing spool file \"%s\" after a failed write or sync",
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
		return false;
	}

	segment->block = (char *) malloc(SPOOL_BLOCK_SIZE);

	if (segment->block == NULL)
	{
		log_error(ALLOCATION_FAILED_ERROR);
		return false;
	}

	/* a segment that exists may hold acknowledged transactions */
	segment->fd = open(segment->filename,
					   O_WRONLY | O_CREAT | O_EXCL | O_APPEND, 0644);

	if (segment->fd < 0)
	{
		log_error("Failed to create spool file \"%s\": %m", segment->filename);
		spool_fail(segment);
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
 * spool_index_encode writes the 64 bytes of a transaction index record to buf.
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
	spool_put_u32(buf + 60, spool_crc32c(buf, 60));
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

	if (pgout_u32(buf, &pos, SPOOL_INDEX_RECORD_SIZE) != spool_crc32c(buf, 60))
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
		.nextSeq = header->firstSeq,
		.lastFinalLSN = header->lastFinalLSN,
		.lastEndLSN = header->lastEndLSN,
		.completeSize = SPOOL_HEADER_SIZE
	};

	initPQExpBuffer(&writer->held);
	initPQExpBuffer(&writer->pendingIndex);

	if (sformat(writer->dirname, sizeof(writer->dirname), "%s",
				dirname) >= (int) sizeof(writer->dirname))
	{
		log_error("Spool directory name \"%s\" is too long", dirname);
		return false;
	}

	return spool_segment_create(&writer->segment, dirname, header);
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
		log_error("Received pgoutput message type %c at %X/%X "
				  "outside a transaction", type, LSN_FORMAT_ARGS(lsn));
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
 * the source sends a transaction without COMMIT again in full.
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
 * spool_writer_rotate_due is true after a COMMIT that took the segment past
 * the limit. A segment is named by its first transaction, so it must hold one.
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
