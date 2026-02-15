-- ============================================================================
-- P1b: Add sub_category column to m_catalog_resource_templates
-- Migration: contracts/039_resource_template_sub_categories.sql
-- Phase: P1 — Equipment & Entity Foundation
--
-- What this does:
--   Adds a sub_category grouping column to resource templates so the UI
--   can cluster templates into meaningful groups (e.g. "Diagnostic Imaging",
--   "Life Support", "HVAC Systems") instead of a flat list.
--
-- Rollback: See 039_resource_template_sub_categories_DOWN.sql
-- ============================================================================

-- Step 1: Add the column
ALTER TABLE m_catalog_resource_templates
  ADD COLUMN IF NOT EXISTS sub_category varchar(100);

-- Step 2: Populate sub_category for existing templates
-- ════════════════════════════════════════════════════════
-- HEALTHCARE — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'Diagnostic Imaging'
  WHERE industry_id = 'healthcare' AND resource_type_id = 'equipment'
    AND name IN ('MRI Scanner', 'CT Scanner', 'X-Ray Machine', 'Ultrasound Machine');

UPDATE m_catalog_resource_templates SET sub_category = 'Life Support'
  WHERE industry_id = 'healthcare' AND resource_type_id = 'equipment'
    AND name IN ('Ventilator', 'Defibrillator');

UPDATE m_catalog_resource_templates SET sub_category = 'Patient Monitoring'
  WHERE industry_id = 'healthcare' AND resource_type_id = 'equipment'
    AND name IN ('Patient Monitor');

-- HEALTHCARE — Assets
UPDATE m_catalog_resource_templates SET sub_category = 'Clinical Facilities'
  WHERE industry_id = 'healthcare' AND resource_type_id = 'asset'
    AND name IN ('Hospital Ward', 'Operation Theatre', 'Diagnostic Lab');

-- ════════════════════════════════════════════════════════
-- FACILITY MANAGEMENT — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'Vertical Transport'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name ILIKE '%elevator%' OR (industry_id = 'facility_management' AND name ILIKE '%lift%');

UPDATE m_catalog_resource_templates SET sub_category = 'HVAC Systems'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name ILIKE '%hvac%';

UPDATE m_catalog_resource_templates SET sub_category = 'Fire & Safety'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name ILIKE '%fire%';

UPDATE m_catalog_resource_templates SET sub_category = 'Power & Electrical'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name IN ('DG Set (Generator)', 'UPS System', 'Transformer');

UPDATE m_catalog_resource_templates SET sub_category = 'Water Treatment'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name ILIKE '%stp%' OR (industry_id = 'facility_management' AND name ILIKE '%wtp%');

UPDATE m_catalog_resource_templates SET sub_category = 'Security & Surveillance'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'equipment'
    AND name ILIKE '%cctv%';

-- FACILITY MANAGEMENT — Assets
UPDATE m_catalog_resource_templates SET sub_category = 'Residential Properties'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'asset'
    AND name ILIKE '%residential%';

UPDATE m_catalog_resource_templates SET sub_category = 'Commercial Properties'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'asset'
    AND name ILIKE '%office%' OR (industry_id = 'facility_management' AND resource_type_id = 'asset' AND name ILIKE '%mall%');

UPDATE m_catalog_resource_templates SET sub_category = 'Industrial Properties'
  WHERE industry_id = 'facility_management' AND resource_type_id = 'asset'
    AND name ILIKE '%industrial%' OR (industry_id = 'facility_management' AND resource_type_id = 'asset' AND name ILIKE '%warehouse%');

-- ════════════════════════════════════════════════════════
-- MANUFACTURING — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'CNC & Machining'
  WHERE industry_id = 'manufacturing' AND resource_type_id = 'equipment'
    AND name ILIKE '%cnc%';

UPDATE m_catalog_resource_templates SET sub_category = 'Pneumatics & Hydraulics'
  WHERE industry_id = 'manufacturing' AND resource_type_id = 'equipment'
    AND name ILIKE '%compressor%';

UPDATE m_catalog_resource_templates SET sub_category = 'Moulding & Forming'
  WHERE industry_id = 'manufacturing' AND resource_type_id = 'equipment'
    AND name ILIKE '%moulding%' OR (industry_id = 'manufacturing' AND name ILIKE '%molding%');

UPDATE m_catalog_resource_templates SET sub_category = 'Material Handling'
  WHERE industry_id = 'manufacturing' AND resource_type_id = 'equipment'
    AND name ILIKE '%conveyor%';

UPDATE m_catalog_resource_templates SET sub_category = 'Thermal Systems'
  WHERE industry_id = 'manufacturing' AND resource_type_id = 'equipment'
    AND name ILIKE '%boiler%' OR (industry_id = 'manufacturing' AND name ILIKE '%steam%');

-- ════════════════════════════════════════════════════════
-- AUTOMOTIVE — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'Workshop Equipment'
  WHERE industry_id = 'automotive' AND resource_type_id = 'equipment'
    AND name IN ('Vehicle Lift / Hoist', 'Tyre Changer', 'Paint Booth');

UPDATE m_catalog_resource_templates SET sub_category = 'Diagnostic Tools'
  WHERE industry_id = 'automotive' AND resource_type_id = 'equipment'
    AND name ILIKE '%alignment%';

-- ════════════════════════════════════════════════════════
-- TECHNOLOGY — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'Server & Compute'
  WHERE industry_id = 'technology' AND resource_type_id = 'equipment'
    AND name ILIKE '%server%';

UPDATE m_catalog_resource_templates SET sub_category = 'Networking'
  WHERE industry_id = 'technology' AND resource_type_id = 'equipment'
    AND name ILIKE '%switch%' OR (industry_id = 'technology' AND name ILIKE '%network%');

UPDATE m_catalog_resource_templates SET sub_category = 'Power & Cooling'
  WHERE industry_id = 'technology' AND resource_type_id = 'equipment'
    AND name IN ('UPS (Data Center)', 'Precision AC Unit');

-- TECHNOLOGY — Assets
UPDATE m_catalog_resource_templates SET sub_category = 'Data Facilities'
  WHERE industry_id = 'technology' AND resource_type_id = 'asset'
    AND name IN ('Data Center', 'Server Room');

-- ════════════════════════════════════════════════════════
-- WELLNESS — Equipment
-- ════════════════════════════════════════════════════════
UPDATE m_catalog_resource_templates SET sub_category = 'Fitness Equipment'
  WHERE industry_id = 'wellness' AND resource_type_id = 'equipment'
    AND name IN ('Treadmill (Commercial)', 'Multi-Gym Station');

UPDATE m_catalog_resource_templates SET sub_category = 'Spa & Relaxation'
  WHERE industry_id = 'wellness' AND resource_type_id = 'equipment'
    AND name ILIKE '%spa%' OR (industry_id = 'wellness' AND name ILIKE '%sauna%');

-- WELLNESS — Assets
UPDATE m_catalog_resource_templates SET sub_category = 'Wellness Facilities'
  WHERE industry_id = 'wellness' AND resource_type_id = 'asset'
    AND name IN ('Gym Floor', 'Swimming Pool');
