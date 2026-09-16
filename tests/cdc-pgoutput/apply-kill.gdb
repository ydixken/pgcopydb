set pagination off
set confirm off
set may-call-functions off
tbreak pgsql_replication_origin_xact_setup
run
python
import pathlib
import time

barrier = pathlib.Path(gdb.parse_and_eval("$barrier_dir").string())
if gdb.newest_frame().name() != "pgsql_replication_origin_xact_setup":
    raise gdb.GdbError("apply did not stop before origin setup and COMMIT")
lsn = gdb.parse_and_eval("origin_lsn").string()
if lsn != gdb.parse_and_eval("$expected_lsn").string():
    raise gdb.GdbError("apply stopped at the wrong transaction")
pid = gdb.selected_inferior().pid
(barrier / "paused.tmp").write_text(f"{pid} {lsn}\n")
(barrier / "paused.tmp").rename(barrier / "paused")
deadline = time.monotonic() + 60
while not (barrier / "kill").exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("test did not confirm the target row-lock barrier")
    time.sleep(0.1)
if (barrier / "kill").read_text().strip() != str(pid):
    raise gdb.GdbError("kill authorization does not match the stopped inferior")
if gdb.selected_inferior().pid != pid:
    raise gdb.GdbError("stopped inferior changed")
end
echo Target row-lock barrier confirmed; killing before COMMIT\n
kill
quit 0
