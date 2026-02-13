-- ============================================================================
-- P1a: Seed m_catalog_resource_templates — Real Industry Equipment & Entity Data
-- Migration: contracts/035_seed_resource_templates.sql
-- Phase: P1 — Equipment & Entity Foundation
--
-- What this does:
--   Inserts granular equipment and entity templates across 6 industries.
--   These templates power the "pre-suggestion" feature when tenants
--   register assets in /settings/configure/resources.
--
-- Existing data: 20 generic templates already seeded via scripts/
-- This migration adds ~60 specific templates (equipment + asset types).
--
-- Rollback: See 035_seed_resource_templates_DOWN.sql
-- ============================================================================

-- Use a DO block so we can handle conflicts gracefully
DO $$
BEGIN

-- ============================================================================
-- HEALTHCARE — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'healthcare', 'equipment', 'MRI Scanner',
     'Magnetic resonance imaging diagnostic system',
     '{"make_examples":["Siemens","GE Healthcare","Philips"],"maintenance_schedule":"quarterly","requires_calibration":true,"typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":8,"suggested_hourly_rate":200}',
     90, true, true, 10),

    (gen_random_uuid(), 'healthcare', 'equipment', 'CT Scanner',
     'Computed tomography scanner for cross-sectional imaging',
     '{"make_examples":["Siemens","GE Healthcare","Canon"],"maintenance_schedule":"quarterly","requires_calibration":true,"typical_lifespan_years":8}',
     '{"typical_amc_percent_of_cost":8,"suggested_hourly_rate":180}',
     85, true, true, 20),

    (gen_random_uuid(), 'healthcare', 'equipment', 'X-Ray Machine',
     'Digital radiography unit for diagnostic imaging',
     '{"make_examples":["Fujifilm","Carestream","Agfa"],"maintenance_schedule":"semi-annual","requires_calibration":true,"typical_lifespan_years":12}',
     '{"typical_amc_percent_of_cost":6,"suggested_hourly_rate":80}',
     80, true, true, 30),

    (gen_random_uuid(), 'healthcare', 'equipment', 'Ultrasound Machine',
     'Portable or stationary ultrasound imaging device',
     '{"make_examples":["Philips","GE Healthcare","Samsung Medison"],"maintenance_schedule":"semi-annual","requires_calibration":true,"typical_lifespan_years":7}',
     '{"typical_amc_percent_of_cost":7,"suggested_hourly_rate":60}',
     75, true, true, 40),

    (gen_random_uuid(), 'healthcare', 'equipment', 'Ventilator',
     'Mechanical ventilation device for respiratory support',
     '{"make_examples":["Drager","Hamilton","Medtronic"],"maintenance_schedule":"monthly","requires_calibration":true,"typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":10,"suggested_hourly_rate":50}',
     70, true, true, 50),

    (gen_random_uuid(), 'healthcare', 'equipment', 'Patient Monitor',
     'Multi-parameter bedside monitoring system',
     '{"make_examples":["Philips","Mindray","Nihon Kohden"],"maintenance_schedule":"semi-annual","requires_calibration":true,"typical_lifespan_years":8}',
     '{"typical_amc_percent_of_cost":6,"suggested_hourly_rate":30}',
     65, true, true, 60),

    (gen_random_uuid(), 'healthcare', 'equipment', 'Defibrillator',
     'Automated external or manual cardiac defibrillator',
     '{"make_examples":["Philips","ZOLL","Stryker"],"maintenance_schedule":"semi-annual","requires_calibration":true,"typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":5,"suggested_hourly_rate":25}',
     60, true, true, 70);

