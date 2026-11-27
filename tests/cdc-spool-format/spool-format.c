/*
 * The spool format of performance mode: the checksum, the segment header and
 * frame codecs, the writer with its sync order, the transaction index, and the
 * relation log with its cursor.
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
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
#include "ld_stream.h"
#include "log.h"
#include "parson.h"

/* defaults.h maps realloc to the collector, and the checks replace realloc */
#undef realloc

static bool failed = false;

/* an XLogData message larger than the log files and than the one-page tmpfs */
static char filler[256 * 1024] = { 'w' };

/* how many of the next fsync calls fail with EIO, without a system call */
static int fsyncFailures = 0;

/* how many fsync calls succeed before those */
static int fsyncSkips = 0;

/* the same for ftruncate */
static int ftruncateFailures = 0;
static int ftruncateSkips = 0;

/* the pread or fstat call, counted from 1, that fails with EIO; 0 for none */
static int preadFailAt = 0;
static int fstatFailAt = 0;

/* the same for realloc, which a PQExpBuffer calls to grow */
static int reallocFailures = 0;

/* the same for fopen, which read_file calls */
static int fopenFailures = 0;

/* the same for readdir, which the scan of a spool directory calls */
static int readdirFailures = 0;

/* runs once, before the next readdir, as receive running between two calls */
static void (*beforeReaddir)(void) = NULL;

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
	if (fsyncFailures > 0 && fsyncSkips > 0)
	{
		fsyncSkips--;
	}
	else if (fsyncFailures > 0)
	{
		fsyncFailures--;
		errno = EIO;
		return -1;
	}

	return (int) syscall(SYS_fsync, fd);
}


/* the same for the ftruncate of a rewind and of the start */
int
ftruncate(int fd, off_t length)
{
	if (ftruncateFailures > 0 && ftruncateSkips > 0)
	{
		ftruncateSkips--;
	}
	else if (ftruncateFailures > 0)
	{
		ftruncateFailures--;
		errno = EIO;
		return -1;
	}

	return (int) syscall(SYS_ftruncate, fd, length);
}


/* a countdown that reaches 0 at the call that fails */
static bool
fails_now(int *countdown)
{
	return *countdown > 0 && --*countdown == 0;
}


/* the same for unlink, which unlink_file calls */
static int unlinkFailAt = 0;

int
unlink(const char *path)
{
	if (fails_now(&unlinkFailAt))
	{
		errno = EIO;
		return -1;
	}

	return (int) syscall(SYS_unlinkat, AT_FDCWD, path, 0);
}


/*
 * The same for pread. Fortified builds call the checking variant, and LFS
 * builds the 64-bit name, so the asm names catch all four.
 */
static ssize_t
next_pread(int fd, void *buf, size_t count, off_t offset)
{
	if (fails_now(&preadFailAt))
	{
		errno = EIO;
		return -1;
	}

	return (ssize_t) syscall(SYS_pread64, fd, buf, count, offset);
}


ssize_t test_pread(int fd, void *buf, size_t count, off_t offset) __asm__ ("pread");
ssize_t test_pread64(int fd, void *buf, size_t count, off_t offset) __asm__ ("pread64");
ssize_t test_pread_chk(int fd, void *buf, size_t count, off_t offset,
					   size_t size) __asm__ ("__pread_chk");
ssize_t test_pread64_chk(int fd, void *buf, size_t count, off_t offset,
						 size_t size) __asm__ ("__pread64_chk");

ssize_t
test_pread(int fd, void *buf, size_t count, off_t offset)
{
	return next_pread(fd, buf, count, offset);
}


ssize_t
test_pread64(int fd, void *buf, size_t count, off_t offset)
{
	return next_pread(fd, buf, count, offset);
}


ssize_t
test_pread_chk(int fd, void *buf, size_t count, off_t offset, size_t size)
{
	return next_pread(fd, buf, count, offset);
}


ssize_t
test_pread64_chk(int fd, void *buf, size_t count, off_t offset, size_t size)
{
	return next_pread(fd, buf, count, offset);
}


/* the same for fstat, which glibc 2.33 and later export under both names */
static int
next_fstat(int fd, void *st, const char *name)
{
	if (fails_now(&fstatFailAt))
	{
		errno = EIO;
		return -1;
	}

	int (*next)(int, void *) = (int (*)(int, void *))dlsym(RTLD_NEXT, name);

	return next(fd, st);
}


int test_fstat(int fd, void *st) __asm__ ("fstat");
int test_fstat64(int fd, void *st) __asm__ ("fstat64");

int
test_fstat(int fd, void *st)
{
	return next_fstat(fd, st, "fstat");
}


int
test_fstat64(int fd, void *st)
{
	return next_fstat(fd, st, "fstat64");
}


/*
 * The same for realloc. It calls the next realloc and not the one of libc,
 * which does not know the heap of a sanitizer.
 */
void *
realloc(void *ptr, size_t size)
{
	static void *(*next)(void *, size_t) = NULL;

	if (reallocFailures > 0)
	{
		reallocFailures--;
		return NULL;
	}

	if (next == NULL)
	{
		next = (void *(*)(void *, size_t))dlsym(RTLD_NEXT, "realloc");
	}

	return next(ptr, size);
}


FILE *
fopen(const char *path, const char *mode)
{
	static FILE *(*next)(const char *, const char *) = NULL;

	if (fopenFailures > 0)
	{
		fopenFailures--;
		errno = EIO;
		return NULL;
	}

	if (next == NULL)
	{
		next = (FILE * (*)(const char *, const char *))dlsym(RTLD_NEXT, "fopen");
	}

	return next(path, mode);
}


/* readdir fails with EIO when asked; LFS builds call readdir64 */
static void *
next_readdir(void *dir, const char *name)
{
	void (*hook)(void) = beforeReaddir;

	beforeReaddir = NULL;

	if (hook != NULL)
	{
		hook();
	}

	if (readdirFailures > 0)
	{
		readdirFailures--;
		errno = EIO;
		return NULL;
	}

	void *(*next)(void *) = (void *(*)(void *))dlsym(RTLD_NEXT, name);

	return next(dir);
}


void * test_readdir(void *dir) __asm__ ("readdir");
void * test_readdir64(void *dir) __asm__ ("readdir64");

void *
test_readdir(void *dir)
{
	return next_readdir(dir, "readdir");
}


void *
test_readdir64(void *dir)
{
	return next_readdir(dir, "readdir64");
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

	be32(want + 4, 2);
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

	/* version 1 had index records without relationLogEnd */
	be32(want + 4, 1);
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

	/* a descriptor without a write block, as in a segment never created */
	char unopenedPath[MAXPGPATH];
	char refusal[2 * MAXPGPATH];
	struct stat st;

	sformat(unopenedPath, sizeof(unopenedPath), "%s/unopened", dir);
	sformat(refusal, sizeof(refusal),
			"refusing spool file \"%s\", which was not opened",
			unopenedPath);

	SpoolSegment unopened = {
		.fd = open(unopenedPath, O_WRONLY | O_CREAT | O_EXCL, 0644)
	};

	sformat(unopened.filename, sizeof(unopened.filename), "%s", unopenedPath);

	mark = log_mark();
	bool refused = unopened.fd >= 0 && !spool_sync(&unopened) &&
				   !spool_append(&unopened, keepalive, sizeof(keepalive));

	text = logged_since(mark);

	check(refused && count(text, refusal) == 2 &&
		  count(text, "Synced spool ") == 0 &&
		  stat(unopenedPath, &st) == 0 && st.st_size == 0,
		  "a segment without a write block is refused");

	(void) close(unopened.fd);

	/* the directory name fits, the name of the segment file does not */
	char longDir[MAXPGPATH];
	char longLine[2 * MAXPGPATH];
	SpoolWriter longName = { 0 };

	memset(longDir, 'd', sizeof(longDir));
	longDir[0] = '/';
	longDir[MAXPGPATH - 10] = '\0';
	sformat(longLine, sizeof(longLine),
			"Spool file name \"%s/000000000000002A.seg\" is too long", longDir);
	mark = log_mark();

	check(!spool_writer_create(&longName, longDir, &header, 0) &&
		  one_line(logged_since(mark), " ERROR ", longLine) &&
		  longName.held.data == NULL && longName.pendingIndex.data == NULL,
		  "a writer whose segment file name does not fit fails with an ERROR line and holds no buffer");
	check(longName.relationLog.fd == -1,
		  "a writer whose segment file name does not fit holds no relation log descriptor");

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
		.commitTime = 0x7172737475767778,
		.relationLogEnd = 0x8182838485868788
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
	be64(want + 60, record.relationLogEnd);
	be32(want + 68, spool_crc32c(want, 68));

	spool_index_encode(&record, buf);
	check(memcmp(buf, want, SPOOL_INDEX_RECORD_SIZE) == 0,
		  "an index record holds its fields big-endian at fixed offsets");
	check(spool_index_decode(buf, SPOOL_INDEX_RECORD_SIZE, &read) &&
		  read.seq == record.seq && read.xid == record.xid &&
		  read.changes == record.changes &&
		  read.beginOffset == record.beginOffset &&
		  read.endOffset == record.endOffset &&
		  read.finalLSN == record.finalLSN && read.endLSN == record.endLSN &&
		  read.commitTime == record.commitTime &&
		  read.relationLogEnd == record.relationLogEnd,
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
	char bytes[128];
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

	/* the spool keeps schema frames as sent, so they are not held like ORIGIN */
	Msg schema[] = {
		begin_msg(0x2610, 0x2600, 905),
		other_msg(0, 'R'),
		other_msg(0, 'Y'),
		commit_msg(0x2630, 0x2600, 0x2630, 5)
	};

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, schema, lengthof(schema));

	check(fed && records(&writer) == 1 && record_at(&writer, 0, &record) &&
		  record.changes == 0 && record.endLSN == 0x2630 &&
		  segment_holds(&writer, schema, lengthof(schema)),
		  "a transaction of RELATION and TYPE frames only gets a record with change count 0, and the segment holds its frames");
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

	Msg emptyOutside = xlog(0x7210, NULL, 0);
	long mark = log_mark();

	check(new_writer(&writer, dir, &header, 0) &&
		  !feed(&writer, &emptyOutside, 1) &&
		  one_line(logged_since(mark), " ERROR ",
				   "Received an empty XLogData message at 0/7210 outside a transaction"),
		  "an empty XLogData message outside a transaction is an error that names it");

	Msg emptyBegin = begin_msg(0x7410, 0x7400, 917);
	Msg emptyOtherEnd = commit_msg(0x7440, 0x7400, 0x7430, 17);
	Msg emptyEarly[] = {
		begin_msg(0x7110, 0x7120, 918),
		commit_msg(0x7128, 0x7120, 0x7128, 18)
	};

	check(new_writer(&writer, dir, &header, 0) && feed(&writer, &emptyBegin, 1) &&
		  !feed(&writer, &emptyOtherEnd, 1) &&
		  new_writer(&writer, dir, &header, 0) && feed(&writer, emptyEarly, 1) &&
		  !feed(&writer, emptyEarly + 1, 1),
		  "an empty transaction whose COMMIT end LSN is not its header LSN, "
		  "or not after the last, is an error");
}


/* a PQExpBuffer that cannot grow drops its bytes, so the writer must fail */
static void
test_out_of_memory(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0x9000, .lastEndLSN = 0x9030
	};
	SpoolWriter writer = { 0 };
	Msg begin = begin_msg(0x9110, 0x9100, 930);

	/* an ORIGIN above the 256 bytes that a new PQExpBuffer holds */
	static char origin[400] = { 'w' };

	origin[SPOOL_XLOGDATA_HEADER_SIZE] = 'O';

	bool fed = new_writer(&writer, dir, &header, 0) && feed(&writer, &begin, 1);

	reallocFailures = 1;
	bool held = fed && spool_writer_message(&writer, origin, sizeof(origin));
	reallocFailures = 0;

	check(fed && !held,
		  "a held frame that cannot be stored in memory is an error");

	/* the fourth record of 72 bytes is the first above those 256 bytes */
	Msg txns[12];

	for (int i = 0; i < 4; i++)
	{
		uint64_t lsn = 0x9200 + 0x100 * (uint64_t) i;

		txns[3 * i] = begin_msg(lsn, lsn + 0x50, 931 + i);
		txns[3 * i + 1] = other_msg(lsn, 'I');
		txns[3 * i + 2] = commit_msg(lsn + 0x80, lsn + 0x50, lsn + 0x80, 31 + i);
	}

	fed = new_writer(&writer, dir, &header, 0) &&
		  feed(&writer, txns, 11) && records(&writer) == 3;

	reallocFailures = 1;
	bool indexed = fed && feed(&writer, txns + 11, 1);
	reallocFailures = 0;

	check(fed && !indexed,
		  "an index record that cannot be stored in memory is an error");
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

	/* the first transaction ends at the limit exactly */
	check(new_writer(&other, dir, &header, limit - 1) &&
		  feed(&other, msgs, lengthof(msgs)) &&
		  spool_writer_rotate_due(&other),
		  "rotation is due when a COMMIT ends at the limit exactly");

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

	/* the full block took the frames before the cut to the file, unsynced */
	refused = new_writer(&other, dir, &header, 50) &&
			  feed(&other, msgs, lengthof(msgs)) &&
			  spool_append(&other.segment, blockFill, sizeof(blockFill)) &&
			  other.segment.size > other.completeSize &&
			  spool_writer_rewind(&other);

	if (refused)
	{
		resetPQExpBuffer(&other.pendingIndex);
	}

	refused = refused && other.segment.blockLength == 0 &&
			  spool_writer_rotate_due(&other) && !spool_writer_rotate(&other);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	check(refused && access(path, F_OK) != 0,
		  "after a rewind cut unsynced frames off, rotation waits for a sync of the frames before the cut");

	/* the create uses O_EXCL, so a file left over by an earlier run stops it */
	struct stat st;
	bool due = new_writer(&other, dir, &header, 50) &&
			   feed(&other, msgs, lengthof(msgs)) && flush(&other) &&
			   spool_writer_rotate_due(&other);

	sformat(path, sizeof(path), "%s/0000000000000015.seg", other.dirname);

	int fd = due ? open(path, O_WRONLY | O_CREAT | O_EXCL, 0644) : -1;

	check(fd >= 0 && !spool_writer_rotate(&other) &&
		  other.header.firstSeq == 20 &&
		  stat(path, &st) == 0 && st.st_size == 0,
		  "rotation onto a segment file that exists fails and leaves the file as it was");

	if (fd >= 0)
	{
		(void) close(fd);
	}

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


