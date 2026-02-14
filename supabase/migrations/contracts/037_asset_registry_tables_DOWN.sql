-- ============================================================================
-- ROLLBACK: 037_asset_registry_tables.sql
-- Drops t_contract_assets, t_client_asset_registry, and denorm columns.
-- ============================================================================

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_contract_assets') THEN
        DROP POLICY IF EXISTS "ca_tenant_isolation" ON t_contract_assets;
        DROP POLICY IF EXISTS "ca_service_role_bypass" ON t_contract_assets;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 't_client_asset_registry') THEN
        DROP POLICY IF EXISTS "car_tenant_isolation" ON t_client_asset_registry;
        DROP POLICY IF EXISTS "car_service_role_bypass" ON t_client_asset_registry;
    END IF;
END $$;

DROP TABLE IF EXISTS t_contract_assets;
DROP TABLE IF EXISTS t_client_asset_registry;

ALTER TABLE t_contracts DROP COLUMN IF EXISTS asset_count;
ALTER TABLE t_contracts DROP COLUMN IF EXISTS asset_summary;
