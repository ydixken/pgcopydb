---
--- pgcopydb test/cdc/ddl.sql
---
--- This file implements DDL changes in the pagila database.

begin;
alter table payment_p2022_01 replica identity full;
alter table payment_p2022_02 replica identity full;
alter table payment_p2022_03 replica identity full;
alter table payment_p2022_04 replica identity full;
alter table payment_p2022_05 replica identity full;
alter table payment_p2022_06 replica identity full;
alter table payment_p2022_07 replica identity full;
commit;

begin;
alter table address replica identity full;
commit;

begin;
create table if not exists generated_column_test
(
    id bigint primary key,
    name text,
    greet_hello text generated always as ('Hello ' || name) stored,
    greet_hi  text generated always as ('Hi ' || name) stored,
    -- tests identifier escaping
    time text generated always as ('identifier 1' || 'now') stored,
    email text not null,
    -- tests identifier escaping
    "table" text generated always as ('identifier 2' || name) stored,
    """table""" text generated always as ('identifier 3' || name) stored,
    """hel""lo""" text generated always as ('identifier 4' || name) stored
);
commit;

begin;
--
-- See https://github.com/dimitri/pgcopydb/issues/968
-- Loss of double precision during CDC replay: %f only gives 6 decimal places.
--
create table if not exists float8_precision_test
(
    id  bigint primary key,
    val double precision
);

-- table with single column to test update is not failing when value is not changed
create table if not exists single_column_table
(
   id bigint
);
alter table single_column_table replica identity full;

-- table with 3 columns to test update is not failing when value is not changed
create table if not exists multi_column_table
(
   id bigint,
   name text,
   email text
);
alter table multi_column_table replica identity full;
commit;

--
-- REPLICA IDENTITY FULL without a primary key or replica identity index:
-- identical rows are legal, and each UPDATE or DELETE must change one of them.
-- Same tables as tests/cdc-replica-identity-full.
--
begin;

create table ri_full_del (a int, b text);
create table ri_full_upd (a int, b text);
create table ri_full_nulldup (a int, b text);
create table ri_full_three (a int, b text);
create table ri_full_keyed (id int primary key, b text);

alter table ri_full_del replica identity full;
alter table ri_full_upd replica identity full;
alter table ri_full_nulldup replica identity full;
alter table ri_full_three replica identity full;
alter table ri_full_keyed replica identity full;

insert into ri_full_del values (1, 'x'), (1, 'x');
insert into ri_full_upd values (1, 'x'), (1, 'x');
insert into ri_full_nulldup values (1, null), (1, null);
insert into ri_full_three values (1, 'x'), (1, 'x'), (1, 'x');
insert into ri_full_keyed values (1, 'x'), (2, 'x');

commit;