/* a spool_sync whose fsync fails, which closes the segment */
static bool
fail_sync(SpoolWriter *writer)
{
	fsyncFailures = 1;
	bool synced = spool_sync(&writer->segment);
	fsyncFailures = 0;

	return !synced && writer->segment.fd == -1;
}


/* a failed fsync is final for the writer too, also with nothing left to sync */
static void
test_closed_segment(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 20, .lastFinalLSN = 0xA000, .lastEndLSN = 0xA030
	};
	SpoolWriter writer = { 0 };
	char path[MAXPGPATH];
	Msg txn[] = {
		begin_msg(0xA110, 0xA100, 940),
		other_msg(0xA110, 'I'),
		commit_msg(0xA130, 0xA100, 0xA130, 40)
	};

	bool closed = new_writer(&writer, dir, &header, 0) &&
				  feed(&writer, txn, 2) && fail_sync(&writer);

	check(closed && !feed(&writer, txn + 2, 1) && records(&writer) == 0,
		  "a COMMIT that the closed segment refuses is an error and gets no record");

	closed = new_writer(&writer, dir, &header, 0) &&
			 feed(&writer, txn, lengthof(txn)) && flush(&writer) &&
			 fail_sync(&writer);

	check(closed && writer.completeSize == writer.segment.size &&
		  !spool_writer_rewind(&writer),
		  "a rewind refuses a segment that a failed fsync closed");

	closed = new_writer(&writer, dir, &header, 50) &&
			 feed(&writer, txn, lengthof(txn)) && flush(&writer) &&
			 fail_sync(&writer);
	sformat(path, sizeof(path), "%s/0000000000000015.seg", writer.dirname);

	check(closed && writer.segment.size == writer.segment.synced &&
		  spool_writer_rotate_due(&writer) && !spool_writer_rotate(&writer) &&
		  access(path, F_OK) != 0,
		  "rotation refuses a segment that a failed fsync closed");

	/* the held BEGIN is the first refusal, so the change itself is not a second */
	closed = new_writer(&writer, dir, &header, 0) && feed(&writer, txn, 1) &&
			 fail_sync(&writer);

	long mark = log_mark();
	bool refusedOnce = closed && !feed(&writer, txn + 1, 1) &&
					   count(logged_since(mark), "refusing spool file") == 1;

	check(refusedOnce,
		  "a change that releases a held BEGIN onto a closed segment fails "
		  "with one refusal");
}


/* a pgoutput RELATION of one key column, named by relname */
static Msg
relation_msg(uint32_t oid, const char *relname)
{
	char body[96] = { 'R' };
	int n = 1;

	be32(body + n, oid);
	n += 4;
	n += sformat(body + n, sizeof(body) - n, "public") + 1;
	n += sformat(body + n, sizeof(body) - n, "%s", relname) + 1;
	body[n++] = 'd';
	body[n++] = 0;
	body[n++] = 1;
	body[n++] = 1;
	n += sformat(body + n, sizeof(body) - n, "id") + 1;
	be32(body + n, 23);
	n += 4;
	be32(body + n, 0xFFFFFFFF);
	n += 4;

	return xlog(0, body, n);
}


static Msg
type_msg(uint32_t oid, const char *typname)
{
	char body[64] = { 'Y' };
	int n = 1;

	be32(body + n, oid);
	n += 4;
	n += sformat(body + n, sizeof(body) - n, "public") + 1;
	n += sformat(body + n, sizeof(body) - n, "%s", typname) + 1;

	return xlog(0, body, n);
}


/* a relation log record as the format defines it */
static uint64_t
relation_raw(char *buf, uint64_t seq, uint64_t changes, const char *message,
			 uint32_t length)
{
	be64(buf, seq);
	be64(buf + 8, changes);
	be32(buf + 16, length);
	memcpy(buf + 20, message, length);
	be32(buf + 20 + length, spool_crc32c(buf, 20 + (size_t) length));

	return SPOOL_RELATION_RECORD_SIZE(length);
}


/* the same, of the pgoutput part of msg */
static uint64_t
relation_record(char *buf, uint64_t seq, uint64_t changes, const Msg *msg)
{
	return relation_raw(buf, seq, changes,
						msg->bytes + SPOOL_XLOGDATA_HEADER_SIZE,
						msg->length - SPOOL_XLOGDATA_HEADER_SIZE);
}


typedef struct Logged
{
	uint64_t seq;
	uint64_t changes;
	Msg msg;
} Logged;


/* syncs the relation log, then compares it with the records of logged */
static bool
log_holds(SpoolWriter *writer, const Logged *logged, int n)
{
	static char want[16 * 1024];
	uint64_t wantSize = 0;
	uint64_t size = 0;

	for (int i = 0; i < n; i++)
	{
		wantSize += relation_record(want + wantSize, logged[i].seq,
									logged[i].changes, &logged[i].msg);
	}

	char *bytes = spool_sync(&writer->relationLog) ?
				  slurp(writer->relationLog.filename, &size) : NULL;

	return bytes != NULL && size == wantSize && memcmp(bytes, want, size) == 0;
}


static void
test_relation_record(void)
{
	Msg rel = relation_msg(16384, "a");
	char buf[256];
	SpoolRelationRecord record = { 0 };
	uint32_t length = rel.length - SPOOL_XLOGDATA_HEADER_SIZE;
	uint64_t size = relation_record(buf, 0x0102030405060708,
									0x1112131415161718, &rel);

	check(spool_relation_decode(buf, size, &record) == SPOOL_FRAME_OK &&
		  record.seq == 0x0102030405060708 &&
		  record.changes == 0x1112131415161718 && record.length == length &&
		  record.message == buf + SPOOL_RELATION_HEADER_SIZE &&
		  memcmp(record.message, rel.bytes + SPOOL_XLOGDATA_HEADER_SIZE,
				 length) == 0,
		  "a relation log record decodes to its position and its message");

	/* the bytes after the cut are 0xFF, so a read past it reads a bad length */
	static char cutBuf[256];
	bool ok = true;

	for (uint64_t cut = 0; cut < size; cut++)
	{
		memset(cutBuf, 0xFF, sizeof(cutBuf));
		memcpy(cutBuf, buf, cut);
		ok = ok && spool_relation_decode(cutBuf, cut, &record) == SPOOL_FRAME_SHORT;
	}
	check(ok, "a relation log record cut at any byte is short");

	ok = true;

	for (uint64_t bit = 0; bit < size * 8; bit++)
	{
		buf[bit / 8] ^= (char) (1 << (bit % 8));
		ok = ok && spool_relation_decode(buf, size, &record) != SPOOL_FRAME_OK;
		buf[bit / 8] ^= (char) (1 << (bit % 8));
	}
	check(ok, "a relation log record with any one bit flipped is not valid");

	be32(buf + 16, SPOOL_MESSAGE_MAX + 1);
	check(spool_relation_decode(buf, size, &record) == SPOOL_FRAME_BAD,
		  "a relation log record longer than any message is invalid, not short");

	Msg other = rel;

	other.bytes[SPOOL_XLOGDATA_HEADER_SIZE] = 'I';
	size = relation_record(buf, 1, 0, &other);
	check(spool_relation_decode(buf, size, &record) == SPOOL_FRAME_BAD,
		  "a relation log record of another message type is invalid");

	other = rel;
	other.length = SPOOL_XLOGDATA_HEADER_SIZE + 4;
	size = relation_record(buf, 1, 0, &other);
	check(spool_relation_decode(buf, size, &record) == SPOOL_FRAME_BAD,
		  "a relation log record too short for an OID is invalid");
}


static void
test_relation_log(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0xB000, .lastEndLSN = 0xB030
	};
	SpoolWriter writer = { 0 };
	SpoolWriter other = { 0 };
	Msg relA = relation_msg(16384, "a");
	Msg relB = relation_msg(16384, "b");
	Msg relOther = relation_msg(16385, "a");
	Msg typeA = type_msg(16384, "a");
	Msg longer = relA;

	longer.bytes[longer.length++] = 'x';

	/* the records that the relation log holds once the checks below ran */
	Logged logged[] = {
		{ 5, 2, relA },
		{ 7, 0, relB },
		{ 8, 0, relA },
		{ 8, 0, typeA },
		{ 9, 0, relOther },
		{ 10, 1, longer },
		{ 11, 0, relB }
	};

	Msg first[] = {
		begin_msg(0xB110, 0xB100, 950),
		other_msg(0xB110, 'I'),
		other_msg(0xB120, 'U'),
		relA,
		other_msg(0xB130, 'I'),
		commit_msg(0xB150, 0xB100, 0xB150, 50)
	};

	bool fed = new_writer(&writer, dir, &header, 0) &&
			   feed(&writer, first, lengthof(first));

	check(fed && log_holds(&writer, logged, 1),
		  "a RELATION is logged unchanged, with the sequence number of its transaction and the count of changes before it");

	Msg same[] = {
		begin_msg(0xB210, 0xB200, 951),
		relA,
		other_msg(0xB210, 'I'),
		commit_msg(0xB250, 0xB200, 0xB250, 51)
	};

	fed = fed && feed(&writer, same, lengthof(same));
	check(fed && records(&writer) == 2 && log_holds(&writer, logged, 1),
		  "a RELATION byte-identical to the last one logged for its relation is not logged again");

	Msg changed[] = {
		begin_msg(0xB310, 0xB300, 952),
		relB,
		other_msg(0xB310, 'I'),
		commit_msg(0xB350, 0xB300, 0xB350, 52)
	};

	fed = fed && feed(&writer, changed, lengthof(changed));
	check(fed && records(&writer) == 3 && log_holds(&writer, logged, 2),
		  "a changed definition of a relation is logged");

	/* sent again after a reconnect, with the definition before the change */
	uint64_t end = writer.segment.size + writer.segment.blockLength;

	fed = fed && feed(&writer, same, lengthof(same));
	check(fed && records(&writer) == 3 &&
		  writer.segment.size + writer.segment.blockLength == end &&
		  log_holds(&writer, logged, 3),
		  "a RELATION inside a transaction sent again is logged at the position of the next transaction");

	Msg kinds[] = {
		begin_msg(0xB410, 0xB400, 953),
		typeA,
		relA,
		other_msg(0xB410, 'I'),
		commit_msg(0xB450, 0xB400, 0xB450, 53)
	};

	fed = fed && feed(&writer, kinds, lengthof(kinds));
	check(fed && log_holds(&writer, logged, 4),
		  "a TYPE and a RELATION with the same OID each keep their last message");

	Msg oids[] = {
		begin_msg(0xB510, 0xB500, 954),
		relOther,
		relA,
		other_msg(0xB510, 'I'),
		commit_msg(0xB550, 0xB500, 0xB550, 54)
	};

	fed = fed && feed(&writer, oids, lengthof(oids));
	check(fed && log_holds(&writer, logged, 5),
		  "two relations keep one last message each");

	Msg extended[] = {
		begin_msg(0xB610, 0xB600, 955),
		other_msg(0xB610, 'I'),
		longer,
		commit_msg(0xB650, 0xB600, 0xB650, 55)
	};

	fed = fed && feed(&writer, extended, lengthof(extended));
	check(fed && log_holds(&writer, logged, 6),
		  "a RELATION that extends the last one logged for its relation is logged");

	/* a start on the same log, as after a restart */
	SpoolHeader later = {
		.firstSeq = 11, .lastFinalLSN = 0xB600, .lastEndLSN = 0xB650
	};
	SpoolWriter restarted = { 0 };
	Msg restart[] = {
		begin_msg(0xB710, 0xB700, 956),
		longer,
		typeA,
		relOther,
		relB,
		other_msg(0xB710, 'I'),
		commit_msg(0xB750, 0xB700, 0xB750, 56)
	};

	fed = fed && spool_writer_create(&restarted, writer.dirname, &later, 0) &&
		  feed(&restarted, restart, lengthof(restart));
	check(fed && log_holds(&restarted, logged, 7),
		  "a writer started on a relation log logs only the definitions that differ from the last ones in it");

	struct stat st;

	check(fed && stat(restarted.relationLog.filename, &st) == 0 &&
		  restarted.relationLog.synced == (uint64_t) st.st_size,
		  "a writer started on a relation log syncs it at its whole length");

	Msg shortRel = relA;

	shortRel.length = SPOOL_XLOGDATA_HEADER_SIZE + 4;
	check(new_writer(&other, dir, &header, 0) && feed(&other, first, 1) &&
		  !feed(&other, &shortRel, 1),
		  "a RELATION too short for its OID is an error");

	char path[MAXPGPATH];
	long mark = log_mark();
	bool created = new_writer(&other, dir, &header, 0);
	char *text = logged_since(mark);

	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, other.dirname);
	check(created && count(text, "Synced spool directory") == 2 &&
		  stat(path, &st) == 0 && st.st_size == 0,
		  "a new writer creates an empty relation log and syncs the directory after it");

	/* the closed log refuses the record */
	fsyncFailures = 1;
	bool closed = created && !spool_sync(&other.relationLog) &&
				  other.relationLog.fd == -1;
	fsyncFailures = 0;

	check(closed && feed(&other, first, 1) && !feed(&other, &relA, 1),
		  "a RELATION that the closed relation log refuses is an error");

	/* the list of last messages grows past the 256 bytes it starts with */
	fed = new_writer(&other, dir, &header, 0) && feed(&other, first, 1);
	reallocFailures = 1;
	bool kept = fed;

	for (uint32_t oid = 20000; kept && oid < 20020; oid++)
	{
		Msg rel = relation_msg(oid, "a");

		kept = feed(&other, &rel, 1);
	}

	bool injected = reallocFailures == 0;

	reallocFailures = 0;

	check(fed && injected && !kept,
		  "a definition that cannot be kept in memory is an error");

	/* above the 256 bytes that a new PQExpBuffer holds */
	static char big[SPOOL_XLOGDATA_HEADER_SIZE + 400] = { 'w' };

	big[SPOOL_XLOGDATA_HEADER_SIZE] = 'R';
	be32(big + SPOOL_XLOGDATA_HEADER_SIZE + 1, 16384);

	fed = new_writer(&other, dir, &header, 0) && feed(&other, first, 1) &&
		  feed(&other, &relA, 1);
	reallocFailures = 1;
	kept = fed && spool_writer_message(&other, big, sizeof(big));
	reallocFailures = 0;

	check(fed && !kept,
		  "a changed definition that cannot be kept in memory is an error");

	/* a log that ends inside a record, which the start cut removes first */
	char name[MAXPGPATH];
	char line[2 * MAXPGPATH];
	char bytes[256];
	uint64_t size = relation_record(bytes, 5, 0, &relA);
	SpoolWriter torn = { 0 };
	int fd = -1;

	sformat(name, sizeof(name), "%s/torn", dir);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);
	sformat(line, sizeof(line),
			"Spool file \"%s\" ends inside a record at offset %" PRIu64,
			path, size);

	bool ready = mkdir(name, 0700) == 0 &&
				 (fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644)) >= 0 &&
				 write(fd, bytes, size + 3) == (ssize_t) (size + 3);

	if (fd >= 0)
	{
		(void) close(fd);
	}

	mark = log_mark();
	created = ready && spool_writer_create(&torn, name, &header, 0);

	check(ready && !created && one_line(logged_since(mark), " ERROR ", line) &&
		  torn.segment.fd == -1 && torn.relationLog.fd == -1,
		  "a writer refuses a relation log that ends inside a record, and closes its files");

	/* zeroes between two records, as a torn write leaves them */
	SpoolWriter damaged = { 0 };

	memset(bytes + size, 0, 24);
	size += 24 + relation_record(bytes + size + 24, 7, 0, &relB);
	sformat(name, sizeof(name), "%s/damaged", dir);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);
	fd = -1;
	ready = mkdir(name, 0700) == 0 &&
			(fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644)) >= 0 &&
			write(fd, bytes, size) == (ssize_t) size;

	if (fd >= 0)
	{
		(void) close(fd);
	}

	check(ready && !spool_writer_create(&damaged, name, &header, 0) &&
		  damaged.segment.fd == -1,
		  "a writer refuses a damaged relation log");

	/* above the 256 bytes that a new PQExpBuffer holds */
	static char wide[400];
	static char wideBody[300] = { 'R' };
	SpoolWriter oom = { 0 };

	be32(wideBody + 1, 16384);
	size = relation_raw(wide, 5, 0, wideBody, sizeof(wideBody));
	sformat(name, sizeof(name), "%s/oom", dir);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);
	fd = -1;
	ready = mkdir(name, 0700) == 0 &&
			(fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644)) >= 0 &&
			write(fd, wide, size) == (ssize_t) size;

	if (fd >= 0)
	{
		(void) close(fd);
	}

	reallocFailures = 1;
	created = ready && spool_writer_create(&oom, name, &header, 0);
	injected = reallocFailures == 0;
	reallocFailures = 0;

	check(ready && injected && !created,
		  "a writer that cannot keep the definitions of its relation log in memory fails");

	SpoolWriter unread = { 0 };

	fopenFailures = 1;
	created = new_writer(&unread, dir, &header, 0);
	injected = fopenFailures == 0;
	fopenFailures = 0;

	check(injected && !created && unread.segment.fd == -1,
		  "a writer that cannot read its relation log fails");

	SpoolWriter blocked = { 0 };

	sformat(name, sizeof(name), "%s/blocked", dir);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);
	sformat(line, sizeof(line),
			"Failed to open spool file \"%s\": Is a directory", path);

	ready = mkdir(name, 0700) == 0 && mkdir(path, 0700) == 0;
	mark = log_mark();
	created = ready && spool_writer_create(&blocked, name, &header, 0);

	check(ready && !created && one_line(logged_since(mark), " ERROR ", line) &&
		  blocked.segment.fd == -1 && blocked.held.data == NULL,
		  "a writer whose relation log cannot be opened fails and closes its segment");
}