-- ============================================================================
-- HEALTHCARE — Asset (Entities)
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'healthcare', 'asset', 'Hospital Ward',
     'Inpatient ward or department floor',
     '{"typical_area_sqft":5000,"capacity":"20-40 beds"}',
     '{"suggested_monthly_rate":15000}',
     70, true, true, 10),

    (gen_random_uuid(), 'healthcare', 'asset', 'Operation Theatre',
     'Surgical suite with sterile environment',
     '{"typical_area_sqft":800,"hvac_class":"HEPA","sterile_zone":true}',
     '{"suggested_monthly_rate":25000}',
     80, true, true, 20),

    (gen_random_uuid(), 'healthcare', 'asset', 'Diagnostic Lab',
     'Pathology or imaging laboratory space',
     '{"typical_area_sqft":1200,"temperature_controlled":true}',
     '{"suggested_monthly_rate":10000}',
     65, true, true, 30);

-- ============================================================================
-- FACILITY MANAGEMENT — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'facility_management', 'equipment', 'Elevator / Lift',
     'Passenger or freight elevator system',
     '{"make_examples":["Otis","KONE","Schindler","ThyssenKrupp"],"maintenance_schedule":"monthly","requires_certification":true,"typical_lifespan_years":25}',
     '{"typical_amc_percent_of_cost":3,"suggested_monthly_rate":5000}',
     95, true, true, 10),

    (gen_random_uuid(), 'facility_management', 'equipment', 'HVAC System',
     'Central air conditioning / heating / ventilation unit',
     '{"make_examples":["Daikin","Carrier","Trane","Blue Star"],"maintenance_schedule":"quarterly","typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":5,"suggested_monthly_rate":3000}',
     90, true, true, 20),

    (gen_random_uuid(), 'facility_management', 'equipment', 'Fire Alarm Panel',
     'Addressable fire detection and alarm system',
     '{"make_examples":["Honeywell","Bosch","Siemens"],"maintenance_schedule":"quarterly","requires_certification":true,"typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":1500}',
     85, true, true, 30),

    (gen_random_uuid(), 'facility_management', 'equipment', 'DG Set (Generator)',
     'Diesel generator for backup power',
     '{"make_examples":["Cummins","Kirloskar","Caterpillar"],"maintenance_schedule":"monthly","typical_lifespan_years":20}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":4000}',
     80, true, true, 40),

    (gen_random_uuid(), 'facility_management', 'equipment', 'STP / WTP Plant',
     'Sewage / water treatment plant',
     '{"make_examples":["Thermax","Ion Exchange","Aqua Designs"],"maintenance_schedule":"monthly","requires_certification":true,"typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":6,"suggested_monthly_rate":8000}',
     70, true, true, 50),

    (gen_random_uuid(), 'facility_management', 'equipment', 'CCTV & Surveillance',
     'IP camera system with NVR/DVR',
     '{"make_examples":["Hikvision","Dahua","CP Plus","Bosch"],"maintenance_schedule":"quarterly","typical_lifespan_years":7}',
     '{"typical_amc_percent_of_cost":8,"suggested_monthly_rate":2000}',
     75, true, true, 60),

    (gen_random_uuid(), 'facility_management', 'equipment', 'UPS System',
     'Uninterruptible power supply for critical loads',
     '{"make_examples":["APC","Emerson","Eaton"],"maintenance_schedule":"quarterly","typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":5,"suggested_monthly_rate":1500}',
     65, true, true, 70),

    (gen_random_uuid(), 'facility_management', 'equipment', 'Transformer',
     'Electrical power distribution transformer',
     '{"make_examples":["ABB","Siemens","Schneider"],"maintenance_schedule":"semi-annual","typical_lifespan_years":25}',
     '{"typical_amc_percent_of_cost":2,"suggested_monthly_rate":2000}',
     60, true, true, 80);

-- ============================================================================
-- FACILITY MANAGEMENT — Asset (Entities)
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'facility_management', 'asset', 'Residential Building',
     'Multi-storey residential apartment complex',
     '{"typical_floors":10,"typical_units":80,"typical_area_sqft":50000}',
     '{"suggested_monthly_per_sqft":3}',
     90, true, true, 10),

    (gen_random_uuid(), 'facility_management', 'asset', 'Commercial Office Tower',
     'Multi-tenant commercial office space',
     '{"typical_floors":15,"typical_area_sqft":100000}',
     '{"suggested_monthly_per_sqft":5}',
     85, true, true, 20),

    (gen_random_uuid(), 'facility_management', 'asset', 'Shopping Mall',
     'Retail mall with common area management',
     '{"typical_area_sqft":200000,"common_area_pct":30}',
     '{"suggested_monthly_per_sqft":4}',
     75, true, true, 30),

    (gen_random_uuid(), 'facility_management', 'asset', 'Industrial Park / Warehouse',
     'Logistics or industrial facility',
     '{"typical_area_sqft":75000,"loading_docks":true}',
     '{"suggested_monthly_per_sqft":2}',
     65, true, true, 40);

