-- One-off data repair for BBB (Test) — NOT a generic schema change.
-- The "Saturday Cadence" catalog block was missing anchorWeekday in its
-- serviceCycles config (unlike "Bi Weekly Meetings", which correctly has
-- anchorWeekday=6). Without an anchor, gs_generate_schedule anchored purely
-- to the earliest linked contract's start_date (2026-04-01, a Wednesday) and
-- walked forward in raw +14-day steps — landing on Thursdays instead of
-- Saturdays. gs_schedule_move only ever touches the single row being moved
-- (confirmed from source), so this was never a "moving one occurrence
-- cascades to the rest" bug — the whole series was miscalculated from the
-- very first generation.
--
-- Repair: backfill anchorWeekday=6, drop the wrongly-anchored future
-- 'scheduled' rows (including the flagged-wrong 07-31 manual patch), and
-- regenerate. The one 'held' row (07-11, real attendance data, already a
-- genuine Saturday) is left untouched — ON CONFLICT DO NOTHING skips it on
-- regenerate. New rows automatically inherit the block's default chair via
-- migration 032. Idempotent: safe to re-run, guarded by the specific block id.

UPDATE m_cat_blocks
SET config = jsonb_set(config, '{serviceCycles,anchorWeekday}', '6', true)
WHERE id = 'c6e86303-4a3c-41fa-8779-e330d5b0574d'
  AND coalesce(config->'serviceCycles'->>'anchorWeekday', '') = '';

DELETE FROM t_group_session_schedule
WHERE source_block_id = 'c6e86303-4a3c-41fa-8779-e330d5b0574d' AND is_live = false
  AND status = 'scheduled' AND occurrence_date >= current_date
  AND extract(dow FROM occurrence_date) <> 6;

SELECT gs_generate_schedule(
  (SELECT tenant_id FROM t_group_session_schedule WHERE source_block_id = 'c6e86303-4a3c-41fa-8779-e330d5b0574d' LIMIT 1),
  'c6e86303-4a3c-41fa-8779-e330d5b0574d'::uuid,
  false, NULL, NULL
);