/* a directory under dir that holds a relation log of the given bytes */
static bool
make_log(char *name, const char *dir, const char *bytes, uint64_t size)
{
	static int logs = 0;
	char path[MAXPGPATH];

	sformat(name, MAXPGPATH, "%s/cursor%d", dir, ++logs);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);

	int fd = mkdir(name, 0700) == 0 ?
			 open(path, O_WRONLY | O_CREAT | O_EXCL, 0644) : -1;
	bool written = fd >= 0 && write(fd, bytes, size) == (ssize_t) size;

	if (fd >= 0)
	{
		(void) close(fd);
	}

	return written;
}


/* the name that the relation cache holds for oid, "" when none */
static const char *
cached(StreamContext *context, uint32_t oid)
{
	PgoutputRelationCache *rel = NULL;

	HASH_FIND_INT(context->pgoutputRelationCache, &oid, rel);

	return rel != NULL ? rel->relname : "";
}


static bool
advanced_to(SpoolRelationCursor *cursor, uint64_t seq, uint64_t changes,
			StreamContext *context, const char *relname)
{
	return spool_relation_cursor_advance(cursor, seq, changes, context) &&
		   strcmp(cached(context, 16384), relname) == 0;
}


static void
test_relation_cursor(const char *dir)
{
	static char log[4096];
	char name[MAXPGPATH];
	char path[MAXPGPATH];
	Msg a = relation_msg(16384, "a");
	Msg b = relation_msg(16384, "b");
	Msg c = relation_msg(16384, "c");
	StreamContext context = { 0 };
	SpoolRelationCursor cursor = { 0 };
	uint64_t size = relation_record(log, 5, 0, &a);

	size += relation_record(log + size, 7, 2, &b);
	size += relation_record(log + size, 9, 0, &c);

	bool opened = make_log(name, dir, log, size) &&
				  spool_relation_cursor_open(&cursor, name) && cursor.count == 3;

	check(opened && advanced_to(&cursor, 5, 0, &context, "a") &&
		  cursor.pendingSeq == 7 && cursor.pendingChanges == 2 &&
		  advanced_to(&cursor, 7, 1, &context, "a"),
		  "a record is applied at its own position, and not before it");
	check(opened && advanced_to(&cursor, 7, 2, &context, "b"),
		  "a changed definition replaces the cached one at its position");
	check(opened && advanced_to(&cursor, 8, 100, &context, "b") &&
		  advanced_to(&cursor, 9, 0, &context, "c") &&
		  advanced_to(&cursor, 12, 0, &context, "c"),
		  "a lookup at a position returns the last record at or below it");
	spool_relation_cursor_close(&cursor);

	/* as after a transaction cut off and sent again */
	StreamContext resent = { 0 };
	Msg x = relation_msg(16384, "x");
	Msg y = relation_msg(16384, "y");

	size = relation_record(log, 5, 3, &x);
	size += relation_record(log + size, 5, 1, &y);
	opened = make_log(name, dir, log, size) &&
			 spool_relation_cursor_open(&cursor, name);

	check(opened && advanced_to(&cursor, 5, 1, &resent, "y"),
		  "a record logged after one with a higher position is applied at its own position");
	check(opened && advanced_to(&cursor, 5, 3, &resent, "y"),
		  "a record logged after one with a higher position stays the last one");
	spool_relation_cursor_close(&cursor);

	StreamContext typed = { 0 };
	Msg t = type_msg(16384, "t");

	size = relation_record(log, 5, 0, &a);
	size += relation_record(log + size, 5, 1, &t);
	opened = make_log(name, dir, log, size) &&
			 spool_relation_cursor_open(&cursor, name);

	check(opened && advanced_to(&cursor, 5, 1, &typed, "a"),
		  "a TYPE record leaves the relation cache as it is");
	spool_relation_cursor_close(&cursor);

	StreamContext two = { 0 };
	Msg z = relation_msg(16385, "z");

	size = relation_record(log, 5, 3, &a);
	size += relation_record(log + size, 5, 1, &z);
	opened = make_log(name, dir, log, size) &&
			 spool_relation_cursor_open(&cursor, name);

	check(opened && advanced_to(&cursor, 5, 1, &two, "") &&
		  advanced_to(&cursor, 5, 3, &two, "a"),
		  "a record of another relation logged after a record does not hide it");
	spool_relation_cursor_close(&cursor);

	/* a mark in the cached entry shows whether a later scan replaced it */
	StreamContext marked = { 0 };
	PgoutputRelationCache *rel = NULL;
	uint32_t markOid = 16384;

	size = relation_record(log, 5, 0, &a);
	size += relation_record(log + size, 6, 0, &z);
	opened = make_log(name, dir, log, size) &&
			 spool_relation_cursor_open(&cursor, name) &&
			 advanced_to(&cursor, 5, 0, &marked, "a");

	HASH_FIND_INT(marked.pgoutputRelationCache, &markOid, rel);

	if (rel != NULL)
	{
		sformat(rel->relname, sizeof(rel->relname), "mark");
	}

	check(opened && rel != NULL && advanced_to(&cursor, 6, 0, &marked, "mark"),
		  "a record already applied is not applied again");
	spool_relation_cursor_close(&cursor);

	StreamContext broken = { 0 };
	Msg unparsed = a;

	unparsed.length = SPOOL_XLOGDATA_HEADER_SIZE + 5;
	size = relation_record(log, 5, 0, &unparsed);
	opened = make_log(name, dir, log, size) &&
			 spool_relation_cursor_open(&cursor, name);

	check(opened && !spool_relation_cursor_advance(&cursor, 5, 0, &broken),
		  "a RELATION record that does not parse fails the cursor");
	spool_relation_cursor_close(&cursor);

	/* the log ends inside the second record, which arrives later */
	StreamContext growing = { 0 };
	uint64_t whole = relation_record(log, 5, 0, &a);

	size = whole + relation_record(log + whole, 7, 0, &b);
	opened = make_log(name, dir, log, whole + 10) &&
			 spool_relation_cursor_open(&cursor, name);

	check(opened && cursor.count == 1 && cursor.size == whole &&
		  cursor.tail == 10 && advanced_to(&cursor, 7, 0, &growing, "a"),
		  "a record cut off at the end of the log is not read");

	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);

	int fd = open(path, O_WRONLY | O_APPEND);
	ssize_t rest = (ssize_t) (size - whole - 10);
	bool appended = fd >= 0 && write(fd, log + whole + 10, rest) == rest;

	if (fd >= 0)
	{
		(void) close(fd);
	}

	check(opened && appended && spool_relation_cursor_read(&cursor) &&
		  cursor.count == 2 && cursor.tail == 0 &&
		  advanced_to(&cursor, 7, 0, &growing, "b"),
		  "a record cut off at the end of the log is read once it is whole");

	char line[2 * MAXPGPATH];
	long mark = log_mark();

	sformat(line, sizeof(line), "Spool file \"%s\" has %" PRIu64 " bytes", path,
			whole);
	check(opened && truncate(path, (off_t) whole) == 0 &&
		  !spool_relation_cursor_read(&cursor) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a relation log shorter than what the cursor read is an error");
	spool_relation_cursor_close(&cursor);

	/* zeroes between two records, as a torn write leaves them */
	size = relation_record(log, 5, 0, &a);
	memset(log + size, 0, 24);
	size += 24;
	size += relation_record(log + size, 7, 0, &b);
	opened = make_log(name, dir, log, size);
	sformat(path, sizeof(path), "%s/" SPOOL_RELATION_LOG, name);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid relation log record at offset %" PRIu64,
			path, whole);
	mark = log_mark();

	check(opened && !spool_relation_cursor_open(&cursor, name) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a damaged record fails the cursor with an ERROR line that names the file and the offset");
	spool_relation_cursor_close(&cursor);

	sformat(name, sizeof(name), "%s/nolog", dir);
	check(mkdir(name, 0700) == 0 && !spool_relation_cursor_open(&cursor, name),
		  "a cursor on a directory without a relation log fails");
	spool_relation_cursor_close(&cursor);

	char longDir[MAXPGPATH];

	memset(longDir, 'd', sizeof(longDir));
	longDir[0] = '/';
	longDir[MAXPGPATH - 10] = '\0';
	sformat(line, sizeof(line), "Spool file name \"%s/" SPOOL_RELATION_LOG
			"\" is too long", longDir);
	mark = log_mark();

	check(!spool_relation_cursor_open(&cursor, longDir) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a cursor whose relation log name does not fit fails with an ERROR line");
	spool_relation_cursor_close(&cursor);

	/* the list of records grows past the 256 bytes it starts with */
	size = 0;

	for (uint32_t oid = 20000; oid < 20020; oid++)
	{
		Msg rel = relation_msg(oid, "a");

		size += relation_record(log + size, 5, 0, &rel);
	}

	opened = make_log(name, dir, log, size);
	reallocFailures = 1;
	bool loaded = opened && spool_relation_cursor_open(&cursor, name);
	bool injected = reallocFailures == 0;

	reallocFailures = 0;

	check(opened && injected && !loaded,
		  "a record that cannot be kept in memory fails the cursor");
	check(cursor.count * sizeof(SpoolRelationEntry) <= cursor.entries.len,
		  "a cursor that cannot keep its records counts none");

	StreamContext lost = { 0 };

	check(opened && !spool_relation_cursor_advance(&cursor, 5, 0, &lost),
		  "a cursor that could not keep its records refuses to advance");
	spool_relation_cursor_close(&cursor);
}


/* on the one-page volume, once test_disk_full removed its segment */
static void
test_relation_log_full(const char *dir)
{
	SpoolHeader header = {
		.firstSeq = 5, .lastFinalLSN = 0xC000, .lastEndLSN = 0xC030
	};
	SpoolWriter writer = { 0 };
	Msg begin = begin_msg(0xC110, 0xC100, 960);
	char line[2 * MAXPGPATH];

	/* a RELATION whose record does not fit in the write block */
	static char huge[SPOOL_XLOGDATA_HEADER_SIZE + SPOOL_BLOCK_SIZE] = { 'w' };

	huge[SPOOL_XLOGDATA_HEADER_SIZE] = 'R';
	be32(huge + SPOOL_XLOGDATA_HEADER_SIZE + 1, 16384);

	bool fed = new_writer(&writer, dir, &header, 0) && feed(&writer, &begin, 1);

	sformat(line, sizeof(line),
			"Failed to write to spool file \"%s\": No space left on device",
			writer.relationLog.filename);

	long mark = log_mark();
	bool logged = fed && spool_writer_message(&writer, huge, sizeof(huge));

	/* the frame of the RELATION would fill the segment too, so it must not follow */
	check(fed && !logged && one_line(logged_since(mark), " ERROR ", line) &&
		  writer.segment.fd >= 0,
		  "a RELATION that the full volume refuses is an error that names the relation log, and its frame is not appended");

	/* the strace run of run.sh uses the volume again */
	(void) unlink(writer.segment.filename);
	(void) unlink(writer.relationLog.filename);
	(void) rmdir(writer.dirname);
}


/* the spool of the start and reader checks: three transactions after 0/D030 */
static const SpoolHeader spoolHeader = {
	.firstSeq = 5, .systemId = 7, .timeline = 2,
	.lastFinalLSN = 0xD000, .lastEndLSN = 0xD030
};
static Msg firstTxn[4];
static Msg secondTxn[3];
static Msg thirdTxn[3];


static void
init_spool_messages(void)
{
	firstTxn[0] = begin_msg(0xD010, 0xD100, 970);
	firstTxn[1] = relation_msg(16384, "a");
	firstTxn[2] = other_msg(0xD010, 'I');
	firstTxn[3] = commit_msg(0xD130, 0xD100, 0xD130, 70);

	secondTxn[0] = begin_msg(0xD150, 0xD200, 971);
	secondTxn[1] = other_msg(0xD150, 'U');
	secondTxn[2] = commit_msg(0xD230, 0xD200, 0xD230, 71);

	thirdTxn[0] = begin_msg(0xD250, 0xD300, 972);
	thirdTxn[1] = other_msg(0xD250, 'D');
	thirdTxn[2] = commit_msg(0xD330, 0xD300, 0xD330, 72);
}


/* where the first and the second transaction end in their segment */
#define FIRST_END (SPOOL_HEADER_SIZE + frames_size(firstTxn, lengthof(firstTxn)))
#define SECOND_END (FIRST_END + frames_size(secondTxn, lengthof(secondTxn)))


static char *
spool_file(char *path, const char *dir, uint64_t seq, const char *suffix)
{
	sformat(path, MAXPGPATH, "%s/%016" PRIX64 "%s", dir, seq, suffix);

	return path;
}


static int64_t
file_size(const char *path)
{
	struct stat st;

	return stat(path, &st) == 0 ? (int64_t) st.st_size : -1;
}


/* writes bytes at offset, or after the end of the file for offset -1 */
static bool
put_bytes(const char *path, int64_t offset, const char *bytes, size_t size)
{
	int fd = open(path, O_WRONLY | O_CREAT | (offset < 0 ? O_APPEND : 0), 0644);
	ssize_t written = fd < 0 ? -1 :
					  offset < 0 ? write(fd, bytes, size) :
					  pwrite(fd, bytes, size, (off_t) offset);

	if (fd >= 0)
	{
		(void) close(fd);
	}

	return written == (ssize_t) size;
}


static bool
flip_byte(const char *path, uint64_t offset)
{
	char byte = 0;
	int fd = open(path, O_RDONLY);
	bool read = fd >= 0 && pread(fd, &byte, 1, (off_t) offset) == 1;

	if (fd >= 0)
	{
		(void) close(fd);
	}

	byte ^= 1;

	return read && put_bytes(path, (int64_t) offset, &byte, 1);
}


/*
 * The flush of receive up to the sync of the index file, which F8 adds: the
 * segment and the relation log are synced, and the records in memory get the
 * synced length of the log and are appended to the index file of the segment.
 */
static bool
write_index(SpoolWriter *writer)
{
	char path[MAXPGPATH];
	PQExpBuffer pending = &writer->pendingIndex;
	bool written = spool_sync(&writer->segment) && spool_sync(&writer->relationLog);

	for (size_t at = 0; written && at < pending->len; at += SPOOL_INDEX_RECORD_SIZE)
	{
		SpoolIndexRecord record = { 0 };

		written = spool_index_decode(pending->data + at, SPOOL_INDEX_RECORD_SIZE,
									 &record);
		record.relationLogEnd = writer->relationLog.synced;
		spool_index_encode(&record, pending->data + at);
	}

	written = written &&
			  put_bytes(spool_file(path, writer->dirname, writer->header.firstSeq,
								   ".idx"),
						-1, pending->data, pending->len);

	resetPQExpBuffer(pending);

	return written;
}


/* closes the files of a writer, as a kill does */
static void
kill_writer(SpoolWriter *writer)
{
	(void) close(writer->segment.fd);
	(void) close(writer->relationLog.fd);
	writer->segment.fd = -1;
	writer->relationLog.fd = -1;
}


/* the writer of receive_overtakes */
static SpoolWriter *racing = NULL;

/* receive indexes its open segment and rotates, between two calls of a reader */
static void
receive_overtakes(void)
{
	(void) (write_index(racing) && spool_writer_rotate(racing));
}


/* the first two transactions in one indexed segment, as a kill leaves them */
static bool
make_spool(SpoolWriter *writer, const char *dir)
{
	bool made = new_writer(writer, dir, &spoolHeader, 0) &&
				feed(writer, firstTxn, lengthof(firstTxn)) &&
				feed(writer, secondTxn, lengthof(secondTxn)) &&
				write_index(writer);

	kill_writer(writer);

	return made;
}


/* the same, rotated after them, and the third transaction indexed when asked */
static bool
make_rotated(SpoolWriter *writer, const char *dir, bool third)
{
	bool made = new_writer(writer, dir, &spoolHeader, 50) &&
				feed(writer, firstTxn, lengthof(firstTxn)) &&
				feed(writer, secondTxn, lengthof(secondTxn)) &&
				write_index(writer) && spool_writer_rotate(writer) &&
				(!third ||
				 (feed(writer, thirdTxn, lengthof(thirdTxn)) && write_index(writer)));

	kill_writer(writer);

	return made;
}


static char *
sync_line(const char *path, uint64_t length)
{
	static char lines[4][2 * MAXPGPATH];
	static int next = 0;
	char *line = lines[next++ % 4];

	sformat(line, 2 * MAXPGPATH, "Synced spool file \"%s\" at %" PRIu64 " bytes",
			path, length);

	return line;
}


/* reads the next record, and true when its frames are msgs */
static bool
next_holds(SpoolReader *reader, StreamContext *context, const Msg *msgs, int n)
{
	const char *message = NULL;
	uint32_t length = 0;
	bool found = false;
	bool done = false;

	if (!spool_reader_next(reader, &found) || !found)
	{
		return false;
	}

	for (int i = 0; i < n; i++)
	{
		if (!spool_reader_frame(reader, context, &message, &length, &done) || done ||
			length != msgs[i].length || memcmp(message, msgs[i].bytes, length) != 0)
		{
			return false;
		}
	}

	return spool_reader_frame(reader, context, &message, &length, &done) && done;
}


typedef struct Txn
{
	const Msg *msgs;
	int n;
} Txn;


/* true when a reader of dir after end LSN after returns txns, then waits */
static bool
reader_holds(const char *dir, uint64_t after, const Txn *txns, int n)
{
	SpoolReader reader = { 0 };
	StreamContext context = { 0 };
	bool found = true;
	bool held = spool_reader_open(&reader, dir, after);

	for (int i = 0; held && i < n; i++)
	{
		held = next_holds(&reader, &context, txns[i].msgs, txns[i].n);
	}

	held = held && spool_reader_next(&reader, &found) && !found;
	spool_reader_close(&reader);

	return held;
}


static void
test_writer_open(const char *dir)
{
	SpoolWriter writer = { 0 };
	SpoolWriter opened = { 0 };
	SpoolHeader read = { 0 };
	SpoolIndexRecord record = { 0 };
	Txn all[] = {
		{ firstTxn, 4 }, { secondTxn, 3 }, { thirdTxn, 3 }
	};
	char name[MAXPGPATH];
	char path[MAXPGPATH];
	uint64_t size = 0;

	sformat(name, sizeof(name), "%s/fresh", dir);

	bool created = mkdir(name, 0700) == 0 && spool_writer_open(&opened, name, 7, 2, 0);
	char *bytes = created ?
				  slurp(spool_file(path, name, SPOOL_FIRST_SEQ, ".seg"), &size) : NULL;

	check(created && bytes != NULL && size == SPOOL_HEADER_SIZE &&
		  spool_header_decode(bytes, size, &read) &&
		  read.firstSeq == SPOOL_FIRST_SEQ && read.systemId == 7 &&
		  read.timeline == 2 && read.lastFinalLSN == 0 && read.lastEndLSN == 0 &&
		  opened.nextSeq == SPOOL_FIRST_SEQ && opened.lastEndLSN == 0,
		  "a writer opened on an empty directory starts a new spool at sequence number 1, whose header carries final_lsn and end LSN 0");
	kill_writer(&opened);

	bool made = make_spool(&writer, dir);
	long mark = log_mark();
	bool reopened = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	char *text = logged_since(mark);

	check(reopened && opened.nextSeq == 7 && opened.lastFinalLSN == 0xD200 &&
		  opened.lastEndLSN == 0xD230 && opened.completeSize == SECOND_END &&
		  opened.segment.size == SECOND_END &&
		  strcmp(opened.segment.filename,
				 spool_file(path, writer.dirname, 5, ".seg")) == 0,
		  "a writer opened on a spool continues after its last indexed transaction, with the final_lsn and end LSN of its record");
	check(reopened &&
		  strstr(text, sync_line(spool_file(path, writer.dirname, 5, ".idx"),
								 2 * SPOOL_INDEX_RECORD_SIZE)) != NULL,
		  "a writer opened on a spool syncs the index file it keeps, so that the end LSN it returns is durable");

	bool appended = reopened &&
					feed(&opened, secondTxn, lengthof(secondTxn)) &&
					records(&opened) == 0 &&
					feed(&opened, thirdTxn, lengthof(thirdTxn)) &&
					record_at(&opened, 0, &record) && record.seq == 7 &&
					record.beginOffset == SECOND_END && write_index(&opened);

	check(appended && reader_holds(writer.dirname, 0, all, lengthof(all)),
		  "a writer opened on a spool skips its last transaction sent again and appends the next one after it");
	kill_writer(&opened);

	/* the start synced the segment, so a rotation can follow at once */
	made = new_writer(&writer, dir, &spoolHeader, 50) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) && write_index(&writer);
	kill_writer(&writer);

	bool rotated = made && spool_writer_open(&opened, writer.dirname, 7, 2, 50) &&
				   spool_writer_rotate_due(&opened) && spool_writer_rotate(&opened);

	check(rotated && file_size(spool_file(path, writer.dirname, 6, ".seg")) ==
		  SPOOL_HEADER_SIZE,
		  "a writer opened on a spool past its limit can rotate before it appends");

	bytes = rotated ? slurp(spool_file(path, writer.dirname, 6, ".seg"), &size) : NULL;

	check(bytes != NULL && spool_header_decode(bytes, size, &read) &&
		  read.firstSeq == 6 && read.systemId == 7 && read.timeline == 2 &&
		  read.lastFinalLSN == 0xD100 && read.lastEndLSN == 0xD130,
		  "a rotation after a start writes the source system, timeline and last transaction into the new header");
	kill_writer(&opened);
}


