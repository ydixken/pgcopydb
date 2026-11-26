/*
 * The spool format of performance mode: the checksum, the segment header and
 * frame codecs, the writer with its sync order, and the transaction index.
 */
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "postgres_fe.h"

#include "file_utils.h"
#include "ld_spool.h"
#include "log.h"

static bool failed = false;

/* an XLogData message larger than the log files and than the one-page tmpfs */
static char filler[256 * 1024] = { 'w' };

/* how many of the next fsync calls fail with EIO, without a system call */
static int fsyncFailures = 0;

/* the same for ftruncate */
static int ftruncateFailures = 0;

/* 'w', dataStart, walEnd, sendTime, then a pgoutput BEGIN */
static char xlogdata[SPOOL_XLOGDATA_HEADER_SIZE + 21];

/* the message of PostgreSQL 13 for a transaction whose origin was dropped */
static char emptyXlogdata[SPOOL_XLOGDATA_HEADER_SIZE] = { 'w' };

static char keepalive[SPOOL_KEEPALIVE_SIZE] = { 'k' };

static char unknownKind[SPOOL_KEEPALIVE_SIZE] = { 'x' };

/* an XLogData message whose frame fills an empty write block */
static char blockFill[SPOOL_BLOCK_SIZE - 8] = { 'w' };

/* the log of the spool code, which the sync checks read */
static FILE *logfile;


static void
check(bool ok, const char *what)
{
	printf("%s: %s\n", ok ? "ok" : "FAIL", what);
	failed = failed || !ok;
}


/*
 * The spool code links to this fsync ahead of the one of libc. Linux reports
 * a failed writeback to one fsync only, so the call after a failure is real.
 */
int
fsync(int fd)
{
	if (fsyncFailures > 0)
	{
		fsyncFailures--;
		errno = EIO;
		return -1;
	}

	return (int) syscall(SYS_fsync, fd);
}


/* the same for the ftruncate of a rewind */
int
ftruncate(int fd, off_t length)
{
	if (ftruncateFailures > 0)
	{
		ftruncateFailures--;
		errno = EIO;
		return -1;
	}

	return (int) syscall(SYS_ftruncate, fd, length);
}


/* big-endian byte by byte, so that the checks do not share the encoder */
static void
be32(char *buf, uint32_t value)
{
	for (int i = 0; i < 4; i++)
	{
		buf[i] = (char) (value >> (24 - 8 * i));
	}
}


static void
be64(char *buf, uint64_t value)
{
	be32(buf, (uint32_t) (value >> 32));
	be32(buf + 4, (uint32_t) value);
}


/* a frame as the format defines it: length, message, CRC-32C of both */
static uint64_t
frame(char *buf, const char *message, uint32_t length)
{
	be32(buf, length);
	memcpy(buf + 4, message, length);
	be32(buf + 4 + length, spool_crc32c(buf, 4 + (size_t) length));

	return SPOOL_FRAME_SIZE(length);
}


static void
init_messages(void)
{
	xlogdata[0] = 'w';
	be64(xlogdata + 1, 0x16B3740);
	be64(xlogdata + 9, 0x16B3770);
	be64(xlogdata + 17, 0x2E3B4C5D6E7F);

	xlogdata[25] = 'B';
	be64(xlogdata + 26, 0x16B3770);
	be64(xlogdata + 34, 0x2E3B4C5D6E00);
	be32(xlogdata + 42, 1234);

	be64(keepalive + 1, 0x16B3770);
	be64(keepalive + 9, 0x2E3B4C5D6E7F);
}


static void
test_crc(void)
{
	check(spool_crc32c("123456789", 9) == 0xE3069283,
		  "CRC-32C of \"123456789\" is 0xE3069283");
}


static void
test_header(void)
{
	SpoolHeader header = {
		.firstSeq = 0x0102030405060708,
		.systemId = 0x1112131415161718,
		.timeline = 0x21222324,
		.lastFinalLSN = 0x3132333435363738,
		.lastEndLSN = 0x4142434445464748
	};
	char want[SPOOL_HEADER_SIZE] = { 'P', 'G', 'C', 'S' };
	char buf[SPOOL_HEADER_SIZE];

	be32(want + 4, 1);
	be64(want + 8, header.firstSeq);
	be64(want + 16, header.systemId);
	be32(want + 24, header.timeline);
	be64(want + 32, header.lastFinalLSN);
	be64(want + 40, header.lastEndLSN);
	be32(want + 60, spool_crc32c(want, 60));

	spool_header_encode(&header, buf);
	check(memcmp(buf, want, SPOOL_HEADER_SIZE) == 0,
		  "the header holds its fields big-endian at fixed offsets");

	SpoolHeader read = { 0 };

	check(spool_header_decode(buf, SPOOL_HEADER_SIZE, &read) &&
		  read.firstSeq == header.firstSeq &&
		  read.systemId == header.systemId &&
		  read.timeline == header.timeline &&
		  read.lastFinalLSN == header.lastFinalLSN &&
		  read.lastEndLSN == header.lastEndLSN,
		  "the header decodes to its fields");
	check(!spool_header_decode(buf, SPOOL_HEADER_SIZE - 1, &read),
		  "a header cut short is invalid");

	bool ok = true;

	for (int bit = 0; bit < SPOOL_HEADER_SIZE * 8; bit++)
	{
		buf[bit / 8] ^= (char) (1 << (bit % 8));
		ok = ok && !spool_header_decode(buf, SPOOL_HEADER_SIZE, &read);
		buf[bit / 8] ^= (char) (1 << (bit % 8));
	}
	check(ok, "a header with any one bit flipped is invalid");

	be32(want + 4, 2);
	be32(want + 60, spool_crc32c(want, 60));
	check(!spool_header_decode(want, SPOOL_HEADER_SIZE, &read),
		  "a header of another format version is invalid");
}


