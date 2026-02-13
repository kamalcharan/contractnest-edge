-- ============================================================================
-- P1b: cat_asset_types LOV — Pricing Variant Dimension
-- Migration: contracts/036_cat_asset_types_lov.sql
-- Phase: P1 — Equipment & Entity Foundation
--
-- What this does:
--   1. Adds 'cat_asset_types' to m_category_master (1 row)
--   2. Seeds m_category_details with pricing-variant types:
--      - Residential variants (1BHK, 2BHK, 3BHK, Villa, Penthouse)
--      - Commercial variants (Office Floor, Retail Shop, Warehouse)
--      - Equipment sizing (Split AC 1.5T, Split AC 2T, Cassette AC, etc.)
--      - Vehicle types (Two-Wheeler, Sedan, SUV, Commercial Vehicle)
--      - IT variants (Desktop, Laptop, Server, Network Device)
--
-- Purpose:
--   These are NOT the same as the asset registry (t_tenant_asset_registry).
--   Asset types are a lookup/LOV used for PRICING VARIANTS — e.g., a
--   "1BHK" costs ₹500/month vs a "3BHK" costs ₹1200/month in the same FMC.
--
-- Rollback: See 036_cat_asset_types_lov_DOWN.sql
-- ============================================================================

-- ============================================================================
-- STEP 1: Create the master category
-- ============================================================================

INSERT INTO m_category_master (
    id, category_name, display_name, description, icon_name, sequence_no, is_active
)
VALUES (
    uuid_generate_v4(),
    'cat_asset_types',
    'Asset Types',
    'Pricing variant dimension — defines billable unit types (1BHK, 2BHK, Split AC 1.5T, etc.)',
    'Layers',
    25,
    true
)
ON CONFLICT (category_name) DO NOTHING;

