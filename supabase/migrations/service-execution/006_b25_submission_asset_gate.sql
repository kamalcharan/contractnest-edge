-- ═══════════════════════════════════════════════════════════════════
-- service-execution/006_b25_submission_asset_gate.sql
-- B2.5 — APPLIED LIVE 2026-09-12 (migration service_execution_006).
-- Source-of-record — DO NOT RE-RUN. Body below matches the live objects
-- (function pulled back from pg_get_functiondef after apply).
--
-- Submission → event-asset binding: a form submission links to exactly
-- one t_contract_event_assets row, and placeholder slots are rejected
-- server-side. The BEFORE INSERT trigger is the AUTHORITATIVE gate; the
-- smart-forms edge function (v7) adds friendly 422 pre-checks with the
-- same three error codes, but a caller bypassing the edge still cannot
-- get a bad row past this trigger.
--
-- Rules:
--   · event_asset_id NULL  → allowed ONLY when the visit has no active
--     per-asset rows (legacy / pre-Sprint-3 contracts). If rows exist:
--     SUBMISSION_ASSET_REQUIRED.
--   · event_asset_id set   → the row must exist, belong to the same
--     tenant AND the same visit (service_event_id), else
--     SUBMISSION_ASSET_MISMATCH.
--   · status='blocked_placeholder' → SUBMISSION_ASSET_PLACEHOLDER
--     (attach the real asset first — the attach flow unlocks the slot).
--
-- HARNESS RESULTS 2026-09-12 (rolled-back transaction, live DB, signia):
--   T1 visit WITH per-asset rows, event_asset_id NULL      → REFUSED (REQUIRED) ✓
--   T2 binding to a blocked_placeholder row                → REFUSED (PLACEHOLDER) ✓
--   T3 binding to an asset row of a DIFFERENT visit        → REFUSED (MISMATCH) ✓
--   T4 binding to an open asset row of the same visit      → ACCEPTED ✓
--   T5 legacy visit with NO per-asset rows, NULL binding   → ACCEPTED ✓
--   (Setup notes: submitted_by is uuid — use the VaNi system id
--   00000000-0000-0000-0000-000000000001 in harnesses, not a text tag.)
--
-- Rollback: DROP TRIGGER trg_zz_submission_asset_gate ON m_form_submissions;
--           DROP FUNCTION trg_fn_submission_asset_gate();
--           DROP INDEX ix_form_submissions_event_asset;
--           ALTER TABLE m_form_submissions DROP COLUMN event_asset_id;
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE m_form_submissions
    ADD COLUMN IF NOT EXISTS event_asset_id uuid NULL;

CREATE INDEX IF NOT EXISTS ix_form_submissions_event_asset
    ON m_form_submissions (event_asset_id);

CREATE OR REPLACE FUNCTION trg_fn_submission_asset_gate() RETURNS trigger AS $fn$
DECLARE
    v_row record;
    v_has_rows boolean;
BEGIN
    -- Visits with per-asset rows demand a binding; visits without them
    -- (pre-Sprint-3 contracts) accept none.
    SELECT EXISTS (
        SELECT 1 FROM t_contract_event_assets ea
        WHERE ea.event_id = NEW.service_event_id
          AND ea.tenant_id = NEW.tenant_id
          AND ea.is_active = true
    ) INTO v_has_rows;

    IF NEW.event_asset_id IS NULL THEN
        IF v_has_rows THEN
            RAISE EXCEPTION 'SUBMISSION_ASSET_REQUIRED: this visit tracks proof per asset — event_asset_id is required';
        END IF;
        RETURN NEW;
    END IF;

    SELECT ea.id, ea.status, ea.event_id, ea.tenant_id INTO v_row
    FROM t_contract_event_assets ea WHERE ea.id = NEW.event_asset_id;

    IF v_row.id IS NULL OR v_row.tenant_id <> NEW.tenant_id OR v_row.event_id <> NEW.service_event_id THEN
        RAISE EXCEPTION 'SUBMISSION_ASSET_MISMATCH: event_asset_id does not belong to this visit';
    END IF;
    IF v_row.status = 'blocked_placeholder' THEN
        RAISE EXCEPTION 'SUBMISSION_ASSET_PLACEHOLDER: this slot is a placeholder — attach the real asset before submitting evidence';
    END IF;

    RETURN NEW;
END
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zz_submission_asset_gate ON m_form_submissions;
CREATE TRIGGER trg_zz_submission_asset_gate
BEFORE INSERT ON m_form_submissions
FOR EACH ROW EXECUTE FUNCTION trg_fn_submission_asset_gate();