static void
test_start_cut(const char *dir)
{
	SpoolWriter writer = { 0 };
	SpoolWriter opened = { 0 };
	SpoolHeader read = { 0 };
	Txn all[] = {
		{ firstTxn, 4 }, { secondTxn, 3 }, { thirdTxn, 3 }
	};
	char seg[MAXPGPATH];
	char idx[MAXPGPATH];
	char log[MAXPGPATH];
	char line[2 * MAXPGPATH];
	char dirLine[2 * MAXPGPATH];
	char zeroes[64] = { 0 };
	char record[SPOOL_INDEX_RECORD_SIZE];
	char junk[40];
	uint64_t size = 0;

	memset(junk, 0xFF, sizeof(junk));

	/* a power loss leaves zeroes and part of a record after the last one */
	SpoolIndexRecord any = { .seq = 7, .endOffset = 1 };

	spool_index_encode(&any, record);

	bool made = make_spool(&writer, dir) &&
				put_bytes(spool_file(idx, writer.dirname, 5, ".idx"), -1, zeroes, 64) &&
				put_bytes(idx, -1, record, 30);
	long mark = log_mark();
	bool started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	char *text = logged_since(mark);

	check(started && file_size(idx) == 2 * SPOOL_INDEX_RECORD_SIZE &&
		  strstr(text, sync_line(idx, 2 * SPOOL_INDEX_RECORD_SIZE)) != NULL &&
		  opened.nextSeq == 7,
		  "the start cuts the invalid index records at the tail, and syncs the index file");
	check(started && feed(&opened, thirdTxn, lengthof(thirdTxn)) &&
		  write_index(&opened) && reader_holds(writer.dirname, 0, all, 3),
		  "after the cut of the index tail, a reader reads the next transaction");
	kill_writer(&opened);

	/* a power loss kept the page of a later record and not the one of the record before */
	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(idx, writer.dirname, 5, ".idx"), -1, zeroes, 64) &&
		   put_bytes(idx, -1, zeroes, SPOOL_INDEX_RECORD_SIZE - 64) &&
		   put_bytes(idx, -1, record, sizeof(record)) &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"), -1, junk, sizeof(junk));
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);
	made = made && put_bytes(log, -1, junk, 10);

	int64_t logBefore = file_size(log);

	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid index record at offset %d",
			idx, 2 * SPOOL_INDEX_RECORD_SIZE);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(idx) == 4 * SPOOL_INDEX_RECORD_SIZE &&
		  file_size(seg) == (int64_t) (SECOND_END + sizeof(junk)) &&
		  file_size(log) == logBefore,
		  "an invalid index record before a valid one ends the start with an error that names its offset, and nothing is cut");

	/* frames of a transaction cut off, a keepalive marker, and junk */
	static char tail[512];
	uint64_t tailSize = frame(tail, thirdTxn[0].bytes, thirdTxn[0].length);

	tailSize += frame(tail + tailSize, thirdTxn[1].bytes, thirdTxn[1].length);
	tailSize += frame(tail + tailSize, keepalive, sizeof(keepalive));

	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"), -1, tail, tailSize) &&
		   put_bytes(seg, -1, junk, sizeof(junk));
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	text = logged_since(mark);

	check(started && file_size(seg) == (int64_t) SECOND_END &&
		  strstr(text, sync_line(seg, SECOND_END)) != NULL,
		  "the start cuts the last segment at the end offset of its last index record, also past a frame that is not valid, and syncs it");
	check(started && feed(&opened, thirdTxn, lengthof(thirdTxn)) &&
		  write_index(&opened) && reader_holds(writer.dirname, 0, all, 3),
		  "after the cut of the segment tail, a reader reads the next transaction");
	kill_writer(&opened);

	made = make_spool(&writer, dir) &&
		   truncate(spool_file(seg, writer.dirname, 5, ".seg"), SECOND_END - 10) == 0;
	sformat(line, sizeof(line), "Spool file \"%s\" ends at %" PRIu64 " bytes", seg,
			SECOND_END - 10);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) SECOND_END - 10 &&
		  file_size(spool_file(idx, writer.dirname, 5, ".idx")) == 2 *
		  SPOOL_INDEX_RECORD_SIZE && opened.segment.fd == -1,
		  "a segment that ends before its last index record ends the start with an error and is not extended");

	/* a frame of the length of a COMMIT, valid, of another type */
	Msg insert = secondTxn[2];
	char other[128];

	insert.bytes[SPOOL_XLOGDATA_HEADER_SIZE] = 'I';

	uint64_t otherSize = frame(other, insert.bytes, insert.length);

	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"),
					 SECOND_END - otherSize, other, otherSize);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no COMMIT at the end of its last indexed transaction",
			seg);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) SECOND_END,
		  "a last indexed transaction that does not end with a COMMIT ends the start with an error");

	/* a bit of the UPDATE of the last transaction */
	made = make_spool(&writer, dir) &&
		   flip_byte(spool_file(seg, writer.dirname, 5, ".seg"),
					 FIRST_END + SPOOL_FRAME_SIZE(secondTxn[0].length) + 6);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid frame at offset %" PRIu64,
			seg, FIRST_END + SPOOL_FRAME_SIZE(secondTxn[0].length));
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) SECOND_END,
		  "a last indexed transaction with a damaged frame ends the start with an error");

	/* cleanup unlinked the index file of a closed segment, and was killed */
	made = make_rotated(&writer, dir, true) &&
		   unlink(spool_file(idx, writer.dirname, 5, ".idx")) == 0;
	sformat(dirLine, sizeof(dirLine), "Synced spool directory \"%s\"", writer.dirname);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	text = logged_since(mark);

	check(started && access(spool_file(seg, writer.dirname, 5, ".seg"), F_OK) != 0 &&
		  strcmp(opened.segment.filename,
				 spool_file(seg, writer.dirname, 7, ".seg")) == 0 &&
		  opened.nextSeq == 8 && count(text, dirLine) == 2,
		  "a segment file without its index file is deleted as a leftover of cleanup, and the directory synced");
	kill_writer(&opened);

	/* the CDC directory holds other files, and names that only look like ours */
	const char *others[] = {
		"origin", "0000000000000000.seg", "000000000000000G.idx",
		"0000000000000009.seg.bak", "00000000000005.idx",
		"0000000000000009.IDX"
	};

	made = make_spool(&writer, dir);

	for (int i = 0; made && i < lengthof(others); i++)
	{
		sformat(line, sizeof(line), "%s/%s", writer.dirname, others[i]);
		made = put_bytes(line, -1, "x", 1);
	}

	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	bool kept = started && opened.nextSeq == 7;

	for (int i = 0; kept && i < lengthof(others); i++)
	{
		sformat(line, sizeof(line), "%s/%s", writer.dirname, others[i]);
		kept = file_size(line) == 1;
	}

	check(kept, "files of other names in the spool directory are left alone");
	kill_writer(&opened);

	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(idx, writer.dirname, 9, ".idx"), -1, zeroes, 0);
	sformat(line, sizeof(line), "Spool index file \"%s\" has no segment file", idx);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(spool_file(seg, writer.dirname, 5, ".seg")) == (int64_t) SECOND_END,
		  "an index file without its segment file ends the start with an error");

	/* rotated, killed before the flush wrote an index file, and cleaned up */
	made = new_writer(&writer, dir, &spoolHeader, 50) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   write_index(&writer) && spool_writer_rotate(&writer) &&
		   feed(&writer, thirdTxn, 2) && spool_sync(&writer.segment);
	kill_writer(&writer);
	made = made && unlink(spool_file(idx, writer.dirname, 5, ".idx")) == 0 &&
		   unlink(spool_file(seg, writer.dirname, 5, ".seg")) == 0;
	sformat(dirLine, sizeof(dirLine), "Synced spool directory \"%s\"", writer.dirname);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	text = logged_since(mark);

	char *bytes = started ? slurp(spool_file(seg, writer.dirname, 7, ".seg"), &size) :
				  NULL;
	char *removal = strstr(text, dirLine);
	char *create = strstr(text, sync_line(seg, SPOOL_HEADER_SIZE));

	check(bytes != NULL && size == SPOOL_HEADER_SIZE &&
		  spool_header_decode(bytes, size, &read) && read.firstSeq == 7 &&
		  read.lastFinalLSN == 0xD200 && read.lastEndLSN == 0xD230 &&
		  opened.nextSeq == 7 && opened.lastFinalLSN == 0xD200 &&
		  opened.lastEndLSN == 0xD230 &&
		  removal != NULL && create != NULL && removal < create,
		  "a last segment without an index file is removed, the directory synced, and the segment created again from its header");
	kill_writer(&opened);

	made = make_spool(&writer, dir) &&
		   truncate(spool_file(idx, writer.dirname, 5, ".idx"), 30) == 0;
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	bytes = started ? slurp(spool_file(seg, writer.dirname, 5, ".seg"), &size) : NULL;

	check(bytes != NULL && size == SPOOL_HEADER_SIZE &&
		  spool_header_decode(bytes, size, &read) && read.firstSeq == 5 &&
		  read.lastEndLSN == 0xD030 && access(idx, F_OK) != 0 &&
		  opened.nextSeq == 5 && opened.lastEndLSN == 0xD030,
		  "a last segment whose index file holds no valid record is removed with it, and created again from its header");
	kill_writer(&opened);

	/* the create of the next segment was cut short before its header */
	made = make_rotated(&writer, dir, false) &&
		   truncate(spool_file(seg, writer.dirname, 7, ".seg"), 10) == 0;
	sformat(dirLine, sizeof(dirLine), "Synced spool directory \"%s\"", writer.dirname);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 50);
	text = logged_since(mark);
	removal = strstr(text, dirLine);

	char *cut = strstr(text, sync_line(spool_file(line, writer.dirname, 5, ".seg"),
									   SECOND_END));

	check(started && removal != NULL && cut != NULL && removal < cut,
		  "the start syncs the directory after it removes a torn last segment, before it cuts the segment before it");

	bool moved = started && access(seg, F_OK) != 0 &&
				 strcmp(opened.segment.filename,
						spool_file(line, writer.dirname, 5, ".seg")) == 0 &&
				 opened.nextSeq == 7 && opened.lastEndLSN == 0xD230;

	check(moved && spool_writer_rotate(&opened) &&
		  file_size(seg) == SPOOL_HEADER_SIZE,
		  "a last segment with a torn header is removed, the writer appends to the segment before it, and rotation creates the removed one again");
	kill_writer(&opened);

	made = make_rotated(&writer, dir, false) &&
		   truncate(spool_file(seg, writer.dirname, 7, ".seg"), 10) == 0 &&
		   put_bytes(spool_file(idx, writer.dirname, 7, ".idx"), -1, zeroes, 0);
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(started && access(seg, F_OK) != 0 && access(idx, F_OK) != 0 &&
		  opened.nextSeq == 7,
		  "a last segment with a torn header and an empty index file is removed with it");
	kill_writer(&opened);

	sformat(line, sizeof(line), "%s/tornfirst", dir);
	sformat(dirLine, sizeof(dirLine), "Synced spool directory \"%s\"", line);
	made = mkdir(line, 0700) == 0 &&
		   put_bytes(spool_file(seg, line, SPOOL_FIRST_SEQ, ".seg"), -1, junk, 10);
	mark = log_mark();
	started = made && spool_writer_open(&opened, line, 7, 2, 0);
	text = logged_since(mark);
	bytes = started ? slurp(seg, &size) : NULL;
	removal = strstr(text, dirLine);
	create = strstr(text, sync_line(seg, SPOOL_HEADER_SIZE));

	check(bytes != NULL && size == SPOOL_HEADER_SIZE &&
		  spool_header_decode(bytes, size, &read) &&
		  read.firstSeq == SPOOL_FIRST_SEQ && read.lastEndLSN == 0 &&
		  opened.nextSeq == SPOOL_FIRST_SEQ &&
		  removal != NULL && create != NULL && removal < create,
		  "a first segment with a torn header is removed, the directory synced, and the spool starts again");
	kill_writer(&opened);

	sformat(line, sizeof(line), "%s/tornlog", dir);
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, line);
	made = mkdir(line, 0700) == 0 &&
		   put_bytes(spool_file(seg, line, SPOOL_FIRST_SEQ, ".seg"), -1, junk, 10) &&
		   put_bytes(log, -1, junk, 10);
	started = made && spool_writer_open(&opened, line, 7, 2, 0);

	check(started && file_size(log) == 0 && opened.nextSeq == SPOOL_FIRST_SEQ,
		  "a start that begins a new spool cuts the torn tail of the relation log");
	kill_writer(&opened);

	/* cleanup removed the segment before a last one whose create was cut short */
	char first[MAXPGPATH];

	made = make_rotated(&writer, dir, false) &&
		   truncate(spool_file(seg, writer.dirname, 7, ".seg"), 10) == 0 &&
		   unlink(spool_file(idx, writer.dirname, 5, ".idx")) == 0 &&
		   unlink(spool_file(first, writer.dirname, 5, ".seg")) == 0;
	sformat(line, sizeof(line),
			"Spool file \"%s\" has no valid header, and no segment before it to continue from",
			seg);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == 10 &&
		  access(spool_file(first, writer.dirname, SPOOL_FIRST_SEQ, ".seg"), F_OK) != 0,
		  "an only segment with a torn header and a sequence number above 1 ends the start with an error that names it, and is kept");

	made = make_spool(&writer, dir) &&
		   flip_byte(spool_file(seg, writer.dirname, 5, ".seg"), 0);
	sformat(line, sizeof(line),
			"Spool file \"%s\" has no valid header, and its index file holds transactions",
			seg);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) SECOND_END &&
		  file_size(spool_file(idx, writer.dirname, 5, ".idx")) == 2 *
		  SPOOL_INDEX_RECORD_SIZE,
		  "a segment with indexed transactions and a torn header ends the start with an error");

	made = make_rotated(&writer, dir, false) &&
		   truncate(spool_file(seg, writer.dirname, 7, ".seg"), 10) == 0 &&
		   truncate(spool_file(idx, writer.dirname, 5, ".idx"), 0) == 0;
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no indexed transaction, but a segment after it was created",
			spool_file(seg, writer.dirname, 5, ".seg"));
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) SECOND_END,
		  "a segment before a removed last segment that holds no indexed transaction ends the start with an error");

	made = make_spool(&writer, dir);
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);

	int64_t logSize = file_size(log);

	made = made && logSize > 0 && put_bytes(log, -1, zeroes, 24) &&
		   put_bytes(log, -1, junk, 10);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	text = logged_since(mark);

	check(started && file_size(log) == logSize &&
		  strstr(text, sync_line(log, (uint64_t) logSize)) != NULL,
		  "the start cuts the relation log after its last valid record, and syncs it");
	kill_writer(&opened);

	/* a bit of the definition that the flush of the index records synced */
	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"), -1, junk, sizeof(junk));
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);
	logSize = file_size(log);
	made = made && logSize > 0 && flip_byte(log, SPOOL_RELATION_HEADER_SIZE + 2);
	sformat(line, sizeof(line),
			"Spool file \"%s\" ends its valid records at offset 0, before the %" PRId64
			" bytes that its index proves synced", log, logSize);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(log) == logSize &&
		  file_size(seg) == (int64_t) (SECOND_END + sizeof(junk)),
		  "a relation log whose valid records end before the length that the last index record holds ends the start with an error, and nothing is cut");

	/* the same after a rotation, killed before the first flush of the new segment */
	made = make_rotated(&writer, dir, false);
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);
	logSize = file_size(log);
	made = made && logSize > 0 && flip_byte(log, SPOOL_RELATION_HEADER_SIZE + 2);
	sformat(line, sizeof(line), "Spool file \"%s\" ends its valid records at offset 0",
			log);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 50);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(log) == logSize,
		  "a relation log damaged below the length that the index record before a removed last segment holds ends the start with an error");

	made = make_spool(&writer, dir);
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);
	made = made && unlink(log) == 0;
	sformat(line, sizeof(line),
			"Failed to open spool file \"%s\": No such file or directory", log);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  access(log, F_OK) != 0,
		  "a missing relation log of a spool whose index records hold a synced length ends the start with an error");

	/* the spool of another source, with a torn tail in the segment and in the log */
	made = make_spool(&writer, dir);
	sformat(log, sizeof(log), "%s/" SPOOL_RELATION_LOG, writer.dirname);
	logSize = file_size(log);
	made = made && logSize > 0 &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"), -1, junk,
					 sizeof(junk)) &&
		   put_bytes(log, -1, junk, 10);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds the changes of source system 7, and the source is system 8",
			seg);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 8, 2, 0);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(seg) == (int64_t) (SECOND_END + sizeof(junk)) &&
		  file_size(log) == logSize + 10,
		  "a spool of another source system ends the start with an error that names both, and nothing is cut");

	/* the same behind a torn last segment, whose removal leads to the header before it */
	made = make_rotated(&writer, dir, false) &&
		   truncate(spool_file(seg, writer.dirname, 7, ".seg"), 10) == 0 &&
		   put_bytes(spool_file(first, writer.dirname, 5, ".seg"), -1, junk,
					 sizeof(junk));
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds the changes of source system 7, and the source is system 8",
			first);
	mark = log_mark();
	started = made && spool_writer_open(&opened, writer.dirname, 8, 2, 50);

	check(made && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(first) == (int64_t) (SECOND_END + sizeof(junk)) &&
		  file_size(spool_file(idx, writer.dirname, 5, ".idx")) == 2 *
		  SPOOL_INDEX_RECORD_SIZE,
		  "a spool of another source system behind a torn last segment ends the start with an error that names both, and the segment before it is not cut");
}


