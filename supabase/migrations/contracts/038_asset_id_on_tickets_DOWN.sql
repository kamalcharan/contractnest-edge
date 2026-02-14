-- ============================================================================
-- ROLLBACK: 038_asset_id_on_tickets.sql
-- ============================================================================

ALTER TABLE t_service_evidence DROP CONSTRAINT IF EXISTS fk_se_asset;
DROP INDEX IF EXISTS idx_se_asset;
ALTER TABLE t_service_evidence DROP COLUMN IF EXISTS asset_id;

ALTER TABLE t_service_tickets DROP CONSTRAINT IF EXISTS fk_st_asset;
DROP INDEX IF EXISTS idx_st_asset;
ALTER TABLE t_service_tickets DROP COLUMN IF EXISTS asset_id;
