-- ============================================================================
-- P0 ROLLBACK: Contract Nomenclature — Undo Seed + Column
-- Migration: contracts/032_nomenclature_seed_DOWN.sql
-- Phase: P0 — Nomenclature Foundation
--
-- PURPOSE: Manual rollback script. Run in Supabase SQL Editor if P0 needs
--          to be reverted. This is NOT auto-applied — keep in repo for safety.
--
-- IMPORTANT: Run this BEFORE rolling back code via git tags.
-- ============================================================================

-- Step 1: Drop index on nomenclature_id
DROP INDEX IF EXISTS idx_contracts_nomenclature;

-- Step 2: Remove nomenclature_id column from t_contracts
-- (Safe — nullable column, no existing data depends on it)
ALTER TABLE t_contracts DROP COLUMN IF EXISTS nomenclature_id;

-- Step 3: Remove all nomenclature detail rows
DELETE FROM m_category_details
WHERE category_id = (
    SELECT id FROM m_category_master
    WHERE category_name = 'cat_contract_nomenclature'
);

-- Step 4: Remove the nomenclature master category
DELETE FROM m_category_master
WHERE category_name = 'cat_contract_nomenclature';

-- ============================================================================
-- VERIFICATION: After running, confirm cleanup:
--
-- SELECT COUNT(*) FROM m_category_master
-- WHERE category_name = 'cat_contract_nomenclature';
-- → Expected: 0
--
-- SELECT column_name FROM information_schema.columns
-- WHERE table_name = 't_contracts' AND column_name = 'nomenclature_id';
-- → Expected: 0 rows
-- ============================================================================
