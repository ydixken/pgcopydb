#! /bin/bash

set -x
set -e

# A TRUNCATE that names several tables must reach the target as one TRUNCATE
# of all of them, with RESTART IDENTITY when the source used it, and without
# the tables that --filters excludes.

pgcopydb ping

SRC=${PGCOPYDB_SOURCE_PGURI}
TGT=${PGCOPYDB_TARGET_PGURI}
TABLES=(public.parent public.child public.tr3 public.tr5 '"S p"."T, ONLY x"'
        public.casc_parent public.casc_child public.tr6 public.flat public.tr7
        public.kept)

sql() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$@"; }

sig() {
    sql "$1" -c "select count(*) || ' ' || md5(coalesce(string_agg(x::text, ',' order by x.id), '')) from $2 x"
}

run() {
    local plugin=$1 dir=/tmp/work-$1 log=/tmp/clone-$1.log

    for uri in "${SRC}" "${TGT}"; do
        sql "${uri}" -c 'drop schema if exists public cascade' \
                     -c 'drop schema if exists "S p" cascade' \
                     -c 'create schema public'
    done
    sql "${SRC}" -f /usr/src/pgcopydb/source.sql

    pgcopydb clone --follow --plugin "${plugin}" --dir "${dir}" \
             --filters /usr/src/pgcopydb/filters.ini > "${log}" 2>&1 &
    local pid=$!

    # TRUNCATE is not MVCC-safe: wait until the copy is done and apply runs
    for i in $(seq 240); do
        grep -q 'Applying CDC changes' "${log}" && break
        sleep 0.5
    done
    grep -q 'Applying CDC changes' "${log}"

    sql "${TGT}" -f /usr/src/pgcopydb/target.sql

    # one transaction per TRUNCATE; a row written after it must survive
    sql "${SRC}" -c 'truncate tr3, "S p"."T, ONLY x", tr5 restart identity' \
                 -c "insert into tr3(v) values ('after')"

    # excl is not on the target: pgoutput leaves it out of the publication,
    # test_decoding has no table filter, so only pgoutput gets excl here
    if [ "${plugin}" = pgoutput ]; then
        sql "${SRC}" -c 'truncate tr6, excl, flat restart identity'
    else
        sql "${SRC}" -c 'truncate tr6, flat restart identity'
    fi

    # CASCADE reaches casc_child, which the source lists as well
    sql "${SRC}" -c 'truncate casc_parent cascade' \
                 -c "insert into casc_parent(v) values ('after')"

    # child references parent: truncating them one by one fails
    sql "${SRC}" -c 'truncate parent, child, tr7' \
                 -c "insert into parent(v) values ('after')" \
                 -c "insert into kept(v) values ('after')"

    pgcopydb stream sentinel set endpos --current --dir "${dir}"

    local rc=124
    for i in $(seq 240); do
        if ! kill -0 ${pid} 2>/dev/null; then
            rc=0
            wait ${pid} || rc=$?
            break
        fi
        sleep 0.5
    done
    if [ ${rc} = 124 ]; then
        kill ${pid}
    fi
    grep -E ' (ERROR|FATAL) ' "${log}" | cut -c1-300 || true

    local bad=0
    for t in "${TABLES[@]}"; do
        local a b
        a=$(sig "${SRC}" "$t")
        b=$(sig "${TGT}" "$t")
        if [ "$a" = "$b" ]; then echo "MATCH $t [$a]"; else echo "DIFF $t src=[$a] tgt=[$b]"; bad=1; fi
    done

    sql "${TGT}" -c 'select * from public.trunc_log order by tbl collate "C"' \
        > /tmp/trunc_log-${plugin}.txt
    diff /usr/src/pgcopydb/expected.txt /tmp/trunc_log-${plugin}.txt || bad=1

    local excl
    excl=$(sql "${TGT}" -c "select count(*) from pg_class where relname = 'excl'")
    test "${excl}" -eq 0

    pgcopydb stream cleanup --dir "${dir}"

    echo "RESULT plugin=${plugin} clone_rc=${rc} data=$([ ${bad} = 0 ] && echo MATCH || echo DIFF)"
    test ${rc} -eq 0 && test ${bad} -eq 0
}

run pgoutput
run test_decoding