/* a start whose system calls fail, or that cannot list its directory */
static void
test_start_failures(const char *dir)
{
	SpoolWriter writer = { 0 };
	SpoolWriter opened = { 0 };
	char files[3][MAXPGPATH];
	char line[2 * MAXPGPATH];
	bool ok = true;

	/* the start cuts the relation log, the segment and its index, in that order */
	for (int skip = 0; skip < 3; skip++)
	{
		bool made = make_spool(&writer, dir);

		sformat(files[0], MAXPGPATH, "%s/" SPOOL_RELATION_LOG, writer.dirname);
		spool_file(files[1], writer.dirname, 5, ".seg");
		spool_file(files[2], writer.dirname, 5, ".idx");
		sformat(line, sizeof(line), "Failed to truncate spool file \"%s\"", files[skip]);

		long mark = log_mark();

		ftruncateSkips = skip;
		ftruncateFailures = 1;
		bool started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
		bool injected = ftruncateFailures == 0;

		ftruncateFailures = 0;
		ftruncateSkips = 0;

		ok = ok && made && injected && !started &&
			 one_line(logged_since(mark), " ERROR ", line);
	}

	check(ok,
		  "a cut that cannot truncate its file fails the start with an ERROR line that names it");

	ok = true;

	for (int skip = 0; skip < 3; skip++)
	{
		bool made = make_spool(&writer, dir);

		sformat(files[0], MAXPGPATH, "%s/" SPOOL_RELATION_LOG, writer.dirname);
		spool_file(files[1], writer.dirname, 5, ".seg");
		spool_file(files[2], writer.dirname, 5, ".idx");
		sformat(line, sizeof(line), "Failed to sync spool file \"%s\"", files[skip]);

		long mark = log_mark();

		fsyncSkips = skip;
		fsyncFailures = 1;
		bool started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
		bool injected = fsyncFailures == 0;

		fsyncFailures = 0;
		fsyncSkips = 0;

		ok = ok && made && injected && !started &&
			 one_line(logged_since(mark), " ERROR ", line);
	}

	check(ok,
		  "a cut that cannot sync its file fails the start with an ERROR line that names it");

	/* the header, the index records, and the frames of the last transaction */
	ok = true;

	for (int call = 0; call <= 3; call++)
	{
		/* call 0: the header of a last segment without an index record */
		bool made = make_spool(&writer, dir) &&
					(call > 0 ||
					 truncate(spool_file(files[0], writer.dirname, 5, ".idx"), 30) == 0);
		long mark = log_mark();

		preadFailAt = Max(call, 1);
		bool started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
		bool injected = preadFailAt == 0;

		preadFailAt = 0;

		ok = ok && made && injected && !started &&
			 one_line(logged_since(mark), " ERROR ", "Failed to read spool file");
	}

	check(ok,
		  "a start that cannot read the segment or its index fails with an ERROR line");

	bool made = make_spool(&writer, dir);
	long mark = log_mark();

	fstatFailAt = 1;
	bool started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	bool injected = fstatFailAt == 0;

	fstatFailAt = 0;
	check(made && injected && !started &&
		  one_line(logged_since(mark), " ERROR ", "Failed to open spool file"),
		  "a start that cannot read the size of the index file fails with an ERROR line");

	/* the header of the last segment, then the header and the index of the one before */
	made = make_rotated(&writer, dir, false);
	mark = log_mark();
	preadFailAt = 3;
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 50);
	injected = preadFailAt == 0;
	preadFailAt = 0;

	check(made && injected && !started &&
		  one_line(logged_since(mark), " ERROR ", "Failed to read spool file"),
		  "a start that cannot read the last index record before a removed last segment fails with an ERROR line");

	/* a header that could not be read would look torn, and a new spool restarts */
	sformat(line, sizeof(line), "%s/unreadheader", dir);
	spool_file(files[0], line, SPOOL_FIRST_SEQ, ".seg");
	made = mkdir(line, 0700) == 0 && spool_writer_open(&opened, line, 7, 2, 0);
	kill_writer(&opened);
	mark = log_mark();
	preadFailAt = 1;
	started = made && spool_writer_open(&opened, line, 7, 2, 0);
	injected = preadFailAt == 0;
	preadFailAt = 0;

	check(made && injected && !started &&
		  one_line(logged_since(mark), " ERROR ", "Failed to read spool file") &&
		  file_size(files[0]) == SPOOL_HEADER_SIZE,
		  "a start that cannot read the header of the only segment of a new spool fails and keeps it");

	/* with index records, and without one, which proves no length of the log synced */
	ok = true;

	for (int indexed = 0; indexed < 2; indexed++)
	{
		made = make_spool(&writer, dir) &&
			   (indexed == 1 ||
				truncate(spool_file(files[0], writer.dirname, 5, ".idx"), 30) == 0);
		mark = log_mark();

		fopenFailures = 1;
		started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
		injected = fopenFailures == 0;

		fopenFailures = 0;

		/* a log that was not read is not damage */
		ok = ok && made && injected && !started &&
			 count(logged_since(mark), "ends its valid records") == 0;
	}

	check(ok, "a relation log that cannot be read fails the start");

	/* a link to itself, as the relation log, the segment, or its index */
	const char *links[] = {
		SPOOL_RELATION_LOG, "0000000000000005.seg", "0000000000000005.idx"
	};

	ok = true;

	for (int i = 0; i < lengthof(links); i++)
	{
		made = make_spool(&writer, dir);
		sformat(files[0], MAXPGPATH, "%s/%s", writer.dirname, links[i]);
		sformat(line, sizeof(line), "Failed to open spool file \"%s\"", files[0]);
		made = made && unlink(files[0]) == 0 && symlink(files[0], files[0]) == 0;

		mark = log_mark();
		started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

		char *text = logged_since(mark);

		/* the relation log comes first, so nothing is cut before its error */
		ok = ok && made && !started && one_line(text, " ERROR ", line) &&
			 (i > 0 || count(text, "Synced spool ") == 0);
	}

	check(ok,
		  "a start that cannot open the relation log, the segment or its index fails with an ERROR line");

	/* a leftover of cleanup, then the index file and the segment of the last one */
	struct
	{
		bool leftover;
		int call;
		const char *suffix;
	}
	removals[] = {
		{ true, 1, ".seg" }, { false, 1, ".idx" }, { false, 2, ".seg" }
	};

	ok = true;

	for (int i = 0; i < lengthof(removals); i++)
	{
		made = removals[i].leftover ?
			   make_rotated(&writer, dir, true) &&
			   unlink(spool_file(files[0], writer.dirname, 5, ".idx")) == 0 :
			   make_spool(&writer, dir) &&
			   truncate(spool_file(files[0], writer.dirname, 5, ".idx"), 30) == 0;
		sformat(line, sizeof(line), "Failed to remove file \"%s\"",
				spool_file(files[1], writer.dirname, 5, removals[i].suffix));
		mark = log_mark();
		unlinkFailAt = removals[i].call;
		started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
		injected = unlinkFailAt == 0;
		unlinkFailAt = 0;
		ok = ok && made && injected && !started &&
			 one_line(logged_since(mark), " ERROR ", line);
	}

	check(ok, "a start that cannot remove a file fails with an ERROR line that names it");

	/* more definitions than the 256 bytes of a new PQExpBuffer hold, in the first */
	Msg defined[13] = { firstTxn[0] };

	for (int i = 1; i <= 10; i++)
	{
		defined[i] = relation_msg(16384 + (uint32_t) i, "a");
	}

	defined[11] = firstTxn[2];
	defined[12] = firstTxn[3];
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, defined, lengthof(defined)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) && write_index(&writer);
	kill_writer(&writer);
	reallocFailures = 1;
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	injected = reallocFailures == 0;
	reallocFailures = 0;

	check(made && injected && !started && opened.segment.fd == -1 &&
		  opened.relationLog.fd == -1,
		  "a writer opened on a spool whose definitions cannot be kept in memory fails and closes its files");

	made = make_spool(&writer, dir);
	sformat(line, sizeof(line), "Failed to read spool directory \"%s\"", writer.dirname);
	mark = log_mark();
	readdirFailures = 1;
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	injected = readdirFailures == 0;
	readdirFailures = 0;

	check(made && injected && !started && one_line(logged_since(mark), " ERROR ", line),
		  "a spool directory that cannot be listed fails the start with an ERROR line");

	sformat(line, sizeof(line), "%s/missing", dir);
	check(!spool_writer_open(&opened, line, 7, 2, 0) && opened.segment.fd == -1,
		  "a writer opened on a directory that does not exist fails");

	/* the list of index files grows past the 256 bytes it starts with */
	made = make_spool(&writer, dir);

	for (uint64_t seq = 100; made && seq < 140; seq++)
	{
		made = put_bytes(spool_file(files[0], writer.dirname, seq, ".idx"), -1, "x", 1);
	}

	reallocFailures = 1;
	started = made && spool_writer_open(&opened, writer.dirname, 7, 2, 0);
	injected = reallocFailures == 0;
	reallocFailures = 0;

	/* an empty list would take the last segment for one without an index */
	check(made && injected && !started &&
		  file_size(spool_file(files[0], writer.dirname, 5, ".seg")) ==
		  (int64_t) SECOND_END,
		  "a spool directory whose list cannot be kept in memory fails the start");

	char longDir[MAXPGPATH];

	memset(longDir, 'd', sizeof(longDir));
	longDir[0] = '/';
	longDir[MAXPGPATH - 10] = '\0';
	sformat(line, sizeof(line), "Spool directory name \"%s\" is too long", longDir);
	mark = log_mark();

	check(!spool_writer_open(&opened, longDir, 7, 2, 0) &&
		  one_line(logged_since(mark), " ERROR ", line) &&
		  opened.segment.fd == -1 && opened.relationLog.fd == -1,
		  "a writer opened on a directory whose file names do not fit fails with an ERROR line");
}


