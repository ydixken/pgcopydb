\echo Use "CREATE EXTENSION cfgdump" to load this file. \quit

-- the rows this script inserts come with CREATE EXTENSION; only the rows that
-- match the dump condition are user data
create table cfgdump_settings(id integer primary key, val text not null);
insert into cfgdump_settings values (1, 'shipped 1'), (2, 'shipped 2'), (3, 'shipped 3');
select pg_catalog.pg_extension_config_dump('cfgdump_settings', 'WHERE id > 100');

create sequence cfgdump_seq;
select pg_catalog.pg_extension_config_dump('cfgdump_seq', '');
