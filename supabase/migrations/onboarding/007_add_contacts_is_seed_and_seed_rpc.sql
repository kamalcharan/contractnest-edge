-- Migration: Add is_seed to t_contacts + SECURITY DEFINER RPC for sample contact seeding
-- Description: Adds is_seed flag for tracking onboarding-seeded contacts (enables clean
--              reseed later). Creates a SECURITY DEFINER function that accepts contact data
--              as JSONB and inserts into t_contacts as DB owner, bypassing RLS.
-- Date: 2026-05-22

-- ============================================================================
-- STEP 1: Add is_seed column to t_contacts
-- ============================================================================

ALTER TABLE "public"."t_contacts"
    ADD COLUMN IF NOT EXISTS "is_seed" BOOLEAN NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS "idx_contacts_tenant_seed"
    ON "public"."t_contacts" (tenant_id, is_seed)
    WHERE is_seed = true;

-- ============================================================================
-- STEP 2: SECURITY DEFINER RPC for seeding sample contacts
-- ============================================================================
-- Parameters:
--   p_tenant_id  UUID  — buyer tenant being onboarded
--   p_contacts   JSONB — array of contact objects (pre-built with UUIDs by API)
--
-- Returns: JSON { contactsSeeded: int, skipped: bool }
--
-- Safety: Idempotent — skips if is_seed contacts already exist for tenant.
-- ============================================================================

CREATE OR REPLACE FUNCTION "public"."seed_sample_contacts"(
    p_tenant_id  UUID,
    p_contacts   JSONB
)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_existing_count  INTEGER;
    v_contact         JSONB;
    v_seeded          INTEGER := 0;
    v_parent_ids      JSONB;
BEGIN
    -- Idempotency: skip if seed contacts already exist for this tenant
    SELECT COUNT(*) INTO v_existing_count
    FROM t_contacts
    WHERE tenant_id = p_tenant_id
      AND is_seed = true;

    IF v_existing_count > 0 THEN
        RETURN json_build_object('contactsSeeded', v_existing_count, 'skipped', true);
    END IF;

    -- Insert each contact from the array
    FOR v_contact IN SELECT * FROM jsonb_array_elements(p_contacts)
    LOOP
        -- Build parent_contact_ids array from parent_contact_id if present
        v_parent_ids := CASE
            WHEN (v_contact->>'parent_contact_id') IS NOT NULL
            THEN jsonb_build_array((v_contact->>'parent_contact_id')::uuid)
            ELSE '[]'::jsonb
        END;

        INSERT INTO t_contacts (
            id,
            tenant_id,
            type,
            status,
            salutation,
            name,
            company_name,
            designation,
            department,
            is_primary_contact,
            parent_contact_id,
            parent_contact_ids,
            classifications,
            tags,
            notes,
            is_live,
            is_seed
        ) VALUES (
            (v_contact->>'id')::uuid,
            p_tenant_id,
            v_contact->>'type',
            COALESCE(NULLIF(v_contact->>'status', ''), 'active'),
            NULLIF(v_contact->>'salutation', ''),
            NULLIF(v_contact->>'name', ''),
            NULLIF(v_contact->>'company_name', ''),
            NULLIF(v_contact->>'designation', ''),
            NULLIF(v_contact->>'department', ''),
            COALESCE((v_contact->>'is_primary_contact')::boolean, false),
            NULLIF(v_contact->>'parent_contact_id', '')::uuid,
            v_parent_ids,
            COALESCE((v_contact->'classifications')::jsonb, '[]'::jsonb),
            COALESCE((v_contact->'tags')::jsonb, '[]'::jsonb),
            NULLIF(v_contact->>'notes', ''),
            false,   -- is_live = false until tenant confirms
            true     -- is_seed = true for cleanup/reseed
        );

        v_seeded := v_seeded + 1;
    END LOOP;

    RETURN json_build_object('contactsSeeded', v_seeded, 'skipped', false);
END;
$$;

-- ============================================================================
-- GRANTS
-- ============================================================================

GRANT EXECUTE ON FUNCTION "public"."seed_sample_contacts"(UUID, JSONB)
    TO anon, authenticated, service_role;