-- ============================================================================
-- STEP 2: Seed pricing variant types into m_category_details
-- ============================================================================

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id
    FROM m_category_master
    WHERE category_name = 'cat_asset_types';

    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'cat_asset_types not found in m_category_master';
    END IF;

    -- ── Residential Variants ─────────────────────────────────────────

    INSERT INTO m_category_details (
        id, category_id, sub_cat_name, display_name, description,
        icon_name, hexcolor, sequence_no, is_active, is_deletable,
        form_settings
    )
    VALUES
    (gen_random_uuid(), v_category_id, 'residential_1bhk', '1 BHK',
     'Single bedroom apartment unit',
     'Home', '#4F46E5', 10, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":550,"pricing_multiplier":1.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'residential_2bhk', '2 BHK',
     'Two bedroom apartment unit',
     'Home', '#4F46E5', 20, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":900,"pricing_multiplier":1.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'residential_3bhk', '3 BHK',
     'Three bedroom apartment unit',
     'Home', '#4F46E5', 30, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":1400,"pricing_multiplier":2.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'residential_4bhk', '4 BHK',
     'Four bedroom apartment unit',
     'Home', '#4F46E5', 40, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":2000,"pricing_multiplier":2.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'residential_villa', 'Villa / Row House',
     'Independent villa or row house unit',
     'Castle', '#4F46E5', 50, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":2500,"pricing_multiplier":3.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'residential_penthouse', 'Penthouse',
     'Top-floor luxury penthouse unit',
     'Crown', '#4F46E5', 60, true, false,
     '{"group":"residential","group_label":"Residential","group_icon":"Building2","typical_area_sqft":3500,"pricing_multiplier":4.0}'::jsonb),

    -- ── Commercial Variants ──────────────────────────────────────────

    (gen_random_uuid(), v_category_id, 'commercial_office', 'Office Floor',
     'Commercial office floor or suite',
     'Briefcase', '#0891B2', 70, true, false,
     '{"group":"commercial","group_label":"Commercial","group_icon":"Building2","pricing_unit":"per_sqft"}'::jsonb),

    (gen_random_uuid(), v_category_id, 'commercial_retail', 'Retail Shop',
     'Retail shop or showroom space',
     'ShoppingBag', '#0891B2', 80, true, false,
     '{"group":"commercial","group_label":"Commercial","group_icon":"Building2","pricing_unit":"per_sqft"}'::jsonb),

    (gen_random_uuid(), v_category_id, 'commercial_warehouse', 'Warehouse',
     'Storage or warehouse space',
     'Warehouse', '#0891B2', 90, true, false,
     '{"group":"commercial","group_label":"Commercial","group_icon":"Building2","pricing_unit":"per_sqft"}'::jsonb),

    (gen_random_uuid(), v_category_id, 'commercial_basement_parking', 'Basement Parking',
     'Covered basement parking area',
     'Car', '#0891B2', 100, true, false,
     '{"group":"commercial","group_label":"Commercial","group_icon":"Building2","pricing_unit":"per_slot"}'::jsonb),

    -- ── HVAC / AC Variants ───────────────────────────────────────────

    (gen_random_uuid(), v_category_id, 'ac_split_1_5t', 'Split AC 1.5 Ton',
     'Wall-mounted split air conditioner 1.5 ton',
     'Wind', '#059669', 110, true, false,
     '{"group":"hvac","group_label":"HVAC / Air Conditioning","group_icon":"Wind","capacity":"1.5 ton","pricing_multiplier":1.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'ac_split_2t', 'Split AC 2 Ton',
     'Wall-mounted split air conditioner 2 ton',
     'Wind', '#059669', 120, true, false,
     '{"group":"hvac","group_label":"HVAC / Air Conditioning","group_icon":"Wind","capacity":"2 ton","pricing_multiplier":1.3}'::jsonb),

    (gen_random_uuid(), v_category_id, 'ac_cassette', 'Cassette AC',
     'Ceiling-mounted cassette air conditioner',
     'Wind', '#059669', 130, true, false,
     '{"group":"hvac","group_label":"HVAC / Air Conditioning","group_icon":"Wind","capacity":"variable","pricing_multiplier":1.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'ac_ductable', 'Ductable AC',
     'Ducted central air conditioning unit',
     'Wind', '#059669', 140, true, false,
     '{"group":"hvac","group_label":"HVAC / Air Conditioning","group_icon":"Wind","capacity":"variable","pricing_multiplier":2.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'ac_vrf_vrv', 'VRF / VRV System',
     'Variable refrigerant flow central AC system',
     'Wind', '#059669', 150, true, false,
     '{"group":"hvac","group_label":"HVAC / Air Conditioning","group_icon":"Wind","capacity":"building_level","pricing_multiplier":5.0}'::jsonb),

    -- ── Vehicle Variants ─────────────────────────────────────────────

    (gen_random_uuid(), v_category_id, 'vehicle_two_wheeler', 'Two-Wheeler',
     'Motorcycle, scooter, or moped',
     'Bike', '#D97706', 160, true, false,
     '{"group":"vehicle","group_label":"Vehicles","group_icon":"Car","pricing_multiplier":0.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'vehicle_sedan', 'Sedan / Hatchback',
     'Passenger car — sedan or hatchback',
     'Car', '#D97706', 170, true, false,
     '{"group":"vehicle","group_label":"Vehicles","group_icon":"Car","pricing_multiplier":1.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'vehicle_suv', 'SUV / MUV',
     'Sport utility vehicle or multi-utility vehicle',
     'Car', '#D97706', 180, true, false,
     '{"group":"vehicle","group_label":"Vehicles","group_icon":"Car","pricing_multiplier":1.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'vehicle_commercial', 'Commercial Vehicle',
     'Truck, van, or commercial transport vehicle',
     'Truck', '#D97706', 190, true, false,
     '{"group":"vehicle","group_label":"Vehicles","group_icon":"Car","pricing_multiplier":2.0}'::jsonb),

    -- ── IT Equipment Variants ────────────────────────────────────────

    (gen_random_uuid(), v_category_id, 'it_desktop', 'Desktop Workstation',
     'Desktop computer or workstation',
     'Monitor', '#7C3AED', 200, true, false,
     '{"group":"it_equipment","group_label":"IT Equipment","group_icon":"Monitor","pricing_multiplier":1.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'it_laptop', 'Laptop',
     'Portable laptop computer',
     'Laptop', '#7C3AED', 210, true, false,
     '{"group":"it_equipment","group_label":"IT Equipment","group_icon":"Monitor","pricing_multiplier":1.2}'::jsonb),

    (gen_random_uuid(), v_category_id, 'it_server', 'Server',
     'Rack-mount or tower server',
     'Server', '#7C3AED', 220, true, false,
     '{"group":"it_equipment","group_label":"IT Equipment","group_icon":"Monitor","pricing_multiplier":3.0}'::jsonb),

    (gen_random_uuid(), v_category_id, 'it_network_device', 'Network Device',
     'Router, switch, firewall, or access point',
     'Network', '#7C3AED', 230, true, false,
     '{"group":"it_equipment","group_label":"IT Equipment","group_icon":"Monitor","pricing_multiplier":1.5}'::jsonb),

    (gen_random_uuid(), v_category_id, 'it_printer_mfp', 'Printer / MFP',
     'Laser printer or multi-function device',
     'Printer', '#7C3AED', 240, true, false,
     '{"group":"it_equipment","group_label":"IT Equipment","group_icon":"Monitor","pricing_multiplier":0.8}'::jsonb);

END $$;
