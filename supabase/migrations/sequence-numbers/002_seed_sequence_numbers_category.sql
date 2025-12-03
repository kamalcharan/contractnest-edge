-- ============================================================
-- Migration: 002_seed_sequence_numbers_category
-- Description: Seed sequence_numbers category in t_category_master
--              and default sequence types in t_category_details
-- Author: Claude
-- Date: 2025-12-03
-- ============================================================

-- ============================================================
-- IMPORTANT: This migration seeds data for a SPECIFIC tenant
-- For production: Run this as part of tenant onboarding flow
-- For development: Replace the tenant_id with your test tenant
-- ============================================================

-- ============================================================
-- TEMPLATE: Create category_master entry for a tenant
-- Usage: Replace {{TENANT_ID}} with actual tenant UUID
-- ============================================================

-- Step 1: Insert into t_category_master (run once per tenant)
-- This creates the "Sequence Numbers" category

/*
-- TEMPLATE FOR NEW TENANT:
INSERT INTO public.t_category_master (
    id,
    category_name,
    display_name,
    is_active,
    description,
    icon_name,
    order_sequence,
    tenant_id,
    created_at,
    is_live
)
VALUES (
    gen_random_uuid(),                    -- Let DB generate ID
    'sequence_numbers',                   -- category_name (code)
    'Sequence Numbers',                   -- display_name
    true,                                 -- is_active
    'Document and record numbering sequences configuration',
    'Hash',                               -- icon_name (Lucide icon)
    10,                                   -- order_sequence
    '{{TENANT_ID}}'::uuid,               -- tenant_id - REPLACE THIS
    NOW(),
    true                                  -- is_live
)
ON CONFLICT DO NOTHING;
*/

-- ============================================================
-- FUNCTION: seed_sequence_numbers_for_tenant
-- Purpose: Seed default sequence configurations for a new tenant
-- Called during: Tenant onboarding
-- ============================================================

