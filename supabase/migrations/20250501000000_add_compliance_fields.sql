-- ─────────────────────────────────────────────────────────────────────────────
-- Compliance Engine: add compliance fields to m_equipment_checkpoints,
-- create kt_equipment_meta and kt_compliance_defaults tables.
-- ─────────────────────────────────────────────────────────────────────────────

-- 1. Add compliance columns to checkpoints
ALTER TABLE m_equipment_checkpoints
  ADD COLUMN IF NOT EXISTS compliance_standard TEXT DEFAULT NULL,
  ADD COLUMN IF NOT EXISTS is_mandatory        BOOLEAN DEFAULT FALSE;

-- 2. Equipment meta: admin-managed criticality + calibration per resource template
CREATE TABLE IF NOT EXISTS kt_equipment_meta (
  id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_template_id     UUID NOT NULL REFERENCES m_catalog_resource_templates(id) ON DELETE CASCADE,
  equipment_criticality    TEXT NOT NULL DEFAULT 'standard'
                             CHECK (equipment_criticality IN ('life_critical', 'mission_critical', 'standard')),
  calibration_interval_days INTEGER DEFAULT NULL,
  notes                    TEXT DEFAULT NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (resource_template_id)
);

-- Auto-update updated_at
CREATE OR REPLACE FUNCTION update_kt_equipment_meta_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_kt_equipment_meta_updated_at ON kt_equipment_meta;
CREATE TRIGGER trg_kt_equipment_meta_updated_at
  BEFORE UPDATE ON kt_equipment_meta
  FOR EACH ROW EXECUTE FUNCTION update_kt_equipment_meta_updated_at();

-- 3. Compliance defaults: admin-managed per sub_category
--    Defines which standards are default for a sub-category, applied during "Tag Compliance".
CREATE TABLE IF NOT EXISTS kt_compliance_defaults (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_category         TEXT NOT NULL,
  compliance_standard  TEXT NOT NULL,
  description          TEXT DEFAULT NULL,
  is_active            BOOLEAN NOT NULL DEFAULT TRUE,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (sub_category, compliance_standard)
);

-- 4. Seed Indian market compliance defaults per equipment sub-category
INSERT INTO kt_compliance_defaults (sub_category, compliance_standard, description) VALUES
  -- Medical equipment
  ('Medical Imaging', 'AERB', 'Atomic Energy Regulatory Board — radiation safety'),
  ('Medical Imaging', 'NABH', 'National Accreditation Board for Hospitals & Healthcare'),
  ('Medical Imaging', 'IEC 60601', 'International standard for medical electrical equipment safety'),
  ('Life Support', 'AERB', 'Atomic Energy Regulatory Board'),
  ('Life Support', 'NABH', 'National Accreditation Board for Hospitals & Healthcare'),
  ('Life Support', 'IEC 60601', 'International standard for medical electrical equipment safety'),
  ('Diagnostic Equipment', 'NABL', 'National Accreditation Board for Testing and Calibration Laboratories'),
  ('Diagnostic Equipment', 'NABH', 'National Accreditation Board for Hospitals & Healthcare'),
  ('Diagnostic Equipment', 'IEC 60601', 'International standard for medical electrical equipment safety'),
  ('Patient Monitoring', 'NABH', 'National Accreditation Board for Hospitals & Healthcare'),
  ('Patient Monitoring', 'IEC 60601', 'International standard for medical electrical equipment safety'),
  -- Fire safety
  ('Fire Safety Systems', 'NBC', 'National Building Code of India'),
  ('Fire Safety Systems', 'BIS', 'Bureau of Indian Standards'),
  -- Power generation
  ('Power Generation', 'CEA', 'Central Electricity Authority regulations'),
  ('Power Generation', 'BIS', 'Bureau of Indian Standards'),
  ('Power Generation', 'CPWD', 'Central Public Works Department specifications'),
  -- Petroleum & oil
  ('Petroleum Equipment', 'PESO', 'Petroleum and Explosives Safety Organisation'),
  ('Petroleum Equipment', 'OISD', 'Oil Industry Safety Directorate'),
  ('Industrial Gases', 'PESO', 'Petroleum and Explosives Safety Organisation'),
  ('Industrial Gases', 'BIS', 'Bureau of Indian Standards'),
  -- HVAC / environment
  ('HVAC', 'ISHRAE', 'Indian Society of Heating, Refrigerating and Air Conditioning Engineers'),
  ('HVAC', 'BEE', 'Bureau of Energy Efficiency — energy performance standards'),
  ('HVAC', 'BIS', 'Bureau of Indian Standards'),
  ('Cooling Systems', 'ISHRAE', 'Indian Society of Heating, Refrigerating and Air Conditioning Engineers'),
  ('Cooling Systems', 'BEE', 'Bureau of Energy Efficiency'),
  -- Electrical infrastructure
  ('Electrical Infrastructure', 'CEA', 'Central Electricity Authority regulations'),
  ('Electrical Infrastructure', 'BIS', 'Bureau of Indian Standards'),
  ('Electrical Infrastructure', 'IEC', 'International Electrotechnical Commission'),
  ('UPS Systems', 'BIS', 'Bureau of Indian Standards'),
  ('UPS Systems', 'IEC', 'International Electrotechnical Commission'),
  -- Vertical transport
  ('Vertical Transport', 'BIS', 'Bureau of Indian Standards IS 14665'),
  ('Vertical Transport', 'NBC', 'National Building Code of India'),
  -- Water treatment
  ('Water Treatment', 'CPCB', 'Central Pollution Control Board — wastewater standards'),
  ('Water Treatment', 'BIS', 'Bureau of Indian Standards'),
  ('Water Treatment', 'FSSAI', 'Food Safety and Standards Authority — potable water'),
  -- Food & pharma
  ('Food Processing Equipment', 'FSSAI', 'Food Safety and Standards Authority of India'),
  ('Food Processing Equipment', 'BIS', 'Bureau of Indian Standards'),
  ('Pharmaceutical Equipment', 'CDSCO', 'Central Drugs Standard Control Organisation'),
  ('Pharmaceutical Equipment', 'GMP', 'Good Manufacturing Practice — Schedule M'),
  -- Generic / cross-industry
  ('Cross Industry', 'BIS', 'Bureau of Indian Standards'),
  ('General Industrial', 'BIS', 'Bureau of Indian Standards')
ON CONFLICT (sub_category, compliance_standard) DO NOTHING;

-- 5. Indexes
CREATE INDEX IF NOT EXISTS idx_kt_equipment_meta_rtemplate
  ON kt_equipment_meta (resource_template_id);

CREATE INDEX IF NOT EXISTS idx_kt_compliance_defaults_sub_category
  ON kt_compliance_defaults (sub_category);

CREATE INDEX IF NOT EXISTS idx_m_equipment_checkpoints_compliance
  ON m_equipment_checkpoints (compliance_standard)
  WHERE compliance_standard IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_m_equipment_checkpoints_mandatory
  ON m_equipment_checkpoints (is_mandatory)
  WHERE is_mandatory = TRUE;
