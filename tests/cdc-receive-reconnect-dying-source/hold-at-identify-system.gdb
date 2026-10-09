set pagination off
set confirm off
set may-call-functions off
break pgsql_identify_system
run
python
import pathlib
import time

caller = gdb.newest_frame().older()
if caller is None or caller.name() != "pgsql_start_replication":
    raise gdb.GdbError("receive did not stop at IDENTIFY_SYSTEM before START_REPLICATION")
gdb.execute("delete")
barrier = pathlib.Path(gdb.parse_and_eval("$barrier_dir").string())
(barrier / "paused").write_text(f"{gdb.selected_inferior().pid}\n")
deadline = time.monotonic() + 60
while not (barrier / "release").exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("test did not release the IDENTIFY_SYSTEM barrier")
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
