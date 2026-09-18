-- ═══════════════════════════════════════════════════════════════════
-- 081 — a plan / credit-pack contract links the subscriber to ContractNest
--       the way a claimed contract links a buyer to its seller
--
-- WHY: subscribe_tenant_to_plan (the live signup path), its unused v2 and
-- purchase_topup_template raise the contract in the PLATFORM tenant's book
-- with the subscriber as buyer (buyer_tenant_id set, a CNAK grant with
-- accessor_tenant_id = subscriber) — but they never do the buyer-side half
-- that claim_contract_by_cnak does: no vendor contact for the platform in
-- the subscriber's own book, grant never accepted or claimed. So on the
-- subscriber's contract list the plan row reads "Contact link missing"
-- (get_contracts_list's seller_contact_id — 079 — finds nothing), and a
-- priced plan awaiting payment would surface as "To accept" on the
-- expense Ops board. Live: 34 plan contracts + 2 packs, none linked.
--
-- WHAT: fn_link_platform_contract_to_subscriber(contract) — idempotent:
--   1. a vendor contact for the platform tenant in the subscriber's book
--      (corporate, company_name = platform business name, classification
--      vendor, source 'platform_subscription', source_tenant_id = platform,
--      source_cnak = the contract's CNAK — the shape claim_contract_by_cnak
--      creates, so 079's lookup and the contact list treat it the same;
--      contact_number comes from trg_auto_contact_number);
--   2. t_contracts.buyer_tenant_id = subscriber (older rows lacked it);
--   3. the grant: accessor_tenant_id / accessor_contact_id (the vendor
--      contact, as claim does) / claimed_at; pending → accepted, because
--      subscribing IS the acceptance (payment, for priced plans, is a
--      separate gate the invoice carries).
-- Called from the three writers (anchor rewrite, post-checked) and
-- back-filled over every platform contract with a known subscriber.
-- Applied live 2026-09-17 (batch plan-contracts-vendor-link) — source of
-- record; do not re-run.
-- ═══════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_link_platform_contract_to_subscriber(p_contract_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_platform   uuid;
  v_c          record;
  v_sub        uuid;
  v_grant      record;
  v_contact    uuid;
  v_new        boolean := false;
  v_pname      text;
  v_accepted   boolean := false;
BEGIN
  SELECT id INTO v_platform FROM t_tenants WHERE is_admin = true LIMIT 1;
  IF v_platform IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_platform_tenant');
  END IF;

  SELECT * INTO v_c FROM t_contracts WHERE id = p_contract_id FOR UPDATE;
  IF v_c.id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;
  IF v_c.tenant_id <> v_platform THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_platform_contract');
  END IF;

  v_sub := COALESCE(v_c.buyer_tenant_id,
                    NULLIF(v_c.metadata->>'subscriber_tenant_id', '')::uuid,
                    NULLIF(v_c.metadata->>'buyer_tenant_id', '')::uuid);
  IF v_sub IS NULL OR v_sub = v_platform THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_subscriber');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM t_tenants WHERE id = v_sub) THEN
    RETURN jsonb_build_object('success', false, 'reason', 'subscriber_missing', 'subscriber_tenant_id', v_sub);
  END IF;

  SELECT * INTO v_grant
    FROM t_contract_access
   WHERE contract_id = p_contract_id AND is_active = true
   ORDER BY created_at
   LIMIT 1
   FOR UPDATE;

  -- 1. the platform as a vendor in the subscriber's book
  SELECT id INTO v_contact
    FROM t_contacts
   WHERE tenant_id = v_sub
     AND source_tenant_id = v_platform
     AND is_active = true
     AND is_live = COALESCE(v_c.is_live, true)
   ORDER BY (source_cnak = v_c.global_access_id) DESC NULLS LAST, created_at
   LIMIT 1;

  IF v_contact IS NULL THEN
    SELECT COALESCE(NULLIF(tp.business_name, ''), t.name, 'ContractNest')
      INTO v_pname
      FROM t_tenants t
      LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
     WHERE t.id = v_platform
     LIMIT 1;

    INSERT INTO t_contacts (
      tenant_id, type, status, name, company_name, classifications,
      source, source_tenant_id, source_cnak, notes, created_by, is_live, is_active, is_seed
    ) VALUES (
      v_sub, 'corporate', 'active', NULL, v_pname,
      '[{"classification_value": "vendor", "classification_label": "Vendor"}]'::jsonb,
      'platform_subscription', v_platform, v_c.global_access_id,
      'Auto-created from your ContractNest subscription (vendor relationship)',
      v_c.created_by, COALESCE(v_c.is_live, true), true, false
    )
    RETURNING id INTO v_contact;
    v_new := true;
  END IF;

  -- 2. the contract knows its buyer tenant
  UPDATE t_contracts
     SET buyer_tenant_id = v_sub
   WHERE id = p_contract_id
     AND buyer_tenant_id IS DISTINCT FROM v_sub;

  -- 3. the grant is accepted and claimed by the subscriber
  IF v_grant.id IS NOT NULL THEN
    v_accepted := v_grant.status IN ('pending', 'viewed', 'sent');
    UPDATE t_contract_access
       SET accessor_tenant_id  = v_sub,
           accessor_contact_id = v_contact,
           claimed_at          = COALESCE(claimed_at, now()),
           claimed_by          = COALESCE(claimed_by, v_c.created_by),
           status              = CASE WHEN v_accepted THEN 'accepted' ELSE status END,
           responded_at        = CASE WHEN v_accepted THEN COALESCE(responded_at, now()) ELSE responded_at END,
           responded_by        = CASE WHEN v_accepted THEN COALESCE(responded_by, v_c.created_by) ELSE responded_by END,
           updated_at          = now()
     WHERE id = v_grant.id;
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'contract_id', p_contract_id,
    'subscriber_tenant_id', v_sub,
    'vendor_contact_id', v_contact,
    'contact_created', v_new,
    'grant_id', v_grant.id,
    'grant_accepted_now', v_accepted
  );
END;
$fn$;

-- ── writers: call the helper right after the contract exists ─────────
DO $$
DECLARE
  v_def text; v_n integer;
  v_a1 text := $a$    -- Priced plans are payment-gated.$a$;
  v_r1 text := $r$    PERFORM fn_link_platform_contract_to_subscriber((v_result->'data'->>'id')::UUID);  -- 081

    -- Priced plans are payment-gated.$r$;
  v_a2 text := $a$    v_contract_id := (v_result->'data'->>'id')::UUID;
$a$;
  v_r2 text := $r$    v_contract_id := (v_result->'data'->>'id')::UUID;
    PERFORM fn_link_platform_contract_to_subscriber(v_contract_id);  -- 081
$r$;
  v_a3 text := $a$    INSERT INTO t_tenant_context (product_code, tenant_id, billing_mode)$a$;
  v_r3 text := $r$    PERFORM fn_link_platform_contract_to_subscriber((v_result->'data'->>'id')::UUID);  -- 081

    INSERT INTO t_tenant_context (product_code, tenant_id, billing_mode)$r$;
BEGIN
  -- subscribe_tenant_to_plan (live signup path)
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'subscribe_tenant_to_plan';
  IF v_def IS NULL THEN RAISE EXCEPTION '081: subscribe_tenant_to_plan not found'; END IF;
  IF position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN
    v_n := (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1);
    IF v_n <> 1 THEN RAISE EXCEPTION '081: subscribe_tenant_to_plan expected one anchor, found %', v_n; END IF;
    EXECUTE replace(v_def, v_a1, v_r1);
    SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname = 'subscribe_tenant_to_plan' AND p.pronamespace = 'public'::regnamespace;
    IF position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN RAISE EXCEPTION '081: subscribe_tenant_to_plan rewrite did not land'; END IF;
  END IF;

  -- purchase_topup_template
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'purchase_topup_template';
  IF v_def IS NULL THEN RAISE EXCEPTION '081: purchase_topup_template not found'; END IF;
  IF position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN
    v_n := (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2);
    IF v_n <> 1 THEN RAISE EXCEPTION '081: purchase_topup_template expected one anchor, found %', v_n; END IF;
    EXECUTE replace(v_def, v_a2, v_r2);
    SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname = 'purchase_topup_template' AND p.pronamespace = 'public'::regnamespace;
    IF position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN RAISE EXCEPTION '081: purchase_topup_template rewrite did not land'; END IF;
  END IF;

  -- subscribe_tenant_to_plan_v2 (no live caller today; kept consistent)
  SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'subscribe_tenant_to_plan_v2';
  IF v_def IS NOT NULL AND position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN
    v_n := (length(v_def) - length(replace(v_def, v_a3, ''))) / length(v_a3);
    IF v_n <> 1 THEN RAISE EXCEPTION '081: subscribe_tenant_to_plan_v2 expected one anchor, found %', v_n; END IF;
    EXECUTE replace(v_def, v_a3, v_r3);
    SELECT pg_get_functiondef(p.oid) INTO v_def FROM pg_proc p WHERE p.proname = 'subscribe_tenant_to_plan_v2' AND p.pronamespace = 'public'::regnamespace;
    IF position('fn_link_platform_contract_to_subscriber' IN v_def) = 0 THEN RAISE EXCEPTION '081: subscribe_tenant_to_plan_v2 rewrite did not land'; END IF;
  END IF;
END $$;

-- ── backfill: every platform contract with a known subscriber ────────
DO $$
DECLARE
  v_platform uuid; r record; v_res jsonb;
  v_total int := 0; v_ok int := 0; v_contacts int := 0; v_accepted int := 0; v_skipped text := '';
  v_left int;
BEGIN
  SELECT id INTO v_platform FROM t_tenants WHERE is_admin = true LIMIT 1;
  FOR r IN
    SELECT c.id, c.contract_number
      FROM t_contracts c
     WHERE c.tenant_id = v_platform
       AND c.record_type = 'contract'
       AND COALESCE(c.buyer_tenant_id,
                    NULLIF(c.metadata->>'subscriber_tenant_id', '')::uuid,
                    NULLIF(c.metadata->>'buyer_tenant_id', '')::uuid) IS NOT NULL
     ORDER BY c.created_at
  LOOP
    v_total := v_total + 1;
    v_res := fn_link_platform_contract_to_subscriber(r.id);
    IF COALESCE((v_res->>'success')::boolean, false) THEN
      v_ok := v_ok + 1;
      IF (v_res->>'contact_created')::boolean THEN v_contacts := v_contacts + 1; END IF;
      IF (v_res->>'grant_accepted_now')::boolean THEN v_accepted := v_accepted + 1; END IF;
    ELSE
      v_skipped := v_skipped || r.contract_number || ':' || (v_res->>'reason') || ' ';
    END IF;
  END LOOP;

  -- post-check: no platform contract with an existing subscriber is left unlinked
  SELECT count(*) INTO v_left
    FROM t_contracts c
    JOIN t_tenants s ON s.id = COALESCE(c.buyer_tenant_id, NULLIF(c.metadata->>'subscriber_tenant_id', '')::uuid, NULLIF(c.metadata->>'buyer_tenant_id', '')::uuid)
   WHERE c.tenant_id = v_platform AND c.record_type = 'contract'
     AND NOT EXISTS (SELECT 1 FROM t_contacts k WHERE k.tenant_id = s.id AND k.source_tenant_id = v_platform AND k.is_active AND k.is_live = COALESCE(c.is_live, true));
  IF v_left <> 0 THEN RAISE EXCEPTION '081: % platform contracts still unlinked after backfill', v_left; END IF;

  RAISE NOTICE '081 backfill: % contracts, % linked, % vendor contacts created, % grants accepted, skipped: %',
    v_total, v_ok, v_contacts, v_accepted, COALESCE(NULLIF(v_skipped, ''), 'none');
END $$;
