set pagination off
set confirm off
set may-call-functions off
break prepareToTerminate
run
python
import pathlib
import time

if gdb.newest_frame().name() != "prepareToTerminate":
    raise gdb.GdbError("receive did not stop where it ends the stream at endpos")
gdb.execute("delete")
barrier = pathlib.Path(gdb.parse_and_eval("$barrier_dir").string())
(barrier / "paused").write_text(f"{gdb.selected_inferior().pid}\n")
deadline = time.monotonic() + 60
while not (barrier / "release").exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("test did not release the endpos barrier")
    time.sleep(0.1)
end
continue
python
# A live inferior here stopped on a signal, such as the SIGABRT of a double free.
if gdb.selected_inferior().pid != 0:
    gdb.execute("bt")
    gdb.execute("kill")
    gdb.execute("quit 1")
gdb.execute(f"quit {int(gdb.parse_and_eval('$_exitcode'))}")
end
