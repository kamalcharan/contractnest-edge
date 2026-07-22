-- ============================================================================
-- Migration: bbb-foundation/045 — Contact list: real search + honest paging
-- ============================================================================
-- Problems fixed (verified live 2026-07-22):
--   1. p_search only matched name/company_name. Typing a phone number, email,
--      or CT number returned 0 rows ("search won't work"). Now also matches:
--        * c.contact_number (CT-xxxx)
--        * any t_contact_channels.value (email/phone/whatsapp/...), including
--          a digits-only comparison so "+91 98906 04059", "9890604059" and
--          "98906" all find the same contact regardless of stored formatting.
--   2. Child contacts (parent_contact_id IS NOT NULL — persons linked to a
--      corporate) were counted and paged by the server but hidden client-side,
--      so a "page of 20" could render fewer rows and totals lied. They are now
--      excluded server-side; the parent corporate remains the list entry.
--   3. Row payload now includes contact_number and parent_contact_id (the
--      list previously had no CT number to show; the edge function spreads
--      the row so no edge redeploy is needed).
--
-- Same signature, same response shape — callers unchanged.
-- Perf note: the channel search is a correlated EXISTS with ILIKE; if tenants
-- grow to tens of thousands of channels, add
--   CREATE INDEX idx_contact_channels_value_trgm ON t_contact_channels
--     USING gin (value gin_trgm_ops);
--
-- Depends on: sequence-numbers/003 (contact_number), contact-view phases
-- Safe to re-run: Yes (CREATE OR REPLACE)
-- Applied live: 2026-07-22 — project uwyqhzotluikawcboldr
-- ============================================================================

