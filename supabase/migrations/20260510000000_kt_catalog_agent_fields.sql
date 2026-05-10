-- ─────────────────────────────────────────────────────────────────────────────
-- KT → Catalog Studio Agent Readiness
-- Adds service_name to checkpoints, catalog_name + pricing to service cycles,
-- and pricing to spare parts — enabling the Onboarding Agent and TemplateAgent
-- to mine KT data without manual entry.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. m_equipment_checkpoints: commercial service name
--    Groups checkpoints under a catalog-facing service name.
--    Multiple checkpoints in the same section/activity share one service_name.
--    Example: "Monthly AC Maintenance" groups all PM checkpoints for that cycle.
ALTER TABLE m_equipment_checkpoints
  ADD COLUMN IF NOT EXISTS service_name TEXT DEFAULT NULL;

-- 2. m_service_cycles: commercial catalog name + geo-aware pricing
--    catalog_name: customer-facing name for this service cycle in catalog-studio.
--    pricing columns: min/median/max from LLM research (geo + currency aware).
--    Median value → auto-populated into cat_blocks.base_price by Onboarding Agent.
ALTER TABLE m_service_cycles
  ADD COLUMN IF NOT EXISTS catalog_name    TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_min       NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_median    NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_max       NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_currency  TEXT    DEFAULT 'INR',
  ADD COLUMN IF NOT EXISTS price_geo       TEXT    DEFAULT 'IN';

-- 3. m_equipment_spare_parts: geo-aware pricing
--    Same min/median/max pattern as service cycles.
--    price_unit: how the part is priced (per unit, per kg, per litre, per set, etc.)
ALTER TABLE m_equipment_spare_parts
  ADD COLUMN IF NOT EXISTS price_min      NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_median   NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_max      NUMERIC DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_unit     TEXT    DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS price_currency TEXT    DEFAULT 'INR',
  ADD COLUMN IF NOT EXISTS price_geo      TEXT    DEFAULT 'IN';

-- 4. Indexes for agent queries
--    Agents will filter by service_name and catalog_name frequently.
CREATE INDEX IF NOT EXISTS idx_m_equipment_checkpoints_service_name
  ON m_equipment_checkpoints (resource_template_id, service_name)
  WHERE service_name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_m_service_cycles_catalog_name
  ON m_service_cycles (catalog_name)
  WHERE catalog_name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_m_equipment_spare_parts_pricing
  ON m_equipment_spare_parts (resource_template_id)
  WHERE price_median IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_m_service_cycles_pricing
  ON m_service_cycles (checkpoint_id)
  WHERE price_median IS NOT NULL;