static void
test_reader(const char *dir)
{
	SpoolWriter writer = { 0 };
	SpoolReader reader = { 0 };
	StreamContext context = { 0 };
	Txn all[] = {
		{ firstTxn, 4 }, { secondTxn, 3 }, { thirdTxn, 3 }
	};
	char seg[MAXPGPATH];
	char idx[MAXPGPATH];
	char line[2 * MAXPGPATH];
	char junk[40];
	bool found = false;

	memset(junk, 0xFF, sizeof(junk));

	bool made = make_rotated(&writer, dir, true);

	check(made && reader_holds(writer.dirname, 0, all, 3),
		  "a reader returns the transactions of every segment in commit order, with their frames");
	check(made && reader_holds(writer.dirname, 0xD130, all + 1, 2),
		  "a reader opened after an end LSN skips the transactions at or below it");

	/* the segment before the one that holds the next record is not read */
	made = made && flip_byte(spool_file(idx, writer.dirname, 5, ".idx"), 10);
	check(made && reader_holds(writer.dirname, 0xD230, all + 2, 1) &&
		  !reader_holds(writer.dirname, 0, all, 3),
		  "a reader opened after an end LSN starts in the segment that holds the next transaction");

	/* as after cleanup: no header of a segment is at or below end LSN 0 */
	made = make_rotated(&writer, dir, true) &&
		   unlink(spool_file(idx, writer.dirname, 5, ".idx")) == 0 &&
		   unlink(spool_file(seg, writer.dirname, 5, ".seg")) == 0;
	check(made && reader_holds(writer.dirname, 0, all + 2, 1),
		  "a reader opened below the header of every segment starts at the first one");

	/* receive writes the first record of a new segment */
	SpoolWriter fresh = { 0 };
	SpoolIndexRecord record = { 0 };
	char name[MAXPGPATH];
	char bytes[SPOOL_INDEX_RECORD_SIZE];
	Msg low[] = {
		begin_msg(0x110, 0x100, 990),
		other_msg(0x110, 'I'),
		commit_msg(0x130, 0x100, 0x130, 90),
		begin_msg(0x150, 0x200, 991),
		other_msg(0x150, 'I'),
		commit_msg(0x230, 0x200, 0x230, 91)
	};

	sformat(name, sizeof(name), "%s/later", dir);
	made = mkdir(name, 0700) == 0 && spool_writer_open(&fresh, name, 7, 2, 50) &&
		   feed(&fresh, low, 3) && write_index(&fresh) && spool_writer_rotate(&fresh) &&
		   feed(&fresh, low + 3, 3) && record_at(&fresh, 0, &record) &&
		   spool_sync(&fresh.segment);

	if (made)
	{
		spool_index_encode(&record, bytes);
	}

	made = made && put_bytes(spool_file(idx, name, 2, ".idx"), -1, bytes, 30) &&
		   spool_reader_open(&reader, name, 0x130);

	bool waiting = made && spool_reader_next(&reader, &found) && !found;

	made = made && put_bytes(idx, -1, bytes + 30, sizeof(bytes) - 30);
	check(waiting && made && next_holds(&reader, &context, low + 3, 3),
		  "a reader that starts in a later segment waits for its first index record");
	spool_reader_close(&reader);
	kill_writer(&fresh);

	Msg marks[] = {
		begin_msg(0xE010, 0xE100, 980),
		other_msg(0xE010, 'I'),
		keepalive_msg(),
		xlog(0xE020, NULL, 0),
		commit_msg(0xE130, 0xE100, 0xE130, 80)
	};
	Msg kept[] = { marks[0], marks[1], marks[4] };
	Txn marked[] = {
		{ kept, 3 }
	};

	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, marks, lengthof(marks)) && write_index(&writer);
	kill_writer(&writer);
	check(made && reader_holds(writer.dirname, 0, marked, 1),
		  "a reader returns the frames of a transaction without its keepalive markers and empty XLogData messages");

	Msg schema[] = {
		begin_msg(0xE210, 0xE200, 981),
		relation_msg(16385, "s"),
		type_msg(16385, "t"),
		commit_msg(0xE230, 0xE200, 0xE230, 81)
	};

	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, schema, lengthof(schema)) && write_index(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0);
	kill_writer(&writer);
	check(made && next_holds(&reader, &context, schema, lengthof(schema)) &&
		  reader.record.changes == 0 && reader.record.seq == 5,
		  "a reader returns a transaction of RELATION and TYPE frames only like any other");
	spool_reader_close(&reader);

	/* the definition changes between two changes of one transaction */
	StreamContext changed = { 0 };
	const char *message = NULL;
	uint32_t length = 0;
	bool done = false;
	Msg redefined[] = {
		begin_msg(0xE310, 0xE300, 982),
		relation_msg(16384, "a"),
		other_msg(0xE310, 'I'),
		relation_msg(16384, "b"),
		other_msg(0xE320, 'U'),
		commit_msg(0xE330, 0xE300, 0xE330, 82)
	};
	char names[3][8] = {
		{ 0 }
	};
	int changes = 0;

	/* the record before it leaves a change count that must not carry over */
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, redefined, lengthof(redefined)) && write_index(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &changed, firstTxn, lengthof(firstTxn)) &&
		   spool_reader_next(&reader, &found) && found;
	kill_writer(&writer);

	while (made && changes < 3 &&
		   (made = spool_reader_frame(&reader, &changed, &message, &length, &done)) &&
		   !done)
	{
		char type = message[SPOOL_XLOGDATA_HEADER_SIZE];

		if (type == 'I' || type == 'U')
		{
			sformat(names[changes++], sizeof(names[0]), "%s", cached(&changed, 16384));
		}
	}

	check(made && changes == 2 && strcmp(names[0], "a") == 0 && strcmp(names[1], "b") ==
		  0,
		  "a reader applies before each change the definition logged before it");
	spool_reader_close(&reader);

	/* receive logs a changed definition after the reader opened */
	StreamContext later = { 0 };
	Msg after[] = {
		begin_msg(0xD150, 0xD200, 983),
		relation_msg(16384, "b"),
		other_msg(0xD150, 'U'),
		commit_msg(0xD230, 0xD200, 0xD230, 83)
	};

	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) && write_index(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &later, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, after, lengthof(after)) && write_index(&writer) &&
		   next_holds(&reader, &later, after, lengthof(after));
	kill_writer(&writer);
	check(made && strcmp(cached(&later, 16384), "b") == 0,
		  "a reader reads the definitions that receive logged after it opened");
	spool_reader_close(&reader);

	/* the second record arrives in two writes */
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) && write_index(&writer) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   spool_sync(&writer.segment) && records(&writer) == 1;

	if (made)
	{
		memcpy(bytes, writer.pendingIndex.data, sizeof(bytes));
	}

	kill_writer(&writer);
	made = made &&
		   put_bytes(spool_file(idx, writer.dirname, 5, ".idx"), -1, bytes, 30) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn));
	waiting = made && spool_reader_next(&reader, &found) && !found;
	made = made && put_bytes(idx, -1, bytes + 30, sizeof(bytes) - 30);
	check(waiting && made && next_holds(&reader, &context, secondTxn, 3),
		  "an invalid index record at the tail of the last index file is not there yet, and is read once it is whole");
	spool_reader_close(&reader);

	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   feed(&writer, thirdTxn, lengthof(thirdTxn)) && write_index(&writer) &&
		   flip_byte(spool_file(idx, writer.dirname, 5, ".idx"),
					 SPOOL_INDEX_RECORD_SIZE + 10);
	kill_writer(&writer);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid index record at offset %d",
			idx, SPOOL_INDEX_RECORD_SIZE);

	long mark = log_mark();

	/* the read that meets the damage fails, before the records in front of it */
	made = made && spool_reader_open(&reader, writer.dirname, 0);
	check(made && !spool_reader_next(&reader, &found) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "an invalid index record before the tail of an index file fails the reader with an ERROR line");
	spool_reader_close(&reader);

	made = make_rotated(&writer, dir, true) &&
		   put_bytes(spool_file(idx, writer.dirname, 5, ".idx"), -1, junk, 30) &&
		   spool_reader_open(&reader, writer.dirname, 0);
	check(made && !spool_reader_next(&reader, &found),
		  "an invalid index record at the tail of a closed index file fails the reader");
	spool_reader_close(&reader);

	/* a bit of the INSERT of the first transaction */
	made = make_spool(&writer, dir) &&
		   flip_byte(spool_file(seg, writer.dirname, 5, ".seg"),
					 SPOOL_HEADER_SIZE + SPOOL_FRAME_SIZE(firstTxn[0].length) +
					 SPOOL_FRAME_SIZE(firstTxn[1].length) + 6) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   spool_reader_next(&reader, &found) && found &&
		   spool_reader_frame(&reader, &context, &message, &length, &done) &&
		   spool_reader_frame(&reader, &context, &message, &length, &done);
	mark = log_mark();
	check(made && !spool_reader_frame(&reader, &context, &message, &length, &done) &&
		  one_line(logged_since(mark), " ERROR ", "holds no valid frame at offset"),
		  "a frame with a flipped bit fails the reader");
	spool_reader_close(&reader);

	/* the high byte of the length of that INSERT: it ends 16 MiB past the file */
	uint64_t insert = SPOOL_HEADER_SIZE + SPOOL_FRAME_SIZE(firstTxn[0].length) +
					  SPOOL_FRAME_SIZE(firstTxn[1].length);

	made = make_spool(&writer, dir) &&
		   flip_byte(spool_file(seg, writer.dirname, 5, ".seg"), insert) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   spool_reader_next(&reader, &found) && found &&
		   spool_reader_frame(&reader, &context, &message, &length, &done) &&
		   spool_reader_frame(&reader, &context, &message, &length, &done);
	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid frame at offset %" PRIu64,
			seg, insert);
	mark = log_mark();
	check(made && !spool_reader_frame(&reader, &context, &message, &length, &done) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a frame whose length ends past its transaction fails the reader as damage, and is not read");
	spool_reader_close(&reader);

	made = make_spool(&writer, dir) &&
		   put_bytes(spool_file(seg, writer.dirname, 5, ".seg"), -1, junk, sizeof(junk));
	check(made && reader_holds(writer.dirname, 0, all, 2),
		  "a reader reads no frame past the end offset of the last index record");

	made = new_writer(&writer, dir, &spoolHeader, 50) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   write_index(&writer) && spool_writer_rotate(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn)) &&
		   next_holds(&reader, &context, secondTxn, lengthof(secondTxn));
	waiting = made && spool_reader_next(&reader, &found) && !found;
	made = made && feed(&writer, thirdTxn, lengthof(thirdTxn)) && write_index(&writer);
	check(waiting && made && next_holds(&reader, &context, thirdTxn, 3),
		  "a reader waits at the end of an index file until the next segment has its index file");
	spool_reader_close(&reader);
	kill_writer(&writer);

	/* rotated twice, and the index file of the middle segment lost */
	made = new_writer(&writer, dir, &spoolHeader, 50) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   write_index(&writer) && spool_writer_rotate(&writer) &&
		   feed(&writer, thirdTxn, lengthof(thirdTxn)) && write_index(&writer) &&
		   spool_writer_rotate(&writer);
	kill_writer(&writer);
	made = made && unlink(spool_file(idx, writer.dirname, 7, ".idx")) == 0 &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn)) &&
		   next_holds(&reader, &context, secondTxn, lengthof(secondTxn));
	sformat(line, sizeof(line),
			"Spool directory \"%s\" holds no index record of sequence number 7, "
			"and segment 0000000000000008 after it exists", writer.dirname);
	mark = log_mark();
	check(made && !spool_reader_next(&reader, &found) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a segment without its index file before a later segment fails the reader with an ERROR line, and the reader does not wait");
	spool_reader_close(&reader);

	/* receive indexes the next segment and rotates while the reader looks */
	made = new_writer(&writer, dir, &spoolHeader, 50) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   feed(&writer, secondTxn, lengthof(secondTxn)) &&
		   write_index(&writer) && spool_writer_rotate(&writer) &&
		   feed(&writer, thirdTxn, lengthof(thirdTxn)) &&
		   spool_sync(&writer.segment) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn)) &&
		   next_holds(&reader, &context, secondTxn, lengthof(secondTxn));
	racing = &writer;
	beforeReaddir = receive_overtakes;

	bool overtaken = made && next_holds(&reader, &context, thirdTxn, lengthof(
											thirdTxn)) &&
					 beforeReaddir == NULL;

	beforeReaddir = NULL;
	check(overtaken &&
		  file_size(spool_file(seg, writer.dirname, 8, ".seg")) == SPOOL_HEADER_SIZE,
		  "a reader that finds a later segment while it waits reads the index again, which receive may have written since its read");
	spool_reader_close(&reader);
	kill_writer(&writer);

	sformat(name, sizeof(name), "%s/early", dir);
	made = mkdir(name, 0700) == 0 && spool_writer_open(&fresh, name, 7, 2, 0) &&
		   spool_reader_open(&reader, name, 0);
	waiting = made && spool_reader_next(&reader, &found) && !found;
	made = made && feed(&fresh, low, 3) && write_index(&fresh);
	check(waiting && made && next_holds(&reader, &context, low, 3),
		  "a reader opened before the first index file exists reads it once it is there");
	spool_reader_close(&reader);
	kill_writer(&fresh);

	made = make_spool(&writer, dir) &&
		   truncate(spool_file(seg, writer.dirname, 5, ".seg"), SECOND_END - 10) == 0 &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn));
	check(made && !next_holds(&reader, &context, secondTxn, lengthof(secondTxn)),
		  "a segment that ends inside an indexed transaction fails the reader");
	spool_reader_close(&reader);

	/* the record ends 3 bytes before the end of its COMMIT frame */
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, firstTxn, lengthof(firstTxn)) &&
		   record_at(&writer, 0, &record) && write_index(&writer);
	kill_writer(&writer);
	record.endOffset -= 3;
	spool_index_encode(&record, bytes);
	made = made &&
		   put_bytes(spool_file(idx, writer.dirname, 5, ".idx"), 0, bytes,
					 sizeof(bytes)) &&
		   spool_reader_open(&reader, writer.dirname, 0);
	check(made && !next_holds(&reader, &context, firstTxn, lengthof(firstTxn)),
		  "an index record whose end offset falls inside a frame fails the reader");
	spool_reader_close(&reader);

	/* an INSERT above the 256 bytes that a new PQExpBuffer holds */
	static char wide[SPOOL_XLOGDATA_HEADER_SIZE + 400] = { 'w' };
	Msg wideBegin = begin_msg(0xE410, 0xE400, 984);
	Msg wideCommit = commit_msg(0xE430, 0xE400, 0xE430, 84);

	wide[SPOOL_XLOGDATA_HEADER_SIZE] = 'I';
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, &wideBegin, 1) &&
		   spool_writer_message(&writer, wide, sizeof(wide)) &&
		   feed(&writer, &wideCommit, 1) && write_index(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   spool_reader_next(&reader, &found) && found;
	kill_writer(&writer);
	mark = log_mark();
	reallocFailures = 1;

	bool framed = made && spool_reader_frame(&reader, &context, &message, &length, &done);
	bool injected = reallocFailures == 0;

	reallocFailures = 0;
	check(made && injected && !framed &&
		  one_line(logged_since(mark), " ERROR ", "Failed to allocate memory"),
		  "a transaction that cannot be read into memory fails the reader");
	spool_reader_close(&reader);
}


