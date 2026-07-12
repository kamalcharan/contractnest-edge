-- ============================================================================
-- 017_group_session_checkin.sql — Group Session check-in (Batch 3)
-- ============================================================================
-- Public, token-gated check-in for group sessions. A member scans one static
-- QR per session contract, is identified by phone (roster = contacts who are
-- the buyer on an active billing contract), marks attendance for today's
-- occurrence, and may declare a BAU payment against one of their own membership
-- billing events. The chair later confirms the declaration, flipping that
-- billing event to 'paid'.
--
-- Security model mirrors the cadence RPCs (016): tables have RLS enabled with
-- no policies; access flows only through SECURITY DEFINER RPCs that bypass RLS
-- and are the sole surface. Public RPCs are gated by an opaque token.
-- ============================================================================

-- ── tables ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.t_group_session_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL,
  contract_id  uuid NOT NULL,
  token        text NOT NULL UNIQUE,
  is_active    boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (contract_id)
);

CREATE TABLE IF NOT EXISTS public.t_session_attendance (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id           uuid NOT NULL,
  session_contract_id uuid NOT NULL,
  occurrence_event_id uuid,                 -- the service event for this date (nullable if ad-hoc)
  occurrence_date     date NOT NULL,
  member_contact_id   uuid,                 -- roster member (null for unmatched first-timer)
  member_name         text,
  member_phone        text,
  status              text NOT NULL DEFAULT 'present' CHECK (status IN ('present','apologies')),
  note                text,
  checked_in_at       timestamptz NOT NULL DEFAULT now(),
  created_at          timestamptz NOT NULL DEFAULT now()
);
-- One attendance row per member per occurrence (re-check-in updates it).
CREATE UNIQUE INDEX IF NOT EXISTS uq_session_attendance_occ_member
  ON public.t_session_attendance (occurrence_event_id, member_contact_id)
  WHERE occurrence_event_id IS NOT NULL AND member_contact_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_session_attendance_contract
  ON public.t_session_attendance (session_contract_id, occurrence_date);

