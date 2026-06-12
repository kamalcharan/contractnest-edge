-- Sprint 1 follow-up — Settings → Seed Data (founder request)
-- UI-managed seed lifecycle: see what onboarding seeded, wipe it safely, and
-- re-run the seed from the persisted intent (t_tenant_selected_resources) —
-- the whole point of S8 is that a reseed never needs the onboarding flow again.
--
-- Both functions are SECURITY DEFINER, callable from the API layer with the
-- anon key + user JWT (the established seed_onboarding_* pattern).

-- ── Overview: everything seed-related for one tenant, one call ───────────────
CREATE OR REPLACE FUNCTION get_tenant_seed_overview(p_tenant_id uuid)
RETURNS json
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
SELECT json_build_object(
  'catalog', json_build_object(
    'test',  (SELECT count(*) FROM m_cat_blocks WHERE tenant_id = p_tenant_id AND is_seed AND NOT is_live),
    'live',  (SELECT count(*) FROM m_cat_blocks WHERE tenant_id = p_tenant_id AND is_seed AND is_live),
    'in_use', (SELECT count(DISTINCT b.id) FROM m_cat_blocks b
               JOIN t_contract_blocks cb ON cb.source_block_id = b.id
               WHERE b.tenant_id = p_tenant_id AND b.is_seed)
  ),
  'registry', json_build_object(
    'total', (SELECT count(*) FROM t_client_asset_registry
              WHERE tenant_id = p_tenant_id AND ownership_type = 'self'
                AND specifications->>'seeded_from' = 'onboarding'),
    'live',  (SELECT count(*) FROM t_client_asset_registry
              WHERE tenant_id = p_tenant_id AND ownership_type = 'self'
                AND specifications->>'seeded_from' = 'onboarding' AND is_live),
    'in_use', (SELECT count(DISTINCT a.id) FROM t_client_asset_registry a
               JOIN t_contract_assets ca ON ca.asset_id = a.id
               WHERE a.tenant_id = p_tenant_id
                 AND a.specifications->>'seeded_from' = 'onboarding')
  ),
  'picks', (SELECT coalesce(json_agg(json_build_object(
              'resource_template_id', sr.resource_template_id,
              'template_name', rt.name,
              'resource_type', rt.resource_type_id,
              'purpose', sr.purpose,
              'selected_at', sr.selected_at)), '[]'::json)
            FROM t_tenant_selected_resources sr
            JOIN m_catalog_resource_templates rt ON rt.id = sr.resource_template_id
            WHERE sr.tenant_id = p_tenant_id),
  'last_seed_logs', (SELECT coalesce(json_agg(l ORDER BY l.created_at DESC), '[]'::json)
                     FROM (SELECT kt_name, status, blocks_created, skip_reason,
                                  error_message, is_live, created_at
                           FROM t_seed_logs WHERE tenant_id = p_tenant_id
                           ORDER BY created_at DESC LIMIT 10) l)
);
$$;

COMMENT ON FUNCTION get_tenant_seed_overview(uuid) IS
  'Settings → Seed Data overview: seeded catalog/registry counts (incl. contract-referenced rows that a reseed must keep), persisted resource picks, recent seed logs.';

-- ── Cleanup: hard-delete seeded rows so the idempotent seed can re-run ───────
-- Safety: rows referenced by contracts are SKIPPED, never deleted.
CREATE OR REPLACE FUNCTION cleanup_tenant_seed_data(
  p_tenant_id uuid,
  p_target    text  -- 'catalog' | 'registry' | 'all'
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_blocks_deleted  integer := 0;
  v_blocks_kept     integer := 0;
  v_assets_deleted  integer := 0;
  v_assets_kept     integer := 0;
BEGIN
  IF p_tenant_id IS NULL OR p_target NOT IN ('catalog', 'registry', 'all') THEN
    RAISE EXCEPTION 'cleanup_tenant_seed_data: invalid arguments';
  END IF;

  IF p_target IN ('catalog', 'all') THEN
    SELECT count(*) INTO v_blocks_kept
    FROM m_cat_blocks b
    WHERE b.tenant_id = p_tenant_id AND b.is_seed
      AND EXISTS (SELECT 1 FROM t_contract_blocks cb WHERE cb.source_block_id = b.id);

    DELETE FROM m_cat_blocks b
    WHERE b.tenant_id = p_tenant_id AND b.is_seed
      AND NOT EXISTS (SELECT 1 FROM t_contract_blocks cb WHERE cb.source_block_id = b.id);
    GET DIAGNOSTICS v_blocks_deleted = ROW_COUNT;
  END IF;

  IF p_target IN ('registry', 'all') THEN
    SELECT count(*) INTO v_assets_kept
    FROM t_client_asset_registry a
    WHERE a.tenant_id = p_tenant_id
      AND a.specifications->>'seeded_from' = 'onboarding'
      AND EXISTS (SELECT 1 FROM t_contract_assets ca WHERE ca.asset_id = a.id);

    DELETE FROM t_client_asset_registry a
    WHERE a.tenant_id = p_tenant_id
      AND a.specifications->>'seeded_from' = 'onboarding'
      AND NOT EXISTS (SELECT 1 FROM t_contract_assets ca WHERE ca.asset_id = a.id);
    GET DIAGNOSTICS v_assets_deleted = ROW_COUNT;
  END IF;

  RETURN json_build_object(
    'blocksDeleted', v_blocks_deleted,
    'blocksKeptInUse', v_blocks_kept,
    'assetsDeleted', v_assets_deleted,
    'assetsKeptInUse', v_assets_kept
  );
END;
$$;

COMMENT ON FUNCTION cleanup_tenant_seed_data(uuid, text) IS
  'Settings → Seed Data: removes onboarding-seeded catalog blocks / registry assets so the idempotent seed can re-run from t_tenant_selected_resources. Rows referenced by contracts (source_block_id / t_contract_assets) are kept and reported.';