/* a reader whose system calls fail, or that cannot list its directory */
static void
test_reader_failures(const char *dir)
{
	SpoolWriter writer = { 0 };
	SpoolWriter fresh = { 0 };
	SpoolReader reader = { 0 };
	StreamContext context = { 0 };
	char path[MAXPGPATH];
	char line[2 * MAXPGPATH];
	bool found = false;
	bool ok = true;

	/* the header at open, then a chunk of the index, then the frames */
	for (int call = 1; call <= 3; call++)
	{
		const char *message = NULL;
		uint32_t length = 0;
		bool done = false;
		bool made = make_spool(&writer, dir);
		long mark = log_mark();

		preadFailAt = call;

		bool opened = made && spool_reader_open(&reader, writer.dirname, 0);
		bool next = opened && spool_reader_next(&reader, &found);
		bool framed = next && found &&
					  spool_reader_frame(&reader, &context, &message, &length, &done);
		bool injected = preadFailAt == 0;

		preadFailAt = 0;

		/* the call that meets the failure returns false, the ones before true */
		ok = ok && made && injected && opened == (call > 1) &&
			 next == (call > 2) && (call < 3 || found) && !framed &&
			 one_line(logged_since(mark), " ERROR ", "Failed to read spool file");
		spool_reader_close(&reader);
	}

	check(ok,
		  "a reader that cannot read the segment or its index fails with an ERROR line");

	ok = true;

	/* the segment at open, and the index file when the reader reads it */
	const char *links[] = { "0000000000000005.seg", "0000000000000005.idx" };

	for (int i = 0; i < lengthof(links); i++)
	{
		bool made = make_spool(&writer, dir);

		sformat(path, sizeof(path), "%s/%s", writer.dirname, links[i]);
		sformat(line, sizeof(line), "Failed to open spool file \"%s\"", path);
		made = made && unlink(path) == 0 && symlink(path, path) == 0;

		long mark = log_mark();

		ok = ok && made && !spool_reader_open(&reader, writer.dirname, 0) &&
			 one_line(logged_since(mark), " ERROR ", line);
		spool_reader_close(&reader);
	}

	/* a segment that a reader opened before its index file existed */
	Msg low[] = {
		begin_msg(0x110, 0x100, 992),
		other_msg(0x110, 'I'),
		commit_msg(0x130, 0x100, 0x130, 92)
	};

	sformat(path, sizeof(path), "%s/linked", dir);

	bool made = mkdir(path, 0700) == 0 && spool_writer_open(&fresh, path, 7, 2, 0) &&
				spool_reader_open(&reader, path, 0) &&
				feed(&fresh, low, lengthof(low)) && write_index(&fresh) &&
				unlink(fresh.segment.filename) == 0 &&
				symlink(fresh.segment.filename, fresh.segment.filename) == 0;

	sformat(line, sizeof(line), "Failed to open spool file \"%s\"",
			fresh.segment.filename);

	long mark = log_mark();

	check(ok && made && !spool_reader_next(&reader, &found) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a reader that cannot open a segment or its index file fails with an ERROR line");
	spool_reader_close(&reader);
	kill_writer(&fresh);

	made = make_spool(&writer, dir) &&
		   flip_byte(spool_file(path, writer.dirname, 5, ".seg"), 0);
	sformat(line, sizeof(line), "Spool file \"%s\" has no valid header", path);
	mark = log_mark();
	check(made && !spool_reader_open(&reader, writer.dirname, 0) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "a reader fails on an indexed segment without a valid header");
	spool_reader_close(&reader);

	made = make_spool(&writer, dir);
	mark = log_mark();
	fstatFailAt = 1;

	bool sized = made && spool_reader_open(&reader, writer.dirname, 0) &&
				 next_holds(&reader, &context, firstTxn, lengthof(firstTxn));

	ok = fstatFailAt == 0;
	fstatFailAt = 0;
	check(made && ok && !sized &&
		  one_line(logged_since(mark), " ERROR ", "Failed to read spool file"),
		  "a reader that cannot read the size of an index file fails with an ERROR line");
	spool_reader_close(&reader);

	made = make_spool(&writer, dir) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn)) &&
		   next_holds(&reader, &context, secondTxn, lengthof(secondTxn)) &&
		   truncate(spool_file(path, writer.dirname, 5, ".idx"),
					SPOOL_INDEX_RECORD_SIZE) == 0;
	sformat(line, sizeof(line),
			"Spool file \"%s\" has %d bytes, and %d were read before",
			path, SPOOL_INDEX_RECORD_SIZE, 2 * SPOOL_INDEX_RECORD_SIZE);
	mark = log_mark();
	check(made && !spool_reader_next(&reader, &found) &&
		  one_line(logged_since(mark), " ERROR ", line),
		  "an index file shorter than what the reader read fails it with an ERROR line");
	spool_reader_close(&reader);

	made = make_spool(&writer, dir);
	readdirFailures = 1;

	bool opened = made && spool_reader_open(&reader, writer.dirname, 0);
	bool injected = readdirFailures == 0;

	readdirFailures = 0;
	check(made && injected && !opened, "a reader that cannot list its directory fails");
	spool_reader_close(&reader);

	/* the reader waits at a segment without its index file, and looks for later ones */
	made = make_rotated(&writer, dir, false) &&
		   spool_reader_open(&reader, writer.dirname, 0) &&
		   next_holds(&reader, &context, firstTxn, lengthof(firstTxn)) &&
		   next_holds(&reader, &context, secondTxn, lengthof(secondTxn));
	sformat(line, sizeof(line), "Failed to read spool directory \"%s\"", writer.dirname);
	mark = log_mark();
	readdirFailures = 1;

	bool waited = made && spool_reader_next(&reader, &found);

	injected = readdirFailures == 0;
	readdirFailures = 0;
	check(made && injected && !waited && one_line(logged_since(mark), " ERROR ", line),
		  "a reader that cannot list its directory while it waits fails with an ERROR line");
	spool_reader_close(&reader);

	made = make_spool(&writer, dir) && spool_reader_open(&reader, writer.dirname, 0);
	fopenFailures = 1;

	bool reread = made && spool_reader_next(&reader, &found);

	injected = fopenFailures == 0;
	fopenFailures = 0;
	check(made && injected && !reread,
		  "a reader that cannot read the relation log again fails");
	spool_reader_close(&reader);

	sformat(path, sizeof(path), "%s/unlogged", dir);
	check(mkdir(path, 0700) == 0 && !spool_reader_open(&reader, path, 0),
		  "a reader on a directory without a relation log fails");
	spool_reader_close(&reader);

	char longDir[MAXPGPATH];

	memset(longDir, 'd', sizeof(longDir));
	longDir[0] = '/';
	longDir[MAXPGPATH - 10] = '\0';
	sformat(line, sizeof(line), "Spool directory name \"%s\" is too long", longDir);
	mark = log_mark();
	check(!spool_reader_open(&reader, longDir, 0) &&
		  one_line(logged_since(mark), " ERROR ", line) &&
		  reader.indexFd == -1 && reader.frames.fd == -1,
		  "a reader on a directory whose file names do not fit fails with an ERROR line and holds no descriptor");
	spool_reader_close(&reader);

	/* a definition in the relation log that does not parse */
	Msg unparsed = relation_msg(16384, "a");
	Msg broken[] = {
		begin_msg(0xD010, 0xD100, 993),
		unparsed,
		other_msg(0xD010, 'I'),
		commit_msg(0xD130, 0xD100, 0xD130, 93)
	};

	broken[1].length = SPOOL_XLOGDATA_HEADER_SIZE + 5;
	made = new_writer(&writer, dir, &spoolHeader, 0) &&
		   feed(&writer, broken, lengthof(broken)) && write_index(&writer) &&
		   spool_reader_open(&reader, writer.dirname, 0);
	kill_writer(&writer);
	check(made && !next_holds(&reader, &context, broken, lengthof(broken)),
		  "a definition that does not parse fails the reader before the change after it");
	spool_reader_close(&reader);
}


