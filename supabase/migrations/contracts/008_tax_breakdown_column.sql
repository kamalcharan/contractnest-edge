-- ═══════════════════════════════════════════════════════════════
-- Migration 008: Add tax_breakdown JSONB column to t_contracts
-- ═══════════════════════════════════════════════════════════════
-- Purpose: Store the full tax breakdown (name, rate %, computed amount)
--          alongside the existing selected_tax_rate_ids array.
--
-- Format:
--   [
--     { "tax_rate_id": "uuid", "name": "CGST", "rate": 9, "amount": 900.00 },
--     { "tax_rate_id": "uuid", "name": "SGST", "rate": 9, "amount": 900.00 }
--   ]
--
-- This captures a point-in-time snapshot of the tax rates applied,
-- so the contract's financial record is self-contained even if
-- tax rate settings change later.
-- ═══════════════════════════════════════════════════════════════

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS tax_breakdown JSONB DEFAULT '[]'::JSONB;

COMMENT ON COLUMN t_contracts.tax_breakdown IS 'Point-in-time snapshot of applied tax rates: [{tax_rate_id, name, rate, amount}]';
