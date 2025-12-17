-- ============================================================
-- Migration: 006_seed_global_sequence_definitions
-- Description: Create GLOBAL sequence type definitions
--              These are templates used when seeding tenant data
--              They do NOT have tenant_id (global for all tenants)
-- Author: Claude
-- Date: 2025-12-17
-- ============================================================

-- ============================================================
-- STEP 1: Create global sequence_numbers category in t_category_master
-- Note: NO tenant_id - this is a GLOBAL category
-- ============================================================
INSERT INTO public.t_category_master (
    id,
    category_name,
    display_name,
    is_active,
    description,
    icon_name,
    order_sequence,
    created_at
)
VALUES (
    'a0000000-0000-0000-0000-000000000001'::uuid,  -- Fixed UUID for global category
    'sequence_numbers',
    'Sequence Numbers',
    true,
    'Global sequence type definitions - templates for tenant configurations',
    'Hash',
    10,
    NOW()
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- STEP 2: Create global sequence type definitions in t_category_details
-- These are TEMPLATES with default values
-- Note: NO tenant_id - these are GLOBAL definitions
-- ============================================================

-- CONTACT sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000001'::uuid,
    'CONTACT',
    'Contact Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#3B82F6',
    'Users',
    true,
    1,
    'Auto-generated number for contacts',
    false,
    '{"prefix": "CT", "separator": "-", "suffix": "", "padding_length": 4, "start_value": 1, "increment_by": 1, "reset_frequency": "NEVER"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- CONTRACT sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000002'::uuid,
    'CONTRACT',
    'Contract Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#10B981',
    'FileText',
    true,
    2,
    'Auto-generated number for contracts',
    false,
    '{"prefix": "CN", "separator": "-", "suffix": "", "padding_length": 4, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- INVOICE sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000003'::uuid,
    'INVOICE',
    'Invoice Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#F59E0B',
    'Receipt',
    true,
    3,
    'Auto-generated number for invoices',
    false,
    '{"prefix": "INV", "separator": "-", "suffix": "", "padding_length": 5, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- QUOTATION sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000004'::uuid,
    'QUOTATION',
    'Quotation Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#8B5CF6',
    'FileQuestion',
    true,
    4,
    'Auto-generated number for quotations',
    false,
    '{"prefix": "QT", "separator": "-", "suffix": "", "padding_length": 4, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- RECEIPT sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000005'::uuid,
    'RECEIPT',
    'Receipt Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#EC4899',
    'CreditCard',
    true,
    5,
    'Auto-generated number for receipts',
    false,
    '{"prefix": "RCP", "separator": "-", "suffix": "", "padding_length": 5, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- PROJECT sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000006'::uuid,
    'PROJECT',
    'Project Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#06B6D4',
    'Folder',
    true,
    6,
    'Auto-generated number for projects',
    true,
    '{"prefix": "PRJ", "separator": "-", "suffix": "", "padding_length": 4, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- TASK sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000007'::uuid,
    'TASK',
    'Task Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#64748B',
    'CheckSquare',
    true,
    7,
    'Auto-generated number for tasks',
    true,
    '{"prefix": "TSK", "separator": "-", "suffix": "", "padding_length": 5, "start_value": 1, "increment_by": 1, "reset_frequency": "NEVER"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- TICKET sequence definition
INSERT INTO public.t_category_details (
    id,
    sub_cat_name,
    display_name,
    category_id,
    hexcolor,
    icon_name,
    is_active,
    sequence_no,
    description,
    is_deletable,
    form_settings
)
VALUES (
    'b0000000-0000-0000-0000-000000000008'::uuid,
    'TICKET',
    'Support Ticket Number',
    'a0000000-0000-0000-0000-000000000001'::uuid,
    '#EF4444',
    'Ticket',
    true,
    8,
    'Auto-generated number for support tickets',
    true,
    '{"prefix": "TKT", "separator": "-", "suffix": "", "padding_length": 5, "start_value": 1, "increment_by": 1, "reset_frequency": "YEARLY"}'::jsonb
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- COMMENTS
-- ============================================================
COMMENT ON TABLE public.t_category_master IS 'Global category definitions. sequence_numbers category (id: a0000000-...-000000000001) contains global sequence type templates.';