/* the start and the reader read an index file in chunks of SPOOL_READER_CHUNK records */
static void
test_index_chunks(const char *dir)
{
	const int total = SPOOL_READER_CHUNK + 6;
	SpoolHeader header = { .firstSeq = 1, .systemId = 7, .timeline = 2 };
	SpoolWriter writer = { 0 };
	SpoolWriter opened = { 0 };
	Msg txn[3];
	char idx[MAXPGPATH];
	char seg[MAXPGPATH];
	char line[2 * MAXPGPATH];
	bool made = new_writer(&writer, dir, &header, 0);

	for (int k = 0; made && k < total; k++)
	{
		uint64_t base = 0x100000 + (uint64_t) k * 0x100;

		txn[0] = begin_msg(base + 0x10, base + 0x80, 2000 + k);
		txn[1] = other_msg(base + 0x10, 'I');
		txn[2] = commit_msg(base + 0x90, base + 0x80, base + 0x90, 100 + k);
		made = feed(&writer, txn, lengthof(txn));
	}

	made = made && write_index(&writer);
	kill_writer(&writer);
	spool_file(idx, writer.dirname, 1, ".idx");
	spool_file(seg, writer.dirname, 1, ".seg");

	int64_t segSize = SPOOL_HEADER_SIZE + total * frames_size(txn, lengthof(txn));
	bool started = made && file_size(idx) == total * SPOOL_INDEX_RECORD_SIZE &&
				   put_bytes(idx, -1, "torn record", 11) &&
				   spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(started && opened.nextSeq == total + 1 &&
		  opened.lastEndLSN == 0x100000 + (total - 1) * 0x100 + 0x90 &&
		  file_size(idx) == total * SPOOL_INDEX_RECORD_SIZE && file_size(seg) == segSize,
		  "a start on an index file of more records than one read chunk keeps them all, and cuts only its torn tail");
	kill_writer(&opened);

	SpoolReader reader = { 0 };
	bool found = true;
	bool read = made && spool_reader_open(&reader, writer.dirname, 0);
	int n = 0;

	while (read && (read = spool_reader_next(&reader, &found)) && found)
	{
		read = reader.record.seq == (uint64_t) n + 1 &&
			   reader.record.xid == (uint32_t) (2000 + n);
		n++;
	}

	check(read && !found && n == total,
		  "a reader returns every record of an index file of more than one read chunk in order, then waits");
	spool_reader_close(&reader);

	char zeroes[SPOOL_INDEX_RECORD_SIZE] = { 0 };
	int gap = (SPOOL_READER_CHUNK + 1) * SPOOL_INDEX_RECORD_SIZE;
	int64_t idxSize = file_size(idx);
	bool gapped = made && put_bytes(idx, gap, zeroes, sizeof(zeroes));

	sformat(line, sizeof(line),
			"Spool file \"%s\" holds no valid index record at offset %d", idx, gap);

	long mark = log_mark();

	started = gapped && spool_writer_open(&opened, writer.dirname, 7, 2, 0);

	check(gapped && !started && one_line(logged_since(mark), " ERROR ", line) &&
		  file_size(idx) == idxSize && file_size(seg) == segSize,
		  "an invalid index record past the first read chunk, before a valid one, ends the start with an error that names its offset, and nothing is cut");

	if (started)
	{
		kill_writer(&opened);
	}
}


/* runs pgcopydb with args, and returns its output and exit status */
static char *
run_pgcopydb(const char *binary, const char *args, int *status)
{
	static char output[64 * 1024];
	char command[4 * MAXPGPATH];

	sformat(command, sizeof(command), "%s %s 2>/dev/null", binary, args);

	FILE *pipe = popen(command, "r");
	size_t n = pipe == NULL ? 0 : fread(output, 1, sizeof(output) - 1, pipe);

	output[n] = '\0';
	*status = pipe == NULL ? -1 : pclose(pipe);

	return output;
}


static void
test_list_spool(const char *dir, const char *binary)
{
	SpoolWriter writer = { 0 };
	char top[MAXPGPATH];
	char cdc[MAXPGPATH];
	char args[2 * MAXPGPATH];
	int status = -1;
	Msg low[] = {
		begin_msg(0x110, 0x100, 994),
		other_msg(0x110, 'I'),
		other_msg(0x120, 'U'),
		commit_msg(0x130, 0x100, 0x130, 94),
		begin_msg(0x150, 0x200, 995),
		other_msg(0x150, 'D'),
		commit_msg(0x230, 0x200, 0x230, 95)
	};

	sformat(top, sizeof(top), "%s/listed", dir);
	sformat(cdc, sizeof(cdc), "%s/cdc", top);

	bool made = mkdir(top, 0700) == 0 && mkdir(cdc, 0700) == 0 &&
				spool_writer_open(&writer, cdc, 7, 2, 0) &&
				feed(&writer, low, lengthof(low)) && write_index(&writer);

	kill_writer(&writer);
	sformat(args, sizeof(args), "list spool --dir %s --json", top);

	char *output = made ? run_pgcopydb(binary, args, &status) : "";
	JSON_Value *js = json_parse_string(output);
	JSON_Array *array = json_value_get_array(js);
	JSON_Object *first = json_array_get_object(array, 0);
	JSON_Object *second = json_array_get_object(array, 1);
	uint64_t end = SPOOL_HEADER_SIZE + frames_size(low, 4);

	check(made && status == 0 && json_array_get_count(array) == 2 &&
		  strcmp(json_object_get_string(first, "segment"), "0000000000000001") == 0 &&
		  json_object_get_number(first, "seq") == 1 &&
		  json_object_get_number(first, "xid") == 994 &&
		  json_object_get_number(first, "changes") == 2 &&
		  json_object_get_number(first, "begin_offset") == SPOOL_HEADER_SIZE &&
		  json_object_get_number(first, "end_offset") == end &&
		  strcmp(json_object_get_string(first, "final_lsn"), "0/100") == 0 &&
		  strcmp(json_object_get_string(first, "end_lsn"), "0/130") == 0 &&
		  json_object_get_string(first, "commit_time") != NULL &&
		  json_object_get_number(second, "seq") == 2 &&
		  json_object_get_number(second, "begin_offset") == end &&
		  strcmp(json_object_get_string(second, "end_lsn"), "0/230") == 0,
		  "pgcopydb list spool --json prints each index record with its segment, sequence number, xid, changes, offsets, LSNs and commit time");
	json_value_free(js);

	sformat(args, sizeof(args), "list spool --dir %s", top);
	output = made ? run_pgcopydb(binary, args, &status) : "";

	check(made && status == 0 && count(output, "\n") == 3 &&
		  count(output, "0000000000000001 |") == 2 && strstr(output, "0/230") != NULL,
		  "pgcopydb list spool prints a header and one line per index record");

	char idx[MAXPGPATH];

	made = made && flip_byte(spool_file(idx, cdc, 1, ".idx"), 10);
	output = made ? run_pgcopydb(binary, args, &status) : "";
	check(made && status != 0, "pgcopydb list spool fails on a damaged index record");

	sformat(args, sizeof(args), "list spool --dir %s --bogus", top);
	output = made ? run_pgcopydb(binary, args, &status) : "";
	check(made && status != 0 && strstr(output, "Segment") == NULL,
		  "pgcopydb list spool refuses an unknown option");

	sformat(top, sizeof(top), "%s/unspooled", dir);
	sformat(args, sizeof(args), "list spool --dir %s", top);
	output = mkdir(top, 0700) == 0 ? run_pgcopydb(binary, args, &status) : "";
	check(status != 0 && strstr(output, "Segment") == NULL,
		  "pgcopydb list spool fails on a work directory without a spool");
}


int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (argc != 3)
	{
		printf("usage: spool-format <directory on a tmpfs of one page> <pgcopydb>\n");
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
	test_out_of_memory(dir);
	test_rotation(dir);
	test_closed_segment(dir);
	test_relation_record();
	test_relation_log(dir);
	test_relation_cursor(dir);
	init_spool_messages();
	test_writer_open(dir);
	test_start_cut(dir);
	test_start_failures(dir);
	test_reader(dir);
	test_reader_failures(dir);
	test_index_chunks(dir);
	test_list_spool(dir, argv[2]);
	test_disk_full(argv[1]);
	test_relation_log_full(argv[1]);

	if (failed)
	{
		printf("FAIL\n");
		return 1;
	}

	printf("PASS: spool format\n");
	return 0;
}