-- ============================================================================
-- MANUFACTURING — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'manufacturing', 'equipment', 'CNC Machine',
     'Computer numerical control machining center',
     '{"make_examples":["DMG Mori","Mazak","Haas"],"maintenance_schedule":"monthly","requires_calibration":true,"typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":5,"suggested_hourly_rate":120}',
     90, true, true, 10),

    (gen_random_uuid(), 'manufacturing', 'equipment', 'Industrial Compressor',
     'Air or gas compressor for pneumatic systems',
     '{"make_examples":["Atlas Copco","Ingersoll Rand","Kaeser"],"maintenance_schedule":"quarterly","typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":3000}',
     80, true, true, 20),

    (gen_random_uuid(), 'manufacturing', 'equipment', 'Injection Moulding Machine',
     'Plastic or metal injection moulding press',
     '{"make_examples":["Engel","Arburg","JSW"],"maintenance_schedule":"monthly","typical_lifespan_years":20}',
     '{"typical_amc_percent_of_cost":4,"suggested_hourly_rate":80}',
     75, true, true, 30),

    (gen_random_uuid(), 'manufacturing', 'equipment', 'Conveyor System',
     'Material handling conveyor belt assembly',
     '{"make_examples":["Dematic","Interroll","FlexLink"],"maintenance_schedule":"quarterly","typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":3,"suggested_monthly_rate":2500}',
     70, true, true, 40),

    (gen_random_uuid(), 'manufacturing', 'equipment', 'Boiler / Steam Generator',
     'Industrial steam generation system',
     '{"make_examples":["Thermax","Forbes Marshall","Cleaver-Brooks"],"maintenance_schedule":"monthly","requires_certification":true,"typical_lifespan_years":20}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":5000}',
     65, true, true, 50);

-- ============================================================================
-- AUTOMOTIVE — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'automotive', 'equipment', 'Vehicle Lift / Hoist',
     'Two-post or four-post vehicle lifting system',
     '{"make_examples":["Rotary","BendPak","Hunter"],"maintenance_schedule":"semi-annual","requires_certification":true,"typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":3,"suggested_monthly_rate":1500}',
     85, true, true, 10),

    (gen_random_uuid(), 'automotive', 'equipment', 'Wheel Alignment Machine',
     'Computerized 3D wheel alignment system',
     '{"make_examples":["Hunter","Corghi","John Bean"],"maintenance_schedule":"quarterly","requires_calibration":true,"typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":6,"suggested_monthly_rate":2000}',
     80, true, true, 20),

    (gen_random_uuid(), 'automotive', 'equipment', 'Tyre Changer',
     'Automatic tyre mounting and demounting machine',
     '{"make_examples":["Corghi","Hunter","Ravaglioli"],"maintenance_schedule":"semi-annual","typical_lifespan_years":12}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":800}',
     75, true, true, 30),

    (gen_random_uuid(), 'automotive', 'equipment', 'Paint Booth',
     'Spray painting and drying booth for vehicles',
     '{"make_examples":["Global Finishing","Garmat","Saico"],"maintenance_schedule":"monthly","typical_lifespan_years":15}',
     '{"typical_amc_percent_of_cost":5,"suggested_monthly_rate":3000}',
     65, true, true, 40);

