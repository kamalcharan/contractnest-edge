-- Sprint 1 / S8 — Persist tenant resource selections (probe finding B0.2: "R is unrecoverable")
-- ResourcePickStep selections previously lived only in React state and died on
-- navigation. This table is the durable record of tenant intent; the onboarding
-- seeder reads it (intersected with industry resolution) so intent drives the seed.
--
-- purpose column (founder-approved deviation from the original S8 shape):
-- a 'both'-persona tenant can legitimately pick the SAME template twice —
-- as equipment they SERVICE ('sell' → catalog blocks) and as equipment they
-- OWN ('own' → asset registry). Unique key therefore includes purpose.

CREATE TABLE IF NOT EXISTS t_tenant_selected_resources (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id            uuid NOT NULL REFERENCES t_tenants(id) ON DELETE CASCADE,
  resource_template_id uuid NOT NULL REFERENCES m_catalog_resource_templates(id),
  purpose              text NOT NULL CHECK (purpose IN ('sell', 'own')),
  source               text NOT NULL DEFAULT 'onboarding' CHECK (source IN ('onboarding', 'settings', 'agent')),
  selected_at          timestamptz NOT NULL DEFAULT now(),
  created_by           uuid,
  UNIQUE (tenant_id, resource_template_id, purpose)
);

COMMENT ON TABLE t_tenant_selected_resources IS
  'Durable record of which resource templates a tenant selected and why (S8, Sprint 1). purpose=sell → seeds m_cat_blocks via the KT mapper (seller catalog); purpose=own → seeds t_client_asset_registry (buyer equipment/facility registries). Written by ResourcePickStep at onboarding; read by seedTenantTemplatesService.';
COMMENT ON COLUMN t_tenant_selected_resources.purpose IS
  'sell = tenant services this resource type (catalog seed); own = tenant owns instances of it (registry seed). A both-persona tenant may hold one row per purpose for the same template.';
COMMENT ON COLUMN t_tenant_selected_resources.source IS
  'Where the selection was made: onboarding flow, settings UI, or an agent acting for the tenant.';

CREATE INDEX IF NOT EXISTS idx_tenant_selected_resources_tenant
  ON t_tenant_selected_resources (tenant_id);

-- RLS: same mechanism as neighbouring tenant tables (t_tenant_served_industries pattern)
ALTER TABLE t_tenant_selected_resources ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_read_selected_resources ON t_tenant_selected_resources
  FOR SELECT USING (
    tenant_id IN (
      SELECT ut.tenant_id FROM t_user_tenants ut
      WHERE ut.user_id = auth.uid() AND ut.status::text = 'active'
    )
  );

CREATE POLICY tenant_insert_selected_resources ON t_tenant_selected_resources
  FOR INSERT WITH CHECK (
    tenant_id IN (
      SELECT ut.tenant_id FROM t_user_tenants ut
      WHERE ut.user_id = auth.uid() AND ut.status::text = 'active'
    )
  );

CREATE POLICY tenant_delete_selected_resources ON t_tenant_selected_resources
  FOR DELETE USING (
    tenant_id IN (
      SELECT ut.tenant_id FROM t_user_tenants ut
      WHERE ut.user_id = auth.uid() AND ut.status::text = 'active'
    )
  );

-- Follow-up (applied 2026-06-11): upsert ON CONFLICT takes the UPDATE path;
-- without an UPDATE policy, authenticated retries were RLS-denied.
CREATE POLICY tenant_update_selected_resources ON t_tenant_selected_resources
  FOR UPDATE USING (
    tenant_id IN (
      SELECT ut.tenant_id FROM t_user_tenants ut
      WHERE ut.user_id = auth.uid() AND ut.status::text = 'active'
    )
  );
