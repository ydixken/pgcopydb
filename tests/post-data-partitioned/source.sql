-- Two-level partitioned tables (LIST, then HASH) with several partitioned
-- indexes on the referenced table and two FKs that reference different
-- unique constraints of it.
CREATE SCHEMA app;

CREATE TYPE app.rule_kind AS ENUM ('allow', 'deny');
CREATE TYPE app.rule_level AS ENUM ('low', 'high');

CREATE TABLE app.rules
(
    id uuid NOT NULL,
    kind app.rule_kind NOT NULL,
    tenant_id uuid NOT NULL,
    level app.rule_level NOT NULL,
    enabled boolean,
    owner_id uuid NOT NULL,
    scope_id uuid NOT NULL
)
PARTITION BY LIST (kind);

ALTER TABLE app.rules ADD PRIMARY KEY (id, kind, tenant_id);
ALTER TABLE app.rules ADD UNIQUE (id, kind, tenant_id, level);
ALTER TABLE app.rules ADD UNIQUE (id, kind, tenant_id, enabled);
CREATE INDEX ON app.rules (id);
CREATE INDEX ON app.rules (kind, tenant_id, scope_id);
CREATE INDEX ON app.rules (kind, tenant_id, owner_id);
CREATE UNIQUE INDEX ON app.rules (kind, tenant_id, owner_id, scope_id);

CREATE TABLE app.rule_items
(
    rule_id uuid NOT NULL,
    item_id uuid NOT NULL,
    tenant_id uuid NOT NULL,
    kind app.rule_kind NOT NULL,
    level app.rule_level NOT NULL,
    enabled boolean NOT NULL
)
PARTITION BY LIST (kind);

ALTER TABLE app.rule_items ADD PRIMARY KEY (rule_id, item_id, tenant_id, kind);
CREATE INDEX ON app.rule_items (rule_id);
CREATE INDEX ON app.rule_items (item_id);

ALTER TABLE app.rule_items
  ADD FOREIGN KEY (rule_id, kind, tenant_id, level)
      REFERENCES app.rules (id, kind, tenant_id, level)
      ON DELETE CASCADE;

ALTER TABLE app.rule_items
  ADD FOREIGN KEY (rule_id, kind, tenant_id, enabled)
      REFERENCES app.rules (id, kind, tenant_id, enabled)
      ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED;

DO $$
DECLARE
  k text;
BEGIN
  FOREACH k IN ARRAY ARRAY['allow', 'deny']
  LOOP
    EXECUTE format('CREATE TABLE app.rules_%s PARTITION OF app.rules '
                   'FOR VALUES IN (%L) PARTITION BY HASH (tenant_id)', k, k);
    EXECUTE format('CREATE TABLE app.rule_items_%s PARTITION OF app.rule_items '
                   'FOR VALUES IN (%L) PARTITION BY HASH (tenant_id)', k, k);

    FOR i IN 0..9
    LOOP
      EXECUTE format('CREATE TABLE app.rules_%s_%s PARTITION OF app.rules_%s '
                     'FOR VALUES WITH (MODULUS 10, REMAINDER %s)', k, i, k, i);
    END LOOP;

    FOR i IN 0..4
    LOOP
      EXECUTE format('CREATE TABLE app.rule_items_%s_%s PARTITION OF app.rule_items_%s '
                     'FOR VALUES WITH (MODULUS 5, REMAINDER %s)', k, i, k, i);
    END LOOP;
  END LOOP;
END
$$;