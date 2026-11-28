BEGIN
PREPARE 155adeb0 AS INSERT INTO "public"."rental" ("rental_id", "rental_date", "inventory_id", "customer_id", "return_date", "staff_id", "last_update") overriding system value VALUES ($1, $2, $3, $4, $5, $6, $7), ($8, $9, $10, $11, $12, $13, $14);
EXECUTE 155adeb0
PREPARE d51d99db AS INSERT INTO "public"."payment_p2022_06" ("payment_id", "customer_id", "staff_id", "rental_id", "amount", "payment_date") overriding system value VALUES ($1, $2, $3, $4, $5, $6), ($7, $8, $9, $10, $11, $12);
EXECUTE d51d99db
COMMIT
BEGIN
PREPARE 7a17efdc AS UPDATE ONLY "public"."payment_p2022_02" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE 7a17efdc
EXECUTE 7a17efdc
PREPARE 1833fd2e AS UPDATE ONLY "public"."payment_p2022_03" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE 1833fd2e
EXECUTE 1833fd2e
PREPARE afb87aee AS UPDATE ONLY "public"."payment_p2022_04" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE afb87aee
PREPARE d5b0dcd7 AS UPDATE ONLY "public"."payment_p2022_05" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE d5b0dcd7
PREPARE 6d34c8da AS UPDATE ONLY "public"."payment_p2022_06" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE 6d34c8da
EXECUTE 6d34c8da
PREPARE 719bfc86 AS UPDATE ONLY "public"."payment_p2022_07" SET "amount" = $1 WHERE "payment_id" = $2 and "customer_id" = $3 and "staff_id" = $4 and "rental_id" = $5 and "amount" = $6 and "payment_date" = $7;
EXECUTE 719bfc86
EXECUTE 719bfc86
COMMIT
BEGIN
PREPARE b0ed1417 AS DELETE FROM ONLY "public"."payment_p2022_06" WHERE ("payment_id", "customer_id", "staff_id", "rental_id", "amount", "payment_date") IN (($1, $2, $3, $4, $5, $6), ($7, $8, $9, $10, $11, $12));
EXECUTE b0ed1417
PREPARE 46ea32ab AS DELETE FROM ONLY "public"."rental" WHERE "rental_id" IN ($1, $2);
EXECUTE 46ea32ab
COMMIT
BEGIN
EXECUTE 7a17efdc
EXECUTE 7a17efdc
EXECUTE 1833fd2e
EXECUTE 1833fd2e
EXECUTE afb87aee
EXECUTE d5b0dcd7
EXECUTE 6d34c8da
EXECUTE 6d34c8da
EXECUTE 719bfc86
EXECUTE 719bfc86
COMMIT
