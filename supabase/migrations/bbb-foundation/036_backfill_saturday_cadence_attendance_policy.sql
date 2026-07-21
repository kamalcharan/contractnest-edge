-- One-off data backfill for BBB (Test) — NOT a generic schema change.
-- The Catalog Studio attendance-policy feature only snapshots onto NEW
-- contracts going forward (the deep-copy happens client-side when a
-- contract is created). The 10 existing Saturday Cadence member contracts
-- predate that feature, so they had no attendancePolicy in their own
-- signed snapshot. Backfilled to match the block's real, live policy
-- (6 no-shows / 6 substitutes) so roster/member-view testing has
-- consistent data across every member. Idempotent (jsonb merge, safe
-- to re-run), scoped to this one block.

UPDATE t_contract_blocks
SET custom_fields = jsonb_set(
  custom_fields,
  '{config,groupSession}',
  coalesce(custom_fields->'config'->'groupSession', '{}'::jsonb) || jsonb_build_object(
    'attendancePolicy', jsonb_build_object('maxNoShows', 6, 'maxSubstitutes', 6)
  ),
  true
)
WHERE source_block_id = 'c6e86303-4a3c-41fa-8779-e330d5b0574d';
