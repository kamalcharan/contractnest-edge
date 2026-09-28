-- Additional-work invoices are receivables, not an intermediate approval state.
-- The previous function wrote 'pending' while Money In only counts unpaid and
-- partially_paid. Patch the live function with exact guards so unrelated edits
-- or invoice functions cannot be silently replaced.
DO $migration$
DECLARE
  definition text;
BEGIN
  definition := pg_get_functiondef('public.create_beyond_scope_invoice(jsonb)'::regprocedure);
  IF strpos(definition, '0, v_total_amount, ''pending'',') = 0
     OR strpos(definition, '''status'', ''pending'',') = 0 THEN
    RAISE EXCEPTION 'Unexpected beyond-scope invoice function; review before migration';
  END IF;
  definition := replace(definition, '0, v_total_amount, ''pending'',', '0, v_total_amount, ''unpaid'',');
  definition := replace(definition, '''status'', ''pending'',', '''status'', ''unpaid'',');
  EXECUTE definition;
END
$migration$;

-- Repair only the already-created, fully unpaid additional-work invoice(s).
UPDATE public.t_invoices
SET status = 'unpaid', updated_at = now()
WHERE status = 'pending'
  AND invoice_type = 'receivable'
  AND line_items->>'beyond_scope' = 'true'
  AND COALESCE(amount_paid, 0) = 0
  AND balance > 0;
