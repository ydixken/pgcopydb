--
-- The final sequence sync of clone --follow hides RESTART IDENTITY, so an
-- ALWAYS trigger records each sequence as the replayed TRUNCATE leaves it.
--
-- TRUNCATE ONLY is refused on a partitioned table, so apply must drop it there
alter table public.flat rename to flat_old;
create table public.flat (id int, v text) partition by range (id);
create table public.flat_all partition of public.flat default;
insert into public.flat select * from public.flat_old;
drop table public.flat_old;

create table public.trunc_log (tbl text, last_value bigint, is_called bool);

create function public.log_truncate() returns trigger language plpgsql as $$
declare
  r record;
begin
  execute format('select last_value, is_called from %s',
                 pg_get_serial_sequence(format('%I.%I', tg_table_schema, tg_table_name), 'id'))
     into r;
  insert into public.trunc_log values (tg_table_schema || '.' || tg_table_name, r.last_value, r.is_called);
  return null;
end
$$;

do $$
declare
  t regclass;
begin
  for t in select c.oid::regclass
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where c.relkind = 'r' and n.nspname in ('public', 'S p')
              and c.relname <> 'trunc_log'
  loop
    continue when pg_get_serial_sequence(t::text, 'id') is null;
    execute format('create trigger log_truncate after truncate on %s
                    for each statement execute function public.log_truncate()', t);
    execute format('alter table %s enable always trigger log_truncate', t);
  end loop;
end
$$;
