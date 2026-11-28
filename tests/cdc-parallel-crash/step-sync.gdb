set pagination off
set confirm off
set may-call-functions off
# Breakpoint 1 is the flush with its ignore count, breakpoint 2 the sync to
# step to, disabled until that flush is reached, and $stops says which of them
# the process is killed at.
run
if $_isvoid($_exitcode)
    delete 1
    enable 2
    while $stops > 0
        continue
        set $stops = $stops - 1
    end
    echo KILLED-AT-BREAKPOINT\n
    kill
    quit 0
end
echo FAIL: the inferior exited before the breakpoint\n
quit 1
