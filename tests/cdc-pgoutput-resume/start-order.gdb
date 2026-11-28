set pagination off
set confirm off

# A receive start records its run only after the start cut. A worker that reads
# the record opens its reader again, and between the unlink and the create of
# the last segment it would log an error for a file that comes back.
set $spool = 0

break spool_writer_open
commands
  silent
  set $spool = 1
  printf "ORDER: spool_writer_open\n"
  continue
end

break pipeline_state_start
commands
  silent
  printf "ORDER: pipeline_state_start %s\n", process_name
  if $spool == 0
    printf "FAIL: receive recorded its run before the spool open\n"
    kill
    quit 1
  end
  printf "PASS: the spool open comes before the run record\n"
  kill
  quit 0
end

run
printf "FAIL: receive recorded no run, spool open seen: %d\n", $spool
quit 1
