/*
 * The spool format of performance mode: the checksum, the segment header and
 * frame codecs, and the writer with its sync order.
 */
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
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

/* 'w', dataStart, walEnd, sendTime, then a pgoutput BEGIN */
static char xlogdata[SPOOL_XLOGDATA_HEADER_SIZE + 21];

/* the message of PostgreSQL 13 for a transaction whose origin was dropped */
static char emptyXlogdata[SPOOL_XLOGDATA_HEADER_SIZE] = { 'w' };

static char keepalive[SPOOL_KEEPALIVE_SIZE] = { 'k' };

static char unknownKind[SPOOL_KEEPALIVE_SIZE] = { 'x' };

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
	test_disk_full(argv[1]);

	if (failed)
	{
		printf("FAIL\n");
		return 1;
	}

	printf("PASS: spool format\n");
	return 0;
}
