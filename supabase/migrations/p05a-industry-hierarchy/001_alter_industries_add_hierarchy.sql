-- ============================================================================
-- P0.5a Migration 001: Add hierarchy columns to m_catalog_industries
-- ============================================================================
-- Purpose: Transform flat industry list into 2-level parent→sub-segment hierarchy
-- Adds: parent_id (self-referencing FK), level (0=parent, 1=sub), segment_type
-- Depends on: m_catalog_industries table (existing)
-- ============================================================================

-- Add parent_id: self-referencing FK for parent→child hierarchy
ALTER TABLE public.m_catalog_industries
  ADD COLUMN parent_id VARCHAR(50) NULL;

-- Add level: 0 = parent segment, 1 = sub-segment
ALTER TABLE public.m_catalog_industries
  ADD COLUMN level INTEGER NOT NULL DEFAULT 0;

-- Add segment_type: human-readable discriminator ('segment' or 'sub_segment')
ALTER TABLE public.m_catalog_industries
  ADD COLUMN segment_type VARCHAR(20) NOT NULL DEFAULT 'segment';

-- Self-referencing foreign key (sub-segment → parent)
ALTER TABLE public.m_catalog_industries
  ADD CONSTRAINT fk_industry_parent
  FOREIGN KEY (parent_id) REFERENCES public.m_catalog_industries(id)
  ON DELETE CASCADE;

-- Index for fetching children of a parent
CREATE INDEX idx_m_catalog_industries_parent_id
  ON public.m_catalog_industries(parent_id);

-- Composite index for hierarchy + active + sort queries
CREATE INDEX idx_m_catalog_industries_level
  ON public.m_catalog_industries(level, is_active, sort_order);


-- ============================================================================
-- ROLLBACK (commented out — run manually if needed)
-- ============================================================================
-- DROP INDEX IF EXISTS public.idx_m_catalog_industries_level;
-- DROP INDEX IF EXISTS public.idx_m_catalog_industries_parent_id;
-- ALTER TABLE public.m_catalog_industries DROP CONSTRAINT IF EXISTS fk_industry_parent;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS segment_type;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS level;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS parent_id;
