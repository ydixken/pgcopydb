set pagination off
set confirm off
set may-call-functions off
python
import pathlib
import re
import time

barrier = pathlib.Path(gdb.parse_and_eval("$barrier_dir").string())
expected = gdb.parse_and_eval("$expected_lsn").string()


class CommitHandoff(gdb.Breakpoint):
    """Stops where the COMMIT of the expected transaction reaches libpq."""

    origin_lsn = None

    def stop(self):
        sql = gdb.parse_and_eval("sql").string()
        if "pg_replication_origin_xact_setup" in sql:
            literal = re.search(r"'([0-9A-F]+/[0-9A-F]+)'", sql)
            self.origin_lsn = (literal.group(1) if literal
                               else gdb.parse_and_eval("paramValues[0]").string())
        return (re.search(r"\bcommit\b", sql, re.IGNORECASE) is not None
                and self.origin_lsn == expected)


CommitHandoff("pgsql_execute_with_params")
end
run
python
if gdb.newest_frame().name() != "pgsql_execute_with_params":
    raise gdb.GdbError("apply did not stop where the COMMIT is sent")

# Let the next send on the wire stop right before the COMMIT keyword, then kill:
# the server gets every statement queued before the COMMIT, and not the COMMIT.
gdb.execute("catch syscall sendto")
x86 = "x86-64" in gdb.selected_frame().architecture().name()
buf_reg, len_reg = ("rsi", "rdx") if x86 else ("x1", "x2")
while True:
    gdb.execute("continue")
    buf = int(gdb.parse_and_eval(f"${buf_reg}"))
    size = int(gdb.parse_and_eval(f"${len_reg}"))
    data = gdb.selected_inferior().read_memory(buf, size).tobytes()
    # COMMIT ends a statement: "\0COMMIT\0" in a Parse message, " commit\0" in a Query
    match = re.search(rb"[\x00 ]commit\x00", data, re.IGNORECASE)
    if match:
        gdb.execute(f"set ${len_reg} = {match.start() + 1}")
        gdb.execute("continue")
        break
    gdb.execute("continue")

pid = gdb.selected_inferior().pid
(barrier / "paused.tmp").write_text(f"{pid} {expected}\n")
(barrier / "paused.tmp").rename(barrier / "paused")
deadline = time.monotonic() + 60
while not (barrier / "kill").exists():
    if time.monotonic() >= deadline:
        raise gdb.GdbError("test did not confirm the target barrier")
    time.sleep(0.1)
if (barrier / "kill").read_text().strip() != str(pid):
    raise gdb.GdbError("kill authorization does not match the stopped inferior")
end
echo Statements before COMMIT executed; killing apply\n
kill
quit 0
