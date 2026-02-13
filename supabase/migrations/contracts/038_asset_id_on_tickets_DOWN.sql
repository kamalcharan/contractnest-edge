-- ============================================================================
-- ROLLBACK: 038_asset_id_on_tickets.sql
-- Removes asset_id from t_service_tickets and t_service_evidence.
-- ============================================================================

-- t_service_evidence
ALTER TABLE t_service_evidence DROP CONSTRAINT IF EXISTS fk_se_asset;
DROP INDEX IF EXISTS idx_se_asset;
ALTER TABLE t_service_evidence DROP COLUMN IF EXISTS asset_id;

-- t_service_tickets
ALTER TABLE t_service_tickets DROP CONSTRAINT IF EXISTS fk_st_asset;
DROP INDEX IF EXISTS idx_st_asset;
ALTER TABLE t_service_tickets DROP COLUMN IF EXISTS asset_id;
