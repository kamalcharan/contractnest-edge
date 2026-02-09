-- ============================================================================
-- Migration 024: Service Evidence Table
-- ============================================================================
-- Purpose: t_service_evidence — stores all evidence collected during service
--          execution. Supports three evidence types configured per block:
--            1. upload-form  → file uploads (photos, documents, videos)
--            2. otp          → customer OTP verification
--            3. service-form → structured form data (checklists, reports)
--
-- Evidence requirements come from cat_blocks.config.evidence_types[]
-- Each evidence row links to a ticket, event, and block.
--
-- Denormalization: block_name, uploaded_by_name, verified_by_name,
--                  otp_verified_by_name, form_template_name stored alongside
--                  FKIDs for buyer (CNAK) visibility.
--
-- Depends on: 012 (t_contract_events), 022 (t_service_tickets)
-- ============================================================================


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T1: t_service_evidence
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
CREATE TABLE IF NOT EXISTS t_service_evidence (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    tenant_id               UUID NOT NULL,

    -- Parent references
    ticket_id               UUID NOT NULL,                          -- FK → t_service_tickets
    event_id                UUID,                                   -- FK → t_contract_events (optional, for event-level evidence)

    -- Block reference (which block's evidence config triggered this)
    block_id                TEXT,                                   -- source block identifier
    block_name              TEXT,                                   -- denormalized for display

    -- Evidence classification (matches cat_blocks.config.evidence_types values)
    evidence_type           TEXT NOT NULL,                          -- 'upload-form' | 'otp' | 'service-form'
    label                   TEXT,                                   -- display label: "Before Photo", "Customer OTP", etc.
    description             TEXT,                                   -- optional description

    -- ── File fields (for evidence_type = 'upload-form') ──
    file_url                TEXT,                                   -- storage URL (Supabase Storage / R2)
    file_name               TEXT,                                   -- original file name
    file_size               BIGINT,                                 -- file size in bytes
    file_type               TEXT,                                   -- MIME type: image/jpeg, application/pdf, etc.
    file_thumbnail_url      TEXT,                                   -- thumbnail URL for images/videos

    -- ── OTP fields (for evidence_type = 'otp') ──
    otp_code                TEXT,                                   -- generated OTP code (hashed or plain depending on security policy)
    otp_sent_to             TEXT,                                   -- phone number or email OTP was sent to
    otp_verified            BOOLEAN DEFAULT false,                  -- whether customer verified
    otp_verified_at         TIMESTAMPTZ,                            -- when verification happened
    otp_verified_by         UUID,                                   -- customer/user who verified
    otp_verified_by_name    TEXT,                                   -- denormalized: "Amit Shah"

    -- ── Form fields (for evidence_type = 'service-form') ──
    form_template_id        UUID,                                   -- FK to form template (future)
    form_template_name      TEXT,                                   -- denormalized: "Maintenance Checklist"
    form_data               JSONB,                                  -- structured form responses

    -- Status tracking
    status                  TEXT NOT NULL DEFAULT 'pending',        -- pending | uploaded | verified | rejected
    rejection_reason        TEXT,                                   -- reason if status = rejected

    -- Who uploaded / verified (denormalized)
    uploaded_by             UUID,
    uploaded_by_name        TEXT,                                   -- denormalized: "Rajesh Kumar"
    verified_by             UUID,
    verified_by_name        TEXT,                                   -- denormalized: "Operations Admin"
    verified_at             TIMESTAMPTZ,

    -- Environment
    is_active               BOOLEAN DEFAULT true,                   -- soft delete
    is_live                 BOOLEAN DEFAULT true,                   -- live vs test

    -- Audit
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW(),

    -- Foreign keys
    CONSTRAINT fk_se_ticket
        FOREIGN KEY (ticket_id) REFERENCES t_service_tickets(id) ON DELETE CASCADE,
    CONSTRAINT fk_se_event
        FOREIGN KEY (event_id) REFERENCES t_contract_events(id) ON DELETE SET NULL
);


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T2: Indexes
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- All evidence for a ticket
CREATE INDEX IF NOT EXISTS idx_se_ticket
    ON t_service_evidence (ticket_id)
    WHERE is_active = true;

-- Evidence by ticket + type
CREATE INDEX IF NOT EXISTS idx_se_ticket_type
    ON t_service_evidence (ticket_id, evidence_type)
    WHERE is_active = true;

-- Evidence by event
CREATE INDEX IF NOT EXISTS idx_se_event
    ON t_service_evidence (event_id)
    WHERE is_active = true AND event_id IS NOT NULL;

-- Tenant-wide evidence queries
CREATE INDEX IF NOT EXISTS idx_se_tenant
    ON t_service_evidence (tenant_id, status)
    WHERE is_active = true;

-- Evidence by block (for block-level coverage report)
CREATE INDEX IF NOT EXISTS idx_se_block
    ON t_service_evidence (ticket_id, block_id)
    WHERE is_active = true;

-- OTP verification lookup
CREATE INDEX IF NOT EXISTS idx_se_otp_pending
    ON t_service_evidence (ticket_id, evidence_type, otp_verified)
    WHERE is_active = true AND evidence_type = 'otp' AND otp_verified = false;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T3: Trigger — auto-update updated_at
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

CREATE OR REPLACE FUNCTION update_service_evidence_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_service_evidence_updated_at ON t_service_evidence;
CREATE TRIGGER trigger_service_evidence_updated_at
    BEFORE UPDATE ON t_service_evidence
    FOR EACH ROW
    EXECUTE FUNCTION update_service_evidence_updated_at();


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T4: RLS Policies
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALTER TABLE t_service_evidence ENABLE ROW LEVEL SECURITY;

-- Tenant members can view evidence
CREATE POLICY "Tenant members can view service evidence"
    ON t_service_evidence FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can upload evidence
CREATE POLICY "Tenant members can create service evidence"
    ON t_service_evidence FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Tenant members can update evidence (verify, reject, update file)
CREATE POLICY "Tenant members can update service evidence"
    ON t_service_evidence FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Service role full access
CREATE POLICY "Service role full access to service evidence"
    ON t_service_evidence FOR ALL
    USING (auth.role() = 'service_role');


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- T5: Grants
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

GRANT ALL ON t_service_evidence TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_service_evidence TO authenticated;


-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Comments
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

COMMENT ON TABLE t_service_evidence IS
    'Service evidence collected during ticket execution. Supports file uploads (upload-form), '
    'customer OTP verification (otp), and structured forms (service-form). Evidence requirements '
    'configured per block in cat_blocks.config.evidence_types[].';

COMMENT ON COLUMN t_service_evidence.evidence_type IS
    'Matches values from cat_blocks.config.evidence_types: upload-form | otp | service-form';

COMMENT ON COLUMN t_service_evidence.block_name IS
    'Denormalized from block config for buyer (CNAK) visibility without FK resolution';

COMMENT ON COLUMN t_service_evidence.form_data IS
    'JSONB structured form responses. Schema defined by form_template_id (future). '
    'Example: {"checklist": [{"item": "Filter replaced", "checked": true}]}';

COMMENT ON COLUMN t_service_evidence.status IS
    'pending → uploaded → verified / rejected. Rejected evidence can be re-uploaded.';
