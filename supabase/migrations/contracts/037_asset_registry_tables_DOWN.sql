-- ============================================================================
-- ROLLBACK: 037_asset_registry_tables.sql
-- Drops t_contract_assets, t_tenant_asset_registry, and denorm columns.
-- Order matters: junction first (FK), then registry, then ALTER columns.
-- ============================================================================

DO $$
BEGIN
    -- Drop RLS policies on t_contract_assets (only if table exists)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_contract_assets') THEN
        DROP POLICY IF EXISTS "ca_tenant_isolation" ON t_contract_assets;
        DROP POLICY IF EXISTS "ca_service_role_bypass" ON t_contract_assets;
    END IF;

    -- Drop RLS policies on t_tenant_asset_registry (only if table exists)
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_tenant_asset_registry') THEN
        DROP POLICY IF EXISTS "tar_tenant_isolation" ON t_tenant_asset_registry;
        DROP POLICY IF EXISTS "tar_service_role_bypass" ON t_tenant_asset_registry;
    END IF;
END $$;

-- Drop junction table first (depends on registry)
DROP TABLE IF EXISTS t_contract_assets;

-- Drop registry table
DROP TABLE IF EXISTS t_tenant_asset_registry;

-- Remove denorm columns from t_contracts
ALTER TABLE t_contracts DROP COLUMN IF EXISTS asset_count;
ALTER TABLE t_contracts DROP COLUMN IF EXISTS asset_summary;
