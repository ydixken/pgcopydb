set pagination off
set confirm off
set may-call-functions off
# the breakpoint comes from the command line; kill the inferior where it stops
run
if $_isvoid($_exitcode)
    echo KILLED-AT-BREAKPOINT\n
    kill
    quit 0
end
echo FAIL: the inferior exited before the breakpoint\n
quit 1