CREATE OR REPLACE FUNCTION public.list_contacts_with_channels_v2(
  p_tenant_id uuid,
  p_is_live boolean DEFAULT true,
  p_page integer DEFAULT 1,
  p_limit integer DEFAULT 20,
  p_type text DEFAULT NULL::text,
  p_status text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_classifications text[] DEFAULT NULL::text[],
  p_user_status text DEFAULT NULL::text,
  p_show_duplicates boolean DEFAULT false,
  p_include_inactive boolean DEFAULT false,
  p_include_archived boolean DEFAULT false,
  p_sort_by text DEFAULT 'created_at'::text,
  p_sort_order text DEFAULT 'desc'::text,
  p_tags text[] DEFAULT NULL::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_offset INTEGER;
  v_total INTEGER;
  v_contacts JSONB;
  v_result JSONB;
  v_search_digits TEXT;
BEGIN
  v_offset := (p_page - 1) * p_limit;
  -- Digits-only form of the search term for format-agnostic phone matching;
  -- require >= 4 digits so a stray digit in a name search doesn't over-match.
  v_search_digits := NULLIF(regexp_replace(COALESCE(p_search, ''), '\D', '', 'g'), '');
  IF v_search_digits IS NOT NULL AND length(v_search_digits) < 4 THEN
    v_search_digits := NULL;
  END IF;

  SELECT COUNT(*)
  INTO v_total
  FROM t_contacts c
  WHERE c.tenant_id = p_tenant_id
    AND c.is_live = p_is_live
    AND c.parent_contact_id IS NULL
    AND (p_type IS NULL OR c.type = p_type)
    AND (
      p_status IS NULL
      OR c.status = p_status
      OR (p_include_inactive AND c.status = 'inactive')
      OR (p_include_archived AND c.status = 'archived')
    )
    AND (
      p_search IS NULL
      OR c.name ILIKE '%' || p_search || '%'
      OR c.company_name ILIKE '%' || p_search || '%'
      OR c.contact_number ILIKE '%' || p_search || '%'
      OR EXISTS (
        SELECT 1 FROM t_contact_channels ch
        WHERE ch.contact_id = c.id
          AND (
            ch.value ILIKE '%' || p_search || '%'
            OR (
              v_search_digits IS NOT NULL
              AND regexp_replace(ch.value, '\D', '', 'g') LIKE '%' || v_search_digits || '%'
            )
          )
      )
    )
    AND (
      p_classifications IS NULL
      OR c.classifications ?| p_classifications
    )
    AND (
      p_tags IS NULL
      OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(c.tags, '[]'::jsonb)) AS tg
        WHERE lower(tg->>'tag_value') IN (SELECT lower(unnest_tag) FROM unnest(p_tags) AS unnest_tag)
      )
    );

  SELECT COALESCE(jsonb_agg(contact_row), '[]'::jsonb)
  INTO v_contacts
  FROM (
    SELECT jsonb_build_object(
      'id', c.id,
      'type', c.type,
      'status', c.status,
      'name', c.name,
      'company_name', c.company_name,
      'contact_number', c.contact_number,
      'parent_contact_id', c.parent_contact_id,
      'displayName', CASE
        WHEN c.type = 'individual' AND c.salutation IS NOT NULL AND c.salutation != ''
        THEN c.salutation || ' ' || c.name
        ELSE COALESCE(c.name, c.company_name)
      END,
      'salutation', c.salutation,
      'designation', c.designation,
      'department', c.department,
      'classifications', c.classifications,
      'tags', c.tags,
      'notes', c.notes,
      'tenant_id', c.tenant_id,
      'auth_user_id', c.auth_user_id,
      'created_at', c.created_at,
      'updated_at', c.updated_at,
      'is_live', c.is_live,
      'primary_channel', (
        SELECT jsonb_build_object(
          'id', ch.id,
          'channel_type', ch.channel_type,
          'value', ch.value,
          'is_primary', ch.is_primary
        )
        FROM t_contact_channels ch
        WHERE ch.contact_id = c.id AND ch.is_primary = true
        LIMIT 1
      ),
      'primary_address', (
        SELECT jsonb_build_object(
          'id', a.id,
          'type', a.type,
          'address_line1', a.address_line1,
          'city', a.city,
          'state_code', a.state_code,
          'country_code', a.country_code,
          'is_primary', a.is_primary
        )
        FROM t_contact_addresses a
        WHERE a.contact_id = c.id AND a.is_primary = true
        LIMIT 1
      )
    ) AS contact_row
    FROM t_contacts c
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.parent_contact_id IS NULL
      AND (p_type IS NULL OR c.type = p_type)
      AND (
        p_status IS NULL
        OR c.status = p_status
        OR (p_include_inactive AND c.status = 'inactive')
        OR (p_include_archived AND c.status = 'archived')
      )
      AND (
        p_search IS NULL
        OR c.name ILIKE '%' || p_search || '%'
        OR c.company_name ILIKE '%' || p_search || '%'
        OR c.contact_number ILIKE '%' || p_search || '%'
        OR EXISTS (
          SELECT 1 FROM t_contact_channels ch
          WHERE ch.contact_id = c.id
            AND (
              ch.value ILIKE '%' || p_search || '%'
              OR (
                v_search_digits IS NOT NULL
                AND regexp_replace(ch.value, '\D', '', 'g') LIKE '%' || v_search_digits || '%'
              )
            )
        )
      )
      AND (
        p_classifications IS NULL
        OR c.classifications ?| p_classifications
      )
      AND (
        p_tags IS NULL
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements(COALESCE(c.tags, '[]'::jsonb)) AS tg
          WHERE lower(tg->>'tag_value') IN (SELECT lower(unnest_tag) FROM unnest(p_tags) AS unnest_tag)
        )
      )
    ORDER BY
      CASE
        WHEN p_sort_by = 'name' THEN
          CASE WHEN p_sort_order = 'asc' THEN 1 ELSE -1 END *
          (CASE WHEN COALESCE(c.name, c.company_name) IS NULL THEN 1 ELSE 0 END)
        ELSE 0
      END,
      CASE WHEN p_sort_by = 'name' AND p_sort_order = 'asc' THEN LOWER(COALESCE(c.name, c.company_name)) END ASC NULLS LAST,
      CASE WHEN p_sort_by = 'name' AND p_sort_order = 'desc' THEN LOWER(COALESCE(c.name, c.company_name)) END DESC NULLS LAST,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'asc' THEN c.created_at END ASC NULLS LAST,
      CASE WHEN p_sort_by = 'created_at' AND p_sort_order = 'desc' THEN c.created_at END DESC NULLS LAST,
      CASE WHEN p_sort_by = 'updated_at' AND p_sort_order = 'asc' THEN c.updated_at END ASC NULLS LAST,
      CASE WHEN p_sort_by = 'updated_at' AND p_sort_order = 'desc' THEN c.updated_at END DESC NULLS LAST,
      c.created_at DESC NULLS LAST
    LIMIT p_limit
    OFFSET v_offset
  ) AS ordered_contacts;

  v_result := jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'contacts', v_contacts,
      'pagination', jsonb_build_object(
        'page', p_page,
        'limit', p_limit,
        'total', v_total,
        'totalPages', CEIL(v_total::FLOAT / p_limit)
      )
    )
  );

  RETURN v_result;

EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object(
    'success', false,
    'error', SQLERRM,
    'code', SQLSTATE
  );
END;
$function$;
