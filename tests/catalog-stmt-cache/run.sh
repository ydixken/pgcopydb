#! /bin/bash

# Links stmt-cache.c against the pgcopydb objects of the image build and runs
# it. SANITIZE=address rebuilds those objects with that sanitizer first.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
cd /usr/src/pgcopydb/src/bin/pgcopydb

flags=()
if test -n "${SANITIZE:-}"; then
    flags=(CFLAGS="-fsanitize=${SANITIZE} -fno-omit-frame-pointer" LDFLAGS="-fsanitize=${SANITIZE}")
    make -s clean
    make -s -j"$(nproc)" "${flags[@]}" pgcopydb
fi

printf 'cflags:\n\t@echo $(CC) $(CFLAGS)\nlibs:\n\t@echo $(LDFLAGS) $(LIBS)\n' > /tmp/vars.mk
read -r -a cc <<< "$(make -s -f Makefile -f /tmp/vars.mk "${flags[@]}" cflags)"
read -r -a libs <<< "$(make -s -f Makefile -f /tmp/vars.mk "${flags[@]}" libs)"
objs=()
for o in *.o; do
    test "${o}" = main.o || objs+=("${o}")
done

# main.c defines globals the other objects use, so it links without its main()
"${cc[@]}" -Dmain=pgcopydb_main -Wno-missing-prototypes -c main.c -o /tmp/main.o
"${cc[@]}" -I. -c "${here}/stmt-cache.c" -o /tmp/stmt-cache.o
"${cc[@]}" /tmp/stmt-cache.o /tmp/main.o "${objs[@]}" "${libs[@]}" -o /tmp/stmt-cache

ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} /tmp/stmt-cache
