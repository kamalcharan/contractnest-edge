-- Migration: bbb-foundation/013_events_list_contact_context.sql
-- ============================================================================
-- Expose contract relationship + buyer contact context in the events list RPC
-- so the Event Schedule can show a proper contact icon (individual vs corporate)
-- and relationship badge (client / partner / vendor), and filter by it — instead
-- of a generic "Customer" column.
--
-- get_contract_events_list builds each row via a dynamic jsonb_build_object and
-- already LEFT JOINs t_contracts c. This adds:
--   * a LEFT JOIN to t_contacts (the buyer) for entity type + classifications
--   * contract_type            (client / partner / vendor)   from t_contracts
--   * buyer_type               (individual / corporate)      from t_contacts
--   * buyer_classifications    (jsonb array)                 from t_contacts
--
-- Applied drift-proof (rewrites the deployed function with the join + fields
-- inserted; idempotent — skips if contract_type is already present).
-- ============================================================================

DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname='get_contract_events_list';
  IF v_def IS NULL THEN RAISE EXCEPTION 'get_contract_events_list not found'; END IF;
  IF v_def LIKE '%contract_type%' THEN RETURN; END IF; -- already patched

  v_def := replace(
    v_def,
    'LEFT JOIN t_appointments ap ON ap.event_id = ce.id AND ap.is_active = true',
    'LEFT JOIN t_contacts bc ON bc.id = c.buyer_id
             LEFT JOIN t_appointments ap ON ap.event_id = ce.id AND ap.is_active = true'
  );

  v_def := replace(
    v_def,
    '''''contract_number'''', c.contract_number,',
    '''''contract_number'''', c.contract_number, ''''contract_type'''', c.contract_type,'
  );

  v_def := replace(
    v_def,
    '''''buyer_name'''', COALESCE(c.buyer_company, c.buyer_name),',
    '''''buyer_name'''', COALESCE(c.buyer_company, c.buyer_name), ''''buyer_type'''', bc.type, ''''buyer_classifications'''', bc.classifications,'
  );

  EXECUTE v_def;
END $mig$;