CREATE TABLE IF NOT EXISTS public.t_session_payment_declarations (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id              uuid NOT NULL,
  session_contract_id    uuid NOT NULL,
  occurrence_event_id    uuid,
  member_contact_id      uuid NOT NULL,
  membership_contract_id uuid NOT NULL,     -- the member's own contract holding the billing event
  billing_event_id       uuid NOT NULL,     -- which BAU due they are paying
  upi_reference          text,
  amount                 numeric,
  currency               text DEFAULT 'INR',
  status                 text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','confirmed','rejected')),
  confirmed_by           uuid,
  confirmed_at           timestamptz,
  created_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_session_decl_tenant_status
  ON public.t_session_payment_declarations (tenant_id, status);

ALTER TABLE public.t_group_session_tokens          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.t_session_attendance            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.t_session_payment_declarations  ENABLE ROW LEVEL SECURITY;

-- ── helper: a member's membership contract (active, has billing events) ──────
CREATE OR REPLACE FUNCTION public.gs_membership_contract(p_tenant uuid, p_member uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
  SELECT c.id
  FROM public.t_contracts c
  WHERE c.tenant_id = p_tenant
    AND c.buyer_id  = p_member
    AND c.status    = 'active'
    AND EXISTS (SELECT 1 FROM public.t_contract_events e
                 WHERE e.contract_id = c.id AND e.event_type = 'billing')
  ORDER BY c.created_at DESC
  LIMIT 1;
$$;

-- ── token management (authenticated: chair/tenant) ──────────────────────────
-- Idempotent: returns the existing token for the contract or mints one.
CREATE OR REPLACE FUNCTION public.gs_ensure_token(p_tenant uuid, p_contract uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_token text;
BEGIN
  SELECT token INTO v_token FROM public.t_group_session_tokens
   WHERE contract_id = p_contract;
  IF v_token IS NULL THEN
    v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    INSERT INTO public.t_group_session_tokens (tenant_id, contract_id, token)
    VALUES (p_tenant, p_contract, v_token);
  END IF;
  RETURN jsonb_build_object('token', v_token, 'contract_id', p_contract);
END;
$$;

-- ── public: resolve a token to today's occurrence ───────────────────────────
CREATE OR REPLACE FUNCTION public.gs_resolve_checkin(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_tok   public.t_group_session_tokens;
  v_c     public.t_contracts;
  v_occ   public.t_contract_events;
  v_next  public.t_contract_events;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token');
  END IF;
  SELECT * INTO v_c FROM public.t_contracts WHERE id = v_tok.contract_id;

  -- today's service occurrence, if any
  SELECT * INTO v_occ FROM public.t_contract_events
   WHERE contract_id = v_tok.contract_id AND event_type = 'service'
     AND scheduled_date::date = current_date
   ORDER BY scheduled_date LIMIT 1;

  -- otherwise the next upcoming occurrence (informational)
  SELECT * INTO v_next FROM public.t_contract_events
   WHERE contract_id = v_tok.contract_id AND event_type = 'service'
     AND scheduled_date::date > current_date
   ORDER BY scheduled_date LIMIT 1;

  RETURN jsonb_build_object(
    'ok', true,
    'tenant_id', v_tok.tenant_id,
    'contract_id', v_tok.contract_id,
    'contract_name', v_c.name,
    'today', current_date,
    'occurrence', CASE WHEN v_occ.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_occ.id, 'date', v_occ.scheduled_date::date, 'name', v_occ.block_name) END,
    'next_occurrence', CASE WHEN v_next.id IS NULL THEN NULL ELSE jsonb_build_object(
        'event_id', v_next.id, 'date', v_next.scheduled_date::date) END
  );
END;
$$;

-- ── public: match a member by phone (roster = active billing-contract buyers) ─
CREATE OR REPLACE FUNCTION public.gs_lookup_member(p_token text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_tok    public.t_group_session_tokens;
  v_member uuid;
  v_name   text;
  v_mc     uuid;
  v_digits text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  IF length(v_digits) < 6 THEN RETURN jsonb_build_object('ok', true, 'found', false); END IF;

  -- match the last 10 digits of any phone channel for a roster contact
  SELECT ct.id, ct.name INTO v_member, v_name
  FROM public.t_contacts ct
  JOIN public.t_contact_channels ch ON ch.contact_id = ct.id
  WHERE ct.tenant_id = v_tok.tenant_id
    AND ch.channel_type IN ('phone','mobile','whatsapp')
    AND right(regexp_replace(ch.value, '\D', '', 'g'), 10) = right(v_digits, 10)
    AND public.gs_membership_contract(v_tok.tenant_id, ct.id) IS NOT NULL
  LIMIT 1;

  IF v_member IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'found', false);
  END IF;

  v_mc := public.gs_membership_contract(v_tok.tenant_id, v_member);
  RETURN jsonb_build_object('ok', true, 'found', true,
    'member', jsonb_build_object('contact_id', v_member, 'name', v_name,
                                 'membership_contract_id', v_mc));
END;
$$;

-- ── public: a member's attendance + BAU billing history ─────────────────────
CREATE OR REPLACE FUNCTION public.gs_member_history(p_token text, p_member uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_tok  public.t_group_session_tokens;
  v_mc   uuid;
  v_att  jsonb;
  v_bill jsonb;
  v_decl jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);

  SELECT coalesce(jsonb_agg(jsonb_build_object('date', occurrence_date, 'status', status)
                            ORDER BY occurrence_date DESC), '[]'::jsonb)
    INTO v_att
    FROM public.t_session_attendance
   WHERE session_contract_id = v_tok.contract_id AND member_contact_id = p_member;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'event_id', e.id, 'label', coalesce(e.billing_cycle_label, e.block_name),
            'date', e.scheduled_date::date, 'amount', e.amount, 'currency', e.currency,
            'status', e.status, 'sub_type', e.billing_sub_type, 'seq', e.sequence_number)
            ORDER BY e.scheduled_date), '[]'::jsonb)
    INTO v_bill
    FROM public.t_contract_events e
   WHERE e.contract_id = v_mc AND e.event_type = 'billing';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
            'billing_event_id', billing_event_id, 'status', status,
            'upi_reference', upi_reference, 'amount', amount)
            ORDER BY created_at DESC), '[]'::jsonb)
    INTO v_decl
    FROM public.t_session_payment_declarations
   WHERE session_contract_id = v_tok.contract_id AND member_contact_id = p_member;

  RETURN jsonb_build_object('ok', true, 'membership_contract_id', v_mc,
    'attendance', v_att, 'billing', v_bill, 'declarations', v_decl);