static void
test_frame(void)
{
	char buf[256];
	char longKeepalive[SPOOL_KEEPALIVE_SIZE + 1] = { 'k' };
	const char *message = NULL;
	uint32_t length = 0;

	uint64_t size = frame(buf, xlogdata, sizeof(xlogdata));
	uint64_t both = size + frame(buf + size, keepalive, sizeof(keepalive));

	check(spool_frame_decode(buf, both, &message, &length) == SPOOL_FRAME_OK &&
		  message == buf + 4 && length == sizeof(xlogdata),
		  "a frame decodes to its message");
	check(spool_frame_decode(buf + size, both - size,
							 &message, &length) == SPOOL_FRAME_OK &&
		  length == sizeof(keepalive) &&
		  memcmp(message, keepalive, length) == 0,
		  "the next frame starts after the CRC of the first");

	bool ok = true;

	for (uint64_t cut = 0; cut < size; cut++)
	{
		ok = ok &&
			 spool_frame_decode(buf, cut, &message, &length) == SPOOL_FRAME_SHORT;
	}
	check(ok, "a frame cut at any byte is short");

	ok = true;

	for (uint64_t bit = 0; bit < size * 8; bit++)
	{
		buf[bit / 8] ^= (char) (1 << (bit % 8));
		ok = ok &&
			 spool_frame_decode(buf, size, &message, &length) != SPOOL_FRAME_OK;
		buf[bit / 8] ^= (char) (1 << (bit % 8));
	}
	check(ok, "a frame with any one bit flipped is not valid");

	size = frame(buf, emptyXlogdata, sizeof(emptyXlogdata));
	check(spool_frame_decode(buf, size, &message, &length) == SPOOL_FRAME_OK,
		  "an XLogData message without a pgoutput message is a frame");

	size = frame(buf, xlogdata, SPOOL_XLOGDATA_HEADER_SIZE - 1);
	check(spool_frame_decode(buf, size, &message, &length) == SPOOL_FRAME_BAD,
		  "an XLogData message shorter than its header is bad");

	size = frame(buf, longKeepalive, sizeof(longKeepalive));
	check(spool_frame_decode(buf, size, &message, &length) == SPOOL_FRAME_BAD,
		  "a keepalive marker of another size is bad");

	size = frame(buf, unknownKind, sizeof(unknownKind));
	check(spool_frame_decode(buf, size, &message, &length) == SPOOL_FRAME_BAD,
		  "a message of an unknown kind is bad");

	size = frame(buf, xlogdata, 0);
	check(spool_frame_decode(buf, size, &message, &length) == SPOOL_FRAME_BAD,
		  "an empty message is bad");

	be32(buf, SPOOL_MESSAGE_MAX + 1);
	check(spool_frame_decode(buf, 4, &message, &length) == SPOOL_FRAME_BAD,
		  "a length above the message limit is bad");

	be32(buf, SPOOL_MESSAGE_MAX);
	check(spool_frame_decode(buf, 4, &message, &length) == SPOOL_FRAME_SHORT,
		  "a length at the message limit is short until its bytes are there");
}


static long
log_mark(void)
{
	fflush(logfile);

	return ftell(logfile);
}


/* the log text written since mark */
static char *
logged_since(long mark)
{
	static char text[64 * 1024];

	fflush(logfile);

	long end = ftell(logfile);

	(void) fseek(logfile, mark, SEEK_SET);
	size_t n = fread(text, 1, sizeof(text) - 1, logfile);
	(void) fseek(logfile, end, SEEK_SET);
	text[n] = '\0';

	return text;
}


static int
count(const char *text, const char *needle)
{
	int n = 0;

	for (const char *p = strstr(text, needle); p != NULL; p = strstr(p + 1, needle))
	{
		n++;
	}

	return n;
}


/* true when one line of text holds first and, after it, second */
static bool
one_line(const char *text, const char *first, const char *second)
{
	for (const char *p = strstr(text, second); p != NULL; p = strstr(p + 1, second))
	{
		const char *start = p;

		while (start > text && start[-1] != '\n')
		{
			start--;
		}

		const char *found = strstr(start, first);

		if (found != NULL && found < p)
		{
			return true;
		}
	}

	return false;
}


/* the bytes of the file at path, NULL when it cannot be read whole */
static char *
slurp(const char *path, uint64_t *size)
{
	static char bytes[2 * SPOOL_BLOCK_SIZE];
	FILE *file = fopen(path, "rb");

	if (file == NULL)
	{
		return NULL;
	}

	*size = fread(bytes, 1, sizeof(bytes), file);

	bool whole = feof(file) && !ferror(file);

	fclose(file);

	return whole ? bytes : NULL;
}


