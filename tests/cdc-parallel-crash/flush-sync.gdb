set pagination off
set confirm off
set may-call-functions off
# the flush breakpoint and its ignore count come from the command line: stop in
# the flush, then at the sync of its segment, then at the sync of the relation
# log, which is after the segment sync and before any index record is written
run
if $_isvoid($_exitcode)
    delete
    break spool_sync
    continue
    continue
    echo KILLED-AT-BREAKPOINT\n
    kill
    quit 0
end
echo FAIL: the inferior exited before the breakpoint\n
quit 1
