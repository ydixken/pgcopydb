-- Run in the ctl database with -v db=<migrated database>.
-- B begins first, A begins, B commits, then A writes and commits last, so
-- A's BEGIN sits below B's COMMIT and nothing commits after A.
\set ON_ERROR_STOP on

select dblink_connect('a', 'dbname=' || :'db');
select dblink_connect('b', 'dbname=' || :'db');

select dblink_exec('b', 'begin');
select dblink_exec('b', $$insert into tb values (4, 'B4')$$);
select dblink_exec('a', 'begin');
select dblink_exec('a', $$update ta set v = 'A4 updated' where id = 3$$);
select dblink_exec('b', 'commit');
select dblink_exec('a', $$delete from ta where id = 4$$);
select dblink_exec('a', $$insert into ta values (204, 'A4 last')$$);
select dblink_exec('a', 'commit');

select dblink_disconnect('a');
select dblink_disconnect('b');
