-- Print one transaction per line for client :client, seeded from the client
-- number, so a failing run can be replayed statement for statement.
-- Every transaction writes d_oplog, which names its class for the vacuity
-- guard and makes pgoutput send the transaction even when nothing else in it
-- is replicated.

\set ON_ERROR_STOP on

select setseed(:client::float8 / 100.0);

select format('begin; insert into d_oplog (cls) values (%L); %s commit;', cls, body)
  from (
    select case
      when op <=   8 then 'keyed-upsert'
      when op <=  15 then 'keyed-update'
      when op <=  20 then 'keyed-keychange'
      when op <=  25 then 'keyed-del-ins'
      when op <=  31 then 'full-key-update'
      when op <=  37 then 'nokey-dup-insert'
      when op <=  42 then 'nokey-update'
      when op <=  46 then 'nokey-delete'
      when op <=  51 then 'deferrable'
      when op <=  56 then 'using-index'
      when op <=  60 then 'ts-key'
      when op <=  65 then 'secondary'
      when op <=  70 then 'partition-move'
      when op <=  74 then 'toast'
      when op <=  82 then 'hot'
      when op <=  88 then 'multi-table'
      when op <=  92 then 'large'
      when op <=  95 then 'truncate'
      else                'altered'
    end as cls,
    case
      when op <= 8 then format(
        'insert into d_keyed values (%s, 0, %L) on conflict (id) do update set v = d_keyed.v + 100;', k, 'n' || k)
      when op <= 15 then format(
        'update d_keyed set v = v + 1, note = case when v %% 2 = 0 then null else %L end where id = %s;', 'u' || k, k)
      when op <= 20 then format(
        'update d_keyed set id = -nextval(''d_seq'') where id = %s;', k)
      when op <= 25 then format(
        'delete from d_keyed where id = %s; insert into d_keyed values (%s, 1, ''reinserted'');', k, k)
      when op <= 31 then format(
        'update d_full_key set v = v + 1 where id = %s;', 1 + k % 200)
      when op <= 37 then format(
        'insert into d_full_nokey values (%s, null), (%s, null);', a, a)
      when op <= 42 then format(
        'update d_full_nokey set b = %L where a = %s;', 'u' || op, a)
      when op <= 46 then format(
        'delete from d_full_nokey where a = %s and b is distinct from ''b'';', a)
      when op <= 51 then format(
        'update d_deferrable set v = v + 1 where id = %s;', 1 + k % 200)
      when op <= 56 then format(
        'update d_using_index set v = v + 1 where id = %s;', 1 + k % 200)
      when op <= 60 then
        'insert into d_ts_key values (timestamptz ''2026-01-01 00:00:00+00'' + nextval(''d_ts_seq'') * interval ''1 microsecond'', 0);'
      when op <= 65 then format(
        'insert into d_secondary values (%s, nextval(''d_sec_seq''), 0) on conflict (id) do update set v = d_secondary.v + 1;',
        1 + k % 400)
      when op <= 70 then format(
        'update d_part set part = (part + 5) %% 10, v = v + 1 where id = %s;', pk)
      when op <= 74 then
        'insert into d_toast values (nextval(''d_toast_seq''), repeat(''x'', 20000));'
      when op <= 82 then format(
        'update d_hot set n = n + 1 where id = %s;', h)
      when op <= 88 then format(
        'update d_keyed set v = v + 1 where id = %s; update d_secondary set v = v + 1 where id = %s; update d_hot set n = n + 1 where id = %s;',
        k, 1 + k % 200, h)
      when op <= 92 then format(
        'insert into d_trunc select g, %s from generate_series(1, 500) g;', op)
      when op <= 95 then
        'truncate d_trunc;'
      else format(
        'insert into d_altered (id, v) values (nextval(''d_seq''), %s);', op)
    end as body,
    g
    from (
      select g,
        1 + (random() * 99)::int as op,
        -- k and pk stay inside this client's slice: two clients that race on
        -- one key hit a unique violation, and two that move the same row
        -- across partitions hit "already moved to another partition"
        1 + (:client::int - 1) * 62 + (random() * 61)::int as k,
        1 + (:client::int - 1) * 12 + (random() * 11)::int as pk,
        (random() * 49)::int as a,
        1 + (random() * 3)::int as h
      from generate_series(1, :txns::int) g
    ) r
  ) t
  order by g;
