-- ============================================================================
-- Migration: Stage 2 Services — 008 Evidence-policy columns (repo hygiene)
-- ============================================================================
-- Purpose: The DDL for t_contracts.evidence_policy_type /
--          evidence_selected_forms was applied to the live DB from
--          MANUAL_COPY_FILES/service-execution-drawer/.../029_... but never
--          landed in the repo migration tree (live sequence jumps 028→030).
--          This file brings the tree in sync. On the live DB it is a NO-OP.
-- Safe to re-run: Yes (fully guarded)
-- Applied by: OWNER — project uwyqhzotluikawcboldr (no-op there)
-- ============================================================================

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS evidence_policy_type    VARCHAR(20) DEFAULT 'none',
    ADD COLUMN IF NOT EXISTS evidence_selected_forms JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN t_contracts.evidence_policy_type IS
    'Evidence policy for service completion: none | upload | smart_form';
COMMENT ON COLUMN t_contracts.evidence_selected_forms IS
    'Selected smart forms: [{form_template_id, name, sequence}] — source for m_form_template_mappings sync (Stage 2)';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'chk_evidence_policy_type' AND conrelid = 't_contracts'::regclass
    ) THEN
        ALTER TABLE t_contracts
            ADD CONSTRAINT chk_evidence_policy_type
            CHECK (evidence_policy_type IN ('none', 'upload', 'smart_form'));
    END IF;
END;
$$;
