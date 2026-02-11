-- ============================================================================
-- P0: Contract Nomenclature — Seed Data + Column Addition
-- Migration: contracts/032_nomenclature_seed.sql
-- Phase: P0 — Nomenclature Foundation
--
-- What this does:
--   1. Adds 'cat_contract_nomenclature' to m_category_master (1 row)
--   2. Adds 21 nomenclature types to m_category_details with rich form_settings
--   3. Adds nomenclature_id column to t_contracts (nullable FK)
--
-- Rollback: See 032_nomenclature_seed_DOWN.sql
-- ============================================================================

-- ============================================================================
-- STEP 1: Create the master category
-- ============================================================================

INSERT INTO m_category_master (
    id, category_name, display_name, description, icon_name, sequence_no, is_active
)
VALUES (
    uuid_generate_v4(),
    'cat_contract_nomenclature',
    'Contract Nomenclature',
    'Industry-standard contract type classifications (AMC, CMC, FMC, etc.)',
    'FileSignature',
    20,
    true
)
ON CONFLICT (category_name) DO NOTHING;

-- ============================================================================
-- STEP 2: Seed 21 nomenclature types into m_category_details
--
-- Groups:
--   Equipment Maintenance (6): AMC, CMC, CAMC, PMC, BMC, Warranty Ext
--   Facility & Property  (3): FMC, O&M, Manpower
--   Service Delivery     (6): Service Package, Care Plan, Subscription,
--                              Consultation, Training, Project-Based
--   Flexible / Hybrid    (6): SLA, Rate Contract, Retainer, Per-Call,
--                              Turnkey, BOT/BOOT
-- ============================================================================

DO $$
DECLARE
    v_category_id UUID;
