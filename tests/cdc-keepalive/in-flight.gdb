set pagination off
set confirm off

# Relation metadata and replayed DML may leave no new progress for streamFlush.
tbreak streamWrite if ((StreamContext *) context->private)->transactionInProgress && context->buffer[0] == 'I' && context->cur_record_lsn > context->tracking->flushed_lsn
python
import pathlib
barrier = pathlib.Path(gdb.parse_and_eval("$barrier_dir").string())
(barrier / "armed").touch()
end
continue
set $context = context
set $private = (StreamContext *) context->private
python
frame = gdb.newest_frame()
while frame is not None and frame.name() != "pgsql_stream_logical":
    frame = frame.older()
if frame is None:
    raise gdb.GdbError("receiver is not inside pgsql_stream_logical")
frame.select()
gdb.execute("set $oldflush = client->feedback.flushed_lsn")
gdb.execute("set $oldreplay = client->feedback.applied_lsn")
gdb.execute("set client->last_fsync = -1")
gdb.execute("set client->last_status = -1")
gdb.newest_frame().select()
end

tbreak streamFlush
continue
if !$private->transactionInProgress
    echo FAIL: transaction completed before the flush barrier\n
    quit 1
end
tbreak streamKeepalive
continue
if !$private->transactionInProgress
    echo FAIL: keepalive did not occur inside a receive transaction\n
    quit 1
end

# The callback order differs between baseline and fix; stop after libpq flushes.
tbreak PQflush
continue
finish
if !$private->transactionInProgress
    echo FAIL: transaction completed before sending feedback\n
    quit 1
end
printf "Open transaction feedback: write=%llu flush=%llu replay=%llu\n", $context->tracking->written_lsn, $context->tracking->flushed_lsn, $context->tracking->applied_lsn
python
import time
if gdb.newest_frame().name() != "pgsqlSendFeedback":
    raise gdb.GdbError("PQflush did not return to pgsqlSendFeedback")
def lsn(expression):
    value = int(gdb.parse_and_eval(expression))
    return f"{value >> 32:X}/{value & 0xffffffff:X}"
(barrier / "paused").write_text(
    " ".join(lsn(expr) for expr in
             ("$context->tracking->written_lsn", "$oldflush", "$oldreplay")) + "\n")
deadline = time.monotonic() + 60
while not (barrier / "release").exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("test did not release the in-flight barrier")
    time.sleep(0.1)
end
detach
quit 0
