-- 1025 rows: a full batch of 1024 rows, then one row on its own
update t_main
   set j = jsonb_build_object('k', id, 'nested', jsonb_build_object('a', array[1, 2])),
       a = array[id, null, 3], e = 'happy', b = b || '\x00ff'::bytea,
       ts = ts + interval '1 day', d = d + 1
 where id between 1001 and 2025;

-- NULL values in every column the SET list writes
update t_main
   set s = null, j = null, a = null, e = null, b = null, ts = null, d = null
 where id between 2026 and 2100;

-- the second statement updates rows 2205 to 2210 again: the batch ends there,
-- or the join applies the first value (41) instead of the last one (42)
begin;
update t_main set n = 41 where id between 2201 and 2210;
update t_main set n = 42 where id between 2205 and 2215;
commit;

-- a key change never joins a batch
begin;
update t_main set n = n + 7 where id between 2301 and 2310;
update t_main set id = id + 100000 where id between 2311 and 2320;
update t_main set n = n + 7 where id between 2321 and 2330;
commit;

-- written on its own, as before batching existed
update t_main set n = 0 where id = 2999;

update t_comp set v = v + 1 where k1 <= 1500;
update t_ci set v = v + 1;
update t_riidx set v = v * 2;

-- rows that leave the TOASTed column unchanged and rows that change it do not
-- share a SET list
begin;
update t_toast set v = v + 1 where id <= 100;
update t_toast set big = big || 'x', v = v + 1 where id between 101 and 150;
update t_toast set v = v + 1 where id between 151 and 200;
commit;

-- moves rows between the target partitions
update t_part set bucket = 1 - bucket, v = v + 1 where id <= 600;

begin;
update t_uniq set u = 1000 where id = 1;
update t_uniq set u = 1 where id = 2;
update t_uniq set u = 2 where id = 1;
update t_uniq set v = v + 1;
commit;

update t_excl set v = v + 1;
update t_rifull set v = v + 1;
update t_keyless set b = b + 1;