-- ============================================================================
-- TECHNOLOGY — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'technology', 'equipment', 'Server Rack',
     'Data center rack-mount server unit',
     '{"make_examples":["Dell","HP","Lenovo"],"maintenance_schedule":"quarterly","typical_lifespan_years":5}',
     '{"typical_amc_percent_of_cost":10,"suggested_monthly_rate":2000}',
     85, true, true, 10),

    (gen_random_uuid(), 'technology', 'equipment', 'Network Switch',
     'Managed L2/L3 network switch for LAN',
     '{"make_examples":["Cisco","Juniper","Aruba"],"maintenance_schedule":"semi-annual","typical_lifespan_years":7}',
     '{"typical_amc_percent_of_cost":8,"suggested_monthly_rate":500}',
     75, true, true, 20),

    (gen_random_uuid(), 'technology', 'equipment', 'UPS (Data Center)',
     'Online double-conversion UPS for IT loads',
     '{"make_examples":["APC","Eaton","Vertiv"],"maintenance_schedule":"quarterly","typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":6,"suggested_monthly_rate":1500}',
     70, true, true, 30),

    (gen_random_uuid(), 'technology', 'equipment', 'Precision AC Unit',
     'Computer room air conditioning (CRAC) unit',
     '{"make_examples":["Stulz","Vertiv","Schneider"],"maintenance_schedule":"quarterly","typical_lifespan_years":12}',
     '{"typical_amc_percent_of_cost":5,"suggested_monthly_rate":3000}',
     65, true, true, 40);

-- ============================================================================
-- TECHNOLOGY — Asset (Entities)
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'technology', 'asset', 'Data Center',
     'Colocation or on-premise data center facility',
     '{"typical_area_sqft":5000,"tier":"Tier-3","cooling":"precision_ac"}',
     '{"suggested_monthly_per_rack":5000}',
     80, true, true, 10),

    (gen_random_uuid(), 'technology', 'asset', 'Server Room',
     'On-premise server room or communications closet',
     '{"typical_area_sqft":500,"cooling":"split_ac"}',
     '{"suggested_monthly_rate":3000}',
     70, true, true, 20);

-- ============================================================================
-- WELLNESS — Equipment
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'wellness', 'equipment', 'Treadmill (Commercial)',
     'Heavy-duty commercial treadmill',
     '{"make_examples":["Life Fitness","Precor","Technogym"],"maintenance_schedule":"quarterly","typical_lifespan_years":8}',
     '{"typical_amc_percent_of_cost":6,"suggested_monthly_rate":500}',
     80, true, true, 10),

    (gen_random_uuid(), 'wellness', 'equipment', 'Multi-Gym Station',
     'Multi-station strength training system',
     '{"make_examples":["Technogym","Matrix","Cybex"],"maintenance_schedule":"semi-annual","typical_lifespan_years":10}',
     '{"typical_amc_percent_of_cost":4,"suggested_monthly_rate":400}',
     70, true, true, 20),

    (gen_random_uuid(), 'wellness', 'equipment', 'Spa / Sauna Unit',
     'Steam sauna, infrared sauna, or jacuzzi system',
     '{"make_examples":["Jacuzzi","Harvia","TylöHelo"],"maintenance_schedule":"monthly","typical_lifespan_years":12}',
     '{"typical_amc_percent_of_cost":5,"suggested_monthly_rate":1000}',
     60, true, true, 30);

-- ============================================================================
-- WELLNESS — Asset (Entities)
-- ============================================================================
INSERT INTO m_catalog_resource_templates
    (id, industry_id, resource_type_id, name, description, default_attributes, pricing_guidance, popularity_score, is_recommended, is_active, sort_order)
VALUES
    (gen_random_uuid(), 'wellness', 'asset', 'Gym Floor',
     'Dedicated fitness floor or gym hall',
     '{"typical_area_sqft":3000,"flooring":"rubber_mat"}',
     '{"suggested_monthly_rate":5000}',
     70, true, true, 10),

    (gen_random_uuid(), 'wellness', 'asset', 'Swimming Pool',
     'Indoor or outdoor swimming pool facility',
     '{"typical_area_sqft":2000,"heated":true,"filtration":"sand_filter"}',
     '{"suggested_monthly_rate":8000}',
     65, true, true, 20);

END $$;
