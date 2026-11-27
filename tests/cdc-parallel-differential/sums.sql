-- Row count and an order-independent checksum over all columns, one line per
-- table.  Taken from the stage 0 probe (tests/bench-cdc/probe/lib.sh), which
-- is where the number this suite compares against was first read.
-- d_excluded is left out: the filters keep its rows off the target.

\set ON_ERROR_STOP on

select format('%I.%I', n.nspname, c.relname) || ' ' ||
  (xpath('/row/s/text()', query_to_xml(format(
    'select count(*) || '':'' || coalesce(sum(hashtextextended(t::text, 0)), 0) as s from %I.%I t',
    n.nspname, c.relname), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where c.relkind = 'r' and n.nspname = 'public'
    and c.relname <> 'd_excluded'
  order by 1;
