-- ═══════════════════════════════════════════════════════════════════
-- service-execution/004_b23_activation_resolver.sql
-- B2.3 — APPLIED LIVE 2026-09-12 (three migrations: service_execution_004
-- + 004b fall-through fix + 004c upload-only rule). Source-of-record;
-- final function version below. 004c (B2.4 companion): block evidence
-- policy 'upload' skips FORM mappings like 'none' — upload-only proof
-- must not force a form; upload enforcement is read from block config
-- at execution time (B3.3).
--
-- resolve_contract_form_mappings(contract, tenant) — the D9 ladder,
-- writing m_form_template_mappings rows; fired at contract activation by
-- trg_zz_resolve_form_mappings (t_contracts AFTER UPDATE → status 'active').
--
-- Ladder, per SERVICE block:
--   rung 1 block_config      custom_fields.config.evidence.formTemplateId
--                            (written by the B2.4 picker; policy 'both' or
--                            evidence.requireUpload=true → require_upload)
--   rung 2 kt_type           approved m_form_templates whose
--                            resource_template_id matches any of the
--                            contract's equipment item category/template ids
--                            (newest version per type; provenance stored in
--                            resource_template_id)
--   — block policy 'none' = explicit opt-out: no row, pulls in no fallback.
-- Contract-level (contract_block_id NULL), written only when ≥1 service
-- block is still uncovered:
--   rung 3 contract_fallback wizard's evidence_policy_type='smart_form' +
--                            evidence_selected_forms (approved only)
--   rung 4 platform_default  "General Service Completion"
--                            f0000000-0000-4000-a000-000000000001
--
-- Interpretation decisions (owner may veto):
--   · contract evidence_policy_type='none' is the wizard DEFAULT on 302/303
--     contracts → treated as UNSPECIFIED (ladder continues to platform
--     default, per D8 "something basic must always be captured"). The
--     explicit opt-out lives at BLOCK level ("policy none ⇒ no rows").
--   · Gating semantics for B2.5: look up block-level row first, else the
--     contract-level rows.
--
-- HARNESS RESULTS (all in rolled-back transactions, live DB):
--   T1 nothing specified → 1 platform_default contract-level row ✓
--   T2 idempotent re-run → 0 rows ✓
--   T3 block evidence {policy both + formTemplateId} → block_config row,
--      require_upload=true; sibling block policy 'none' → no rows at all ✓
--   T4 equipment item matching a KT form's resource_template_id →
--      kt_type row with provenance ✓
--   T5a smart_form contract whose 6 selected forms are ALL DRAFT (real
--      data, tenant a4d9ac86 CN-1001) → falls through to platform_default
--      (first version wrote ZERO rows here — the bug 004b fixed) ✓
--   T5b one of those forms approved → contract_fallback row for it, no
--      default row ✓
--
-- Cross-tenant lesson re-learned during harness: contract numbers repeat
-- per tenant — the smart_form 'CN-1001' is NOT signia's CN-1001.
--
-- Rollback: DROP TRIGGER trg_zz_resolve_form_mappings ON t_contracts;
--           DROP FUNCTION trg_fn_resolve_form_mappings();
--           DROP FUNCTION resolve_contract_form_mappings(uuid, uuid);
--           DELETE FROM m_form_template_mappings;  -- table was empty before B2
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION resolve_contract_form_mappings(p_contract_id uuid, p_tenant_id uuid)
RETURNS int AS $fn$
DECLARE
    v_vani          uuid := '00000000-0000-0000-0000-000000000001';
    v_default_form  uuid := 'f0000000-0000-4000-a000-000000000001';
    v_contract      record;
    v_block         record;
    v_ev            jsonb;
    v_policy        text;
    v_form_id       uuid;
    v_today         date := ((now() at time zone 'Asia/Kolkata'))::date;
    v_rows          int := 0;
    v_ins           int;
    v_needs_fallback boolean := false;
    v_fallback_written boolean := false;
    v_matched       boolean;
