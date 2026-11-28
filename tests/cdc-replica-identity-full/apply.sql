BEGIN
PREPARE 4d5aa5fc AS DELETE FROM ONLY "public"."ri_full_del" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_del" WHERE "a" = $1 and "b" = $2 LIMIT 1);
EXECUTE 4d5aa5fc
PREPARE 29854b1a AS UPDATE ONLY "public"."ri_full_upd" SET "b" = $1 WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_upd" WHERE "a" = $2 and "b" = $3 LIMIT 1);
EXECUTE 29854b1a
PREPARE fb5feb40 AS DELETE FROM ONLY "public"."ri_full_nulldup" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_nulldup" WHERE "a" = $1 and "b" IS NULL LIMIT 1);
EXECUTE fb5feb40
PREPARE 79167951 AS DELETE FROM ONLY "public"."ri_full_three" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_three" WHERE "a" = $1 and "b" = $2 LIMIT 1);
EXECUTE 79167951
EXECUTE 79167951
PREPARE 2d0284c1 AS UPDATE ONLY "public"."ri_full_keyed" SET "b" = $1 WHERE "id" = $2 and "b" = $3;
EXECUTE 2d0284c1
PREPARE c1a56d8e AS DELETE FROM ONLY "public"."ri_full_keyed" WHERE "id" = $1 and "b" = $2;
EXECUTE c1a56d8e
PREPARE c68f071f AS DELETE FROM ONLY "public"."ri_full_allnulldel" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_allnulldel" WHERE "a" IS NULL and "b" IS NULL LIMIT 1);
EXECUTE c68f071f
PREPARE bb04bda8 AS UPDATE ONLY "public"."ri_full_allnullupd" SET "b" = $1 WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM ONLY "public"."ri_full_allnullupd" WHERE "a" IS NULL and "b" IS NULL LIMIT 1);
EXECUTE bb04bda8
COMMIT
