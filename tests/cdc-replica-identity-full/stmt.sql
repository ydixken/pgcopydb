DELETE FROM "public"."ri_full_del" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_del" WHERE "a" = $1 and "b" = $2 LIMIT 1)
UPDATE "public"."ri_full_upd" SET "b" = $1 WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_upd" WHERE "a" = $2 and "b" = $3 LIMIT 1)
DELETE FROM "public"."ri_full_nulldup" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_nulldup" WHERE "a" = $1 and "b" IS NULL LIMIT 1)
DELETE FROM "public"."ri_full_three" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_three" WHERE "a" = $1 and "b" = $2 LIMIT 1)
UPDATE "public"."ri_full_keyed" SET "b" = $1 WHERE "id" = $2 and "b" = $3
DELETE FROM "public"."ri_full_keyed" WHERE "id" = $1 and "b" = $2
DELETE FROM "public"."ri_full_allnulldel" WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_allnulldel" WHERE "a" IS NULL and "b" IS NULL LIMIT 1)
UPDATE "public"."ri_full_allnullupd" SET "b" = $1 WHERE (tableoid, ctid) = (SELECT tableoid, ctid FROM "public"."ri_full_allnullupd" WHERE "a" IS NULL and "b" IS NULL LIMIT 1)
