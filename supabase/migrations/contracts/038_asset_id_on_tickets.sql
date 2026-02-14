-- ============================================================================
-- P1+: Add asset_id to t_service_tickets + t_service_evidence
-- Migration: contracts/038_asset_id_on_tickets.sql
-- Phase: P1 — Client Asset Foundation
--
-- Links service execution to a specific client asset.
-- Rollback: See 038_asset_id_on_tickets_DOWN.sql
-- ============================================================================

ALTER TABLE t_service_tickets
    ADD COLUMN IF NOT EXISTS asset_id UUID,
    ADD CONSTRAINT fk_st_asset
        FOREIGN KEY (asset_id) REFERENCES t_client_asset_registry(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_st_asset
    ON t_service_tickets(asset_id) WHERE asset_id IS NOT NULL;

COMMENT ON COLUMN t_service_tickets.asset_id IS 'Optional FK to t_client_asset_registry — which specific client asset this ticket is for';

ALTER TABLE t_service_evidence
    ADD COLUMN IF NOT EXISTS asset_id UUID,
    ADD CONSTRAINT fk_se_asset
        FOREIGN KEY (asset_id) REFERENCES t_client_asset_registry(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_se_asset
    ON t_service_evidence(asset_id) WHERE asset_id IS NOT NULL;

COMMENT ON COLUMN t_service_evidence.asset_id IS 'Optional FK to t_client_asset_registry — evidence tied to a specific client asset';
