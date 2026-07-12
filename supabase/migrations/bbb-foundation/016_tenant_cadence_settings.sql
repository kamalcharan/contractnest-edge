-- Migration: bbb-foundation/016_tenant_cadence_settings.sql
-- ============================================================================
-- Batch 2a (Group Session / smart Service Cycles): a TENANT-LEVEL cadence
-- calendar that every service cycle can respect.
--
-- Defines, per tenant:
--   • weekly_holidays  — which weekdays are off (0=Sun .. 6=Sat)
--   • default_shift    — when an occurrence lands on a holiday, the SUGGESTED
--                        move: 'next' (N+1 working day) or 'previous' (N-1).
--                        This is only the default the wizard pre-selects; the
--                        user is alerted and decides per occurrence.
--   • marked holiday dates (t_tenant_holiday_dates) — one-off holidays.
--
-- Seeding mirrors 010 (event-status): an AFTER INSERT trigger on t_tenants seeds
-- defaults for every new tenant (all onboarding paths incl. VaNi), plus a
-- backfill for existing tenants. Non-fatal so tenant creation never fails.
--
-- Access is via the API (service role); RLS is enabled deny-by-default.
-- ============================================================================

-- ── tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_tenant_cadence_settings (
  tenant_id      uuid PRIMARY KEY REFERENCES public.t_tenants(id) ON DELETE CASCADE,
  weekly_holidays int[]  NOT NULL DEFAULT '{0}',           -- default: Sunday off
  default_shift   text   NOT NULL DEFAULT 'next'
                    CHECK (default_shift IN ('next','previous')),
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.t_tenant_holiday_dates (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES public.t_tenants(id) ON DELETE CASCADE,
  holiday_date date NOT NULL,
  label        text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, holiday_date)
);
CREATE INDEX IF NOT EXISTS idx_tenant_holiday_dates_tenant
  ON public.t_tenant_holiday_dates (tenant_id, holiday_date);

ALTER TABLE public.t_tenant_cadence_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.t_tenant_holiday_dates    ENABLE ROW LEVEL SECURITY;

-- ── seed function (idempotent) ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.seed_cadence_defaults(p_tenant uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.t_tenant_cadence_settings (tenant_id, weekly_holidays, default_shift)
  VALUES (p_tenant, '{0}', 'next')
  ON CONFLICT (tenant_id) DO NOTHING;
END;
$$;

-- ── AFTER INSERT trigger on t_tenants (mirrors trg_tenants_seed_event_status) ─
CREATE OR REPLACE FUNCTION public.trg_fn_seed_cadence_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $$
BEGIN
  BEGIN
    PERFORM seed_cadence_defaults(NEW.id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'seed_cadence_defaults failed for tenant %: %', NEW.id, SQLERRM;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tenants_seed_cadence ON public.t_tenants;
CREATE TRIGGER trg_tenants_seed_cadence
  AFTER INSERT ON public.t_tenants
  FOR EACH ROW EXECUTE FUNCTION trg_fn_seed_cadence_defaults();

-- ── backfill existing tenants ───────────────────────────────────────────────
INSERT INTO public.t_tenant_cadence_settings (tenant_id, weekly_holidays, default_shift)
SELECT t.id, '{0}', 'next'
FROM public.t_tenants t
WHERE NOT EXISTS (
  SELECT 1 FROM public.t_tenant_cadence_settings s WHERE s.tenant_id = t.id
);

-- ── thin RPCs ───────────────────────────────────────────────────────────────
-- SECURITY DEFINER: the tables have RLS enabled with no policies (access only
-- via these trusted, tenant-scoped RPCs), so the functions run as the owner and
-- bypass RLS regardless of which key the backend authenticates with.
CREATE OR REPLACE FUNCTION public.get_tenant_cadence_settings(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_settings public.t_tenant_cadence_settings;
  v_holidays jsonb;
BEGIN
  PERFORM seed_cadence_defaults(p_tenant);   -- guarantee a row
  SELECT * INTO v_settings FROM public.t_tenant_cadence_settings WHERE tenant_id = p_tenant;
  SELECT coalesce(jsonb_agg(jsonb_build_object('date', holiday_date, 'label', label)
                            ORDER BY holiday_date), '[]'::jsonb)
    INTO v_holidays
    FROM public.t_tenant_holiday_dates WHERE tenant_id = p_tenant;
  RETURN jsonb_build_object(
    'weekly_holidays', to_jsonb(v_settings.weekly_holidays),
    'default_shift',   v_settings.default_shift,
    'holidays',        v_holidays
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_tenant_cadence_settings(
  p_tenant uuid, p_weekly_holidays int[], p_default_shift text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  IF p_default_shift NOT IN ('next','previous') THEN
    RAISE EXCEPTION 'default_shift must be next or previous';
  END IF;
  INSERT INTO public.t_tenant_cadence_settings (tenant_id, weekly_holidays, default_shift, updated_at)
  VALUES (p_tenant, coalesce(p_weekly_holidays, '{0}'), p_default_shift, now())
  ON CONFLICT (tenant_id) DO UPDATE
    SET weekly_holidays = excluded.weekly_holidays,
        default_shift   = excluded.default_shift,
        updated_at      = now();
  RETURN get_tenant_cadence_settings(p_tenant);
END;
$$;

CREATE OR REPLACE FUNCTION public.add_tenant_holiday(
  p_tenant uuid, p_date date, p_label text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  INSERT INTO public.t_tenant_holiday_dates (tenant_id, holiday_date, label)
  VALUES (p_tenant, p_date, p_label)
  ON CONFLICT (tenant_id, holiday_date) DO UPDATE SET label = excluded.label;
  RETURN get_tenant_cadence_settings(p_tenant);
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_tenant_holiday(p_tenant uuid, p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
BEGIN
  DELETE FROM public.t_tenant_holiday_dates WHERE tenant_id = p_tenant AND holiday_date = p_date;
  RETURN get_tenant_cadence_settings(p_tenant);
END;
$$;
