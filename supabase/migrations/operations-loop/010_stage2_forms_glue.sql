-- ============================================================================
-- Migration: Stage 2 Services — 010 Smart-forms creation-time glue
-- ============================================================================
-- Purpose (POA §3, owner-agreed): m_form_template_mappings had ZERO writers.
--   1. sync_contract_form_mappings(contract, tenant): writes mappings from
--      (a) t_contracts.evidence_selected_forms [{form_template_id, name, ...}]
--      (b) fallback: the contract's blocks → m_cat_blocks.form_template_id
--      timing='pre_service', is_mandatory=true, effective_from = contract
--      start date (stable → idempotent re-runs).
--   2. Trigger on t_contracts: fires when a contract becomes ACTIVE
--      (insert or status change) — same moment events materialize.
--   3. Backfill for existing active contracts.
--
-- KNOWN LIMIT (documented, next-session item): create_contract_transaction
-- still drops evidence_policy_type/evidence_selected_forms from its payload —
-- contracts get these fields only via update_contract (wizard edits). VaNi
-- auto-accept contracts therefore may activate with an empty forms list; the
-- sync is a no-op there until the create RPC persists the fields.
--
-- Depends on: smart-forms/001+002 (m_form_* tables), 008 (columns)
-- Safe to re-run: Yes (ON CONFLICT DO NOTHING; stable effective_from)
-- Applied by: OWNER — project uwyqhzotluikawcboldr
-- ============================================================================

-- ─────────────────────────────────────────────
-- 1. sync_contract_form_mappings
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION sync_contract_form_mappings(
    p_contract_id UUID,
    p_tenant_id   UUID,
    p_created_by  UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contract  RECORD;
    v_effective DATE;
    v_creator   UUID;
    v_inserted  INT := 0;
BEGIN
    IF p_contract_id IS NULL OR p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'contract_id and tenant_id are required');
    END IF;

    SELECT id, evidence_selected_forms, start_date, created_at
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id AND tenant_id = p_tenant_id AND is_active = true;

    IF v_contract IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Contract not found', 'error_code', 'NOT_FOUND');
    END IF;

    -- Stable per contract → re-runs hit the unique constraint, not duplicates
    v_effective := COALESCE(v_contract.start_date::date, v_contract.created_at::date, CURRENT_DATE);
    -- created_by is NOT NULL on m_form_template_mappings; fall back to the
    -- VaNi system actor used across the JTD framework
    v_creator := COALESCE(p_created_by, '00000000-0000-0000-0000-000000000001'::uuid);

    INSERT INTO m_form_template_mappings
        (tenant_id, contract_id, form_template_id, timing, is_mandatory, effective_from, status, created_by)
    SELECT DISTINCT p_tenant_id, p_contract_id, s.form_id, 'pre_service', true, v_effective, 'active', v_creator
    FROM (
        -- (a) contract-level curated forms
        SELECT (f->>'form_template_id')::uuid AS form_id
        FROM jsonb_array_elements(COALESCE(v_contract.evidence_selected_forms, '[]'::jsonb)) f
        WHERE COALESCE(f->>'form_template_id', '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        UNION
        -- (b) block-level forms (catalog blocks used by this contract)
        SELECT cb.form_template_id
        FROM t_contract_blocks tcb
        JOIN m_cat_blocks cb ON cb.id = tcb.source_block_id
        WHERE tcb.contract_id = p_contract_id
          AND cb.form_template_id IS NOT NULL
    ) s
    WHERE s.form_id IS NOT NULL
      AND EXISTS (SELECT 1 FROM m_form_templates t WHERE t.id = s.form_id)
    ON CONFLICT (tenant_id, contract_id, form_template_id, timing, effective_from) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id', p_contract_id,
        'mappings_created', v_inserted
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to sync form mappings',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION sync_contract_form_mappings(UUID, UUID, UUID) TO service_role;

-- ─────────────────────────────────────────────
-- 2. Trigger: sync when a contract becomes active
--    (covers both the UPDATE→active path and direct INSERT as active —
--     the auto-accept flow inserts active without a status transition)
-- ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION trg_fn_sync_form_mappings()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.status = 'active'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        BEGIN
            PERFORM sync_contract_form_mappings(NEW.id, NEW.tenant_id, COALESCE(NEW.updated_by, NEW.created_by));
        EXCEPTION WHEN OTHERS THEN
            -- Never break contract activation over the forms glue
            RAISE WARNING 'sync_contract_form_mappings failed for contract %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_form_mappings ON t_contracts;
CREATE TRIGGER trg_sync_form_mappings
    AFTER INSERT OR UPDATE OF status ON t_contracts
    FOR EACH ROW
    EXECUTE FUNCTION trg_fn_sync_form_mappings();

-- ─────────────────────────────────────────────
-- 3. Backfill: existing active contracts
--    (currently a no-op — no contract has evidence forms configured yet;
--     kept so re-running after configuring policies backfills correctly)
-- ─────────────────────────────────────────────
DO $$
DECLARE
    v_c RECORD;
    v_r JSONB;
    v_total INT := 0;
BEGIN
    FOR v_c IN
        SELECT id, tenant_id FROM t_contracts
        WHERE status = 'active' AND is_active = true
    LOOP
        v_r := sync_contract_form_mappings(v_c.id, v_c.tenant_id, NULL);
        v_total := v_total + COALESCE((v_r->>'mappings_created')::INT, 0);
    END LOOP;
    RAISE NOTICE 'Form-mapping backfill complete: % mappings created', v_total;
END;
$$;
