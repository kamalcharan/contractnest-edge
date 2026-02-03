-- ═══════════════════════════════════════════════════════════════
-- Migration 009: Extend t_contract_access for sign-off workflow
-- ═══════════════════════════════════════════════════════════════
-- Adds: secret_code, status workflow, response tracking
-- Pattern follows t_user_invitations (code + secret validation)
-- ═══════════════════════════════════════════════════════════════

-- Secret code for public link validation (paired with global_access_id / CNAK)
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS secret_code VARCHAR(32);

-- Status workflow: pending → sent → viewed → accepted | rejected | expired
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS status VARCHAR(20) DEFAULT 'pending';

-- Response tracking
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS responded_by UUID;
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS responded_at TIMESTAMPTZ;
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS rejection_reason TEXT;

-- Link tracking
ALTER TABLE t_contract_access
    ADD COLUMN IF NOT EXISTS link_clicked_at TIMESTAMPTZ;

-- Index for public validation lookup: CNAK + secret_code
CREATE INDEX IF NOT EXISTS idx_contract_access_public_validate
    ON t_contract_access (global_access_id, secret_code)
    WHERE is_active = true AND secret_code IS NOT NULL;

-- Backfill existing rows with a secret_code so they can use the public flow
UPDATE t_contract_access
SET secret_code = encode(gen_random_bytes(16), 'hex')
WHERE secret_code IS NULL;

-- Now make it NOT NULL for future inserts
ALTER TABLE t_contract_access
    ALTER COLUMN secret_code SET NOT NULL;

COMMENT ON COLUMN t_contract_access.secret_code IS 'Random hex secret for public link validation (paired with CNAK)';
COMMENT ON COLUMN t_contract_access.status IS 'Workflow status: pending, sent, viewed, accepted, rejected, expired';
