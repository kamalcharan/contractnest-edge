-- ============================================================================
-- bbb-foundation/019_checkin_smart_form.sql
-- Smart-Forms-driven Group Session check-in (hybrid).
-- ----------------------------------------------------------------------------
-- The member-facing check-in page (public, token-gated) renders its QUESTIONS
-- from a Smart Forms template mapped to the session's owner contract, instead
-- of hardcoded fields. The token wizard (resolve → phone lookup → history →
-- dues) stays; only the questions step becomes Smart-Forms-configurable.
--
--   * gs_checkin_form(token)  → serves the approved Smart Forms schema mapped to
--     the session (m_form_template_mappings, timing='during_service'); falls
--     back to a built-in attendance-only default when nothing is mapped.
--   * gs_submit_checkin(...)  → extended to persist the renderer's answers on
--     t_session_attendance (token-gated; NOT m_form_submissions, which is
--     tenant-JWT bound and unreachable by a logged-out member).
--
-- SECURITY DEFINER; underlying tables have RLS enabled with no policies, so all
-- access is through these RPCs (same model as 017). Idempotent / drift-safe.
-- Depends on: 017 (check-in), smart-forms/001 (m_form_templates + mappings).
-- ============================================================================

-- 1. store the questionnaire answers alongside attendance (token-gated) --------
ALTER TABLE public.t_session_attendance
  ADD COLUMN IF NOT EXISTS form_responses        jsonb,
  ADD COLUMN IF NOT EXISTS form_template_id       uuid,
  ADD COLUMN IF NOT EXISTS form_template_version  int;

-- 2. token-gated fetch of the check-in form schema ----------------------------
CREATE OR REPLACE FUNCTION public.gs_checkin_form(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
DECLARE
  v_tok    public.t_group_session_tokens;
  v_tid    uuid;
  v_ver    int;
  v_schema jsonb;
  -- built-in attendance-only fallback (valid FormSchema shape for FormRenderer)
  v_default jsonb := jsonb_build_object(
    'id', 'checkin_default', 'title', 'Session Check-in', 'version', 1,
    'sections', jsonb_build_array(jsonb_build_object(
      'id', 'attendance', 'title', 'Attendance',
      'fields', jsonb_build_array(jsonb_build_object(
        'id', 'attendance_status', 'type', 'radio',
        'label', 'Are you attending today?',
        'default_value', 'present',
        'validation', jsonb_build_object('required', true),
        'options', jsonb_build_array(
          jsonb_build_object('label', 'Present', 'value', 'present'),
          jsonb_build_object('label', 'Apologies (not attending)', 'value', 'apologies')
        )
      ))
    ))
  );
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token = p_token AND is_active;
  IF v_tok.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token');
  END IF;

  -- newest active 'during_service' mapping whose template is approved
  SELECT t.id, t.version, t.schema
    INTO v_tid, v_ver, v_schema
  FROM public.m_form_template_mappings m
  JOIN public.m_form_templates t ON t.id = m.form_template_id
  WHERE m.tenant_id   = v_tok.tenant_id
    AND m.contract_id = v_tok.contract_id
    AND coalesce(m.status, 'active') = 'active'
    AND m.timing = 'during_service'
    AND m.effective_from <= current_date
    AND (m.effective_to IS NULL OR m.effective_to >= current_date)
    AND t.status = 'approved'
  ORDER BY m.effective_from DESC, t.version DESC
  LIMIT 1;

  IF v_schema IS NULL THEN
    RETURN jsonb_build_object(
      'ok', true, 'source', 'default',
      'form_template_id', NULL, 'form_template_version', NULL,
      'schema', v_default);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'source', 'template',
    'form_template_id', v_tid, 'form_template_version', v_ver,
    'schema', v_schema);
END;
$$;

-- 3. extend gs_submit_checkin to persist the answers --------------------------
-- Drop the prior 6-arg signature, recreate with the questionnaire params.
DROP FUNCTION IF EXISTS public.gs_submit_checkin(text, uuid, text, text, text, jsonb);

CREATE OR REPLACE FUNCTION public.gs_submit_checkin(
  p_token text, p_member uuid, p_member_name text, p_member_phone text,
  p_status text, p_payment jsonb DEFAULT NULL,
  p_responses jsonb DEFAULT NULL, p_form_template_id uuid DEFAULT NULL,
  p_form_template_version int DEFAULT NULL)
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

  -- upsert attendance (unique on occurrence + member), now carrying form answers
  IF p_member IS NOT NULL THEN
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_contact_id, member_name, member_phone, status,
       form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member, p_member_name, p_member_phone, v_status,
       p_responses, p_form_template_id, p_form_template_version)
    ON CONFLICT (occurrence_event_id, member_contact_id)
      DO UPDATE SET status = excluded.status, member_name = excluded.member_name,
                    member_phone = excluded.member_phone, checked_in_at = now(),
                    form_responses = excluded.form_responses,
                    form_template_id = excluded.form_template_id,
                    form_template_version = excluded.form_template_version;
  ELSE
    INSERT INTO public.t_session_attendance
      (tenant_id, session_contract_id, occurrence_event_id, occurrence_date,
       member_name, member_phone, status,
       form_responses, form_template_id, form_template_version)
    VALUES (v_tok.tenant_id, v_tok.contract_id, v_occ.id, v_occ.scheduled_date::date,
       p_member_name, p_member_phone, v_status,
       p_responses, p_form_template_id, p_form_template_version);
  END IF;

  -- optional BAU payment declaration (unchanged)
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

GRANT EXECUTE ON FUNCTION public.gs_checkin_form(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.gs_submit_checkin(text, uuid, text, text, text, jsonb, jsonb, uuid, int)
  TO anon, authenticated, service_role;
