-- ============================================================================
-- Migration: contracts/055_asset_registry_nullable_owner.sql
-- Purpose: Allow self-owned assets (Expense mode) without an owner_contact_id
--
-- Context:
--   t_client_asset_registry.owner_contact_id was originally NOT NULL because
--   the table was designed for client-owned assets only. With the addition of
--   ownership_type = 'self' (Expense / tenant-owned assets), owner_contact_id
--   must be nullable — self-owned assets belong to the tenant, not a contact.
--
-- What this does:
--   1. DROP NOT NULL on owner_contact_id
--   2. Add a CHECK constraint: if ownership_type = 'client', owner_contact_id
--      must still be provided (preserves original business rule)
--
-- Rollback:
--   ALTER TABLE t_client_asset_registry ALTER COLUMN owner_contact_id SET NOT NULL;
--   ALTER TABLE t_client_asset_registry DROP CONSTRAINT IF EXISTS chk_car_client_needs_owner;
-- ============================================================================

-- Step 1: Add ownership_type column if it doesn't already exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 't_client_asset_registry'
          AND column_name = 'ownership_type'
    ) THEN
        ALTER TABLE t_client_asset_registry
            ADD COLUMN ownership_type VARCHAR(10) NOT NULL DEFAULT 'client';
    END IF;
END $$;

-- Step 2: Drop NOT NULL on owner_contact_id
ALTER TABLE t_client_asset_registry
    ALTER COLUMN owner_contact_id DROP NOT NULL;

-- Step 3: Enforce owner_contact_id for client-owned assets via CHECK
ALTER TABLE t_client_asset_registry
    DROP CONSTRAINT IF EXISTS chk_car_client_needs_owner;

ALTER TABLE t_client_asset_registry
    ADD CONSTRAINT chk_car_client_needs_owner
    CHECK (
        ownership_type != 'client'
        OR owner_contact_id IS NOT NULL
    );

-- Step 4: Index on ownership_type for filtered queries
CREATE INDEX IF NOT EXISTS idx_car_ownership_type
    ON t_client_asset_registry(tenant_id, ownership_type);
