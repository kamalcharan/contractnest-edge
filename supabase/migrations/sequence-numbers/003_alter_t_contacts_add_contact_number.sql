-- ============================================================
-- Migration: 003_alter_t_contacts_add_contact_number
-- Description: Add contact_number column to t_contacts table
-- Author: Claude
-- Date: 2025-12-03
-- ============================================================

-- ============================================================
-- ADD COLUMN: contact_number
-- Purpose: Human-readable auto-generated contact identifier
-- Format: e.g., "CT-1001", "CT-1002"
-- ============================================================

-- Add the column if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 't_contacts'
          AND column_name = 'contact_number'
    ) THEN
        ALTER TABLE public.t_contacts
        ADD COLUMN contact_number VARCHAR(50);

        RAISE NOTICE 'Column contact_number added to t_contacts';
    ELSE
        RAISE NOTICE 'Column contact_number already exists in t_contacts';
    END IF;
END $$;

-- ============================================================
-- INDEX: For fast lookup by contact_number
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_contacts_contact_number
ON public.t_contacts(contact_number);

-- Composite index for tenant + contact_number (most common query)
CREATE INDEX IF NOT EXISTS idx_contacts_tenant_contact_number
ON public.t_contacts(tenant_id, contact_number);

-- ============================================================
-- UNIQUE CONSTRAINT: contact_number per tenant per environment
-- Note: contact_number should be unique within tenant+environment
-- ============================================================

-- Create unique index (allows NULLs, unlike UNIQUE constraint)
CREATE UNIQUE INDEX IF NOT EXISTS idx_contacts_unique_contact_number
ON public.t_contacts(tenant_id, contact_number, is_live)
WHERE contact_number IS NOT NULL;

-- ============================================================
-- FUNCTION: Auto-generate contact_number on INSERT
-- Purpose: Automatically assigns contact_number when creating contact
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_generate_contact_number()
RETURNS TRIGGER AS $$
DECLARE
    v_sequence_result JSONB;
BEGIN
    -- Only generate if contact_number is not provided
    IF NEW.contact_number IS NULL OR NEW.contact_number = '' THEN
        BEGIN
            -- Get next formatted sequence
            v_sequence_result := public.get_next_formatted_sequence(
                'CONTACT',
                NEW.tenant_id,
                COALESCE(NEW.is_live, true)
            );

            NEW.contact_number := v_sequence_result->>'formatted';
        EXCEPTION WHEN OTHERS THEN
            -- If sequence generation fails (e.g., sequence not configured),
            -- log warning but don't fail the insert
            RAISE WARNING 'Could not auto-generate contact_number: %', SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- TRIGGER: Auto-generate contact_number before INSERT
-- ============================================================

-- Drop existing trigger if it exists
DROP TRIGGER IF EXISTS trg_auto_contact_number ON public.t_contacts;

-- Create trigger
CREATE TRIGGER trg_auto_contact_number
    BEFORE INSERT ON public.t_contacts
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_generate_contact_number();

-- ============================================================
-- BACKFILL: Generate contact_numbers for existing contacts
-- Run this AFTER seeding sequence_numbers for the tenant
-- ============================================================

/*
-- TEMPLATE: Backfill existing contacts for a specific tenant
-- WARNING: Run this carefully in production!

DO $$
DECLARE
    v_tenant_id UUID := '70f8eb69-9ccf-4a0c-8177-cb6131934344';  -- REPLACE
    v_contact RECORD;
    v_sequence_result JSONB;
BEGIN
    -- Process contacts without contact_number
    FOR v_contact IN
        SELECT id, tenant_id, is_live
        FROM public.t_contacts
        WHERE tenant_id = v_tenant_id
          AND (contact_number IS NULL OR contact_number = '')
        ORDER BY created_at ASC  -- Preserve chronological order
    LOOP
        v_sequence_result := public.get_next_formatted_sequence(
            'CONTACT',
            v_contact.tenant_id,
            v_contact.is_live
        );

        UPDATE public.t_contacts
        SET contact_number = v_sequence_result->>'formatted'
        WHERE id = v_contact.id;
    END LOOP;

    RAISE NOTICE 'Backfill complete for tenant %', v_tenant_id;
END $$;
*/

-- ============================================================
-- FUNCTION: Backfill contact_numbers for a tenant
-- Can be called from edge function or API
-- ============================================================

CREATE OR REPLACE FUNCTION public.backfill_contact_numbers(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB AS $$
DECLARE
    v_contact RECORD;
    v_sequence_result JSONB;
    v_count INTEGER := 0;
BEGIN
    -- Process contacts without contact_number
    FOR v_contact IN
        SELECT id, tenant_id, is_live
        FROM public.t_contacts
        WHERE tenant_id = p_tenant_id
          AND is_live = p_is_live
          AND (contact_number IS NULL OR contact_number = '')
        ORDER BY created_at ASC
    LOOP
        v_sequence_result := public.get_next_formatted_sequence(
            'CONTACT',
            v_contact.tenant_id,
            v_contact.is_live
        );

        UPDATE public.t_contacts
        SET contact_number = v_sequence_result->>'formatted'
        WHERE id = v_contact.id;

        v_count := v_count + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'success', true,
        'tenant_id', p_tenant_id,
        'is_live', p_is_live,
        'contacts_updated', v_count
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- COMMENTS
-- ============================================================

COMMENT ON COLUMN public.t_contacts.contact_number IS
'Human-readable auto-generated contact identifier. Format: PREFIX-SEQUENCE (e.g., CT-1001).
Generated automatically on insert using sequence configuration from t_category_details.';

COMMENT ON FUNCTION public.auto_generate_contact_number IS
'Trigger function to auto-generate contact_number on INSERT if not provided.';

COMMENT ON FUNCTION public.backfill_contact_numbers IS
'Generates contact_numbers for existing contacts that dont have one.
Call after setting up sequence_numbers for a tenant.';

-- ============================================================
-- VERIFICATION QUERIES
-- ============================================================

/*
-- Check if column was added:
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 't_contacts'
  AND column_name = 'contact_number';

-- Check trigger exists:
SELECT trigger_name, event_manipulation, action_timing
FROM information_schema.triggers
WHERE trigger_name = 'trg_auto_contact_number';

-- Test sequence generation (after seeding):
SELECT public.get_next_formatted_sequence(
    'CONTACT',
    '70f8eb69-9ccf-4a0c-8177-cb6131934344'::uuid,
    true
);
*/
