set pagination off
set confirm off

# Keep receive's output.db batch open: skip the idle and flush commits.
# Feedback still runs, so only the keepalive guard can hold the slot back.
break streamIdle
commands
silent
return 1
continue
end
break streamFlush
commands
silent
return 1
continue
end
python
import pathlib
pathlib.Path(gdb.parse_and_eval("$barrier_dir").string(), "armed").touch()
end
continue
