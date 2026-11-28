set pagination off
set confirm off
set may-call-functions off
# the breakpoint, its ignore count and $finish come from the command line; with
# $finish set the function returns first, then the process is killed
run
if $_isvoid($_exitcode)
    if $finish
        finish
    end
    echo KILLED-AT-BREAKPOINT\n
    kill
    quit 0
end
echo FAIL: the inferior exited before the breakpoint\n
quit 1
