-- ============================================================================
-- P0.5a Migration 001: Add hierarchy columns to m_catalog_industries
-- ============================================================================
-- IDEMPOTENT: Safe to run multiple times. Skips columns/constraints that exist.
-- Purpose: Transform flat industry list into 2-level parent→sub-segment hierarchy
-- Adds: parent_id (self-referencing FK), level (0=parent, 1=sub), segment_type
-- ============================================================================

-- Add parent_id (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'm_catalog_industries'
      AND column_name = 'parent_id'
  ) THEN
    ALTER TABLE public.m_catalog_industries ADD COLUMN parent_id VARCHAR(50) NULL;
    RAISE NOTICE 'Added column: parent_id';
  ELSE
    RAISE NOTICE 'Column parent_id already exists — skipping';
  END IF;
END $$;

-- Add level (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'm_catalog_industries'
      AND column_name = 'level'
  ) THEN
    ALTER TABLE public.m_catalog_industries ADD COLUMN level INTEGER NOT NULL DEFAULT 0;
    RAISE NOTICE 'Added column: level';
  ELSE
    RAISE NOTICE 'Column level already exists — skipping';
  END IF;
END $$;

-- Add segment_type (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'm_catalog_industries'
      AND column_name = 'segment_type'
  ) THEN
    ALTER TABLE public.m_catalog_industries ADD COLUMN segment_type VARCHAR(20) NOT NULL DEFAULT 'segment';
    RAISE NOTICE 'Added column: segment_type';
  ELSE
    RAISE NOTICE 'Column segment_type already exists — skipping';
  END IF;
END $$;

-- Add self-referencing FK (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'fk_industry_parent'
      AND conrelid = 'public.m_catalog_industries'::regclass
  ) THEN
    ALTER TABLE public.m_catalog_industries
      ADD CONSTRAINT fk_industry_parent
      FOREIGN KEY (parent_id) REFERENCES public.m_catalog_industries(id)
      ON DELETE CASCADE;
    RAISE NOTICE 'Added FK constraint: fk_industry_parent';
  ELSE
    RAISE NOTICE 'FK fk_industry_parent already exists — skipping';
  END IF;
END $$;

-- Add index on parent_id (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_m_catalog_industries_parent_id'
  ) THEN
    CREATE INDEX idx_m_catalog_industries_parent_id
      ON public.m_catalog_industries(parent_id);
    RAISE NOTICE 'Created index: idx_m_catalog_industries_parent_id';
  ELSE
    RAISE NOTICE 'Index idx_m_catalog_industries_parent_id already exists — skipping';
  END IF;
END $$;

-- Add composite index on level + is_active + sort_order (skip if already exists)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'idx_m_catalog_industries_level'
  ) THEN
    CREATE INDEX idx_m_catalog_industries_level
      ON public.m_catalog_industries(level, is_active, sort_order);
    RAISE NOTICE 'Created index: idx_m_catalog_industries_level';
  ELSE
    RAISE NOTICE 'Index idx_m_catalog_industries_level already exists — skipping';
  END IF;
END $$;


-- ============================================================================
-- ROLLBACK (commented out — run manually if needed)
-- ============================================================================
-- DROP INDEX IF EXISTS public.idx_m_catalog_industries_level;
-- DROP INDEX IF EXISTS public.idx_m_catalog_industries_parent_id;
-- ALTER TABLE public.m_catalog_industries DROP CONSTRAINT IF EXISTS fk_industry_parent;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS segment_type;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS level;
-- ALTER TABLE public.m_catalog_industries DROP COLUMN IF EXISTS parent_id;
