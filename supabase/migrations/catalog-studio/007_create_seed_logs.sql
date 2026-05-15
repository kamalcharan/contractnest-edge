-- ============================================================================
-- CATALOG STUDIO: t_seed_logs Table
-- ============================================================================
-- Observability layer for the Onboarding Agent bulk seeding process.
-- Records the outcome of every KT → cat_blocks seeding attempt per tenant,
-- enabling retry logic, debugging, and progress tracking (Screen 7 / VaNi).
-- ============================================================================

CREATE TABLE IF NOT EXISTS t_seed_logs (
  id                   UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  tenant_id            UUID REFERENCES t_tenants(id) ON DELETE CASCADE,
  resource_template_id UUID,
  kt_name              TEXT,
  status               TEXT NOT NULL CHECK (status IN ('success', 'failed', 'skipped')),
  blocks_created       INTEGER NOT NULL DEFAULT 0,
  blocks_skipped       INTEGER NOT NULL DEFAULT 0,
  skip_reason          TEXT,        -- 'already_seeded' | 'no_kt_data'
  error_message        TEXT,
  duration_ms          INTEGER,
  is_live              BOOLEAN NOT NULL DEFAULT true,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_seed_logs_tenant_id ON t_seed_logs(tenant_id);
CREATE INDEX idx_seed_logs_resource_template_id ON t_seed_logs(resource_template_id);
CREATE INDEX idx_seed_logs_status ON t_seed_logs(status);
CREATE INDEX idx_seed_logs_created_at ON t_seed_logs(created_at DESC);
