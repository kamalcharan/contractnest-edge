-- ═══════════════════════════════════════════════════════════════════
-- contracts/080_validate_access_already_responded.sql  (2026-09-17)
-- A review link opened after the contract was answered says what happened.
--
-- validate_contract_access answered an accepted / rejected / expired grant
-- with {valid:false, error:'This contract has already been accepted'} and
-- the page rendered "Access Error" — the buyer reads that as a failure
-- (owner, on CN-1010 after accepting and claiming it). Now the same branch
-- returns valid:false + already_responded:true, status, responded_at,
-- claimed (a workspace holds it), the contract (id, name, number, status,
-- total, currency) and the issuing tenant's display name, so the page can
-- show "Already accepted on 17 Sep — add it to your ContractHub / log in".
-- Nothing else in the function changes. Anchor rewrite with post-check.
-- Applied live 2026-09-17 (batch review-link-already-responded) — source of
-- record; do not re-run.
-- ═══════════════════════════════════════════════════════════════════
DO $$
DECLARE
  v_def    text;
  v_anchor text := $a$    IF v_access.status IN ('accepted', 'rejected') THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This contract has already been ' || v_access.status, 'status', v_access.status);
    END IF;

    IF v_access.status = 'expired' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'This access link has expired');
    END IF;$a$;
  v_new    text := $n$    IF v_access.status IN ('accepted', 'rejected', 'expired') THEN
        -- contracts/080: answer with the facts, not a bare error.
        SELECT c.id, c.name, c.contract_number, c.status, c.grand_total, c.currency
        INTO v_contract FROM t_contracts c WHERE c.id = v_access.contract_id;
        SELECT t.id, t.name, tp.business_name
        INTO v_tenant FROM t_tenants t LEFT JOIN t_tenant_profiles tp ON tp.tenant_id = t.id
        WHERE t.id = v_access.tenant_id LIMIT 1;
        RETURN jsonb_build_object(
            'valid', false,
            'already_responded', true,
            'status', v_access.status,
            'error', CASE WHEN v_access.status = 'expired' THEN 'This access link has expired'
                          ELSE 'This contract has already been ' || v_access.status END,
            'responded_at', v_access.responded_at,
            'claimed', v_access.accessor_tenant_id IS NOT NULL,
            'contract', jsonb_build_object('id', v_contract.id, 'name', v_contract.name,
                'contract_number', v_contract.contract_number, 'status', v_contract.status,
                'grand_total', v_contract.grand_total, 'currency', v_contract.currency),
            'tenant', jsonb_build_object('id', v_tenant.id,
                'name', COALESCE(NULLIF(v_tenant.business_name, ''), v_tenant.name)));
    END IF;$n$;
  v_n integer;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'validate_contract_access';
  IF v_def IS NULL THEN RAISE EXCEPTION '080: validate_contract_access not found'; END IF;
  IF position('already_responded' IN v_def) > 0 THEN RAISE NOTICE '080: already applied'; RETURN; END IF;
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  IF v_n <> 1 THEN RAISE EXCEPTION '080: expected exactly one anchor, found %', v_n; END IF;
  v_def := replace(v_def, v_anchor, v_new);
  EXECUTE v_def;
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'validate_contract_access';
  IF position('already_responded' IN v_def) = 0 THEN RAISE EXCEPTION '080: rewrite did not land'; END IF;
END $$;
