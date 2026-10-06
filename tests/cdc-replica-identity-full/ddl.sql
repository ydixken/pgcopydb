---
--- pgcopydb tests/cdc-replica-identity-full/ddl.sql
---
--- REPLICA IDENTITY FULL tables. Without a primary key or a replica identity
--- index, identical rows are legal, and each replicated UPDATE or DELETE must
--- change exactly one of them, as PostgreSQL's own apply worker does.
---

begin;

create table ri_full_del (a int, b text);
create table ri_full_upd (a int, b text);
create table ri_full_nulldup (a int, b text);
create table ri_full_three (a int, b text);

-- all-NULL rows: the old row has no value to match with a parameter
create table ri_full_allnulldel (a int, b text);
create table ri_full_allnullupd (a int, b text);

-- with a primary key the generated statements keep their usual WHERE clause
create table ri_full_keyed (id int primary key, b text);

alter table ri_full_del replica identity full;
alter table ri_full_upd replica identity full;
alter table ri_full_nulldup replica identity full;
alter table ri_full_three replica identity full;
alter table ri_full_allnulldel replica identity full;
alter table ri_full_allnullupd replica identity full;
alter table ri_full_keyed replica identity full;

commit;

-- Seed rows that exist before the clone snapshot.
insert into ri_full_del values (1, 'x'), (1, 'x');
insert into ri_full_upd values (1, 'x'), (1, 'x');
insert into ri_full_nulldup values (1, null), (1, null);
insert into ri_full_three values (1, 'x'), (1, 'x'), (1, 'x');
insert into ri_full_allnulldel values (null, null), (1, 'x');
insert into ri_full_allnullupd values (null, null), (1, 'x');
insert into ri_full_keyed values (1, 'x'), (2, 'x');
