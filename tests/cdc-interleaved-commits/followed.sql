-- Run in the ctl database with -v db=<migrated database>.
-- In each round A writes, B begins, writes and commits, then A writes and
-- commits, so A's BEGIN sits below B's COMMIT.  A later commit follows.
\set ON_ERROR_STOP on

select dblink_connect('a', 'dbname=' || :'db');
select dblink_connect('b', 'dbname=' || :'db');

select dblink_exec('a', 'begin');
select dblink_exec('a', $$insert into ta values (101, 'A1 first')$$);
select dblink_exec('b', 'begin');
select dblink_exec('b', $$insert into tb values (1, 'B1')$$);
select dblink_exec('b', 'commit');
select dblink_exec('a', $$insert into ta values (201, 'A1 last')$$);
select dblink_exec('a', 'commit');

select dblink_exec('a', 'begin');
select dblink_exec('a', $$update ta set v = 'A2 updated' where id = 1$$);
select dblink_exec('b', 'begin');
select dblink_exec('b', $$insert into tb values (2, 'B2')$$);
select dblink_exec('b', 'commit');
select dblink_exec('a', $$insert into ta values (202, 'A2 last')$$);
select dblink_exec('a', 'commit');

select dblink_exec('a', 'begin');
select dblink_exec('a', $$delete from ta where id = 2$$);
select dblink_exec('b', 'begin');
select dblink_exec('b', $$insert into tb values (3, 'B3')$$);
select dblink_exec('b', 'commit');
select dblink_exec('a', $$insert into ta values (203, 'A3 last')$$);
select dblink_exec('a', 'commit');

select dblink_exec('b', $$insert into tb values (9, 'after A')$$);

select dblink_disconnect('a');
select dblink_disconnect('b');
