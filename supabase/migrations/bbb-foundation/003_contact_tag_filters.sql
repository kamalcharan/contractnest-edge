-- ============================================================
-- BBB FOUNDATION 003 — Contact tag filters + correct classification counts
-- 1. get_contact_stats: adds `client` to by_classification (the UI's live
--    classification set is client/vendor/partner/team_member but the RPC
--    only counted legacy buyer/seller/customer), adds a `by_tag` count map,
--    and accepts p_tags for filtered stats.
-- 2. list_contacts_with_channels_v2 (the 14-param overload the edge calls):
--    adds p_tags — matches contacts carrying ANY of the given tag values
--    (case-insensitive on tags[].tag_value).
-- Both functions are dropped first (adding a defaulted param via CREATE OR
-- REPLACE would create an ambiguous overload for named-argument RPC calls).
-- ============================================================

-- 1. get_contact_stats ----------------------------------------------
DROP FUNCTION IF EXISTS public.get_contact_stats(uuid, boolean, text, text, text[]);

CREATE FUNCTION public.get_contact_stats(
  p_tenant_id uuid,
  p_is_live boolean DEFAULT true,
  p_type text DEFAULT NULL::text,
  p_search text DEFAULT NULL::text,
  p_classifications text[] DEFAULT NULL::text[],
  p_tags text[] DEFAULT NULL::text[]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_counts record;
  v_by_tag jsonb;
BEGIN
  SELECT
    COUNT(*) AS total,
    COUNT(*) FILTER (WHERE status = 'active') AS active,
    COUNT(*) FILTER (WHERE status = 'inactive') AS inactive,
    COUNT(*) FILTER (WHERE status = 'archived') AS archived,
    COUNT(*) FILTER (WHERE type = 'individual') AS individual,
    COUNT(*) FILTER (WHERE type = 'corporate') AS corporate,
    COUNT(*) FILTER (WHERE potential_duplicate = true) AS duplicates,
    COUNT(*) FILTER (WHERE classifications ? 'client') AS client,
    COUNT(*) FILTER (WHERE classifications ? 'buyer') AS buyer,
    COUNT(*) FILTER (WHERE classifications ? 'seller') AS seller,
    COUNT(*) FILTER (WHERE classifications ? 'vendor') AS vendor,
    COUNT(*) FILTER (WHERE classifications ? 'partner') AS partner,
    COUNT(*) FILTER (WHERE classifications ? 'team_member') AS team_member,
    COUNT(*) FILTER (WHERE classifications ? 'team_staff') AS team_staff,
    COUNT(*) FILTER (WHERE classifications ? 'supplier') AS supplier,
    COUNT(*) FILTER (WHERE classifications ? 'customer') AS customer,
    COUNT(*) FILTER (WHERE classifications ? 'lead') AS lead
  INTO v_counts
  FROM t_contacts
  WHERE
    tenant_id = p_tenant_id
    AND is_live = p_is_live
    AND (p_type IS NULL OR type = p_type)
    AND (
      p_search IS NULL
      OR name ILIKE '%' || p_search || '%'
      OR company_name ILIKE '%' || p_search || '%'
    )
    AND (
      p_classifications IS NULL
      OR classifications ?| p_classifications
    )
    AND (
      p_tags IS NULL
      OR EXISTS (
        SELECT 1 FROM jsonb_array_elements(COALESCE(tags, '[]'::jsonb)) AS tg
        WHERE lower(tg->>'tag_value') IN (SELECT lower(unnest_tag) FROM unnest(p_tags) AS unnest_tag)
      )
    );

  -- Per-tag counts over the same population EXCEPT the tag filter itself,
  -- so tag chips keep their counts while one of them is selected.
  SELECT COALESCE(jsonb_object_agg(tag_value, cnt), '{}'::jsonb)
  INTO v_by_tag
  FROM (
    SELECT tg->>'tag_value' AS tag_value, COUNT(DISTINCT c.id) AS cnt
    FROM t_contacts c
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(c.tags, '[]'::jsonb)) AS tg
    WHERE c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND (p_type IS NULL OR c.type = p_type)
      AND (
        p_search IS NULL
        OR c.name ILIKE '%' || p_search || '%'
        OR c.company_name ILIKE '%' || p_search || '%'
      )
      AND (
        p_classifications IS NULL
        OR c.classifications ?| p_classifications
      )
      AND (tg->>'tag_value') IS NOT NULL
    GROUP BY tg->>'tag_value'
  ) tag_counts;

  RETURN jsonb_build_object(
    'success', true,
    'data', jsonb_build_object(
      'total', v_counts.total,
      'active', v_counts.active,
      'inactive', v_counts.inactive,
      'archived', v_counts.archived,
      'by_type', jsonb_build_object(
        'individual', v_counts.individual,
        'corporate', v_counts.corporate
      ),
      'by_classification', jsonb_build_object(
        'client', v_counts.client,
        'buyer', v_counts.buyer,
        'seller', v_counts.seller,
        'vendor', v_counts.vendor,
        'partner', v_counts.partner,
        'team_member', v_counts.team_member,
        'team_staff', v_counts.team_staff,
        'supplier', v_counts.supplier,
        'customer', v_counts.customer,
        'lead', v_counts.lead
      ),
      'by_tag', v_by_tag,
      'duplicates', v_counts.duplicates
    )
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', SQLERRM,
      'code', SQLSTATE
    );
END;
$function$;

-- 2. list_contacts_with_channels_v2 (14-param overload) --------------
DROP FUNCTION IF EXISTS public.list_contacts_with_channels_v2(
  uuid, boolean, integer, integer, text, text, text, text[], text, boolean, boolean, boolean, text, text
);

CREATE FUNCTION public.list_contacts_with_channels_v2(
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
BEGIN
  -- Calculate offset
  v_offset := (p_page - 1) * p_limit;

  -- Get total count first
  SELECT COUNT(*)
  INTO v_total
  FROM t_contacts c
  WHERE c.tenant_id = p_tenant_id
    AND c.is_live = p_is_live
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

  -- Get contacts with sorting applied via subquery
  SELECT COALESCE(jsonb_agg(contact_row), '[]'::jsonb)
  INTO v_contacts
  FROM (
    SELECT jsonb_build_object(
      'id', c.id,
      'type', c.type,
      'status', c.status,
      'name', c.name,
      'company_name', c.company_name,
      -- FIX: Include salutation in displayName for individuals
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
    -- FIX: Simpler sorting logic
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

  -- Build result
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

-- 3. Privileges — service-role-only (018 posture) --------------------
REVOKE EXECUTE ON FUNCTION public.get_contact_stats(uuid, boolean, text, text, text[], text[]) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.list_contacts_with_channels_v2(uuid, boolean, integer, integer, text, text, text, text[], text, boolean, boolean, boolean, text, text, text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_contact_stats(uuid, boolean, text, text, text[], text[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.list_contacts_with_channels_v2(uuid, boolean, integer, integer, text, text, text, text[], text, boolean, boolean, boolean, text, text, text[]) TO service_role;
