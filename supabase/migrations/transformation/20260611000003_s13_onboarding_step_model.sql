-- Sprint 1 / S13 — Onboarding step-model fix (probe finding B0.1)
-- The DB recorded total_steps = 6 against a 13-step VaNi UI flow, with
-- step_data = {} everywhere. The edge onboarding function is updated in the
-- same sprint to register the 13-step model and merge each step's payload
-- into step_data. This migration documents the model and corrects open rows.

COMMENT ON COLUMN t_tenant_onboarding.total_steps IS
  'Number of steps in the flow this record tracks. VaNi flow (2026) = 13: vani-intro, user-profile, business-details, persona-selection, theme-selection, industry-selection, resource-pick, vani-consent, vani-working, pricing-review, equipment-confirm, vani-intelligence, done. Legacy flow = 6.';

COMMENT ON COLUMN t_tenant_onboarding.step_data IS
  'Accumulated per-step payloads, keyed by step id (e.g. {"persona-selection": {"persona": "seller"}, "resource-pick": {...}}). Written by the onboarding edge function on every step/complete call (S13). Persona, industry, resource picks, consent and pricing acceptance must be reconstructable from here plus the durable tables (t_tenant_profiles.persona, t_tenant_selected_resources).';

COMMENT ON COLUMN t_tenant_onboarding.completed_steps IS
  'JSONB array of completed step ids for the flow named by onboarding_type/total_steps.';

-- Correct open (not-yet-completed) VaNi-era records still carrying the 6-step model.
-- Completed legacy records keep total_steps = 6 as a historical fact.
UPDATE t_tenant_onboarding
SET total_steps = 13,
    updated_at  = now()
WHERE is_completed = false
  AND total_steps = 6;
