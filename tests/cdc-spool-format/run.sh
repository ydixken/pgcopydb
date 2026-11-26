#! /bin/bash

# Links spool-format.c against the pgcopydb objects of the image build and
# runs it. SANITIZE=address rebuilds those objects with that sanitizer first.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd /usr/src/pgcopydb/src/bin/pgcopydb
pg_config --version

flags=()
if test -n "${SANITIZE:-}"; then
    flags=(CFLAGS="-fsanitize=${SANITIZE} -fno-omit-frame-pointer" LDFLAGS="-fsanitize=${SANITIZE}")
    make -s clean
    make -s -j"$(nproc)" "${flags[@]}" pgcopydb
fi

# make expands these variables, not the shell
# shellcheck disable=SC2016
printf 'cflags:\n\t@echo $(CC) $(CFLAGS)\nlibs:\n\t@echo $(LDFLAGS) $(LIBS)\n' > /tmp/vars.mk
read -r -a cc <<< "$(make -s -f Makefile -f /tmp/vars.mk "${flags[@]}" cflags)"
read -r -a libs <<< "$(make -s -f Makefile -f /tmp/vars.mk "${flags[@]}" libs)"
objs=()
for o in *.o; do
    test "${o}" = main.o || objs+=("${o}")
done

# main.c defines globals the other objects use, so it links without its main()
"${cc[@]}" -Dmain=pgcopydb_main -Wno-missing-prototypes -c main.c -o /tmp/main.o
"${cc[@]}" -I. -c "${here}/spool-format.c" -o /tmp/spool-format.o
"${cc[@]}" /tmp/spool-format.o /tmp/main.o "${objs[@]}" "${libs[@]}" -o /tmp/spool-format

export ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0}
status=0
/tmp/spool-format /spool-full || status=1

# Again under strace: each "Synced spool" debug line must be one fsync that
# returned 0, on a descriptor of the file it names, in the same order. This
# runs after a failed check too, so that a mutant shows each check it fails.
rc=0
strace -f -y -o /tmp/strace.log -e trace=fsync,fdatasync,ftruncate \
    /tmp/spool-format /spool-full > /tmp/traced.log 2>&1 || rc=$?
if test "${rc}" -ne 0; then
    test "${status}" -ne 0 || cat /tmp/traced.log
    status=1
fi

sed -nE 's/.*Synced spool (file|directory) "([^"]*)".*/\2/p' /tmp/traced.log > /tmp/logged.txt
grep -E '(fsync|fdatasync)\(' /tmp/strace.log > /tmp/calls.txt || true
sed -nE 's/^([0-9]+ +)?fsync\([0-9]+<(.*)>\) += 0$/\2/p' /tmp/calls.txt > /tmp/synced.txt

test -s /tmp/logged.txt
if test "$(wc -l < /tmp/calls.txt)" -ne "$(wc -l < /tmp/synced.txt)" ||
   ! diff /tmp/logged.txt /tmp/synced.txt; then
    echo 'FAIL: the sync debug lines are not the fsync calls'
    cat /tmp/strace.log
    exit 1
fi
echo "PASS: $(wc -l < /tmp/logged.txt) sync debug lines, each one fsync of the file it names"
exit "${status}"
