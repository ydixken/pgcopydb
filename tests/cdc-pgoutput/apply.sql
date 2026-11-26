BEGIN
PREPARE ec9f2790 AS INSERT INTO "public"."rental" ("rental_id", "rental_date", "inventory_id", "customer_id", "return_date", "staff_id", "last_update") overriding system value VALUES ($1, $2, $3, $4, $5, $6, $7);
EXECUTE ec9f2790
PREPARE 4afa901a AS INSERT INTO "public"."payment_p2022_06" ("payment_id", "customer_id", "staff_id", "rental_id", "amount", "payment_date") overriding system value VALUES ($1, $2, $3, $4, $5, $6);
EXECUTE 4afa901a
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
PREPARE c5d1b287 AS DELETE FROM ONLY "public"."payment_p2022_06" WHERE "payment_id" = $1 and "customer_id" = $2 and "staff_id" = $3 and "rental_id" = $4 and "amount" = $5 and "payment_date" = $6;
EXECUTE c5d1b287
PREPARE 2ed5e2b2 AS DELETE FROM ONLY "public"."rental" WHERE "rental_id" = $1;
EXECUTE 2ed5e2b2
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
BEGIN
PREPARE 150e8d8a AS DELETE FROM ONLY "public"."address" WHERE "address_id" = $1 and "address" = $2 and "address2" IS NULL and "district" = $3 and "city_id" = $4 and "postal_code" = $5 and "phone" = $6 and "last_update" = $7;
EXECUTE 150e8d8a
EXECUTE 150e8d8a
PREPARE a8e9e67b AS UPDATE ONLY "public"."address" SET "postal_code" = $1 WHERE "address_id" = $2 and "address" = $3 and "address2" IS NULL and "district" = $4 and "city_id" = $5 and "postal_code" = $6 and "phone" = $7 and "last_update" = $8;
EXECUTE a8e9e67b
COMMIT
BEGIN
PREPARE a5a12d9d AS INSERT INTO "public"."generated_column_test" ("id", "name", "email") overriding system value VALUES ($1, $2, $3), ($4, $5, $6), ($7, $8, $9);
EXECUTE a5a12d9d
COMMIT
BEGIN
PREPARE d9a82a7d AS UPDATE ONLY "public"."generated_column_test" SET "name" = $1, "email" = $2 WHERE "id" = $3;
EXECUTE d9a82a7d
EXECUTE d9a82a7d
COMMIT
BEGIN
EXECUTE d9a82a7d
COMMIT
BEGIN
PREPARE 9319a7c8 AS DELETE FROM ONLY "public"."generated_column_test" WHERE "id" = $1;
EXECUTE 9319a7c8
COMMIT
BEGIN
PREPARE 14a82b14 AS INSERT INTO "public"."single_column_table" ("id") overriding system value VALUES ($1), ($2);
EXECUTE 14a82b14
PREPARE 45a47ea2 AS INSERT INTO "public"."multi_column_table" ("id", "name", "email") overriding system value VALUES ($1, $2, $3), ($4, $5, $6);
EXECUTE 45a47ea2
COMMIT
BEGIN
COMMIT
BEGIN
PREPARE 34fb45dc AS INSERT INTO "public"."multi_delete_test" ("id", "val") overriding system value VALUES ($1, $2), ($3, $4), ($5, $6), ($7, $8), ($9, $10);
EXECUTE 34fb45dc
COMMIT
BEGIN
PREPARE 68eed850 AS DELETE FROM ONLY "public"."multi_delete_test" WHERE "id" IN ($1, $2, $3, $4, $5);
EXECUTE 68eed850
COMMIT
BEGIN
PREPARE 2eb2b427 AS INSERT INTO "public"."multi_delete_composite_test" ("id1", "id2", "val") overriding system value VALUES ($1, $2, $3), ($4, $5, $6), ($7, $8, $9);
EXECUTE 2eb2b427
COMMIT
BEGIN
PREPARE 30ed2a AS DELETE FROM ONLY "public"."multi_delete_composite_test" WHERE ("id1", "id2") IN (($1, $2), ($3, $4), ($5, $6));
EXECUTE 30ed2a
COMMIT
BEGIN
COMMIT
BEGIN
PREPARE 5fb4b087 AS INSERT INTO "Sp1eCial .Char"."source1testing" ("s0", "s""1") overriding system value VALUES ($1, $2), ($3, $4), ($5, $6), ($7, $8), ($9, $10);
EXECUTE 5fb4b087
COMMIT
BEGIN
PREPARE b653bae2 AS UPDATE ONLY "Sp1eCial .Char"."source1testing" SET "s""1" = $1 WHERE "s0" = $2;
EXECUTE b653bae2
EXECUTE b653bae2
EXECUTE b653bae2
EXECUTE b653bae2
EXECUTE b653bae2
COMMIT
BEGIN
PREPARE ee7cd43f AS DELETE FROM ONLY "Sp1eCial .Char"."source1testing" WHERE "s0" = $1;
EXECUTE ee7cd43f
COMMIT
BEGIN
PREPARE 477f61f7 AS INSERT INTO "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789012345678901234567890123456"."abcdefghijklmnopqrstuvwxyz0123456789012345678901234567890123456" ("abcdefghijklmnopqrstuvwxyz0123456789012345678901234567890123456", "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789012345678901234567890123456") overriding system value VALUES ($1, $2), ($3, $4), ($5, $6), ($7, $8), ($9, $10);
EXECUTE 477f61f7
COMMIT
BEGIN
PREPARE 181792cc AS UPDATE ONLY "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789012345678901234567890123456"."abcdefghijklmnopqrstuvwxyz0123456789012345678901234567890123456" SET "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789012345678901234567890123456" = $1 WHERE "abcdefghijklmnopqrstuvwxyz0123456789012345678901234567890123456" = $2;
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
EXECUTE 181792cc
COMMIT
