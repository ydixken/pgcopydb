---
--- pgcopydb tests/cdc-replica-identity-full/dml.sql
---
--- Each statement changes some of a set of identical rows. A WHERE clause
--- over all columns matches every copy, so the target must not use one.
---

begin;

delete from ri_full_del where ctid = (select ctid from ri_full_del limit 1);
update ri_full_upd set b = 'y' where ctid = (select ctid from ri_full_upd limit 1);
delete from ri_full_nulldup where ctid = (select ctid from ri_full_nulldup limit 1);

-- two DELETE messages in one transaction: they must not be batched into IN
delete from ri_full_three where ctid in (select ctid from ri_full_three limit 2);

update ri_full_keyed set b = 'y' where id = 1;
delete from ri_full_keyed where id = 2;

commit;
