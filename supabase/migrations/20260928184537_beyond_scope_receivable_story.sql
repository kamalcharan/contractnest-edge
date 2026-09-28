-- Let Money In distinguish the extra invoice from scheduled-contract billing
-- without exposing the invoice's full line-item envelope in its list payload.
DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_get_functiondef('public.get_tenant_receivables(uuid,boolean)'::regprocedure);
  IF strpos(definition, '(c.id IS NULL) AS is_adhoc,') = 0
     OR strpos(definition, '(i.line_items->>''beyond_scope'' = ''true'') AS is_beyond_scope,') > 0 THEN
    RAISE EXCEPTION 'Unexpected Money In function; review before migration';
  END IF;
  definition := replace(definition,
    '(c.id IS NULL) AS is_adhoc,',
    '(i.line_items->>''beyond_scope'' = ''true'') AS is_beyond_scope, (c.id IS NULL) AS is_adhoc,');
  EXECUTE definition;
END
$migration$;
