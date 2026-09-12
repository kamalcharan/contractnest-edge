-- ═══════════════════════════════════════════════════════════════════
-- service-execution/005_backfill_signia_form_mappings.sql
-- APPLIED LIVE 2026-09-12 (owner: "may be older contracts/tasks - need
-- seeding?"). Source-of-record — do not re-run blindly (idempotent via
-- the unique index + ON CONFLICT DO NOTHING inside the resolver).
--
-- The B2.3 resolver fires at ACTIVATION, so contracts activated before
-- it went live had no form-mapping rows. This runs the resolver once
-- over signia's active contracts (both environments).
-- Result: 50 contracts seeded, 50 platform_default rows (no block-level
-- evidence configs and no KT matches exist on signia yet, and signia's
-- contract-level policy is the wizard default 'none' → ladder bottom).
--
-- NOTE: seeding alone does NOT make the form visible in the service
-- ticket drawer — ServiceExecutionDrawer still reads the contract-level
-- wizard fields (evidence_policy_type / evidence_selected_forms), not
-- m_form_template_mappings. Wiring the execution surface to the RESOLVED
-- mappings is B2.5.
-- BBB deliberately NOT backfilled: no service execution there (group
-- sessions); revisit when/if BBB gains service blocks.
-- Rollback: DELETE FROM m_form_template_mappings
--           WHERE tenant_id='80e3b843-525e-4368-b418-b1250d1d1d63'
--             AND resolved_via='platform_default';
-- ═══════════════════════════════════════════════════════════════════

DO $do$
DECLARE
    v_tenant uuid := '80e3b843-525e-4368-b418-b1250d1d1d63';
    r record;
    v_rows int; v_total int := 0; v_contracts int := 0;
BEGIN
    FOR r IN
        SELECT id, contract_number FROM t_contracts
        WHERE tenant_id = v_tenant AND record_type = 'contract' AND status = 'active'
    LOOP
        v_rows := resolve_contract_form_mappings(r.id, v_tenant);
        IF v_rows > 0 THEN
            v_contracts := v_contracts + 1;
            v_total := v_total + v_rows;
        END IF;
    END LOOP;
    RAISE NOTICE 'Backfill OK: % mapping rows written across % signia contracts', v_total, v_contracts;
END
$do$;
