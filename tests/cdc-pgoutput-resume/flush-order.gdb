set pagination off
set confirm off
handle SIGCONT nostop noprint pass
handle SIGSTOP nostop noprint nopass

# Make the next loop flush while the large source transaction is incomplete.
python
frame = gdb.newest_frame()
while frame is not None and frame.name() != "pgsql_stream_logical":
    frame = frame.older()
if frame is None:
    raise gdb.GdbError("receive is not inside pgsql_stream_logical")
frame.select()
gdb.execute("set client->last_fsync = -1")
gdb.newest_frame().select()
end

tbreak streamFlush
shell pkill -CONT -x pgcopydb
continue
set $tracking = context->tracking
set $flushed = $tracking->flushed_lsn
if $tracking->written_lsn <= $flushed
    echo FAIL: no unflushed receive progress\n
    quit 1
end

tbreak ld_store_output_commit
continue
printf "Before flush commit: written=%llu flushed=%llu previous_flush=%llu\n", $tracking->written_lsn, $tracking->flushed_lsn, $flushed
if $tracking->flushed_lsn != $flushed
    echo FAIL: flushed_lsn advanced before SQLite commit\n
    quit 1
end
if (int) sqlite3_get_autocommit(catalog->db) != 0
    echo FAIL: no open SQLite transaction at flush\n
    quit 1
end

shell pkill -KILL -x pgcopydb
echo PASS: killed receive before SQLite flush commit\n
quit 0
