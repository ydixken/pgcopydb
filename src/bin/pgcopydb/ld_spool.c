/*
 * src/bin/pgcopydb/ld_spool.c
 *	 The raw spool of performance mode: segment files of checksummed frames.
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
		return false;
	}

	spool_header_encode(header, buf);

	return spool_put(segment, buf, SPOOL_HEADER_SIZE) &&
		   spool_sync(segment) &&
		   spool_sync_directory(dirname);
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
 */
bool
spool_sync(SpoolSegment *segment)
{
	return spool_write_block(segment) &&
		   spool_fsync(segment->fd, segment->filename, false, segment->size);
}