static void
test_writer(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 42,
		.systemId = 7,
		.timeline = 1,
		.lastFinalLSN = 0x16B3740,
		.lastEndLSN = 0x16B3770
	};
	SpoolSegment segment = { 0 };
	SpoolHeader read = { 0 };
	char path[MAXPGPATH];
	char fileLine[2 * MAXPGPATH];
	char dirLine[2 * MAXPGPATH];
	uint64_t size = 0;

	sformat(path, sizeof(path), "%s/000000000000002A.seg", dir);
	sformat(fileLine, sizeof(fileLine),
			"Synced spool file \"%s\" at 64 bytes", path);
	sformat(dirLine, sizeof(dirLine), "Synced spool directory \"%s\"", dir);

	long mark = log_mark();
	bool created = spool_segment_create(&segment, dir, &header);
	char *text = logged_since(mark);
	char *bytes = slurp(path, &size);

	check(created && bytes != NULL && size == SPOOL_HEADER_SIZE &&
		  spool_header_decode(bytes, size, &read) &&
		  read.firstSeq == header.firstSeq &&
		  read.lastEndLSN == header.lastEndLSN,
		  "a new segment is named by its first sequence number and holds its header");

	char *fileSync = strstr(text, fileLine);
	char *dirSync = strstr(text, dirLine);

	check(count(text, "Synced spool ") == 2 &&
		  fileSync != NULL && dirSync != NULL && fileSync < dirSync,
		  "a new segment syncs its header, then its directory");

	SpoolSegment again = { 0 };

	check(!spool_segment_create(&again, dir, &header) &&
		  slurp(path, &size) != NULL && size == SPOOL_HEADER_SIZE,
		  "a segment that exists is not created again");

	char want[256];
	uint64_t wantSize = frame(want, xlogdata, sizeof(xlogdata));

	wantSize += frame(want + wantSize, emptyXlogdata, sizeof(emptyXlogdata));
	wantSize += frame(want + wantSize, keepalive, sizeof(keepalive));

	mark = log_mark();
	bool appended =
		spool_append(&segment, xlogdata, sizeof(xlogdata)) &&
		spool_append(&segment, emptyXlogdata, sizeof(emptyXlogdata)) &&
		spool_append(&segment, keepalive, sizeof(keepalive));

	check(appended && slurp(path, &size) != NULL &&
		  size == SPOOL_HEADER_SIZE &&
		  count(logged_since(mark), "Synced spool ") == 0,
		  "appended frames stay in the write block");

	bool synced = spool_sync(&segment);

	text = logged_since(mark);
	bytes = slurp(path, &size);
	sformat(fileLine, sizeof(fileLine),
			"Synced spool file \"%s\" at %" PRIu64 " bytes",
			path, SPOOL_HEADER_SIZE + wantSize);

	check(synced && bytes != NULL && size == SPOOL_HEADER_SIZE + wantSize &&
		  memcmp(bytes + SPOOL_HEADER_SIZE, want, wantSize) == 0,
		  "spool_sync writes the frames as the format defines them");
	check(count(text, "Synced spool ") == 1 && strstr(text, fileLine) != NULL,
		  "spool_sync syncs the segment once, at its new length");

	uint64_t before = size;

	check(!spool_append(&segment, unknownKind, sizeof(unknownKind)) &&
		  spool_sync(&segment) && slurp(path, &size) != NULL && size == before,
		  "spool_append refuses a message that the reader refuses");

	static char big[SPOOL_BLOCK_SIZE + 1000] = { 'w' };
	const char *message = NULL;
	uint32_t length = 0;

	for (size_t i = 1; i < sizeof(big); i++)
	{
		big[i] = (char) (i * 7);
	}

	mark = log_mark();
	appended = spool_append(&segment, big, sizeof(big));
	text = logged_since(mark);
	synced = spool_sync(&segment);
	bytes = slurp(path, &size);

	check(appended && count(text, "Synced spool ") == 0 && synced &&
		  bytes != NULL && size == before + SPOOL_FRAME_SIZE(sizeof(big)) &&
		  spool_frame_decode(bytes + before, size - before,
							 &message, &length) == SPOOL_FRAME_OK &&
		  length == sizeof(big) && memcmp(message, big, length) == 0,
		  "a frame larger than the write block is written whole");

	/* the frame ends at the block boundary, so spool_put writes it out */
	struct stat st;

	before = size;
	mark = log_mark();
	appended = spool_append(&segment, blockFill, sizeof(blockFill));

	bool writtenOut = appended && segment.blockLength == 0 &&
					  stat(path, &st) == 0 &&
					  (uint64_t) st.st_size == before + SPOOL_BLOCK_SIZE;
	int syncsBefore = count(logged_since(mark), "Synced spool ");

	synced = spool_sync(&segment);
	text = logged_since(mark);
	sformat(fileLine, sizeof(fileLine),
			"Synced spool file \"%s\" at %" PRIu64 " bytes",
			path, before + SPOOL_BLOCK_SIZE);

	check(writtenOut && syncsBefore == 0 && synced &&
		  count(text, "Synced spool ") == 1 && strstr(text, fileLine) != NULL,
		  "a frame that ends at the write block boundary is written out unsynced, and spool_sync syncs it");
}


/*
 * A file size limit cuts the write of the block short and then fails it. The
 * file now ends inside a frame, so the segment must refuse every later call,
 * also once the limit is raised again.
 */
static void
test_write_failure_is_final(const char *dir)
{
	SpoolHeader header = { .firstSeq = 43 };
	SpoolSegment segment = { 0 };
	struct rlimit saved = { 0 };
	char path[MAXPGPATH];
	char failure[2 * MAXPGPATH];
	char refusal[2 * MAXPGPATH];
	uint64_t size = 0;

	sformat(path, sizeof(path), "%s/000000000000002B.seg", dir);
	sformat(failure, sizeof(failure),
			"Failed to write to spool file \"%s\": File too large", path);
	sformat(refusal, sizeof(refusal), "refusing spool file \"%s\"", path);

	/* with the filler, the limit is above the size of the log files */
	uint64_t limit = SPOOL_HEADER_SIZE + SPOOL_FRAME_SIZE(sizeof(filler)) + 10;
	bool ready = spool_segment_create(&segment, dir, &header) &&
				 spool_append(&segment, filler, sizeof(filler)) &&
				 spool_sync(&segment) &&
				 spool_append(&segment, xlogdata, sizeof(xlogdata)) &&
				 signal(SIGXFSZ, SIG_IGN) != SIG_ERR &&
				 getrlimit(RLIMIT_FSIZE, &saved) == 0;
	struct rlimit cut = { .rlim_cur = limit, .rlim_max = saved.rlim_max };

	long mark = log_mark();
	bool cutShort = ready && setrlimit(RLIMIT_FSIZE, &cut) == 0 &&
					!spool_sync(&segment);
	bool raised = setrlimit(RLIMIT_FSIZE, &saved) == 0;

	check(cutShort && raised && slurp(path, &size) != NULL && size == limit &&
		  one_line(logged_since(mark), " ERROR ", failure),
		  "a write cut short by the file size limit fails spool_sync");

	mark = log_mark();
	bool refused = !spool_sync(&segment) &&
				   !spool_append(&segment, keepalive, sizeof(keepalive));
	char *text = logged_since(mark);

	check(refused && count(text, "Synced spool ") == 0 &&
		  count(text, refusal) == 2 && one_line(text, " ERROR ", refusal) &&
		  slurp(path, &size) != NULL && size == limit,
		  "after a failed write, spool_sync and spool_append refuse the segment and write nothing");

	(void) unlink(path);
}


/*
 * After a failed fsync, the next fsync of the file returns 0 for the pages
 * that were lost. The segment must refuse to sync again, or it would log a
 * synced length for bytes that are not on disk.
 */
