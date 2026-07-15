-- Migration: bbb-foundation/014_events_audience_marker.sql
-- ============================================================================
-- Persist the group-session marker (audience) on contract events, so the Event
-- Schedule / Ops calendars can label a "Group Session" and route to check-in
-- instead of offering a 1:1 appointment, and so a "Group Sessions" tab can
-- filter on it (WHERE audience = 'group').
--
-- Flow (all layers now carry audience):
--   UI computed_events  ->  process_contract_events_from_computed (verbatim)
--   ->  insert_contract_events_batch  ->  t_contract_events.audience
--   ->  get_contract_events_list  ->  EventCard (already reads event.audience).
--
-- The two RPC patches are drift-proof (rewrite the *deployed* function via
-- pg_get_functiondef + replace, preserving any earlier patches) and idempotent.
-- ============================================================================

-- 1. Column ----------------------------------------------------------------
ALTER TABLE t_contract_events ADD COLUMN IF NOT EXISTS audience TEXT;

-- 2. insert_contract_events_batch — persist audience -----------------------
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname = 'insert_contract_events_batch';
  IF v_def IS NULL THEN RAISE EXCEPTION 'insert_contract_events_batch not found'; END IF;
  IF v_def LIKE '%v_event->>''audience''%' THEN RETURN; END IF;   -- already patched

  -- add the column to the INSERT list (event_type, is unique in this fn body)
  v_def := replace(v_def, 'event_type,', 'event_type, audience,');
  -- add the matching value
  v_def := replace(v_def, 'v_event->>''event_type'',', 'v_event->>''event_type'', v_event->>''audience'',');

  EXECUTE v_def;
END $mig$;

-- 3. get_contract_events_list — return audience ----------------------------
DO $mig$
DECLARE v_def text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO v_def FROM pg_proc WHERE proname = 'get_contract_events_list';
  IF v_def IS NULL THEN RAISE EXCEPTION 'get_contract_events_list not found'; END IF;
  IF v_def LIKE '%ce.audience%' THEN RETURN; END IF;              -- already patched

  -- inject into the dynamic jsonb_build_object (doubled quotes = dynamic SQL)
  v_def := replace(
    v_def,
    '''''event_type'''', ce.event_type,',
    '''''event_type'''', ce.event_type, ''''audience'''', ce.audience,'
  );

  EXECUTE v_def;
END $mig$;
