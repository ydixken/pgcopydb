/*
 * src/bin/pgcopydb/ld_spool.h
 *	 The raw spool of performance mode: segment files of checksummed frames.
 *	 Every integer of the format is big-endian.
 */

#ifndef LD_SPOOL_H
#define LD_SPOOL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "postgres_fe.h"

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
 * A segment file open for appending. A failed create, write or sync is final:
 * it closes the file and sets fd to -1, and later calls refuse the segment.
 * Only the refusal of a message that the format does not hold leaves it open.
 */
typedef struct SpoolSegment
{
	char filename[MAXPGPATH];
	int fd;
	uint64_t size;              /* bytes written to the file */
	char *block;
	size_t blockLength;
} SpoolSegment;

uint32_t spool_crc32c(const char *data, size_t length);

void spool_header_encode(const SpoolHeader *header, char *buf);
bool spool_header_decode(const char *buf, uint64_t size, SpoolHeader *header);

SpoolFrameStatus spool_frame_decode(const char *buf, uint64_t size,
									const char **message, uint32_t *length);

bool spool_segment_create(SpoolSegment *segment, const char *dirname,
						  const SpoolHeader *header);
bool spool_append(SpoolSegment *segment, const char *message, uint32_t length);
bool spool_sync(SpoolSegment *segment);

#endif /* LD_SPOOL_H */
