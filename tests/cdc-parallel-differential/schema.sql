-- The classes that the differential workload hits.  Each one is a shape whose
-- replica identity, constraint set or transaction size changes what apply has
-- to send, so a wrong statement or a wrong order shows up in the row hash.

\set ON_ERROR_STOP on

create table d_keyed (id bigint primary key, v int not null, note text);
insert into d_keyed select i, 0, case when i % 3 = 0 then null else 'n' || i end
  from generate_series(1, 1000) i;
create sequence d_seq;

create table d_full_key (id bigint primary key, v int not null);
alter table d_full_key replica identity full;
insert into d_full_key select i, 0 from generate_series(1, 200) i;

-- rows can be equal under = and still print differently, and the statement
-- finds its row by =
create table d_full_nokey (a int, b text);
alter table d_full_nokey replica identity full;
insert into d_full_nokey select i % 50, case when i % 4 = 0 then null else 'b' end
  from generate_series(1, 200) i;

-- the target does not enforce a deferrable key in replica role, so this table
-- is keyless for the apply order
create table d_deferrable (id bigint, v int not null,
  constraint d_deferrable_pkey primary key (id) deferrable initially immediate);
alter table d_deferrable replica identity full;
insert into d_deferrable select i, 0 from generate_series(1, 200) i;

create table d_using_index (id bigint not null, v int not null);
create unique index d_using_index_key on d_using_index (id);
alter table d_using_index replica identity using index d_using_index_key;
insert into d_using_index select i, 0 from generate_series(1, 200) i;

create table d_ts_key (at timestamptz primary key, v int not null);

create table d_secondary (id bigint primary key, u bigint not null unique, v int not null);
insert into d_secondary select i, i, 0 from generate_series(1, 200) i;

-- its data stays on the source: the filters exclude it
create table d_excluded (id bigint primary key, v int not null);
insert into d_excluded select i, i from generate_series(1, 50) i;

create table d_part (id bigint not null, part int not null, v int not null,
  primary key (id, part)) partition by range (part);
create table d_part_lo partition of d_part for values from (0) to (5);
create table d_part_hi partition of d_part for values from (5) to (10);
insert into d_part select i, i % 10, 0 from generate_series(1, 200) i;

create table d_toast (id bigint primary key, big text);

-- four rows that every client updates
create table d_hot (id int primary key, n bigint not null);
insert into d_hot select i, 0 from generate_series(1, 4) i;

create table d_trunc (id bigint, v int not null);

create table d_altered (id bigint primary key, v int not null);

-- one row per transaction, so pgoutput sends every transaction and the
-- vacuity guard can count the classes the workload actually reached
create table d_oplog (cls text not null, at timestamptz not null default clock_timestamp());

create sequence d_ts_seq;
create sequence d_sec_seq start 1000;
create sequence d_toast_seq;
