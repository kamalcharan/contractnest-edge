-- Sprint 1 / S7 — Persist tenant persona (probe finding A10)
-- The product previously wrote 'seller'/'buyer'/'both' strings into
-- t_tenant_profiles.business_type_id (an *_id-named varchar mapped onto
-- profile_type by the tenant-profile edge function). That made the most basic
-- agent question — "am I working for a provider or a buyer?" — unanswerable
-- from data. This migration gives persona a first-class, constrained column.

ALTER TABLE t_tenant_profiles
  ADD COLUMN IF NOT EXISTS persona text
  CHECK (persona IN ('seller', 'buyer', 'both'));

COMMENT ON COLUMN t_tenant_profiles.persona IS
  'Tenant operating persona captured during onboarding (S7). seller = provides services (gets a sales catalog), buyer = procures services (gets asset/facility registries), both = dual setup. Canonical source for persona; written by PersonaSelectionStep via tenant-profile edge function.';

COMMENT ON COLUMN t_tenant_profiles.business_type_id IS
  'Legacy persona field (stored in profile_type by the tenant-profile edge function), values buyer|seller|both. Still WRITTEN (dual-write with persona) because /settings/business-profile and AuthContext perspective init consume it. persona is the constrained, canonical column for agent reads.';

COMMENT ON COLUMN t_tenant_profiles.profile_type IS
  'Legacy duplicate of business_type_id written by tenant-profile edge upserts. Superseded by persona for seller/buyer/both semantics.';

-- Backfill from the legacy columns (covers both current and pre-rename values)
UPDATE t_tenant_profiles
SET persona = CASE
  WHEN business_type_id IN ('seller', 'buyer', 'both') THEN business_type_id
  WHEN business_type_id = 'service_provider' THEN 'seller'
  WHEN business_type_id = 'merchant' THEN 'buyer'
  WHEN profile_type IN ('seller', 'buyer', 'both') THEN profile_type
  WHEN profile_type = 'service_provider' THEN 'seller'
  WHEN profile_type = 'merchant' THEN 'buyer'
  ELSE NULL
END
WHERE persona IS NULL
  AND (business_type_id IS NOT NULL OR profile_type IS NOT NULL);