static void
test_sync_failure_is_final(const char *dir)
{
	SpoolHeader header = { .firstSeq = 44 };
	SpoolSegment segment = { 0 };
	char path[MAXPGPATH];
	char failure[2 * MAXPGPATH];
	char refusal[2 * MAXPGPATH];

	sformat(path, sizeof(path), "%s/000000000000002C.seg", dir);
	sformat(failure, sizeof(failure),
			"Failed to sync spool file \"%s\": Input/output error", path);
	sformat(refusal, sizeof(refusal), "refusing spool file \"%s\"", path);

	bool appended = spool_segment_create(&segment, dir, &header) &&
					spool_append(&segment, keepalive, sizeof(keepalive));

	long mark = log_mark();

	fsyncFailures = 1;
	bool syncFailed = appended && !spool_sync(&segment);
	fsyncFailures = 0;

	bool refused = !spool_sync(&segment);
	char *text = logged_since(mark);

	check(syncFailed && refused && one_line(text, " ERROR ", failure) &&
		  one_line(text, " ERROR ", refusal) &&
		  count(text, "Synced spool ") == 0,
		  "after a failed fsync, spool_sync refuses the segment, though a second fsync returns 0");

	(void) unlink(path);
}


static void
test_disk_full(const char *dir)
{
	SpoolHeader header = { .firstSeq = 1 };
	SpoolSegment segment = { 0 };
	char path[MAXPGPATH];
	char line[2 * MAXPGPATH];

	sformat(path, sizeof(path), "%s/0000000000000001.seg", dir);
	sformat(line, sizeof(line),
			"Failed to write to spool file \"%s\": No space left on device",
			path);

	long mark = log_mark();
	bool appended = spool_segment_create(&segment, dir, &header) &&
					spool_append(&segment, filler, sizeof(filler));
	bool synced = appended && spool_sync(&segment);

	check(appended && !synced && one_line(logged_since(mark), " ERROR ", line),
		  "a full volume fails spool_sync with an ERROR line that names the file and the system error");

	(void) unlink(path);
}


static void
test_index_record(void)
{
	SpoolIndexRecord record = {
		.seq = 0x0102030405060708,
		.xid = 0x11121314,
		.changes = 0x2122232425262728,
		.beginOffset = 0x3132333435363738,
		.endOffset = 0x4142434445464748,
		.finalLSN = 0x5152535455565758,
		.endLSN = 0x6162636465666768,
		.commitTime = 0x7172737475767778
	};
	char want[SPOOL_INDEX_RECORD_SIZE] = { 0 };
	char buf[SPOOL_INDEX_RECORD_SIZE];
	SpoolIndexRecord read = { 0 };

	be64(want, record.seq);
	be32(want + 8, record.xid);
	be64(want + 12, record.changes);
	be64(want + 20, record.beginOffset);
	be64(want + 28, record.endOffset);
	be64(want + 36, record.finalLSN);
	be64(want + 44, record.endLSN);
	be64(want + 52, record.commitTime);
	be32(want + 60, spool_crc32c(want, 60));

	spool_index_encode(&record, buf);
	check(memcmp(buf, want, SPOOL_INDEX_RECORD_SIZE) == 0,
		  "an index record holds its fields big-endian at fixed offsets");
	check(spool_index_decode(buf, SPOOL_INDEX_RECORD_SIZE, &read) &&
		  read.seq == record.seq && read.xid == record.xid &&
		  read.changes == record.changes &&
		  read.beginOffset == record.beginOffset &&
		  read.endOffset == record.endOffset &&
		  read.finalLSN == record.finalLSN && read.endLSN == record.endLSN &&
		  read.commitTime == record.commitTime,
		  "an index record decodes to its fields");
	check(!spool_index_decode(buf, SPOOL_INDEX_RECORD_SIZE - 1, &read),
		  "an index record cut short is invalid");

	bool ok = true;

	for (int bit = 0; bit < SPOOL_INDEX_RECORD_SIZE * 8; bit++)
	{
		buf[bit / 8] ^= (char) (1 << (bit % 8));
		ok = ok && !spool_index_decode(buf, SPOOL_INDEX_RECORD_SIZE, &read);
		buf[bit / 8] ^= (char) (1 << (bit % 8));
	}
	check(ok, "an index record with any one bit flipped is invalid");
}


/* one spool message as receive hands it to the writer */
typedef struct Msg
{
	char bytes[64];
	uint32_t length;
} Msg;


/* an XLogData message with header LSN lsn around a pgoutput message */
static Msg
xlog(uint64_t lsn, const char *pgoutput, uint32_t length)
{
	Msg msg = { .length = SPOOL_XLOGDATA_HEADER_SIZE + length };

	msg.bytes[0] = 'w';
	be64(msg.bytes + 1, lsn);
	be64(msg.bytes + 9, lsn);
	be64(msg.bytes + 17, 0x2E3B4C5D6E7F);

	if (length > 0)
	{
		memcpy(msg.bytes + SPOOL_XLOGDATA_HEADER_SIZE, pgoutput, length);
	}

	return msg;
}


static Msg
begin_msg(uint64_t lsn, uint64_t finalLSN, uint32_t xid)
{
	char body[21] = { 'B' };

	be64(body + 1, finalLSN);
	be64(body + 9, 0x2E3B4C5D6E00);
	be32(body + 17, xid);

	return xlog(lsn, body, sizeof(body));
}


static Msg
commit_msg(uint64_t lsn, uint64_t finalLSN, uint64_t endLSN, uint64_t time)
{
	char body[26] = { 'C' };

	be64(body + 2, finalLSN);
	be64(body + 10, endLSN);
	be64(body + 18, time);

	return xlog(lsn, body, sizeof(body));
}


/* a message of the given type, whose body the writer does not read */
static Msg
other_msg(uint64_t lsn, char type)
{
	char body[9] = { type, 0, 0, 0x40, 0x01, 'N', 0, 2, 0 };

	return xlog(lsn, body, sizeof(body));
}


static Msg
keepalive_msg(void)
{
	Msg msg = { .length = SPOOL_KEEPALIVE_SIZE };

	memcpy(msg.bytes, keepalive, SPOOL_KEEPALIVE_SIZE);

	return msg;
}


