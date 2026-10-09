create extension if not exists citext;
create type mood as enum ('sad', 'ok', 'happy');
create domain posint as integer check (value > 0);

-- batchable: the only unique index is the primary key or the replica identity
create table t_main (
    id integer primary key,
    n integer,
    s text,
    j jsonb,
    a integer[],
    e mood,
    b bytea,
    ts timestamptz,
    d posint,
    g integer generated always as (n * 2) stored,
    ia integer generated always as identity
);

create table t_comp (k1 integer, k2 text collate "C", v integer, primary key (k1, k2));
create table t_ci (k citext primary key, v integer);

create table t_riidx (k integer not null, v integer);
create unique index t_riidx_k on t_riidx (k);
alter table t_riidx replica identity using index t_riidx_k;

create table t_toast (id integer primary key, v integer, big text);
alter table t_toast alter column big set storage external;

-- copydb.sh makes it a partitioned table on the target
create table t_part (id integer primary key, bucket integer not null, v integer);

-- never batched
create table t_uniq (id integer primary key, u integer unique, v integer);
create table t_excl (id integer primary key, r int4range, v integer,
                     exclude using gist (r with &&));
create table t_rifull (id integer primary key, v integer);
alter table t_rifull replica identity full;
create table t_keyless (a integer, b integer);
alter table t_keyless replica identity full;

insert into t_main (id, n, s, j, a, e, b, ts, d)
     select i, i, 's' || i, jsonb_build_object('k', i), array[i, i + 1], 'ok',
            decode(md5(i::text), 'hex'),
            '2026-01-01 00:00:00+00'::timestamptz + i * interval '1 minute', i
       from generate_series(1, 3000) i;

insert into t_comp select i, 'k' || i, i from generate_series(1, 2000) i;
insert into t_ci select 'Key' || i, i from generate_series(1, 300) i;
insert into t_riidx select i, i from generate_series(1, 300) i;
insert into t_toast
     select i, i, (select string_agg(md5(i::text || j::text), '')
                     from generate_series(1, 300) j)
       from generate_series(1, 200) i;
insert into t_part select i, i % 2, i from generate_series(1, 1000) i;

insert into t_uniq select i, i, i from generate_series(1, 100) i;
insert into t_excl select i, int4range(i * 10, i * 10 + 5), i from generate_series(1, 100) i;
insert into t_rifull select i, i from generate_series(1, 100) i;
insert into t_keyless select i, i from generate_series(1, 100) i;