BEGIN
    SELECT id, evidence_policy_type, evidence_selected_forms, equipment_details
    INTO v_contract
    FROM t_contracts
    WHERE id = p_contract_id AND tenant_id = p_tenant_id AND record_type = 'contract';
    IF NOT FOUND THEN RETURN 0; END IF;

    FOR v_block IN
        SELECT b.id, b.custom_fields
        FROM t_contract_blocks b
        WHERE b.contract_id = p_contract_id AND b.category_id = 'service'
    LOOP
        v_ev     := v_block.custom_fields->'config'->'evidence';
        v_policy := v_ev->>'policy';

        -- Explicit opt-outs from FORM mappings: 'none' and upload-only proof (004c)
        IF v_policy IN ('none','upload') THEN CONTINUE; END IF;

        v_form_id := NULL;
        BEGIN
            v_form_id := (v_ev->>'formTemplateId')::uuid;
        EXCEPTION WHEN others THEN v_form_id := NULL; END;

        IF v_form_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM m_form_templates f WHERE f.id = v_form_id AND f.status = 'approved') THEN
            INSERT INTO m_form_template_mappings
                (id, tenant_id, contract_id, form_template_id, contract_block_id,
                 require_upload, resolved_via, timing, is_mandatory, effective_from,
                 status, created_by)
            VALUES
                (gen_random_uuid(), p_tenant_id, p_contract_id, v_form_id, v_block.id,
                 COALESCE((v_ev->>'requireUpload')::boolean, v_policy IN ('both','form_and_upload')),
                 'block_config', 'during_service', true, v_today, 'active', v_vani)
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_ins = ROW_COUNT; v_rows := v_rows + v_ins;
            CONTINUE;
        END IF;

        v_matched := false;
        INSERT INTO m_form_template_mappings
            (id, tenant_id, contract_id, form_template_id, contract_block_id,
             resource_template_id, require_upload, resolved_via, timing,
             is_mandatory, effective_from, status, created_by)
        SELECT DISTINCT ON (f.resource_template_id)
             gen_random_uuid(), p_tenant_id, p_contract_id, f.id, v_block.id,
             f.resource_template_id,
             COALESCE((v_ev->>'requireUpload')::boolean, false),
             'kt_type', 'during_service', true, v_today, 'active', v_vani
        FROM m_form_templates f
        WHERE f.status = 'approved' AND f.resource_template_id IS NOT NULL
          AND EXISTS (
              SELECT 1 FROM jsonb_array_elements(COALESCE(v_contract.equipment_details,'[]'::jsonb)) item
              WHERE f.resource_template_id::text IN (item->>'category_id', item->>'template_id'))
        ORDER BY f.resource_template_id, f.version DESC
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_ins = ROW_COUNT;
        IF v_ins > 0 THEN
            v_rows := v_rows + v_ins; v_matched := true;
        END IF;

        IF NOT v_matched THEN v_needs_fallback := true; END IF;
    END LOOP;

    IF v_needs_fallback THEN
        IF v_contract.evidence_policy_type IN ('smart_form','smartform')
           AND jsonb_typeof(COALESCE(v_contract.evidence_selected_forms,'[]'::jsonb)) = 'array'
           AND jsonb_array_length(COALESCE(v_contract.evidence_selected_forms,'[]'::jsonb)) > 0 THEN
            INSERT INTO m_form_template_mappings
                (id, tenant_id, contract_id, form_template_id, require_upload,
                 resolved_via, timing, is_mandatory, effective_from, status, created_by)
            SELECT gen_random_uuid(), p_tenant_id, p_contract_id,
                   (sel->>'form_template_id')::uuid, false,
                   'contract_fallback', 'during_service', true, v_today, 'active', v_vani
            FROM jsonb_array_elements(v_contract.evidence_selected_forms) sel
            WHERE (sel->>'form_template_id') IS NOT NULL
              AND EXISTS (SELECT 1 FROM m_form_templates f
                          WHERE f.id = (sel->>'form_template_id')::uuid AND f.status='approved')
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_ins = ROW_COUNT;
            IF v_ins > 0 THEN
                v_rows := v_rows + v_ins; v_fallback_written := true;
            END IF;
        END IF;

        -- Fall through: no valid contract-level forms → platform default,
        -- so a contract with service blocks never ends with zero coverage.
        IF NOT v_fallback_written THEN
            INSERT INTO m_form_template_mappings
                (id, tenant_id, contract_id, form_template_id, require_upload,
                 resolved_via, timing, is_mandatory, effective_from, status, created_by)
            VALUES
                (gen_random_uuid(), p_tenant_id, p_contract_id, v_default_form, false,
                 'platform_default', 'during_service', true, v_today, 'active', v_vani)
            ON CONFLICT DO NOTHING;
            GET DIAGNOSTICS v_ins = ROW_COUNT; v_rows := v_rows + v_ins;
        END IF;
    END IF;

    RETURN v_rows;
END
$fn$ LANGUAGE plpgsql;

-- Activation hook: same pattern as trg_zz_generate_event_assets_v2
CREATE OR REPLACE FUNCTION trg_fn_resolve_form_mappings() RETURNS trigger AS $fn$
BEGIN
    IF NEW.record_type = 'contract' AND NEW.status = 'active' AND OLD.status IS DISTINCT FROM 'active' THEN
        PERFORM resolve_contract_form_mappings(NEW.id, NEW.tenant_id);
    END IF;
    RETURN NULL;
END
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zz_resolve_form_mappings ON t_contracts;
CREATE TRIGGER trg_zz_resolve_form_mappings
AFTER UPDATE ON t_contracts
FOR EACH ROW EXECUTE FUNCTION trg_fn_resolve_form_mappings();
