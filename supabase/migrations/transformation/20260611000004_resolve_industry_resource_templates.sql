-- Sprint 1 / Task 2 — Single shared industry → resource-template resolution
-- (probe break-point B0.5 point 2: tenants select leaf segments, templates are
-- tagged at parent level; m_catalog_industries.parent_id existed in data and
-- was walked by no shared code — only a one-level walk buried in the resources
-- edge function.)
--
-- This function is THE one place industry coverage is resolved. Implemented as
-- a recursive CTE (full ancestor chain, not one level) so a template tagged at
-- any ancestor of the tenant's segment is found. Resolution set =
--   templates tagged on the industry itself
-- ∪ templates tagged on any ancestor (parent_id walk)
-- ∪ templates linked via m_catalog_resource_template_industries (self or ancestor)
-- ∪ universal templates (industry_id IS NULL and no junction rows)
--
-- This is the embryo of vw_kt_service_definitions (legibility report §4.1) and
-- is named for reuse: API seeder, resources edge browse, and future agents all
-- resolve through here.

CREATE OR REPLACE FUNCTION resolve_industry_resource_templates(p_industry_ids text[])
RETURNS TABLE (
  resource_template_id uuid,
  template_name        text,
  resource_type_id     varchar,
  matched_industry_id  varchar,
  via                  text
)
LANGUAGE sql
STABLE
AS $$
WITH RECURSIVE industry_chain AS (
  -- the selected industries themselves
  SELECT i.id, i.parent_id, 0 AS depth
  FROM m_catalog_industries i
  WHERE i.id = ANY (p_industry_ids)
  UNION
  -- walk up the full ancestor chain
  SELECT p.id, p.parent_id, c.depth + 1
  FROM m_catalog_industries p
  JOIN industry_chain c ON c.parent_id = p.id
  WHERE c.depth < 10  -- cycle guard
),
resolved AS (
  -- direct + ancestor tagging on the template row
  SELECT rt.id, rt.name, rt.resource_type_id, rt.industry_id AS matched, 'tagged' AS via
  FROM m_catalog_resource_templates rt
  JOIN industry_chain ic ON ic.id = rt.industry_id
  WHERE rt.is_active = true

  UNION

  -- junction-table links (self or ancestor)
  SELECT rt.id, rt.name, rt.resource_type_id, j.industry_id AS matched, 'junction' AS via
  FROM m_catalog_resource_template_industries j
  JOIN m_catalog_resource_templates rt ON rt.id = j.template_id
  JOIN industry_chain ic ON ic.id = j.industry_id
  WHERE rt.is_active = true

  UNION

  -- universal templates: tagged nowhere at all
  SELECT rt.id, rt.name, rt.resource_type_id, NULL AS matched, 'universal' AS via
  FROM m_catalog_resource_templates rt
  WHERE rt.is_active = true
    AND rt.industry_id IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM m_catalog_resource_template_industries j2
      WHERE j2.template_id = rt.id
    )
)
SELECT DISTINCT ON (resolved.id)
  resolved.id, resolved.name, resolved.resource_type_id, resolved.matched, resolved.via
FROM resolved
ORDER BY resolved.id, resolved.via;
$$;

COMMENT ON FUNCTION resolve_industry_resource_templates(text[]) IS
  'Sprint 1 Task 2: canonical industry→resource-template resolution. Walks the m_catalog_industries.parent_id hierarchy (recursive CTE) plus junction + universal templates. Used by the onboarding seeder to validate coverage (zero rows ⇒ no_coverage, never silent success) and intended for every future caller that needs "what templates apply to industry X".';

GRANT EXECUTE ON FUNCTION resolve_industry_resource_templates(text[]) TO authenticated, service_role, anon;
