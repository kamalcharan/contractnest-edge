-- Reuse the tenant-scoped receivables response to restore invoices in a
-- reopened service workspace. Only the ticket UUID is exposed; invoice detail
-- and authorization remain on the existing invoice endpoints.
DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_get_functiondef('public.get_tenant_receivables(uuid,boolean)'::regprocedure);
  IF strpos(definition, '(i.line_items->>''beyond_scope'' = ''true'') AS is_beyond_scope,') = 0
     OR strpos(definition, '(i.line_items->>''ticket_id'') AS service_ticket_id,') > 0 THEN
    RAISE EXCEPTION 'Unexpected Money In function; review before migration';
  END IF;
  definition := replace(definition,
    '(i.line_items->>''beyond_scope'' = ''true'') AS is_beyond_scope,',
    '(i.line_items->>''ticket_id'') AS service_ticket_id, (i.line_items->>''beyond_scope'' = ''true'') AS is_beyond_scope,');
  EXECUTE definition;
END
$migration$;