static bool
feed(SpoolWriter *writer, const Msg *msgs, int n)
{
	for (int i = 0; i < n; i++)
	{
		if (!spool_writer_message(writer, msgs[i].bytes, msgs[i].length))
		{
			return false;
		}
	}

	return true;
}


/* a writer in a directory of its own under dir */
static bool
new_writer(SpoolWriter *writer, const char *dir, const SpoolHeader *header,
		   uint64_t maxSegmentSize)
{
	static int writers = 0;
	char path[MAXPGPATH];

	sformat(path, sizeof(path), "%s/writer%d", dir, ++writers);

	return mkdir(path, 0700) == 0 &&
		   spool_writer_create(writer, path, header, maxSegmentSize);
}


static int
records(const SpoolWriter *writer)
{
	return (int) (writer->pendingIndex.len / SPOOL_INDEX_RECORD_SIZE);
}


static bool
record_at(const SpoolWriter *writer, int i, SpoolIndexRecord *record)
{
	return i < records(writer) &&
		   spool_index_decode(writer->pendingIndex.data +
							  (size_t) i * SPOOL_INDEX_RECORD_SIZE,
							  SPOOL_INDEX_RECORD_SIZE, record);
}


static uint64_t
frames_size(const Msg *msgs, int n)
{
	uint64_t size = 0;

	for (int i = 0; i < n; i++)
	{
		size += SPOOL_FRAME_SIZE(msgs[i].length);
	}

	return size;
}


/* syncs the segment, then compares it with its header and the frames of msgs */
static bool
segment_holds(SpoolWriter *writer, const Msg *msgs, int n)
{
	static char want[16 * 1024];
	uint64_t wantSize = SPOOL_HEADER_SIZE;
	uint64_t size = 0;

	spool_header_encode(&writer->header, want);

	for (int i = 0; i < n; i++)
	{
		wantSize += frame(want + wantSize, msgs[i].bytes, msgs[i].length);
	}

	char *bytes = spool_sync(&writer->segment) ?
				  slurp(writer->segment.filename, &size) : NULL;

	return bytes != NULL && size == wantSize && memcmp(bytes, want, size) == 0;
}


/* the flush of receive: sync the frames, then write the index records */
static bool
flush(SpoolWriter *writer)
{
	if (!spool_sync(&writer->segment))
	{
		return false;
	}

	resetPQExpBuffer(&writer->pendingIndex);

	return true;
}


static void
test_transaction(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .systemId = 7, .timeline = 1,
		.lastFinalLSN = 0x2000, .lastEndLSN = 0x2030
	};
	SpoolWriter writer = { 0 };
	SpoolIndexRecord record = { 0 };
	Msg msgs[] = {
		begin_msg(0x3010, 0x3100, 900),
		other_msg(0, 'R'),
		other_msg(0x3010, 'I'),
		other_msg(0x3040, 'U'),
		other_msg(0x3070, 'D'),
		other_msg(0x30A0, 'T'),
		commit_msg(0x3130, 0x3100, 0x3130, 0x2E3B4C5D6E7F)
	};
	int n = lengthof(msgs);

	bool fed = new_writer(&writer, dir, &header, 0) && feed(&writer, msgs, n);

	check(fed && records(&writer) == 1 && record_at(&writer, 0, &record) &&
		  record.seq == 5 && record.xid == 900 && record.changes == 4 &&
		  record.beginOffset == SPOOL_HEADER_SIZE &&
		  record.endOffset == SPOOL_HEADER_SIZE + frames_size(msgs, n) &&
		  record.finalLSN == 0x3100 && record.endLSN == 0x3130 &&
		  record.commitTime == 0x2E3B4C5D6E7F && writer.nextSeq == 6,
		  "a transaction gives one index record with its sequence number, xid, change count, offsets, final_lsn, end LSN and commit time");
	check(fed && segment_holds(&writer, msgs, n),
		  "the segment holds the frames of the transaction as they arrived");
}


static void
test_empty_transactions(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0x2000, .lastEndLSN = 0x2030
	};
	SpoolWriter writer = { 0 };
	SpoolIndexRecord record = { 0 };
	Msg empty[] = {
		begin_msg(0x2130, 0x2100, 901),
		commit_msg(0x2130, 0x2100, 0x2130, 1),
		begin_msg(0, 0x2200, 902),
		other_msg(0x2210, 'O'),
		commit_msg(0x2230, 0x2200, 0x2230, 2)
	};
	Msg withKeepalive[] = {
		begin_msg(0x2330, 0x2300, 903),
		keepalive_msg(),
		commit_msg(0x2330, 0x2300, 0x2330, 3)
	};
	Msg next[] = {
		begin_msg(0x2410, 0x2500, 904),
		other_msg(0x2410, 'I'),
		commit_msg(0x2530, 0x2500, 0x2530, 4)
	};

	bool fed = new_writer(&writer, dir, &header, 0) &&
			   feed(&writer, empty, lengthof(empty));

	check(fed && records(&writer) == 0 && segment_holds(&writer, NULL, 0),
		  "BEGIN and COMMIT, and BEGIN, ORIGIN and COMMIT, leave no byte and no record");

	fed = fed && feed(&writer, withKeepalive, lengthof(withKeepalive));

	check(fed && records(&writer) == 0 &&
		  segment_holds(&writer, withKeepalive + 1, 1),
		  "a keepalive marker inside an empty transaction is kept, and the transaction leaves no byte");

	fed = fed && feed(&writer, next, lengthof(next));

	check(fed && records(&writer) == 1 && record_at(&writer, 0, &record) &&
		  record.seq == 5 &&
		  record.beginOffset == SPOOL_HEADER_SIZE +
		  SPOOL_FRAME_SIZE(SPOOL_KEEPALIVE_SIZE),
		  "the transaction after empty ones takes the next sequence number");

	Msg kept[] = { withKeepalive[1], next[0], next[1], next[2] };

	check(fed && segment_holds(&writer, kept, lengthof(kept)),
		  "the transaction after empty ones holds no frame of theirs");
}


