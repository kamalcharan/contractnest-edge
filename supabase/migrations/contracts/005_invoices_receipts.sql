-- =============================================================
-- INVOICES & RECEIPTS TABLES
-- Migration: contracts/005_invoices_receipts.sql
-- Purpose: Core accounting tables for contract billing
--   - t_invoices: Invoice records (AR/AP)
--   - t_invoice_receipts: Payment receipts against invoices
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- 1. t_invoices
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS t_invoices (
    id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    contract_id         UUID NOT NULL,
    tenant_id           UUID NOT NULL,

    -- Sequence
    invoice_number      VARCHAR(30) NOT NULL,          -- INV-10001 (from sequencing system)

    -- AR / AP classification
    invoice_type        VARCHAR(20) NOT NULL,           -- 'receivable' (AR) | 'payable' (AP)

    -- Amounts
    amount              NUMERIC NOT NULL DEFAULT 0,     -- base amount (excl tax)
    tax_amount          NUMERIC NOT NULL DEFAULT 0,     -- tax portion
    total_amount        NUMERIC NOT NULL DEFAULT 0,     -- amount + tax_amount
    currency            VARCHAR(3) NOT NULL DEFAULT 'INR',

    -- Payment tracking
    amount_paid         NUMERIC NOT NULL DEFAULT 0,     -- sum of receipts
    balance             NUMERIC NOT NULL DEFAULT 0,     -- total_amount - amount_paid
    status              VARCHAR(20) NOT NULL DEFAULT 'unpaid',
                                                        -- 'unpaid' | 'partially_paid' | 'paid' | 'overdue' | 'cancelled'

    -- Schedule context: what generated this invoice
    payment_mode        VARCHAR(20),                    -- 'prepaid' | 'emi' | 'defined'
    emi_sequence        INTEGER,                        -- for EMI: installment # (1, 2, 3...)
    emi_total           INTEGER,                        -- for EMI: total installments
    billing_cycle       VARCHAR(30),                    -- for defined: cycle this covers
    block_ids           JSONB DEFAULT '[]'::JSONB,      -- which blocks this invoice covers

    -- Dates
    due_date            DATE,
    issued_at           TIMESTAMPTZ DEFAULT NOW(),
    paid_at             TIMESTAMPTZ,                    -- set when fully paid

    -- Audit
    notes               TEXT,
    is_live             BOOLEAN DEFAULT true,
    is_active           BOOLEAN DEFAULT true,
    created_by          UUID,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),

    -- FK
    CONSTRAINT fk_invoice_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
);


-- ─────────────────────────────────────────────────────────────
-- 2. t_invoice_receipts
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS t_invoice_receipts (
    id                  UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_id          UUID NOT NULL,
    contract_id         UUID NOT NULL,
    tenant_id           UUID NOT NULL,

    -- Sequence
    receipt_number      VARCHAR(30) NOT NULL,            -- RCP-10001 (from sequencing system)

    -- Payment details
    amount              NUMERIC NOT NULL,
    currency            VARCHAR(3) NOT NULL DEFAULT 'INR',
    payment_date        DATE NOT NULL,
    payment_method      VARCHAR(30) NOT NULL,            -- 'cash' | 'bank_transfer' | 'upi' | 'cheque' | 'card' | 'other'
    reference_number    TEXT,                             -- NEFT ref, UPI ID, cheque #, etc.
    notes               TEXT,

    -- Offline transaction flag
    is_offline          BOOLEAN DEFAULT true,            -- true = manually recorded, false = gateway

    -- Verification
    is_verified         BOOLEAN DEFAULT false,
    verified_by         UUID,
    verified_at         TIMESTAMPTZ,

    -- Audit
    recorded_by         UUID,
    is_active           BOOLEAN DEFAULT true,
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    updated_at          TIMESTAMPTZ DEFAULT NOW(),

    -- FK
    CONSTRAINT fk_receipt_invoice
        FOREIGN KEY (invoice_id) REFERENCES t_invoices(id) ON DELETE CASCADE,
    CONSTRAINT fk_receipt_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
);


-- ─────────────────────────────────────────────────────────────
-- 3. Indexes
-- ─────────────────────────────────────────────────────────────

-- t_invoices
CREATE INDEX IF NOT EXISTS idx_invoices_contract
    ON t_invoices (contract_id) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_invoices_tenant_status
    ON t_invoices (tenant_id, status) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_invoices_due_date
    ON t_invoices (tenant_id, due_date) WHERE status IN ('unpaid', 'partially_paid') AND is_active = true;

CREATE UNIQUE INDEX IF NOT EXISTS idx_invoices_number_tenant
    ON t_invoices (tenant_id, invoice_number) WHERE is_active = true;

-- t_invoice_receipts
CREATE INDEX IF NOT EXISTS idx_receipts_invoice
    ON t_invoice_receipts (invoice_id) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_receipts_contract
    ON t_invoice_receipts (contract_id) WHERE is_active = true;

CREATE UNIQUE INDEX IF NOT EXISTS idx_receipts_number_tenant
    ON t_invoice_receipts (tenant_id, receipt_number) WHERE is_active = true;


-- ─────────────────────────────────────────────────────────────
-- 4. RLS Policies
-- ─────────────────────────────────────────────────────────────

ALTER TABLE t_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE t_invoice_receipts ENABLE ROW LEVEL SECURITY;

-- Invoices: tenant members can view
CREATE POLICY "Tenant members can view invoices"
    ON t_invoices FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Invoices: tenant members can create
CREATE POLICY "Tenant members can create invoices"
    ON t_invoices FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Invoices: tenant members can update
CREATE POLICY "Tenant members can update invoices"
    ON t_invoices FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Receipts: tenant members can view
CREATE POLICY "Tenant members can view receipts"
    ON t_invoice_receipts FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Receipts: tenant members can create
CREATE POLICY "Tenant members can create receipts"
    ON t_invoice_receipts FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Receipts: tenant members can update
CREATE POLICY "Tenant members can update receipts"
    ON t_invoice_receipts FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );


-- ─────────────────────────────────────────────────────────────
-- 5. Grants
-- ─────────────────────────────────────────────────────────────

GRANT ALL ON t_invoices TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_invoices TO authenticated;

GRANT ALL ON t_invoice_receipts TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_invoice_receipts TO authenticated;
