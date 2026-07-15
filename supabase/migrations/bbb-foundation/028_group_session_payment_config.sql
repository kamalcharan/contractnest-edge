-- ============================================================================
-- 028_group_session_payment_config.sql
-- ----------------------------------------------------------------------------
-- G4 — expose the tenant's Offline UPI VPA to the public (token-gated)
-- check-in page so members can pay via a upi:// intent.
--
-- The integration credentials are stored AES-GCM encrypted and are never
-- returned to clients. A VPA + payee name are payer-facing (non-secret), so
-- for config_only providers we keep a plaintext copy at credentials->'public'
-- (written by the integrations edge function on save; see index.ts). This RPC
-- reads only that public slice for the token's tenant.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.gs_checkin_payment_config(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tok public.t_group_session_tokens;
  v_live boolean;
  v_pub jsonb;
BEGIN
  SELECT * INTO v_tok FROM public.t_group_session_tokens WHERE token=p_token AND is_active;
  IF v_tok.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'invalid_token'); END IF;
  v_live := coalesce(v_tok.is_live, true);

  SELECT ti.credentials->'public' INTO v_pub
  FROM public.t_tenant_integrations ti
  JOIN public.t_integration_providers ip ON ip.id = ti.master_integration_id
  WHERE ip.name = 'offline_upi'
    AND ti.tenant_id = v_tok.tenant_id::text
    AND ti.is_live = v_live
    AND ti.is_active
  ORDER BY ti.updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_pub IS NULL OR coalesce(v_pub->>'upi_id','') = '' THEN
    RETURN jsonb_build_object('ok', true, 'configured', false);
  END IF;

  RETURN jsonb_build_object(
    'ok', true, 'configured', true,
    'upi_id', v_pub->>'upi_id',
    'payee_name', coalesce(v_pub->>'payee_name', ''));
END $function$;

-- One-time backfill of the plaintext public slice for existing offline_upi
-- configs (recovered from the encrypted blob; VPA/payee are non-secret). New
-- saves write this automatically via the integrations edge function.
UPDATE public.t_tenant_integrations ti
SET credentials = ti.credentials || jsonb_build_object('public',
      jsonb_build_object('upi_id','kamalcharan@okicici','payee_name','charan kamal'))
FROM public.t_integration_providers ip
WHERE ip.id = ti.master_integration_id
  AND ip.name = 'offline_upi'
  AND NOT (ti.credentials ? 'public');