static void
test_begin_without_lsn(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0x4000, .lastEndLSN = 0x4030
	};
	SpoolWriter writer = { 0 };
	SpoolIndexRecord first = { 0 };
	SpoolIndexRecord second = { 0 };
	Msg msgs[] = {
		begin_msg(0, 0x4100, 905),
		xlog(0x4010, NULL, 0),
		other_msg(0x4010, 'I'),
		commit_msg(0x4130, 0x4100, 0x4130, 5),
		begin_msg(0, 0x4200, 906),
		other_msg(0x4150, 'O'),
		other_msg(0, 'Y'),
		other_msg(0, 'R'),
		other_msg(0x4150, 'U'),
		commit_msg(0x4230, 0x4200, 0x4230, 6)
	};

	/* the empty message stands for an ORIGIN, so it does not open the body */
	Msg empty[] = {
		begin_msg(0, 0x4300, 914),
		xlog(0x4310, NULL, 0),
		commit_msg(0x4330, 0x4300, 0x4330, 14)
	};

	bool fed = new_writer(&writer, dir, &header, 0) &&
			   feed(&writer, msgs, lengthof(msgs));

	check(fed && records(&writer) == 2 &&
		  record_at(&writer, 0, &first) && record_at(&writer, 1, &second) &&
		  first.finalLSN == 0x4100 && first.changes == 1 &&
		  first.endOffset == SPOOL_HEADER_SIZE + frames_size(msgs, 4) &&
		  second.finalLSN == 0x4200 && second.changes == 1 &&
		  second.beginOffset == first.endOffset &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a BEGIN with header LSN 0/0 and an empty XLogData message are accepted");

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, empty, lengthof(empty));

	check(fed && records(&writer) == 0 && segment_holds(&writer, NULL, 0),
		  "BEGIN, an empty XLogData message and COMMIT leave no byte and no record");
}


static void
test_cut_off(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0x5000, .lastEndLSN = 0x5030
	};
	SpoolWriter writer = { 0 };
	SpoolIndexRecord first = { 0 };
	SpoolIndexRecord second = { 0 };

	/* the first transaction, then all of the second */
	Msg msgs[] = {
		begin_msg(0x5010, 0x5100, 907),
		other_msg(0x5010, 'I'),
		commit_msg(0x5130, 0x5100, 0x5130, 7),
		begin_msg(0x5150, 0x5200, 908),
		other_msg(0x5150, 'I'),
		other_msg(0x5180, 'U'),
		commit_msg(0x5230, 0x5200, 0x5230, 8)
	};
	Msg held[] = { msgs[3], other_msg(0x5150, 'O') };

	bool fed = new_writer(&writer, dir, &header, 0) &&
			   feed(&writer, msgs, 6) &&
			   spool_sync(&writer.segment) &&
			   spool_writer_rewind(&writer) &&
			   feed(&writer, msgs + 3, 4);

	check(fed && records(&writer) == 2 &&
		  record_at(&writer, 0, &first) && record_at(&writer, 1, &second) &&
		  second.seq == first.seq + 1 && second.beginOffset == first.endOffset &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a transaction cut off after a sync, then sent in full, gives one record, and the segment holds no byte of the first attempt");

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, msgs, 3) &&
		  feed(&writer, held, lengthof(held)) &&
		  spool_writer_rewind(&writer) &&
		  feed(&writer, msgs + 3, 3) &&
		  spool_writer_rewind(&writer) &&
		  feed(&writer, msgs + 3, 4);

	check(fed && records(&writer) == 2 &&
		  record_at(&writer, 1, &second) && second.changes == 2 &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a transaction cut off before COMMIT, then sent in full, gives one record, and the segment holds no byte of the first attempt");

	/* one rewind only, as a second one cuts a stale held frame off again */
	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, msgs, 3) &&
		  feed(&writer, held, lengthof(held)) &&
		  spool_writer_rewind(&writer) &&
		  feed(&writer, msgs + 3, 4);

	check(fed && records(&writer) == 2 &&
		  record_at(&writer, 1, &second) && second.changes == 2 &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a transaction cut off while its BEGIN and ORIGIN wait in memory, then sent in full, leaves no byte of the first attempt");

	/* the frames that wait in the write block after the sync go too */
	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, msgs, 5) &&
		  spool_sync(&writer.segment) &&
		  feed(&writer, msgs + 5, 1) &&
		  spool_writer_rewind(&writer) &&
		  feed(&writer, msgs + 3, 4);

	check(fed && records(&writer) == 2 &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a transaction cut off after a sync and more frames, then sent in full, leaves no byte of the first attempt");

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, msgs, 2) &&
		  spool_sync(&writer.segment) &&
		  spool_writer_rewind(&writer) &&
		  feed(&writer, msgs, lengthof(msgs));

	check(fed && records(&writer) == 2 &&
		  segment_holds(&writer, msgs, lengthof(msgs)),
		  "a transaction cut off before the first COMMIT of a writer, then sent in full, keeps the segment header");

	/* the partial bytes reached the file, so the rewind needs ftruncate */
	char failure[2 * MAXPGPATH];
	struct stat st;

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, msgs, 5) &&
		  spool_sync(&writer.segment);
	sformat(failure, sizeof(failure),
			"Failed to truncate spool file \"%s\" to %" PRIu64
			" bytes: Input/output error",
			writer.segment.filename, SPOOL_HEADER_SIZE + frames_size(msgs, 3));

	uint64_t written = writer.segment.size;
	long mark = log_mark();

	ftruncateFailures = 1;
	bool rewound = fed && spool_writer_rewind(&writer);
	ftruncateFailures = 0;

	bool refused = !spool_sync(&writer.segment);
	char *text = logged_since(mark);

	check(fed && !rewound && writer.segment.fd == -1 && refused &&
		  one_line(text, " ERROR ", failure) &&
		  one_line(text, " ERROR ", "refusing spool file") &&
		  count(text, "Synced spool ") == 0 &&
		  stat(writer.segment.filename, &st) == 0 &&
		  (uint64_t) st.st_size == written,
		  "a failed ftruncate fails the rewind with an ERROR line and closes the segment, which refuses the next sync");
}


