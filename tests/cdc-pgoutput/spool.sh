#! /bin/bash

# Read only after prefetch exits, so no receive writer can change the evidence.
spool_transaction() {
    local xid=$1 expected_inserts=$2 expected_updates=${3:-0}
    local file row nb nc ni nu nd begin commit
    local begins=0 commits=0 inserts=0 updates=0 other_dml=0
    local files=("${XDG_DATA_HOME}/pgcopydb"/*-output.db)
    begin_lsn= commit_lsn=
    [[ ${xid} =~ ^[1-9][0-9]*$ ]] || return 1
    test -f "${files[0]}" || { echo 'FAIL: no output spool files' >&2; return 1; }
    for file in "${files[@]}"; do
        row=$(timeout 5s sqlite3 -readonly -init /dev/null -batch -noheader -list "${file}" "select
            count(*) filter (where action = 'B'),
            count(*) filter (where action = 'C'),
            count(*) filter (where action = 'I'),
            count(*) filter (where action = 'U'),
            count(*) filter (where action in ('D', 'T')),
            coalesce(max(case when action = 'B' and lsn > 0 then printf('%X/%X', lsn >> 32, lsn & 4294967295) end), '-'),
            coalesce(max(case when action = 'C' and lsn > 0 then printf('%X/%X', lsn >> 32, lsn & 4294967295) end), '-')
            from output where xid = ${xid}") || return 1
        [[ ${row} =~ ^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+\|([-]|[0-9A-F]+/[0-9A-F]+)\|([-]|[0-9A-F]+/[0-9A-F]+)$ ]] || return 1
        IFS='|' read -r nb nc ni nu nd begin commit <<<"${row}"
        begins=$((begins + nb))
        commits=$((commits + nc))
        inserts=$((inserts + ni))
        updates=$((updates + nu))
        other_dml=$((other_dml + nd))
        if test "${nb}" -gt 0; then begin_lsn=${begin}; fi
        if test "${nc}" -gt 0; then commit_lsn=${commit}; fi
    done
    echo "Spool: xid=${xid}, B=${begins}, C=${commits}, I=${inserts}, U=${updates}, other DML=${other_dml}, BEGIN=${begin_lsn}, COMMIT=${commit_lsn}" >&2
    test "${begins}|${commits}|${inserts}|${updates}|${other_dml}" = "1|1|${expected_inserts}|${expected_updates}|0" \
        && [[ ${begin_lsn} =~ ^[0-9A-F]+/[0-9A-F]+$ && ${commit_lsn} =~ ^[0-9A-F]+/[0-9A-F]+$ ]]
}
