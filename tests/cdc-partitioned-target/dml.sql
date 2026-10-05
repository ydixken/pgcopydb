---
--- pgcopydb tests/cdc-partitioned-target/dml.sql
---
--- DML phase 1: INSERT new rows on the flat source. After replay these
--- should land in the correct partitions on the target. Phase 2 (the
--- TRUNCATE) is in dml-truncate.sql so the test can checkpoint between
--- the two and assert each phase independently.
---

begin;

insert into partitioned_target.events (id, bucket, payload)
     values (4, 1, 'd'),
            (5, 0, 'e');

-- both keyless rows sit at ctid (0,1) of their own target partition
delete from partitioned_target.keyless where payload = 'a';

commit;
