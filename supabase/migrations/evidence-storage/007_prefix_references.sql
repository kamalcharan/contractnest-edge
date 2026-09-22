-- evidence-storage/007_prefix_references.sql
--
-- ⚠️ ALREADY APPLIED LIVE (2026-09-22). Source-of-record copy — DO NOT RE-RUN.
--
-- Which storage prefixes LIVE data still points at, and what points at them.
--
-- ⚠️ THE BUG THIS FIXES: the storage admin screen classified a prefix as a
-- deletable legacy folder on SHAPE alone (/^tenant_/). Two shared asset
-- folders match that shape and are very much alive:
--
--     tenant_logos                 stw and vikuna tenant logos
--     tenant_integration_assets    BBB's live payment QR
--
-- So the screen offered a Delete button on BBB's production payment QR — the
-- same asset that has already been wiped twice by an unrelated bug. Two of the
-- per-tenant folders are also still referenced (a user avatar, six stored
-- files), so shape alone is wrong in four of six cases.
--
-- Deletability is now decided by REFERENCES, not by name.
--
-- A Firebase download URL encodes the object path after /o/ with %2F
-- separators, so the first segment is the top-level prefix.

CREATE OR REPLACE FUNCTION public.storage_prefix_references()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $body$
WITH refs AS (
    SELECT 'tenant logo'::text AS kind, t.name AS label, p.logo_url AS url
      FROM t_tenant_profiles p JOIN t_tenants t ON t.id = p.tenant_id
     WHERE p.logo_url LIKE '%firebasestorage%'
    UNION ALL
    SELECT 'payment QR', COALESCE(t.name, i.tenant_id),
           (regexp_matches(i.credentials::text, '(https://firebasestorage[^"]+)'))[1]
      FROM t_tenant_integrations i LEFT JOIN t_tenants t ON t.id::text = i.tenant_id
     WHERE i.credentials::text LIKE '%firebasestorage%'
    UNION ALL
    SELECT 'user avatar',
           COALESCE(NULLIF(trim(concat_ws(' ', u.first_name, u.last_name)), ''), u.email, 'a user'),
           u.avatar_url
      FROM t_user_profiles u WHERE u.avatar_url LIKE '%firebasestorage%'
    UNION ALL
    SELECT 'stored file', f.file_name, f.download_url
      FROM t_tenant_files f WHERE f.download_url LIKE '%firebasestorage%'
    UNION ALL
    SELECT 'service evidence', e.file_name, e.file_url
      FROM t_service_evidence e WHERE e.file_url LIKE '%firebasestorage%'
),
parsed AS (
    SELECT kind, label,
           split_part(replace(split_part(split_part(url, '/o/', 2), '?', 1), '%2F', '/'), '/', 1) AS prefix
      FROM refs WHERE url IS NOT NULL
)
SELECT COALESCE(jsonb_object_agg(prefix, entries), '{}'::jsonb) FROM (
    SELECT prefix, jsonb_agg(DISTINCT jsonb_build_object('kind', kind, 'label', label)) AS entries
      FROM parsed WHERE prefix <> '' GROUP BY prefix
) s;
$body$;

GRANT EXECUTE ON FUNCTION public.storage_prefix_references() TO authenticated, service_role;
