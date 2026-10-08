-- the apply blocks on a row into tx while the target holds a lock on it
create table tx (id integer primary key);

create table t_copy (id integer primary key, v text);
create table t_ins (id integer primary key, v text);
create table t_resend (id integer primary key, v text);

create table p_copy (id integer primary key, v text) partition by range (id);
create table p_copy_a partition of p_copy for values from (minvalue) to (2501);
create table p_copy_b partition of p_copy for values from (2501) to (maxvalue);
