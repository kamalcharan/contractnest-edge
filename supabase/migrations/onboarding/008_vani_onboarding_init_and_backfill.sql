-- 008_vani_onboarding_init_and_backfill.sql
--
-- Onboarding-completion fix, DB side. (UI side: PlanStep now AWAITS the
-- terminal 'done' write, and VaniDoneStep — the one screen every persona
-- reaches — flips is_completed explicitly on mount.)
--
-- PROBLEM
-- -------
-- initialize_tenant_onboarding() (AFTER INSERT ON t_tenants) still seeded the
-- LEGACY model: onboarding_type='business', total_steps=6, and the six legacy
-- step rows (user-profile, business-profile, data-setup, storage, team, tour).
-- The live VaNi/express flow never emits 'user-profile'/'business-profile',
-- so the edge function's legacy completion rule could never fire, and the
-- fallback rule (completed_steps.length >= total_steps) only completed
-- tenants who happened to accumulate >= 6 steps. A buyer's journey emits at
-- most 5 — buyers could NEVER be marked complete. Verified live 2026-08-01:
-- every t_tenant_onboarding row has total_steps=6; of the 20 most recent
-- tenants only 1 ever recorded the terminal 'done' step; tenants with all
-- their persona's work finished (e.g. 5/5 buyer steps incl. lov-setup) sat at
-- is_completed=false and were forced back into onboarding on every login.
--
-- FIX (two parts)
-- ---------------
-- 1. Trigger seeds the VaNi 13-step model — identical list, order and
--    onboarding_type to VANI_STEPS in supabase/functions/onboarding/index.ts
--    (the S13 registry). With total_steps=13, the edge function's
--    isLegacyModel branch (total_steps <= 6) no longer misfires for new
--    tenants, and completion flows through the 'done' rule the UI now
--    reliably triggers.
-- 2. Backfill: tenants whose recorded steps show they finished the setup work
--    ('done', or the last work step 'lov-setup' — terminal for every persona
--    before the optional rehearsal/plan screens) get is_completed=true, so
--    they stop being forced back into onboarding.
--
-- Deliberately NOT touched: the edge function's completion rule itself (its
-- 'done' rule is correct and proven live), and rows for tenants who genuinely
-- stopped mid-flow (they should resume onboarding).

-- ============================================================================
-- 1. Trigger: seed the VaNi 13-step model for new tenants
-- ============================================================================
CREATE OR REPLACE FUNCTION public.initialize_tenant_onboarding()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
    -- Main onboarding record — the S13 VaNi model, matching VANI_STEPS in
    -- the onboarding edge function (functions/v1/onboarding).
    INSERT INTO t_tenant_onboarding (
        tenant_id,
        onboarding_type,
        total_steps,
        current_step,
        completed_steps,
        skipped_steps,
        step_data,
        is_completed
    ) VALUES (
        NEW.id,
        'vani',
        13,
        1,
        '[]'::jsonb,
        '[]'::jsonb,
        '{}'::jsonb,
        false
    );

    -- Step registry — same 13 ids, same order as the edge function's
    -- VANI_STEPS. Steps outside this list (e.g. terms-conditions, lov-setup)
    -- are upserted by the edge function at completion time with sequence 99,
    -- exactly as before.
    INSERT INTO t_onboarding_step_status (tenant_id, step_id, step_sequence, status)
    VALUES
        (NEW.id, 'vani-intro',         1,  'pending'),
        (NEW.id, 'user-profile',       2,  'pending'),
        (NEW.id, 'business-details',   3,  'pending'),
        (NEW.id, 'persona-selection',  4,  'pending'),
        (NEW.id, 'theme-selection',    5,  'pending'),
        (NEW.id, 'industry-selection', 6,  'pending'),
        (NEW.id, 'resource-pick',      7,  'pending'),
        (NEW.id, 'vani-consent',       8,  'pending'),
        (NEW.id, 'vani-working',       9,  'pending'),
        (NEW.id, 'pricing-review',     10, 'pending'),
        (NEW.id, 'equipment-confirm',  11, 'pending'),
        (NEW.id, 'vani-intelligence',  12, 'pending'),
        (NEW.id, 'done',               13, 'pending');

    RETURN NEW;
END;
$function$;

-- ============================================================================
-- 2. Backfill: complete the tenants whose recorded steps prove they finished
-- ============================================================================
-- 'done'      = the terminal step (only 1 tenant ever managed to record it
--               before the UI fix, because the write was fire-and-forget).
-- 'lov-setup' = the last WORK step of every persona's journey (seller:
--               ...terms -> lists -> done; buyer: ...assets -> lists -> done),
--               reached only after seeding/pricing/terms are behind them.
-- Tenants without either genuinely stopped mid-flow and are left incomplete
-- on purpose — they should resume onboarding.
UPDATE t_tenant_onboarding
SET is_completed = true,
    completed_at = COALESCE(completed_at, now()),
    updated_at   = now()
WHERE is_completed = false
  AND (
        completed_steps ? 'done'
     OR completed_steps ? 'lov-setup'
  );
