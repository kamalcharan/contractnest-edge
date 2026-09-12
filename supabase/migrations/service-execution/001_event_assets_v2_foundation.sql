-- ═══════════════════════════════════════════════════════════════════
-- service-execution/001_event_assets_v2_foundation.sql — B1 foundation
-- APPLIED LIVE 2026-09-03. Source-of-record copy — idempotent, but do
-- not re-run without reason.
--
-- Sprint 2+7 foundation (Service Execution V3, decisions D3/D9/D10):
-- 1) generate_contract_event_assets_v2 — per-asset fan-out reading n_jtd
--    SERVICE JOBS (event_type_code='service_visit') × equipment_details,
--    writing the same t_contract_event_assets shape as V1 (event_id =
--    jtd id). V1 function + trigger completely untouched.
-- 2) trg_zz_generate_event_assets_v2 — ADDITIVE second trigger on
--    t_contracts activation calling the V2 fan-out (no-ops for V1
--    contracts: they have no service jobs).
-- 3) FK transition: t_contract_event_assets_event_id_fkey (→
--    t_contract_events, NO ACTION) DROPPED — V2 contracts have no event
--    rows, so the fan-out could never insert. Integrity kept by
--    trg_zz_event_assets_ref_check (event_id must exist in
--    t_contract_events OR n_jtd job rows). Definitive FK → n_jtd lands
--    at cutover Phase 6 when all tenants' rows exist there.
-- 4) Backfill for already-active V2 contracts. Live result:
--    CN-1005 (signia) 48 rows, CN-1027 (signia) 11 rows — all keyed to
--    job ids, all blocked_placeholder (their equipment entries carry no
--    asset_registry_id, per the placeholder rule).
--
-- Placeholder rule (matches V1): an equipment_details entry with no
-- asset_registry_id (or specifications.placeholder='true') fans out as
-- status='blocked_placeholder'; attach-asset unlocks it.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.generate_contract_event_assets_v2(p_contract_id uuid, p_tenant_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_inserted integer := 0;
BEGIN
  WITH assets AS (
    SELECT
      coalesce(a->>'asset_registry_id', a->>'id') AS asset_ref,
      coalesce(a->>'item_name', a->>'name', 'Asset') AS asset_name,
      (a->>'asset_registry_id' IS NULL
        OR coalesce(a->'specifications'->>'placeholder', 'false') = 'true') AS is_placeholder
    FROM t_contracts c,
         jsonb_array_elements(coalesce(c.equipment_details, '[]'::jsonb)) a
    WHERE c.id = p_contract_id AND c.tenant_id = p_tenant_id
  ), ins AS (
    INSERT INTO t_contract_event_assets
      (tenant_id, contract_id, event_id, asset_ref, asset_name, status, is_live)
    SELECT j.tenant_id, j.contract_id, j.id, a.asset_ref, a.asset_name,
           CASE WHEN a.is_placeholder THEN 'blocked_placeholder' ELSE 'open' END,
           j.is_live
    FROM n_jtd j CROSS JOIN assets a
    WHERE j.contract_id = p_contract_id AND j.tenant_id = p_tenant_id
      AND j.channel_code IS NULL AND j.event_type_code = 'service_visit' AND j.is_active
    ON CONFLICT (event_id, asset_ref) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO v_inserted FROM ins;
  RETURN v_inserted;
END $function$;

CREATE OR REPLACE FUNCTION public.trg_fn_generate_event_assets_v2()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
AS $function$
BEGIN
  IF NEW.status = 'active' AND (OLD.status IS DISTINCT FROM NEW.status) THEN
    PERFORM generate_contract_event_assets_v2(NEW.id, NEW.tenant_id);
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_zz_generate_event_assets_v2 ON t_contracts;
CREATE TRIGGER trg_zz_generate_event_assets_v2
AFTER UPDATE ON t_contracts
FOR EACH ROW EXECUTE FUNCTION trg_fn_generate_event_assets_v2();

ALTER TABLE t_contract_event_assets DROP CONSTRAINT IF EXISTS t_contract_event_assets_event_id_fkey;

CREATE OR REPLACE FUNCTION public.trg_fn_event_assets_ref_check()
RETURNS trigger LANGUAGE plpgsql
AS $function$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM t_contract_events e WHERE e.id = NEW.event_id)
     AND NOT EXISTS (SELECT 1 FROM n_jtd j WHERE j.id = NEW.event_id AND j.channel_code IS NULL) THEN
    RAISE EXCEPTION 'event_id % exists in neither t_contract_events nor n_jtd', NEW.event_id;
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_zz_event_assets_ref_check ON t_contract_event_assets;
CREATE TRIGGER trg_zz_event_assets_ref_check
BEFORE INSERT OR UPDATE OF event_id ON t_contract_event_assets
FOR EACH ROW EXECUTE FUNCTION trg_fn_event_assets_ref_check();

-- Backfill: active V2 contracts that never got a fan-out.
DO $do$
DECLARE r RECORD; v_n integer; v_total integer := 0; v_contracts integer := 0;
BEGIN
  FOR r IN
    SELECT c.id, c.tenant_id, c.contract_number
    FROM t_contracts c
    WHERE c.status = 'active' AND c.record_type = 'contract'
      AND jsonb_array_length(COALESCE(c.equipment_details, '[]'::jsonb)) > 0
      AND EXISTS (SELECT 1 FROM n_jtd j WHERE j.contract_id = c.id AND j.channel_code IS NULL
                  AND j.event_type_code = 'service_visit'
                  AND COALESCE(j.business_context->>'migration','') <> 'jtd-cutover/001')
      AND NOT EXISTS (SELECT 1 FROM t_contract_event_assets ea WHERE ea.contract_id = c.id)
  LOOP
    v_n := generate_contract_event_assets_v2(r.id, r.tenant_id);
    v_total := v_total + v_n; v_contracts := v_contracts + 1;
    RAISE NOTICE 'backfill %: % rows', r.contract_number, v_n;
  END LOOP;
  RAISE NOTICE 'B1 backfill: % contracts, % event-asset rows', v_contracts, v_total;
END
$do$;