static void
test_sent_again(const char *dir)
{
	/* as after a rotation, or once cleanup deleted the segment of 0x6100 */
	SpoolHeader header = {
		.firstSeq = 9, .lastFinalLSN = 0x6100, .lastEndLSN = 0x6130
	};
	SpoolWriter writer = { 0 };
	SpoolIndexRecord record = { 0 };
	Msg again[] = {
		begin_msg(0x6010, 0x6100, 909),
		other_msg(0, 'R'),
		other_msg(0x6010, 'I'),
		commit_msg(0x6130, 0x6100, 0x6130, 9),
		begin_msg(0x5F10, 0x5F00, 910),
		other_msg(0x5F10, 'D'),
		commit_msg(0x5F30, 0x5F00, 0x5F30, 10)
	};

	/* its first change comes before the COMMIT of 0x6100 */
	Msg interleaved[] = {
		begin_msg(0x6050, 0x6200, 911),
		other_msg(0x6050, 'I'),
		commit_msg(0x6230, 0x6200, 0x6230, 11)
	};

	bool fed = new_writer(&writer, dir, &header, 0) &&
			   feed(&writer, again, lengthof(again));

	check(fed && records(&writer) == 0 && segment_holds(&writer, NULL, 0),
		  "a BEGIN whose final_lsn is at or below that of the last complete transaction is skipped up to its COMMIT");

	fed = fed && feed(&writer, interleaved, lengthof(interleaved));

	check(fed && records(&writer) == 1 && record_at(&writer, 0, &record) &&
		  record.seq == 9 && record.finalLSN == 0x6200 &&
		  segment_holds(&writer, interleaved, lengthof(interleaved)),
		  "a BEGIN whose header LSN is below the last final_lsn is kept by its own final_lsn");

	fed = fed && feed(&writer, interleaved, lengthof(interleaved));

	check(fed && records(&writer) == 1 &&
		  segment_holds(&writer, interleaved, lengthof(interleaved)),
		  "a transaction sent again while its record waits in memory is skipped");
}


static void
test_stream_errors(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0x7100, .lastEndLSN = 0x7130
	};
	SpoolWriter writer = { 0 };
	Msg open[] = {
		begin_msg(0x7210, 0x7300, 912),
		other_msg(0x7210, 'I')
	};
	Msg logical = other_msg(0x7220, 'M');
	Msg otherEnd = commit_msg(0x7340, 0x7300, 0x7330, 12);

	/* above the last final_lsn, and at or below the last end LSN */
	Msg early[] = {
		begin_msg(0x7110, 0x7120, 913),
		other_msg(0x7110, 'I'),
		commit_msg(0x7128, 0x7120, 0x7128, 13)
	};

	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 2) &&
		  !feed(&writer, &logical, 1),
		  "an unknown message type is an error");
	check(new_writer(&writer, dir, &header, 0) && !feed(&writer, open + 1, 1),
		  "a change outside a transaction is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 2) &&
		  !feed(&writer, open, 1),
		  "a BEGIN inside a transaction is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 2) &&
		  !feed(&writer, &otherEnd, 1),
		  "a COMMIT whose end LSN is not its header LSN is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, early, 2) &&
		  !feed(&writer, early + 2, 1),
		  "a COMMIT at or below the end LSN of the last complete transaction is an error");

	Msg secondBegin = begin_msg(0x7250, 0x7400, 915);
	Msg resent = begin_msg(0x7010, 0x7100, 916);

	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 1) &&
		  !feed(&writer, &secondBegin, 1),
		  "a BEGIN while a BEGIN is held is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, &resent, 1) &&
		  writer.state == SPOOL_TXN_SKIP && !feed(&writer, &secondBegin, 1),
		  "a BEGIN inside a transaction sent again is an error");

	Msg shortBegin = open[0];
	Msg shortCommit = commit_msg(0x7330, 0x7300, 0x7330, 12);
	Msg shortXlogdata = xlog(0x7220, NULL, 0);

	shortBegin.length--;
	shortCommit.length--;
	shortXlogdata.length = SPOOL_XLOGDATA_HEADER_SIZE - 1;

	check(new_writer(&writer, dir, &header, 0) && !feed(&writer, &shortBegin, 1),
		  "a BEGIN one byte short is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 2) &&
		  !feed(&writer, &shortCommit, 1),
		  "a COMMIT one byte short is an error");
	check(new_writer(&writer, dir, &header, 0) && feed(&writer, open, 1) &&
		  !feed(&writer, &shortXlogdata, 1),
		  "an XLogData message shorter than its header is an error while a BEGIN is held");
}