BEGIN
    SELECT id INTO v_category_id
    FROM m_category_master
    WHERE category_name = 'cat_contract_nomenclature';

    IF v_category_id IS NULL THEN
        RAISE EXCEPTION 'cat_contract_nomenclature not found in m_category_master';
    END IF;

    -- ── Equipment Maintenance Contracts (6) ─────────────────────────

    INSERT INTO m_category_details (
        id, category_id, sub_cat_name, display_name, description,
        icon_name, hexcolor, sequence_no, is_active, is_deletable,
        tags, tool_tip, form_settings
    )
    VALUES
    (
        uuid_generate_v4(), v_category_id,
        'amc', 'AMC',
        'Yearly contract with scheduled preventive visits. Labor included, parts may or may not be included.',
        'Wrench', '#3B82F6', 1, true, false,
        '["equipment", "maintenance", "annual"]'::jsonb,
        'Annual Maintenance Contract — scheduled visits with labor, parts optional',
        '{
            "short_name": "AMC",
            "full_name": "Annual Maintenance Contract",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "12_months",
            "typical_billing": "quarterly",
            "scope_includes": ["scheduled_visits", "labor", "diagnostics"],
            "scope_excludes": ["parts_optional"],
            "industries": ["healthcare", "manufacturing", "real_estate", "technology"],
            "icon": "Wrench"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'cmc', 'CMC',
        'Everything included — labor + parts + consumables. Zero extra cost to buyer.',
        'ShieldCheck', '#8B5CF6', 2, true, false,
        '["equipment", "maintenance", "comprehensive"]'::jsonb,
        'Comprehensive Maintenance Contract — all-inclusive coverage',
        '{
            "short_name": "CMC",
            "full_name": "Comprehensive Maintenance Contract",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "12_months",
            "typical_billing": "quarterly",
            "scope_includes": ["scheduled_visits", "labor", "parts", "consumables", "breakdown_support"],
            "scope_excludes": [],
            "industries": ["healthcare", "manufacturing"],
            "icon": "ShieldCheck"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'camc', 'CAMC',
        'Same as CMC but specifically annual. Common in government/PSU procurement.',
        'ShieldPlus', '#7C3AED', 3, true, false,
        '["equipment", "maintenance", "comprehensive", "annual", "government"]'::jsonb,
        'Comprehensive Annual Maintenance Contract — CMC with annual scope',
        '{
            "short_name": "CAMC",
            "full_name": "Comprehensive Annual Maintenance Contract",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "12_months",
            "typical_billing": "annually",
            "scope_includes": ["scheduled_visits", "labor", "parts", "consumables", "breakdown_support"],
            "scope_excludes": [],
            "industries": ["healthcare", "manufacturing", "government"],
            "icon": "ShieldPlus"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'pmc', 'PMC',
        'Only scheduled preventive checks. No breakdown coverage.',
        'CalendarCheck', '#0EA5E9', 4, true, false,
        '["equipment", "maintenance", "preventive"]'::jsonb,
        'Preventive Maintenance Contract — scheduled checks only, no breakdowns',
        '{
            "short_name": "PMC",
            "full_name": "Preventive Maintenance Contract",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "12_months",
            "typical_billing": "quarterly",
            "scope_includes": ["scheduled_visits", "diagnostics", "lubrication", "calibration"],
            "scope_excludes": ["breakdown_support", "parts"],
            "industries": ["manufacturing", "healthcare", "technology"],
            "icon": "CalendarCheck"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'bmc', 'BMC',
        'On-call repair only. No scheduled visits. Pay per incident.',
        'AlertTriangle', '#F59E0B', 5, true, false,
        '["equipment", "maintenance", "breakdown", "on_call"]'::jsonb,
        'Breakdown Maintenance Contract — reactive repair, no scheduled visits',
        '{
            "short_name": "BMC",
            "full_name": "Breakdown Maintenance Contract",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "ongoing",
            "typical_billing": "per_visit",
            "scope_includes": ["breakdown_support", "labor"],
            "scope_excludes": ["scheduled_visits"],
            "industries": ["manufacturing", "real_estate"],
            "icon": "AlertTriangle"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'warranty_ext', 'Warranty Extension',
        'Post-OEM-warranty coverage, usually equipment-specific.',
        'BadgeCheck', '#6366F1', 6, true, false,
        '["equipment", "warranty", "post_oem"]'::jsonb,
        'Extended Warranty — coverage after OEM warranty expires',
        '{
            "short_name": "Warranty Ext",
            "full_name": "Extended Warranty",
            "group": "equipment_maintenance",
            "group_label": "Equipment Maintenance Contracts",
            "group_icon": "Wrench",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "equipment",
            "typical_duration": "12_months",
            "typical_billing": "annually",
            "scope_includes": ["post_warranty_coverage", "parts", "labor"],
            "scope_excludes": [],
            "industries": ["healthcare", "manufacturing", "technology"],
            "icon": "BadgeCheck"
        }'::jsonb
    ),

    -- ── Facility & Property Contracts (3) ───────────────────────────

    (
        uuid_generate_v4(), v_category_id,
        'fmc', 'FMC',
        'Holistic facility operations — cleaning + security + maintenance + utilities.',
        'Building2', '#10B981', 7, true, false,
        '["facility", "property", "management", "operations"]'::jsonb,
        'Facility Management Contract — comprehensive building/property operations',
        '{
            "short_name": "FMC",
            "full_name": "Facility Management Contract",
            "group": "facility_property",
            "group_label": "Facility & Property Contracts",
            "group_icon": "Building2",
            "is_equipment_based": false,
            "is_entity_based": true,
            "is_service_based": false,
            "wizard_route": "entity",
            "typical_duration": "12_months",
            "typical_billing": "monthly",
            "scope_includes": ["cleaning", "security", "maintenance", "utilities", "landscaping"],
            "scope_excludes": [],
            "industries": ["real_estate", "hospitality", "corporate"],
            "icon": "Building2"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'om', 'O&M',
        'Full operational responsibility. Common in infrastructure and utilities.',
        'Settings2', '#14B8A6', 8, true, false,
        '["operations", "maintenance", "infrastructure"]'::jsonb,
        'Operations & Maintenance — full operational responsibility for equipment + property',
        '{
            "short_name": "O&M",
            "full_name": "Operations & Maintenance",
            "group": "facility_property",
            "group_label": "Facility & Property Contracts",
            "group_icon": "Building2",
            "is_equipment_based": true,
            "is_entity_based": true,
            "is_service_based": false,
            "wizard_route": "both",
            "typical_duration": "36_months",
            "typical_billing": "monthly",
            "scope_includes": ["operations", "maintenance", "staffing", "reporting"],
            "scope_excludes": [],
            "industries": ["infrastructure", "utilities", "energy"],
            "icon": "Settings2"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'manpower', 'Manpower',
        'Staffing/labor supply — guards, housekeeping staff, technicians.',
        'Users', '#059669', 9, true, false,
        '["staffing", "labor", "manpower", "outsourcing"]'::jsonb,
        'Manpower Supply Contract — staff deployment with attendance and replacement guarantees',
        '{
            "short_name": "Manpower",
            "full_name": "Manpower Supply Contract",
            "group": "facility_property",
            "group_label": "Facility & Property Contracts",
            "group_icon": "Building2",
            "is_equipment_based": false,
            "is_entity_based": true,
            "is_service_based": false,
            "wizard_route": "entity",
            "typical_duration": "12_months",
            "typical_billing": "monthly",
            "scope_includes": ["staff_supply", "attendance_tracking", "replacement_guarantee"],
            "scope_excludes": [],
            "industries": ["real_estate", "hospitality", "manufacturing", "corporate"],
            "icon": "Users"
        }'::jsonb
    ),

    -- ── Service Delivery Contracts (6) ──────────────────────────────

    (
        uuid_generate_v4(), v_category_id,
        'service_package', 'Service Package',
        'Bundled set of deliverables/sessions over a fixed period. Buyer gets a defined quantity of each service type.',
        'Package', '#EC4899', 10, true, false,
        '["service", "package", "bundled", "sessions"]'::jsonb,
        'Service Package Agreement — bundled deliverables over a fixed period',
        '{
            "short_name": "Service Package",
            "full_name": "Service Package Agreement",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "deliverables",
            "typical_duration": "1_to_12_months",
            "typical_billing": "prepaid_or_monthly",
            "scope_includes": ["defined_sessions", "fixed_deliverables", "scheduled_appointments"],
            "scope_excludes": ["unlimited_access", "on_demand"],
            "industries": ["wellness", "healthcare", "beauty", "fitness", "nutrition"],
            "example": "Pregnancy Care — 4 Gynec + 6 Diet Charts + 20 Yoga Sessions over 3 months",
            "icon": "Package"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'care_plan', 'Care Plan',
        'Healthcare/wellness outcome-oriented contract with a protocol of sessions, assessments, and deliverables.',
        'HeartPulse', '#F43F5E', 11, true, false,
        '["healthcare", "wellness", "care", "protocol"]'::jsonb,
        'Care Plan Agreement — outcome-oriented wellness/healthcare protocol',
        '{
            "short_name": "Care Plan",
            "full_name": "Care Plan Agreement",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "deliverables",
            "typical_duration": "1_to_12_months",
            "typical_billing": "monthly_or_prepaid",
            "scope_includes": ["protocol_sessions", "assessments", "monitoring", "diet_charts", "therapy"],
            "scope_excludes": ["equipment_servicing"],
            "industries": ["healthcare", "wellness", "mental_health", "elder_care", "rehabilitation"],
            "example": "PCOD Balance Program — 3 months — Gynec + Nutrition + Yoga protocol",
            "icon": "HeartPulse"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'subscription_service', 'Subscription',
        'Recurring access to a defined scope of services. May include usage limits or be unlimited within scope.',
        'RefreshCw', '#A855F7', 12, true, false,
        '["subscription", "recurring", "access"]'::jsonb,
        'Subscription Service Agreement — recurring access to defined service scope',
        '{
            "short_name": "Subscription",
            "full_name": "Subscription Service Agreement",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "deliverables",
            "typical_duration": "ongoing_or_12_months",
            "typical_billing": "monthly_or_annual",
            "scope_includes": ["recurring_access", "support_tickets", "periodic_reviews", "updates"],
            "scope_excludes": ["one_time_projects"],
            "industries": ["technology", "consulting", "creative", "marketing", "media"],
            "example": "IT Support — Unlimited tickets + 4hr SLA + Monthly health check",
            "icon": "RefreshCw"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'consultation', 'Consultation',
        'Time-banked or session-based professional advisory services.',
        'MessageSquare', '#6366F1', 13, true, false,
        '["consulting", "advisory", "professional"]'::jsonb,
        'Consultation Agreement — time-banked or session-based advisory services',
        '{
            "short_name": "Consultation",
            "full_name": "Consultation Agreement",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "deliverables",
            "typical_duration": "6_to_12_months",
            "typical_billing": "monthly_retainer",
            "scope_includes": ["advisory_hours", "reviews", "recommendations", "reports"],
            "scope_excludes": ["implementation", "hands_on_execution"],
            "industries": ["legal", "finance", "management", "technology", "healthcare"],
            "example": "Legal Advisory — 10 hours/month + Quarterly compliance audit",
            "icon": "MessageSquare"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'training_contract', 'Training',
        'Structured learning program with workshops, assessments, and certification.',
        'GraduationCap', '#0891B2', 14, true, false,
        '["training", "education", "workshop", "certification"]'::jsonb,
        'Training & Development Contract — structured learning with assessments and certification',
        '{
            "short_name": "Training",
            "full_name": "Training & Development Contract",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "deliverables",
            "typical_duration": "1_to_6_months",
            "typical_billing": "milestone_or_split",
            "scope_includes": ["workshops", "assessments", "coaching", "certification", "materials"],
            "scope_excludes": ["ongoing_support"],
            "industries": ["education", "corporate", "technology", "healthcare", "manufacturing"],
            "example": "Corporate Leadership Program — 8 Workshops + Coaching + Certification",
            "icon": "GraduationCap"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'project_service', 'Project-Based',
        'One-time deliverable with defined milestones and handover. May transition to AMC/subscription post-delivery.',
        'Target', '#F97316', 15, true, false,
        '["project", "milestone", "deliverable", "one_time"]'::jsonb,
        'Project-Based Service Agreement — milestone-driven with defined handover',
        '{
            "short_name": "Project-Based",
            "full_name": "Project-Based Service Agreement",
            "group": "service_delivery",
            "group_label": "Service Delivery Contracts",
            "group_icon": "Briefcase",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": true,
            "wizard_route": "milestones",
            "typical_duration": "project_based",
            "typical_billing": "milestone",
            "scope_includes": ["design", "development", "testing", "handover", "documentation"],
            "scope_excludes": ["ongoing_maintenance"],
            "industries": ["technology", "construction", "creative", "marketing", "consulting"],
            "example": "Website Redesign — 5 milestones over 3 months then transitions to Subscription",
            "icon": "Target"
        }'::jsonb
    ),

    -- ── Flexible / Hybrid Contracts (6) ─────────────────────────────

    (
        uuid_generate_v4(), v_category_id,
        'sla', 'SLA',
        'Performance-bound contract with penalties for non-compliance.',
        'Gauge', '#EF4444', 16, true, false,
        '["sla", "performance", "uptime", "penalties"]'::jsonb,
        'Service Level Agreement — performance guarantees with penalty clauses',
        '{
            "short_name": "SLA",
            "full_name": "Service Level Agreement",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": true,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "flexible",
            "typical_duration": "12_months",
            "typical_billing": "monthly",
            "scope_includes": ["guaranteed_uptime", "response_time", "resolution_time", "penalties"],
            "scope_excludes": [],
            "industries": ["technology", "telecom", "healthcare"],
            "icon": "Gauge"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'rate_contract', 'Rate Contract',
        'Pre-negotiated rates, pay only for actual usage/quantity consumed.',
        'Calculator', '#78716C', 17, true, false,
        '["rate", "usage", "on_demand", "pre_negotiated"]'::jsonb,
        'Rate Contract — pre-negotiated rates, pay per actual usage',
        '{
            "short_name": "Rate Contract",
            "full_name": "Rate Contract",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "flexible",
            "typical_duration": "12_months",
            "typical_billing": "per_usage",
            "scope_includes": ["pre_negotiated_rates", "on_demand"],
            "scope_excludes": ["fixed_commitment"],
            "industries": ["manufacturing", "construction", "government"],
            "icon": "Calculator"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'retainer', 'Retainer',
        'Fixed monthly/quarterly fee for guaranteed availability.',
        'Clock', '#64748B', 18, true, false,
        '["retainer", "availability", "guaranteed", "fixed_fee"]'::jsonb,
        'Retainer Agreement — fixed fee for guaranteed availability and priority response',
        '{
            "short_name": "Retainer",
            "full_name": "Retainer Agreement",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "flexible",
            "typical_duration": "12_months",
            "typical_billing": "monthly",
            "scope_includes": ["guaranteed_availability", "priority_response"],
            "scope_excludes": [],
            "industries": ["professional", "technology", "legal"],
            "icon": "Clock"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'per_call', 'Per-Call',
        'No commitment. Pay per service visit. Common for plumbing, electrical.',
        'PhoneCall', '#D97706', 19, true, false,
        '["on_demand", "per_visit", "no_commitment"]'::jsonb,
        'Per-Call / On-Demand Service — pay per visit, no minimum commitment',
        '{
            "short_name": "Per-Call",
            "full_name": "Per-Call / On-Demand Service",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": false,
            "is_entity_based": false,
            "is_service_based": false,
            "wizard_route": "flexible",
            "typical_duration": "ongoing",
            "typical_billing": "per_visit",
            "scope_includes": ["on_demand", "per_visit_billing"],
            "scope_excludes": ["scheduled_visits", "commitment"],
            "industries": ["real_estate", "residential", "commercial"],
            "icon": "PhoneCall"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'turnkey', 'Turnkey',
        'End-to-end project delivery, then transitions to AMC/O&M.',
        'Rocket', '#7C3AED', 20, true, false,
        '["turnkey", "project", "end_to_end", "handover"]'::jsonb,
        'Turnkey Contract — full design-build-commission cycle with handover',
        '{
            "short_name": "Turnkey",
            "full_name": "Turnkey Contract",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": true,
            "is_entity_based": true,
            "is_service_based": false,
            "wizard_route": "both",
            "typical_duration": "project_based",
            "typical_billing": "milestone",
            "scope_includes": ["design", "installation", "commissioning", "handover"],
            "scope_excludes": [],
            "industries": ["construction", "infrastructure", "technology"],
            "icon": "Rocket"
        }'::jsonb
    ),
    (
        uuid_generate_v4(), v_category_id,
        'bot_boot', 'BOT/BOOT',
        'Long-term operational contracts with eventual asset handover.',
        'ArrowRightLeft', '#475569', 21, true, false,
        '["bot", "boot", "build_operate_transfer", "long_term"]'::jsonb,
        'Build-Operate-Transfer — long-term ops with asset handover at end of term',
        '{
            "short_name": "BOT/BOOT",
            "full_name": "Build-Operate-Transfer",
            "group": "flexible_hybrid",
            "group_label": "Flexible / Hybrid Contracts",
            "group_icon": "Shuffle",
            "is_equipment_based": true,
            "is_entity_based": true,
            "is_service_based": false,
            "wizard_route": "both",
            "typical_duration": "60_months",
            "typical_billing": "monthly",
            "scope_includes": ["build", "operate", "maintain", "transfer"],
            "scope_excludes": [],
            "industries": ["infrastructure", "utilities", "energy"],
            "icon": "ArrowRightLeft"
        }'::jsonb
    )
    ON CONFLICT DO NOTHING;

END $$;

-- ============================================================================
-- STEP 3: Add nomenclature_id column to t_contracts
-- ============================================================================

ALTER TABLE t_contracts
    ADD COLUMN IF NOT EXISTS nomenclature_id UUID REFERENCES m_category_details(id);

-- Index for filtering contracts by nomenclature
CREATE INDEX IF NOT EXISTS idx_contracts_nomenclature
    ON t_contracts (tenant_id, nomenclature_id)
    WHERE nomenclature_id IS NOT NULL;

-- ============================================================================
-- STEP 4: Add RLS policy for nomenclature master data (public read)
-- ============================================================================
-- m_category_master and m_category_details already have public read access
-- via existing RLS policies, so no additional policy is needed.

-- ============================================================================
-- VERIFICATION QUERY (run after applying to confirm success):
--
-- SELECT cd.sub_cat_name, cd.display_name, cd.form_settings->>'group' as grp
-- FROM m_category_details cd
-- JOIN m_category_master cm ON cd.category_id = cm.id
-- WHERE cm.category_name = 'cat_contract_nomenclature'
-- ORDER BY cd.sequence_no;
--
-- Expected: 21 rows (6 equipment + 3 facility + 6 service + 6 flexible)
-- ============================================================================
