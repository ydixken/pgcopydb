-- A writes to ta, B writes to tb, so each table is compared on its own.
create table ta (id integer primary key, v text);
create table tb (id integer primary key, v text);

insert into ta select g, 'seed' from generate_series(1, 10) g;
