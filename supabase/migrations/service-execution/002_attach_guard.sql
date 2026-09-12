-- ═══════════════════════════════════════════════════════════════════
-- service-execution/002_attach_guard.sql — APPLIED LIVE 2026-09-04.
-- Source-of-record copy (marker-guarded; re-run no-ops).
--
-- THE BUG (owner-reported, CN-1005 went 3 → 4 → 6 units): the UI has
-- always sent replaces_item_id on attach, and the RPCs have always had
-- a complete replacement branch (in-place JSONB swap + placeholder
-- validation + unlock_placeholder_event_assets) — but the API
-- controller destructured only equipment_item, and the edge handlers
-- passed only p_equipment_item. The field died at the API boundary, so
-- EVERY attach appended a new unit and no placeholder was ever
-- replaced or unlocked.
--
-- FULL FIX, four layers:
--   L1 (this file, part a) coverage cap: while open placeholder slots
--      of the same category exist, a plain (non-replacement) add is
--      REFUSED with code SLOTS_OPEN — spliced into BOTH
--      buyer/seller_add_equipment_to_contract append paths
--      (anchored, exactly-once asserted, marker 'service-execution/002').
--   L1 (part b) unlock_placeholder_event_assets also refreshes
--      asset_name from t_tenant_asset_registry / t_client_asset_registry
--      so proof rows show the real unit's name.
--   L2 edge contracts fn v55 (DEPLOYED): both handlers pass
--      p_replaces_item_id: replaces_item_id ?? null. Deployed source
--      byte-verified against the patch (index.ts identical).
--   L3 API contractController.ts + contractService.ts pass the field
--      through (files in this batch).
--   L4 UI already correct (sends replacesItemId on both attach paths).
--
-- Verified live (forced-rollback harness on signia CN-1005):
--   replace: success, equipment_details 6 → 6 (in-place swap),
--   16 blocked proof rows → 16 open rows rewired to the new asset ref;
--   plain append while slots remain: success=false, code=SLOTS_OPEN.
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_fn TEXT; v_def TEXT;
    v_anchor TEXT := $a$v_item_id := COALESCE(p_equipment_item->>'id', gen_random_uuid()::text);$a$;
    v_guard TEXT;
BEGIN
    v_guard :=
        $g$-- service-execution/002: coverage cap — attach into open slots first
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(v_contract.equipment_details,'[]'::jsonb)) e
        WHERE (e->>'asset_registry_id' IS NULL
               OR COALESCE(e->'specifications'->>'placeholder','false') = 'true')
          AND COALESCE(e->>'category_id','') = COALESCE(p_equipment_item->>'category_id','')
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'This contract still has uncovered slots for this equipment category — use Attach asset on a placeholder instead of adding a new unit',
            'code', 'SLOTS_OPEN'
        );
    END IF;

    $g$;

    FOREACH v_fn IN ARRAY ARRAY['buyer_add_equipment_to_contract','seller_add_equipment_to_contract'] LOOP
        SELECT pg_get_functiondef(oid) INTO v_def
        FROM pg_proc WHERE proname = v_fn AND pronamespace = 'public'::regnamespace;

        IF v_def IS NULL THEN
            RAISE EXCEPTION '% not found', v_fn;
        END IF;
        IF position('service-execution/002' in v_def) > 0 THEN
            RAISE NOTICE '% already guarded — skipping', v_fn;
            CONTINUE;
        END IF;
        IF (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 THEN
            RAISE EXCEPTION 'append-path anchor not found exactly once in % — aborting', v_fn;
        END IF;

        v_def := replace(v_def, v_anchor, v_guard || v_anchor);
        EXECUTE v_def;

        SELECT pg_get_functiondef(oid) INTO v_def
        FROM pg_proc WHERE proname = v_fn AND pronamespace = 'public'::regnamespace;
        IF position('service-execution/002' in v_def) = 0 THEN
            RAISE EXCEPTION 'post-check FAILED: guard not present in %', v_fn;
        END IF;
        RAISE NOTICE '%: coverage cap installed and verified', v_fn;
    END LOOP;
END
$do$;

CREATE OR REPLACE FUNCTION public.unlock_placeholder_event_assets(
    p_contract_id uuid, p_tenant_id uuid, p_old_ref text, p_new_ref text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE v_count integer; v_name text;
BEGIN
  -- service-execution/002: pick up the real unit's name from either registry
  SELECT name INTO v_name FROM t_tenant_asset_registry WHERE id::text = p_new_ref
  UNION ALL
  SELECT name FROM t_client_asset_registry WHERE id::text = p_new_ref
  LIMIT 1;

  UPDATE t_contract_event_assets
  SET asset_ref = coalesce(p_new_ref, asset_ref),
      asset_name = coalesce(v_name, asset_name),
      status = 'open', updated_at = now()
  WHERE contract_id = p_contract_id AND tenant_id = p_tenant_id
    AND asset_ref = p_old_ref AND status = 'blocked_placeholder' AND is_active;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END $fn$;
