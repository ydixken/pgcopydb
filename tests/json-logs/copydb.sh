#! /bin/bash

# A clone at the default log level with PGCOPYDB_LOG_JSON=on whose CREATE INDEX
# fails on the target: the error logs the whole statement, a partial index
# definition of over 2 kB, and that has to reach one JSON message intact.

set -euo pipefail

pgcopydb ping

# a partial index on a long IN list, as users write them
psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" <<'EOF'
create table t(id integer, status text);
insert into t select i, 'status-' || i from generate_series(1, 300) as i;
select format('create index t_status_idx on t (id) where status in (%s)',
              string_agg(quote_literal('status-' || i), ', '))
  from generate_series(1, 300) as i
\gexec
EOF

# the index name is taken on the target, so its CREATE INDEX fails there
psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_TARGET_PGURI}" \
     -c 'create table t_status_idx(id integer)'

def=$(psql -AtqX -v ON_ERROR_STOP=1 -d "${PGCOPYDB_SOURCE_PGURI}" \
      -c "select pg_get_indexdef('t_status_idx'::regclass)")

status=0
PGCOPYDB_LOG_JSON=on timeout -k 10s 300s \
    pgcopydb clone --dir /tmp/pgcopydb \
    --source "${PGCOPYDB_SOURCE_PGURI}" \
    --target "${PGCOPYDB_TARGET_PGURI}" 2>/tmp/clone.json || status=$?
cat /tmp/clone.json

result=0
fail() { echo "FAIL: $*" >&2; result=1; }

if test "${#def}" -gt 2048; then
    echo "PASS: the index definition is ${#def} bytes long"
else
    fail "the index definition length: expected=over 2048 bytes actual=${#def}"
fi

# timeout exits 124, or 137 after its kill: the clone has to stop on its own
case "${status}" in
    0 | 124 | 137) fail "the clone exit status: expected=non-zero, not 124 or 137 actual=${status}" ;;
    *) echo "PASS: the clone fails on the taken index name with exit ${status}" ;;
esac

# a process that aborts leaves a libc message, which is not JSON, and its
# parent reports the signal
json=$(jq -Rn '[inputs | try fromjson catch empty] | length' /tmp/clone.json)
other=$(jq -Rr '. as $line | try (fromjson | empty) catch $line' /tmp/clone.json)

if test "${json}" = 0; then
    fail "JSON lines on stderr: expected=at least 1 actual=0"
elif test -n "${other}"; then
    fail "lines on stderr that are not JSON: ${other}"
else
    echo "PASS: all ${json} lines on stderr are JSON"
fi

signaled=$(jq -Rr 'try fromjson catch {} | .message? // "" | select(test("(and|by) signal"))' \
    /tmp/clone.json)

if test -z "${signaled}"; then
    echo "PASS: no process ended on a signal"
else
    fail "processes that ended on a signal: ${signaled}"
fi

# the overflow still writes this message before the abort: this check rejects
# a message cut at the buffer size, the two above catch the overflow
count=$(jq -Rn --arg stmt "] SQL query: ${def};" \
    '[inputs | try fromjson catch {} | .message? // "" | select(endswith($stmt))] | length' \
    /tmp/clone.json)

if test "${count}" = 1; then
    echo "PASS: one JSON message ends with the whole CREATE INDEX statement"
else
    fail "JSON messages that end with the whole CREATE INDEX statement: expected=1 actual=${count}"
fi

exit "${result}"
