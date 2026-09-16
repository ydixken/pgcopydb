-- Drop an orphan publication only when no slot exists; refuse a slot without its publication.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_replication_slots WHERE slot_name = 'pgcopydb') THEN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_publication WHERE pubname = 'pgcopydb') THEN
      RAISE EXCEPTION 'publication retry refused: source slot "pgcopydb" exists but auto publication "pgcopydb" is missing';
    END IF;
  ELSE
    DROP PUBLICATION IF EXISTS "pgcopydb";
  END IF;
END;
$$;
