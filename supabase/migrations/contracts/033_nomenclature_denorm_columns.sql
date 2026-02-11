-- ============================================================================
-- Add denormalized nomenclature columns to t_contracts
-- Migration: contracts/033_nomenclature_denorm_columns.sql
--
-- Depends on: 032_nomenclature_seed.sql (adds nomenclature_id FK)
--
-- What this does:
--   t_contracts already has nomenclature_id (UUID FK to m_category_details).
--   This migration adds denormalized columns so queries don't need JOINs:
--     - nomenclature_code  (e.g. 'CMC', 'AMC', 'SLA')
--     - nomenclature_name  (e.g. 'Comprehensive Maintenance Contract')
--
-- The RPC (create_contract_transaction) will populate these via lookup
-- from m_category_details when nomenclature_id is provided.
--
-- Rollback: See 033_nomenclature_denorm_columns_DOWN.sql
-- ============================================================================

-- Add denormalized nomenclature columns
ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS nomenclature_code TEXT,
    ADD COLUMN IF NOT EXISTS nomenclature_name TEXT;

-- Comment for clarity
COMMENT ON COLUMN t_contracts.nomenclature_id IS 'FK to m_category_details — the selected contract nomenclature (AMC, CMC, SLA, etc.)';
COMMENT ON COLUMN t_contracts.nomenclature_code IS 'Denormalized short code from m_category_details.sub_cat_name (e.g. amc, cmc, sla)';
COMMENT ON COLUMN t_contracts.nomenclature_name IS 'Denormalized display name from m_category_details.display_name (e.g. AMC, CMC, SLA)';
