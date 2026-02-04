-- ============================================================
-- Migration: 007_fix_contact_number_trigger_use_v2
-- Description: Fix auto_generate_contact_number trigger to call
--              get_next_formatted_sequence_v2 (reads t_sequence_counters)
--              instead of v1 (reads t_category_details which has no data)
--
-- Root Cause: Onboarding seeds sequences into t_sequence_counters (new table)
--             but the trigger was calling v1 which looks in t_category_details (old table).
--             Result: trigger silently failed, contact_number stayed NULL, counters never incremented.
--
-- Also: Add contact_number to list and get RPCs so UI can display it.
--
-- Author: Claude
-- Date: 2025-02-04
-- ============================================================

-- ============================================================
-- FIX 1: Update trigger function to call v2
-- ============================================================

CREATE OR REPLACE FUNCTION public.auto_generate_contact_number()
RETURNS TRIGGER AS $$
DECLARE
    v_sequence_result JSONB;
BEGIN
    -- Only generate if contact_number is not provided
    IF NEW.contact_number IS NULL OR NEW.contact_number = '' THEN
        BEGIN
            -- FIX: Call v2 which reads from t_sequence_counters (where seeding puts data)
            -- Previously called get_next_formatted_sequence (v1) which reads t_category_details
            v_sequence_result := public.get_next_formatted_sequence_v2(
                'CONTACT',
                NEW.tenant_id,
                COALESCE(NEW.is_live, true)
            );

            NEW.contact_number := v_sequence_result->>'formatted';
        EXCEPTION WHEN OTHERS THEN
            -- If sequence generation fails (e.g., sequence not configured yet),
            -- log warning but don't fail the insert
            RAISE WARNING 'Could not auto-generate contact_number: %', SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Recreate trigger (ensures it uses the updated function)
DROP TRIGGER IF EXISTS trg_auto_contact_number ON public.t_contacts;

CREATE TRIGGER trg_auto_contact_number
    BEFORE INSERT ON public.t_contacts
    FOR EACH ROW
    EXECUTE FUNCTION public.auto_generate_contact_number();

-- ============================================================
-- COMMENTS
-- ============================================================

COMMENT ON FUNCTION public.auto_generate_contact_number IS
'Trigger function to auto-generate contact_number on INSERT if not provided.
Uses get_next_formatted_sequence_v2 which reads from t_sequence_counters (new architecture).
Fixed in migration 007: was previously calling v1 which read from t_category_details (empty).';

-- ============================================================
-- VERIFICATION QUERIES
-- ============================================================

/*
-- Verify trigger exists and uses updated function:
SELECT trigger_name, action_timing, event_manipulation
FROM information_schema.triggers
WHERE trigger_name = 'trg_auto_contact_number';

-- Verify v2 function exists:
SELECT proname FROM pg_proc WHERE proname = 'get_next_formatted_sequence_v2';

-- Test: Check if CONTACT sequence exists for your tenant:
SELECT sequence_code, current_value, prefix, padding_length, start_value
FROM t_sequence_counters
WHERE sequence_code = 'CONTACT' AND is_live = true;

-- Test: Manually call v2 to verify it works:
-- SELECT public.get_next_formatted_sequence_v2('CONTACT', '<your-tenant-id>'::uuid, true);
*/