static void
test_rotation(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 20, .systemId = 7, .timeline = 2,
		.lastFinalLSN = 0x8000, .lastEndLSN = 0x8030
	};
	SpoolWriter writer = { 0 };
	SpoolWriter restarted = { 0 };
	SpoolWriter other = { 0 };
	SpoolHeader read = { 0 };
	SpoolIndexRecord record = { 0 };
	char path[MAXPGPATH];
	uint64_t size = 0;
	Msg msgs[] = {
		begin_msg(0x8010, 0x8100, 920),
		other_msg(0x8010, 'I'),
		commit_msg(0x8130, 0x8100, 0x8130, 20)
	};
	Msg next[] = {
		begin_msg(0x8150, 0x8200, 921),
		other_msg(0x8150, 'I'),
		commit_msg(0x8230, 0x8200, 0x8230, 21)
	};

	/* below the header size, so only the rules of rotation hold it back */
	bool fed = new_writer(&writer, dir, &header, 50);
	bool dueAtStart = spool_writer_rotate_due(&writer);

	fed = fed && feed(&writer, msgs, 2);

	bool dueInside = spool_writer_rotate_due(&writer);

	fed = fed && feed(&writer, msgs + 2, 1);

	check(fed && !dueAtStart && !dueInside && spool_writer_rotate_due(&writer),
		  "rotation is due only after a COMMIT that takes the segment past the limit");

	/* one byte above the end of the first transaction */
	uint64_t limit = SPOOL_HEADER_SIZE + frames_size(msgs, lengthof(msgs)) + 1;
	bool below = new_writer(&other, dir, &header, limit) &&
				 feed(&other, msgs, lengthof(msgs)) &&
				 !spool_writer_rotate_due(&other);

	check(below && feed(&other, next, lengthof(next)) &&
		  spool_writer_rotate_due(&other),
		  "rotation is not due while the segment is below the limit");

	check(new_writer(&other, dir, &header, 0) &&
		  feed(&other, msgs, lengthof(msgs)) &&
		  !spool_writer_rotate_due(&other),
		  "with the limit 0, rotation is never due");

	bool inside = new_writer(&other, dir, &header, 50) &&
				  feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
				  feed(&other, next, 1);
	bool dueHeld = spool_writer_rotate_due(&other);

	inside = inside && feed(&other, next + 1, 1);

	check(inside && !dueHeld && !spool_writer_rotate_due(&other),
		  "after a flushed COMMIT past the limit, rotation is not due inside the next transaction");

	bool refused = new_writer(&other, dir, &header, limit) &&
				   feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
				   !spool_writer_rotate_due(&other) &&
				   !spool_writer_rotate(&other);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	check(refused && access(path, F_OK) != 0,
		  "rotation refuses while it is not due");

	/* the frames are synced and their record waits in memory */
	refused = new_writer(&other, dir, &header, 50) &&
			  feed(&other, msgs, lengthof(msgs)) &&
			  spool_sync(&other.segment) && records(&other) == 1 &&
			  spool_writer_rotate_due(&other) && !spool_writer_rotate(&other);

	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	check(refused && access(path, F_OK) != 0,
		  "rotation waits until the flush has written the index records");

	/* the record is taken and the frames wait in the write block */
	refused = new_writer(&other, dir, &header, 50) &&
			  feed(&other, msgs, lengthof(msgs));

	if (refused)
	{
		resetPQExpBuffer(&other.pendingIndex);
	}

	refused = refused && other.segment.blockLength > 0 &&
			  spool_writer_rotate_due(&other) && !spool_writer_rotate(&other);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	check(refused && access(path, F_OK) != 0,
		  "rotation waits until the flush has synced the frames");

	/* after the flush, a frame that fills the block goes out unsynced */
	refused = new_writer(&other, dir, &header, 50) &&
			  feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
			  spool_append(&other.segment, blockFill, sizeof(blockFill)) &&
			  other.segment.blockLength == 0 &&
			  spool_writer_rotate_due(&other) && !spool_writer_rotate(&other);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	bool missing = access(path, F_OK) != 0;

	check(refused && missing && spool_sync(&other.segment) &&
		  spool_writer_rotate(&other) && access(path, F_OK) == 0,
		  "rotation waits until the flush has synced a frame that ends at the write block boundary");

	/* a rewind cuts synced frames off, and a frame that fills the block follows */
	refused = new_writer(&other, dir, &header, 50) &&
			  feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
			  spool_append(&other.segment, blockFill, sizeof(blockFill)) &&
			  spool_append(&other.segment, blockFill, sizeof(blockFill)) &&
			  spool_sync(&other.segment) && spool_writer_rewind(&other) &&
			  spool_append(&other.segment, blockFill, sizeof(blockFill)) &&
			  other.segment.blockLength == 0 &&
			  spool_writer_rotate_due(&other) && !spool_writer_rotate(&other);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	check(refused && access(path, F_OK) != 0,
		  "after a rewind cut synced frames off, rotation waits until the flush has synced the frames written since");

	sformat(path, sizeof(path), "%s/0000000000000015.seg", writer.dirname);

	bool rotated = fed && flush(&writer) && spool_writer_rotate(&writer);
	char *bytes = slurp(path, &size);

	check(rotated && bytes != NULL &&
		  spool_header_decode(bytes, size, &read) &&
		  read.firstSeq == 21 && read.systemId == 7 && read.timeline == 2 &&
		  read.lastFinalLSN == 0x8100 && read.lastEndLSN == 0x8130 &&
		  strcmp(writer.segment.filename, path) == 0,
		  "a new segment is named by the next sequence number and carries final_lsn and end LSN of the last complete transaction");

	check(rotated && feed(&writer, next, lengthof(next)) &&
		  records(&writer) == 1 && record_at(&writer, 0, &record) &&
		  record.seq == 21 && record.beginOffset == SPOOL_HEADER_SIZE &&
		  segment_holds(&writer, next, lengthof(next)),
		  "the next transaction starts the new segment");

	bool cut = new_writer(&other, dir, &header, 50) &&
			   feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
			   spool_writer_rotate(&other) &&
			   feed(&other, next, 2) &&
			   spool_writer_rewind(&other) &&
			   feed(&other, next, lengthof(next));

	check(cut && records(&other) == 1 && record_at(&other, 0, &record) &&
		  record.beginOffset == SPOOL_HEADER_SIZE &&
		  segment_holds(&other, next, lengthof(next)),
		  "a transaction cut off before the first COMMIT of a new segment, then sent in full, leaves the header and the transaction");

	/* a start that finds only the new segment, as after cleanup */
	check(rotated && new_writer(&restarted, dir, &read, 0) &&
		  feed(&restarted, msgs, lengthof(msgs)) && records(&restarted) == 0 &&
		  segment_holds(&restarted, NULL, 0),
		  "a writer started from that header skips the last transaction of the old segment sent again");
}


int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (argc != 2)
	{
		printf("usage: spool-format <directory on a tmpfs of one page>\n");
		return 2;
	}

	char dir[] = "/tmp/cdc-spool-format.XXXXXX";

	logfile = tmpfile();

	if (logfile == NULL || mkdtemp(dir) == NULL)
	{
		printf("FAIL: tmpfile or mkdtemp\n");
		return 2;
	}

	log_set_fp(logfile);
	log_set_level(LOG_DEBUG);

	init_messages();

	test_crc();
	test_header();
	test_frame();
	test_writer(dir);
	test_write_failure_is_final(dir);
	test_sync_failure_is_final(dir);
	test_index_record();
	test_transaction(dir);
	test_empty_transactions(dir);
	test_begin_without_lsn(dir);
	test_cut_off(dir);
	test_sent_again(dir);
	test_stream_errors(dir);
	test_rotation(dir);
	test_disk_full(argv[1]);

	if (failed)
	{
		printf("FAIL\n");
		return 1;
	}

	printf("PASS: spool format\n");
	return 0;
}
