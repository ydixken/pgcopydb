set pagination off
set confirm off

# Receive syncs the segment, then the relation log, and only then writes and
# syncs the index records, and it reports the flushed position after all three.
# A kill at the index sync must leave the spool without the transaction,
# because no record of it is durable yet.
break spool_writer_flush if writer->pendingIndex.len > 0
run

python
def fail(msg):
    gdb.write("FAIL: %s\n" % msg)
    gdb.execute("quit 1")


if not gdb.selected_inferior().threads():
    fail("receive held no index record before it exited")

# the flush is called from the batch commit, which has the feedback positions
frame = gdb.selected_frame()
while frame is not None:
    frame.select()
    try:
        gdb.execute("set $tracking = context->tracking", to_string=True)
        break
    except gdb.error:
        frame = frame.older()
if frame is None:
    fail("no caller of the flush carries the feedback positions")

gdb.Breakpoint("spool_sync")
seen = []

for _ in range(64):
    try:
        gdb.execute("continue", to_string=True)
        if not gdb.selected_inferior().threads():
            fail("receive exited after the syncs %s, with no index sync" % seen)
        name = gdb.parse_and_eval("segment->filename").string()
    except gdb.error as e:
        fail("receive left the spool syncs after %s: %s" % (seen, e))
    if not name.endswith(".idx"):
        seen.append(name)
        continue
    if len(seen) < 2 or not seen[-2].endswith(".seg") or \
            not seen[-1].endswith("relation.log"):
        fail("the index sync follows %s, not a segment and a relation log"
             % seen[-2:])
    written = int(gdb.parse_and_eval("$tracking->written_lsn"))
    flushed = int(gdb.parse_and_eval("$tracking->flushed_lsn"))
    if flushed >= written:
        fail("flushed %d is not below written %d at the index sync"
             % (flushed, written))
    gdb.write("Index sync after %s, flushed %d below written %d\n"
              % (seen[-2:], flushed, written))
    break
else:
    fail("no index sync in 64 spool_sync calls after %s" % seen)
end

kill
echo PASS: killed receive before the index sync\n
quit 0