CREATE OR REPLACE FUNCTION public.seed_sequence_numbers_for_tenant(
    p_tenant_id UUID,
    p_created_by UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
    v_category_id UUID;
    v_result JSONB := '[]'::JSONB;
    v_sequence_type RECORD;
BEGIN
    -- Step 1: Create the category_master entry
    INSERT INTO public.t_category_master (
        category_name,
        display_name,
        is_active,
        description,
        icon_name,
        order_sequence,
        tenant_id,
        is_live
    )
    VALUES (
        'sequence_numbers',
        'Sequence Numbers',
        true,
        'Document and record numbering sequences configuration',
        'Hash',
        10,
        p_tenant_id,
        true
    )
    ON CONFLICT DO NOTHING
    RETURNING id INTO v_category_id;

    -- If category already exists, get its ID
    IF v_category_id IS NULL THEN
        SELECT id INTO v_category_id
        FROM public.t_category_master
        WHERE category_name = 'sequence_numbers'
          AND tenant_id = p_tenant_id
          AND is_live = true;
    END IF;

    -- Step 2: Insert default sequence types
    -- Each sequence type has form_settings with its configuration

    -- CONTACT sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'CONTACT',
        'Contact Number',
        v_category_id,
        '#3B82F6',  -- Blue
        'Users',
        true,
        1,
        'Auto-generated number for contacts',
        p_tenant_id,
        false,      -- System sequence, not deletable
        jsonb_build_object(
            'prefix', 'CT',
            'separator', '-',
            'suffix', '',
            'padding_length', 4,
            'start_value', 1001,
            'reset_frequency', 'NEVER',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- CONTRACT sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'CONTRACT',
        'Contract Number',
        v_category_id,
        '#10B981',  -- Green
        'FileText',
        true,
        2,
        'Auto-generated number for contracts',
        p_tenant_id,
        false,
        jsonb_build_object(
            'prefix', 'CN',
            'separator', '-',
            'suffix', '',
            'padding_length', 4,
            'start_value', 1001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- INVOICE sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'INVOICE',
        'Invoice Number',
        v_category_id,
        '#F59E0B',  -- Amber
        'Receipt',
        true,
        3,
        'Auto-generated number for invoices',
        p_tenant_id,
        false,
        jsonb_build_object(
            'prefix', 'INV',
            'separator', '-',
            'suffix', '',
            'padding_length', 5,
            'start_value', 10001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- QUOTATION sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'QUOTATION',
        'Quotation Number',
        v_category_id,
        '#8B5CF6',  -- Purple
        'FileQuestion',
        true,
        4,
        'Auto-generated number for quotations',
        p_tenant_id,
        false,
        jsonb_build_object(
            'prefix', 'QT',
            'separator', '-',
            'suffix', '',
            'padding_length', 4,
            'start_value', 1001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- RECEIPT sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'RECEIPT',
        'Receipt Number',
        v_category_id,
        '#EC4899',  -- Pink
        'CreditCard',
        true,
        5,
        'Auto-generated number for receipts',
        p_tenant_id,
        false,
        jsonb_build_object(
            'prefix', 'RCP',
            'separator', '-',
            'suffix', '',
            'padding_length', 5,
            'start_value', 10001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- PROJECT sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'PROJECT',
        'Project Number',
        v_category_id,
        '#06B6D4',  -- Cyan
        'Folder',
        true,
        6,
        'Auto-generated number for projects',
        p_tenant_id,
        true,       -- Optional, can be deleted
        jsonb_build_object(
            'prefix', 'PRJ',
            'separator', '-',
            'suffix', '',
            'padding_length', 4,
            'start_value', 1001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- TASK sequence
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'TASK',
        'Task Number',
        v_category_id,
        '#64748B',  -- Slate
        'CheckSquare',
        true,
        7,
        'Auto-generated number for tasks',
        p_tenant_id,
        true,
        jsonb_build_object(
            'prefix', 'TSK',
            'separator', '-',
            'suffix', '',
            'padding_length', 5,
            'start_value', 10001,
            'reset_frequency', 'NEVER',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- TICKET sequence (Support)
    INSERT INTO public.t_category_details (
        sub_cat_name,
        display_name,
        category_id,
        hexcolor,
        icon_name,
        is_active,
        sequence_no,
        description,
        tenant_id,
        is_deletable,
        form_settings,
        is_live
    )
    VALUES (
        'TICKET',
        'Support Ticket Number',
        v_category_id,
        '#EF4444',  -- Red
        'Ticket',
        true,
        8,
        'Auto-generated number for support tickets',
        p_tenant_id,
        true,
        jsonb_build_object(
            'prefix', 'TKT',
            'separator', '-',
            'suffix', '',
            'padding_length', 5,
            'start_value', 10001,
            'reset_frequency', 'YEARLY',
            'increment_by', 1
        ),
        true
    )
    ON CONFLICT DO NOTHING;

    -- Return summary of what was created
    SELECT jsonb_agg(jsonb_build_object(
        'sub_cat_name', sub_cat_name,
        'display_name', display_name,
        'form_settings', form_settings
    ))
    INTO v_result
    FROM public.t_category_details
    WHERE category_id = v_category_id
      AND tenant_id = p_tenant_id
      AND is_live = true;

    RETURN jsonb_build_object(
        'success', true,
        'category_id', v_category_id,
        'tenant_id', p_tenant_id,
        'sequences_created', v_result
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- COMMENTS
-- ============================================================

COMMENT ON FUNCTION public.seed_sequence_numbers_for_tenant IS
'Seeds default sequence number configurations for a new tenant.
Called during tenant onboarding to create:
- Category master entry for sequence_numbers
- Default sequence types: CONTACT, CONTRACT, INVOICE, QUOTATION, RECEIPT, PROJECT, TASK, TICKET
Each sequence type has configurable prefix, separator, padding, start value, and reset frequency.';

-- ============================================================
-- EXAMPLE USAGE (for testing - replace with actual tenant ID):
-- ============================================================

/*
-- To seed sequences for a specific tenant:
SELECT public.seed_sequence_numbers_for_tenant(
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid  -- tenant_id
);

-- To get the next contact number:
SELECT public.get_next_formatted_sequence(
    'CONTACT',                                     -- sequence code
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid, -- tenant_id
    true                                           -- is_live
);
-- Returns: {"formatted": "CT-1001", "sequence": 1001, "prefix": "CT", "separator": "-", "suffix": ""}
*/