END;
$$;

-- ── public: submit a check-in (attendance + optional payment declaration) ────
CREATE OR REPLACE FUNCTION public.gs_submit_checkin(
  p_token text, p_member uuid, p_member_name text, p_member_phone text,
  p_status text, p_payment jsonb DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_tok   public.t_group_session_tokens;
  v_occ   public.t_contract_events;
  v_mc    uuid;
  v_status text := CASE WHEN p_status = 'apologies' THEN 'apologies' ELSE 'present' END;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;

  SELECT * INTO v_occ FROM public.t_contract_events
   WHERE contract_id = v_tok.contract_id AND event_type = 'service'
     AND scheduled_date::date = current_date
   ORDER BY scheduled_date LIMIT 1;
  IF v_occ.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'no_session_today'); END IF;

  -- upsert attendance (unique on occurrence + member)
  IF p_member IS NOT NULL THEN
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_contact_id, member_name, member_phone, status)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member, p_member_name, p_member_phone, v_status)
    ON CONFLICT (occurrence_event_id, member_contact_id)
      DO UPDATE SET status = excluded.status, member_name = excluded.member_name,
                    member_phone = excluded.member_phone, checked_in_at = now();
  ELSE
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_name, member_phone, status)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member_name, p_member_phone, v_status);
  END IF;

  -- optional BAU payment declaration
  IF p_member IS NOT NULL AND p_payment IS NOT NULL
     AND (p_payment->>'billing_event_id') IS NOT NULL THEN
    v_mc := public.gs_membership_contract(v_tok.tenant_id, p_member);
    INSERT INTO public.t_session_payment_declarations
      (tenant_id, session_contract_id, occurrence_event_id, member_contact_id,
       membership_contract_id, billing_event_id, upi_reference, amount, currency)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, p_member, v_mc,
       (p_payment->>'billing_event_id')::uuid, p_payment->>'upi_reference',
       nullif(p_payment->>'amount','')::numeric, coalesce(p_payment->>'currency','INR'));
  END IF;

  RETURN public.gs_member_history(p_token, p_member);
END;
$$;

-- ── chair (authenticated): pending declarations for a tenant ────────────────
CREATE OR REPLACE FUNCTION public.gs_pending_declarations(p_tenant uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_out jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(jsonb_build_object(
      'id', d.id, 'member_contact_id', d.member_contact_id, 'member_name', ct.name,
      'billing_event_id', d.billing_event_id, 'label', coalesce(e.billing_cycle_label, e.block_name),
      'due_date', e.scheduled_date::date, 'amount', d.amount, 'currency', d.currency,
      'upi_reference', d.upi_reference, 'event_status', e.status, 'created_at', d.created_at)
      ORDER BY d.created_at DESC), '[]'::jsonb)
    INTO v_out
    FROM public.t_session_payment_declarations d
    LEFT JOIN public.t_contacts ct ON ct.id = d.member_contact_id
    LEFT JOIN public.t_contract_events e ON e.id = d.billing_event_id
   WHERE d.tenant_id = p_tenant AND d.status = 'pending';
  RETURN jsonb_build_object('ok', true, 'declarations', v_out);
END;
$$;

-- ── chair (authenticated): confirm/reject a declaration ─────────────────────
-- On confirm, flip the member's billing event to 'paid' (manual-status path).
CREATE OR REPLACE FUNCTION public.gs_confirm_declaration(
  p_tenant uuid, p_declaration uuid, p_confirm boolean, p_user uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE v_d public.t_session_payment_declarations;
BEGIN
  SELECT * INTO v_d FROM public.t_session_payment_declarations
   WHERE id = p_declaration AND tenant_id = p_tenant;
  IF v_d.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;

  IF p_confirm THEN
    UPDATE public.t_session_payment_declarations
       SET status = 'confirmed', confirmed_by = p_user, confirmed_at = now()
     WHERE id = p_declaration;
    UPDATE public.t_contract_events
       SET status = 'paid', updated_at = now()
     WHERE id = v_d.billing_event_id AND event_type = 'billing';
  ELSE
    UPDATE public.t_session_payment_declarations
       SET status = 'rejected', confirmed_by = p_user, confirmed_at = now()
     WHERE id = p_declaration;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
