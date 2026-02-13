-- ============================================================================
-- P0.5a Migration 002: Create t_tenant_industry_segments table
-- ============================================================================
-- Purpose: Multi-select junction table for tenant → sub-segment associations
-- Replaces single industry_id on t_tenant_profiles for segment tracking
-- t_tenant_profiles.industry_id remains as-is (backward compatibility)
-- Depends on: 001_alter_industries_add_hierarchy.sql
-- ============================================================================

CREATE TABLE public.t_tenant_industry_segments (
  id UUID DEFAULT gen_random_uuid() NOT NULL,
  tenant_id UUID NOT NULL,
  industry_id VARCHAR(50) NOT NULL,
  is_primary BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  CONSTRAINT t_tenant_industry_segments_pkey PRIMARY KEY (id),
  CONSTRAINT t_tenant_industry_segments_tenant_fkey
    FOREIGN KEY (tenant_id) REFERENCES public.t_tenants(id) ON DELETE CASCADE,
  CONSTRAINT t_tenant_industry_segments_industry_fkey
    FOREIGN KEY (industry_id) REFERENCES public.m_catalog_industries(id) ON DELETE CASCADE,
  CONSTRAINT unique_tenant_industry UNIQUE (tenant_id, industry_id)
);

-- Indexes for common query patterns
CREATE INDEX idx_tenant_industry_segments_tenant
  ON public.t_tenant_industry_segments(tenant_id);
CREATE INDEX idx_tenant_industry_segments_industry
  ON public.t_tenant_industry_segments(industry_id);

-- Enable Row Level Security
ALTER TABLE public.t_tenant_industry_segments ENABLE ROW LEVEL SECURITY;

-- RLS: service_role bypass (matches t_catalog_resources pattern)
CREATE POLICY "service_role_access_t_tenant_industry_segments"
  ON public.t_tenant_industry_segments
  TO service_role
  USING (true) WITH CHECK (true);

-- RLS: SELECT — any authenticated tenant member can read
CREATE POLICY "tenant_industry_segments_select"
  ON public.t_tenant_industry_segments
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
  );

-- RLS: INSERT — Owner or Admin only
CREATE POLICY "tenant_industry_segments_insert"
  ON public.t_tenant_industry_segments
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

-- RLS: UPDATE — Owner or Admin only
CREATE POLICY "tenant_industry_segments_update"
  ON public.t_tenant_industry_segments
  FOR UPDATE TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

-- RLS: DELETE — Owner or Admin only
CREATE POLICY "tenant_industry_segments_delete"
  ON public.t_tenant_industry_segments
  FOR DELETE TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

-- Grant access (match existing table patterns)
GRANT ALL ON TABLE public.t_tenant_industry_segments TO authenticated;
GRANT ALL ON TABLE public.t_tenant_industry_segments TO service_role;


-- ============================================================================
-- ROLLBACK (commented out — run manually if needed)
-- ============================================================================
-- DROP TABLE IF EXISTS public.t_tenant_industry_segments;
