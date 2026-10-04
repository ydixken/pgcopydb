WITH RECURSIVE
eligible AS (
    SELECT unnest($1::oid[]) AS oid
),
relations AS (
    SELECT c.oid, format('%I.%I', n.nspname, c.relname) AS qname,
           c.relkind, c.relispartition, c.relpartbound
      FROM pg_catalog.pg_class c
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
),
edges AS (
    -- Ordinary inheritance does not define a declarative partition family.
    SELECT i.inhrelid AS child, i.inhparent AS parent
      FROM pg_catalog.pg_inherits i
      JOIN relations r ON r.oid = i.inhrelid
     WHERE r.relispartition AND r.relkind IN ('r', 'p', 'f')
),
source_names AS (
    SELECT json_array_elements_text($2::json) AS qname
),
source_anchors AS (
    SELECT json_array_elements_text($3::json) AS qname
),
family(oid) AS (
    SELECT r.oid
      FROM relations r
      JOIN source_anchors a USING (qname)
    UNION
    SELECT e.child
      FROM family f
      JOIN edges e ON e.parent = f.oid
),
selected AS (
    SELECT r.oid
      FROM relations r
     WHERE ($2::json IS NULL AND (r.relkind IN ('r', 'p') OR r.relispartition)
            AND r.oid IN (SELECT oid FROM eligible))
        OR ($2::json IS NOT NULL
            AND (r.qname IN (SELECT qname FROM source_names)
                 OR (r.oid IN (SELECT oid FROM family)
                     AND r.oid IN (SELECT oid FROM eligible))))
),
inventory(oid) AS (
    SELECT oid FROM selected
    UNION
    SELECT e.parent
      FROM inventory i
      JOIN edges e ON e.child = i.oid
)
SELECT r.qname, r.relkind::text,
       coalesce(parent.qname, '') AS parent_qname,
       coalesce(p.partstrat::text, '') AS strategy,
       coalesce(pg_catalog.pg_get_partkeydef(r.oid), '') AS partkey,
       coalesce(pg_catalog.pg_get_expr(r.relpartbound, r.oid, false), '') AS bound,
       r.oid IN (SELECT oid FROM eligible) AS eligible,
       r.oid
  FROM inventory i
  JOIN relations r ON r.oid = i.oid
  LEFT JOIN edges e ON e.child = r.oid
  LEFT JOIN relations parent ON parent.oid = e.parent
  LEFT JOIN pg_catalog.pg_partitioned_table p ON p.partrelid = r.oid
 ORDER BY r.qname COLLATE "C";
