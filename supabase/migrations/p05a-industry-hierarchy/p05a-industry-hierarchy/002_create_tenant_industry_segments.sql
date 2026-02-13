-- ============================================================================
-- P0.5a Migration 002: Create t_tenant_industry_segments table
-- ============================================================================
-- IDEMPOTENT: Safe to run multiple times. Uses IF NOT EXISTS for table + DO blocks.
-- Purpose: Multi-select junction table for tenant → sub-segment associations
-- t_tenant_profiles.industry_id remains as-is (backward compatibility)
-- Depends on: 001_alter_industries_add_hierarchy.sql
-- ============================================================================

-- Create table (IF NOT EXISTS)
CREATE TABLE IF NOT EXISTS public.t_tenant_industry_segments (
  id UUID DEFAULT gen_random_uuid() NOT NULL,
  tenant_id UUID NOT NULL,
  industry_id VARCHAR(50) NOT NULL,
  is_primary BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),

  CONSTRAINT t_tenant_industry_segments_pkey PRIMARY KEY (id)
);

-- Add FK to t_tenants (skip if exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 't_tenant_industry_segments_tenant_fkey'
  ) THEN
    ALTER TABLE public.t_tenant_industry_segments
      ADD CONSTRAINT t_tenant_industry_segments_tenant_fkey
      FOREIGN KEY (tenant_id) REFERENCES public.t_tenants(id) ON DELETE CASCADE;
    RAISE NOTICE 'Added FK: t_tenant_industry_segments_tenant_fkey';
  ELSE
    RAISE NOTICE 'FK t_tenant_industry_segments_tenant_fkey already exists — skipping';
  END IF;
END $$;

-- Add FK to m_catalog_industries (skip if exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 't_tenant_industry_segments_industry_fkey'
  ) THEN
    ALTER TABLE public.t_tenant_industry_segments
      ADD CONSTRAINT t_tenant_industry_segments_industry_fkey
      FOREIGN KEY (industry_id) REFERENCES public.m_catalog_industries(id) ON DELETE CASCADE;
    RAISE NOTICE 'Added FK: t_tenant_industry_segments_industry_fkey';
  ELSE
    RAISE NOTICE 'FK t_tenant_industry_segments_industry_fkey already exists — skipping';
  END IF;
END $$;

-- Add unique constraint (skip if exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'unique_tenant_industry'
  ) THEN
    ALTER TABLE public.t_tenant_industry_segments
      ADD CONSTRAINT unique_tenant_industry UNIQUE (tenant_id, industry_id);
    RAISE NOTICE 'Added unique constraint: unique_tenant_industry';
  ELSE
    RAISE NOTICE 'Unique constraint unique_tenant_industry already exists — skipping';
  END IF;
END $$;

-- Indexes (IF NOT EXISTS via DO blocks)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_tenant_industry_segments_tenant'
  ) THEN
    CREATE INDEX idx_tenant_industry_segments_tenant
      ON public.t_tenant_industry_segments(tenant_id);
    RAISE NOTICE 'Created index: idx_tenant_industry_segments_tenant';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes WHERE indexname = 'idx_tenant_industry_segments_industry'
  ) THEN
    CREATE INDEX idx_tenant_industry_segments_industry
      ON public.t_tenant_industry_segments(industry_id);
    RAISE NOTICE 'Created index: idx_tenant_industry_segments_industry';
  END IF;
END $$;

-- Enable RLS (safe to run multiple times)
ALTER TABLE public.t_tenant_industry_segments ENABLE ROW LEVEL SECURITY;

-- RLS Policies (DROP IF EXISTS + CREATE to ensure correct definition)
DROP POLICY IF EXISTS "service_role_access_t_tenant_industry_segments" ON public.t_tenant_industry_segments;
CREATE POLICY "service_role_access_t_tenant_industry_segments"
  ON public.t_tenant_industry_segments
  TO service_role
  USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "tenant_industry_segments_select" ON public.t_tenant_industry_segments;
CREATE POLICY "tenant_industry_segments_select"
  ON public.t_tenant_industry_segments
  FOR SELECT TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
  );

DROP POLICY IF EXISTS "tenant_industry_segments_insert" ON public.t_tenant_industry_segments;
CREATE POLICY "tenant_industry_segments_insert"
  ON public.t_tenant_industry_segments
  FOR INSERT TO authenticated
  WITH CHECK (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

DROP POLICY IF EXISTS "tenant_industry_segments_update" ON public.t_tenant_industry_segments;
CREATE POLICY "tenant_industry_segments_update"
  ON public.t_tenant_industry_segments
  FOR UPDATE TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

DROP POLICY IF EXISTS "tenant_industry_segments_delete" ON public.t_tenant_industry_segments;
CREATE POLICY "tenant_industry_segments_delete"
  ON public.t_tenant_industry_segments
  FOR DELETE TO authenticated
  USING (
    tenant_id = public.get_current_tenant_id()
    AND public.has_tenant_access(tenant_id)
    AND public.has_tenant_role(tenant_id, ARRAY['Owner'::text, 'Admin'::text])
  );

-- Grants (safe to run multiple times)
GRANT ALL ON TABLE public.t_tenant_industry_segments TO authenticated;
GRANT ALL ON TABLE public.t_tenant_industry_segments TO service_role;


-- ============================================================================
-- ROLLBACK (commented out — run manually if needed)
-- ============================================================================
-- DROP TABLE IF EXISTS public.t_tenant_industry_segments;
