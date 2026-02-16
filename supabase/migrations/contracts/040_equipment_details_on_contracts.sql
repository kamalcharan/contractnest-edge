-- ============================================================================
-- Migration: contracts/040_equipment_details_on_contracts.sql
-- Purpose: Add denormalized equipment_details JSONB column to t_contracts
--
-- Why denormalized?
--   Contracts are denormalized by design — buyer details, blocks, nomenclature
--   are all stored directly. Equipment/entity details follow the same pattern.
--   This avoids cross-tenant FK resolution issues when both seller and buyer
--   can add equipment to a contract.
--
-- JSONB schema per array element:
--   {
--     "id":                 <client-generated UUID>,
--     "asset_registry_id":  <UUID | null>,       -- optional FK back to t_client_asset_registry
--     "added_by_tenant_id": <UUID>,              -- tenant who added this entry
--     "added_by_role":      "seller" | "buyer",  -- who added it
--     "resource_type":      "equipment" | "entity",
--     "category_id":        <UUID | null>,       -- FK to m_catalog_resource_types
--     "category_name":      <string>,            -- denormalized: "Diagnostic Imaging"
--     "item_name":          <string>,            -- "MRI Scanner"
--     "quantity":           <integer>,           -- e.g. 1
--     "make":               <string | null>,
--     "model":              <string | null>,
--     "serial_number":      <string | null>,
--     "condition":          "good" | "fair" | "poor" | "critical" | null,
--     "criticality":        "low" | "medium" | "high" | "critical" | null,
--     "location":           <string | null>,
--     "purchase_date":      <ISO date string | null>,
--     "warranty_expiry":    <ISO date string | null>,
--     "area_sqft":          <number | null>,     -- entity-specific
--     "dimensions":         <object | null>,     -- entity-specific
--     "capacity":           <integer | null>,    -- entity-specific
--     "specifications":     <object>,            -- overflow key-value pairs
--     "notes":              <string | null>
--   }
--
-- Rollback: ALTER TABLE t_contracts DROP COLUMN IF EXISTS equipment_details;
-- ============================================================================

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS equipment_details JSONB DEFAULT '[]'::jsonb;

COMMENT ON COLUMN t_contracts.equipment_details
    IS 'Denormalized array of equipment/entity details covered by this contract. Each element stores full details (category, item, qty, make, model, etc.) to avoid cross-tenant FK resolution.';
