-- =====================================================================
-- 023_topup_is_a_contract.sql   —   BUSINESS MODEL V4, PHASE D
--
-- Buying credits becomes a contract, like everything else.
--
-- NOTHING HERE READS t_bm_topup_pack. There is no migration of its 19
-- rows and no port of its prices. A credit pack is authored in
-- catalog-studio exactly like a plan — one metering block (mode
-- 'one_time', grants keyed by channel) plus one priced block — and the
-- authoring surface for that already exists. The old table stays where
-- it is for the kaladristi product; ContractNest simply stops reading it.
--
-- THE PATH: buy → contract → invoice → payment → credits.
--
-- Credits land ON PAYMENT (owner decision). create_contract_transaction
-- already raises the invoice, and record_invoice_payment already
-- auto-activates a contract on full payment, so the only new thing is a
-- trigger that turns "invoice paid" into "credits granted". This also
-- closes the hole in the old purchase_topup, which took a payment
-- reference as free text and minted credits whether or not money moved.
--
-- ── THE COLLISION THIS HAD TO SOLVE ──────────────────────────────────
-- A top-up purchase is a contract raised BY the platform tenant FOR a
-- subscriber — structurally identical to a plan subscription. Three
-- existing pieces of logic match on exactly that shape:
--
--   · subscribe_tenant_to_plan's ALREADY_SUBSCRIBED guard would treat a
--     purchased pack as an existing plan and refuse to ever sell that
--     tenant a plan again.
--   · get_tenant_context resolves the plan as the newest active platform
--     contract for the tenant — so a pack bought after subscribing would
--     display AS the plan, replacing "Free" on the subscription page.
--   · trg_plan_contract_lapsed (Phase C) zeroes allowances when such a
--     contract expires — so an expiring pack would wipe the tenant's
--     plan limits.
--
-- All three are now filtered on metadata->>'source' <> 'topup_purchase'.
-- The filter is written as an exclusion rather than requiring
-- source = 'plan_subscription', so any plan contract created by some
-- other path in future still counts as a plan.
--
-- ── AND A BUG FOUND ON THE WAY ───────────────────────────────────────
-- subscribe_tenant_to_plan folded both metering modes into one bucket:
--
--     ELSIF v_meter->>'mode' IN ('per_creation', 'one_time') ...
--         v_grants := v_grants || v_meter->'grants';
--
-- ...and v_grants is written to credit_grant_rates — the RATE APPLIED ON
-- EVERY CREATION. A 'one_time' block means "grant N once"; filed there it
-- becomes "grant N on every contract this tenant ever creates". Any plan
-- carrying a signing-bonus block has been a credit fountain. Fixed below:
-- one_time is applied once, immediately, via add_credits.
-- =====================================================================


-- ── 1. subscribe_tenant_to_plan: three in-place corrections ──────────
-- Patched in place rather than retyped, so the 250 lines that are right
-- cannot drift. Every anchor is asserted — a missed anchor raises, it
-- does not silently no-op.
DO $do$
DECLARE
    v_src TEXT;
    v_old TEXT;
    v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'subscribe_tenant_to_plan';

    IF v_src IS NULL THEN
        RAISE EXCEPTION 'subscribe_tenant_to_plan not found';
    END IF;

    -- (a) a bucket for one-off grants
    v_old := '    v_grants          JSONB := ''{}''::JSONB;';
    v_new := '    v_grants          JSONB := ''{}''::JSONB;
    v_once            JSONB := ''{}''::JSONB;
    v_gkey            TEXT;
    v_gval            INTEGER;';
    IF position(v_old in v_src) = 0 THEN
        RAISE EXCEPTION 'anchor (a) not found in subscribe_tenant_to_plan';
    END IF;
    v_src := replace(v_src, v_old, v_new);

    -- (b) a purchased pack is not an existing plan
    v_old := '      AND c.status IN (''active'', ''pending_acceptance'')
      AND ct.source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;';
    v_new := '      AND c.status IN (''active'', ''pending_acceptance'')
      AND COALESCE(c.metadata->>''source'', '''') <> ''topup_purchase''
      AND ct.source_tenant_id = p_subscriber_tenant_id
    LIMIT 1;';
    IF position(v_old in v_src) = 0 THEN
        RAISE EXCEPTION 'anchor (b) not found in subscribe_tenant_to_plan';
    END IF;
    v_src := replace(v_src, v_old, v_new);

    -- (c) one_time is a one-off grant, NOT a per-creation rate
    v_old := '        ELSIF v_meter->>''mode'' IN (''per_creation'', ''one_time'') AND v_meter->''grants'' IS NOT NULL THEN
            v_grants := v_grants || v_meter->''grants'';';
    v_new := '        ELSIF v_meter->>''mode'' = ''per_creation'' AND v_meter->''grants'' IS NOT NULL THEN
            v_grants := v_grants || v_meter->''grants'';
        ELSIF v_meter->>''mode'' = ''one_time'' AND v_meter->''grants'' IS NOT NULL THEN
            v_once := v_once || v_meter->''grants'';';
    IF position(v_old in v_src) = 0 THEN
        RAISE EXCEPTION 'anchor (c) not found in subscribe_tenant_to_plan';
    END IF;
    v_src := replace(v_src, v_old, v_new);

    -- (d) apply the one-off grants, once, after the context is written
    v_old := '    WHERE product_code = ''contractnest''
      AND tenant_id = p_subscriber_tenant_id;

    RETURN jsonb_build_object(
        ''success'', true,';
    v_new := '    WHERE product_code = ''contractnest''
      AND tenant_id = p_subscriber_tenant_id;

    -- A one_time block is a signing bonus: granted once, here, not filed
    -- as a rate that would re-grant on every future creation.
    FOR v_gkey, v_gval IN SELECT key, value::INTEGER FROM jsonb_each_text(v_once)
    LOOP
        CONTINUE WHEN v_gval IS NULL OR v_gval <= 0;
        PERFORM add_credits(
            p_subscriber_tenant_id,
            CASE WHEN v_gkey IN (''whatsapp'',''sms'',''email'',''inapp'')
                 THEN ''notification'' ELSE v_gkey END,
            v_gval,
            CASE WHEN v_gkey IN (''whatsapp'',''sms'',''email'',''inapp'')
                 THEN v_gkey ELSE NULL END,
            ''plan_grant'',
            (v_result->''data''->>''id''),
            ''Included with '' || COALESCE(v_template.display_name, v_template.name),
            ''contract''
        );
    END LOOP;

    RETURN jsonb_build_object(
        ''success'', true,';
    IF position(v_old in v_src) = 0 THEN
        RAISE EXCEPTION 'anchor (d) not found in subscribe_tenant_to_plan';
    END IF;
    v_src := replace(v_src, v_old, v_new);

    EXECUTE v_src;
END $do$;


-- ── 2. buying a pack raises a contract ───────────────────────────────
CREATE OR REPLACE FUNCTION public.purchase_topup_template(
    p_template_id UUID, p_buyer_tenant_id UUID, p_user_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_platform_id UUID;
    v_template    RECORD;
    v_buyer       RECORD;
    v_contact_id  UUID;
    v_seq         JSONB;
    v_blocks      JSONB := '[]'::JSONB;
    v_block       JSONB;
    v_meter       JSONB;
    v_grants      JSONB := '{}'::JSONB;
    v_events      JSONB := '[]'::JSONB;
    v_payload     JSONB;
    v_result      JSONB;
    v_contract_id UUID;
    v_dur_value   INTEGER;
    v_dur_unit    TEXT;
BEGIN
    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;
    IF v_platform_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No platform tenant configured',
                                  'error_code', 'NO_PLATFORM_TENANT');
    END IF;

    IF p_buyer_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'buyer tenant is required',
                                  'error_code', 'VALIDATION_ERROR');
    END IF;

    IF p_buyer_tenant_id = v_platform_id THEN
        RETURN jsonb_build_object('success', false,
            'error', 'The platform tenant cannot buy its own credit pack',
            'error_code', 'SELF_PURCHASE');
    END IF;

    -- Same publication gate as a plan: authored, signed off, listed.
    SELECT * INTO v_template
    FROM t_cat_templates
    WHERE id = p_template_id
      AND tenant_id = v_platform_id
      AND is_active = TRUE
      AND is_live = TRUE
      AND is_public = TRUE
      AND settings->>'lifecycle' = 'signed_off';

    IF v_template.id IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Pack not found, not published, or not listed for sale',
            'error_code', 'PACK_NOT_AVAILABLE');
    END IF;

    -- What makes a template a PACK rather than a plan: it grants credits
    -- once. A template with limits or a per-creation rate is a plan and
    -- must go through subscribe_tenant_to_plan instead.
    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_meter := v_block->'config_overrides'->'config'->'metering';
        CONTINUE WHEN v_meter IS NULL;
        IF v_meter->>'mode' = 'one_time' AND v_meter->'grants' IS NOT NULL THEN
            v_grants := v_grants || v_meter->'grants';
        END IF;
    END LOOP;

    IF v_grants = '{}'::JSONB THEN
        RETURN jsonb_build_object('success', false,
            'error', 'This template grants nothing once — it is a plan, not a credit pack',
            'error_code', 'NOT_A_TOPUP_PACK');
    END IF;

    SELECT id, name INTO v_buyer FROM t_tenants WHERE id = p_buyer_tenant_id;
    IF v_buyer.id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Buyer tenant not found',
                                  'error_code', 'TENANT_NOT_FOUND');
    END IF;

    -- The same platform-side contact the plan uses. source_tenant_id is
    -- the only link between a contact and a tenant account.
    SELECT id INTO v_contact_id
    FROM t_contacts
    WHERE tenant_id = v_platform_id AND is_live = TRUE
      AND source_tenant_id = p_buyer_tenant_id
    LIMIT 1;

    IF v_contact_id IS NULL THEN
        v_seq := get_next_formatted_sequence('CONTACT', v_platform_id, TRUE);
        INSERT INTO t_contacts (
            tenant_id, is_live, type, name, company_name, contact_number,
            classifications, status, is_active, is_seed,
            source, source_tenant_id, created_by
        ) VALUES (
            v_platform_id, TRUE, 'corporate',
            NULL, v_buyer.name, v_seq->>'formatted',
            '["client"]'::JSONB, 'active', TRUE, FALSE,
            'topup_purchase', p_buyer_tenant_id, p_user_id
        )
        RETURNING id INTO v_contact_id;
    END IF;

    FOR v_block IN SELECT * FROM jsonb_array_elements(COALESCE(v_template.blocks, '[]'::JSONB))
    LOOP
        v_blocks := v_blocks || jsonb_build_array(jsonb_build_object(
            'position',        COALESCE((v_block->>'order')::INT, 0),
            'source_type',     'catalog',
            'source_block_id', v_block->>'block_id',
            'block_name',      v_block->'config_overrides'->>'name',
            'category_id',     v_block->'config_overrides'->>'category_id',
            'category_name',   v_block->'config_overrides'->>'category_name',
            'unit_price',      COALESCE((v_block->'config_overrides'->>'unit_price')::NUMERIC, 0),
            'quantity',        COALESCE((v_block->'config_overrides'->>'quantity')::INT, 1),
            'billing_cycle',   'prepaid',
            'total_price',     COALESCE((v_block->'config_overrides'->>'total_price')::NUMERIC, 0),
            'custom_fields',   jsonb_build_object(
                                  'config',   COALESCE(v_block->'config_overrides'->'config', '{}'::JSONB),
                                  'currency', COALESCE(v_template.currency, 'INR'),
                                  'notes',    'Credit pack: ' || COALESCE(v_template.display_name, v_template.name)
                               )
        ));
    END LOOP;

    -- A pack is bought outright, so one prepaid billing event for the
    -- whole amount. That is what gives the invoice something to collect,
    -- and collecting it is what releases the credits.
    IF COALESCE(v_template.total, 0) > 0 THEN
        v_events := jsonb_build_array(jsonb_build_object(
            'id', 'billing-1',
            'event_type', 'billing',
            'category_id', '',
            'block_name', COALESCE(v_template.display_name, v_template.name),
            'scheduled_date', now(),
            'amount', v_template.total,
            'status', 'pending'
        ));
    END IF;

    v_dur_value := COALESCE((v_template.settings->'defaults'->>'duration_value')::INT, 1);
    v_dur_unit  := COALESCE(v_template.settings->'defaults'->>'duration_unit', 'months');

    v_payload := jsonb_build_object(
        'tenant_id',         v_platform_id,
        'is_live',           TRUE,
        'record_type',       'contract',
        'contract_type',     'client',
        'name',              COALESCE(v_template.display_name, v_template.name),
        'buyer_id',          v_contact_id,
        'buyer_company',     v_buyer.name,
        'currency',          COALESCE(v_template.currency, 'INR'),
        'duration_value',    v_dur_value,
        'duration_unit',     v_dur_unit,
        'start_date',        now(),
        'acceptance_method', 'auto',
        'nomenclature_id',   v_template.settings->'defaults'->>'nomenclature_id',
        'billing_cycle_type','unified',
        'grand_total',       COALESCE(v_template.total, 0),
        'total_value',       COALESCE(v_template.total, 0),
        'tax_total',         0,
        'discount_total',    0,
        'blocks',            v_blocks,
        'computed_events',   v_events,
        'created_by',        p_user_id,
        'performed_by_type', 'user',
        -- The grants are SNAPSHOT here, not re-read from the template at
        -- payment time. Re-pricing or re-authoring the pack later must not
        -- change what an already-bought purchase delivers.
        'metadata',          jsonb_build_object(
                                'source',           'topup_purchase',
                                'pack_template_id', v_template.id,
                                'buyer_tenant_id',  p_buyer_tenant_id,
                                'topup_grants',     v_grants
                             )
    );

    v_result := create_contract_transaction(v_payload, NULL);

    IF NOT COALESCE((v_result->>'success')::BOOLEAN, FALSE) THEN
        RETURN jsonb_build_object('success', false,
            'error', COALESCE(v_result->>'error', 'Contract creation failed'),
            'error_code', 'CONTRACT_CREATE_FAILED', 'detail', v_result);
    END IF;

    v_contract_id := (v_result->'data'->>'id')::UUID;

    -- A free pack has nothing to collect, so there is nothing to wait for.
    IF COALESCE(v_template.total, 0) <= 0 THEN
        PERFORM fn_apply_topup_grants(v_contract_id);
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'contract_id',     v_contract_id,
        'contract_number', v_result->'data'->>'contract_number',
        'contact_id',      v_contact_id,
        'pack_name',       COALESCE(v_template.display_name, v_template.name),
        'amount',          COALESCE(v_template.total, 0),
        'currency',        COALESCE(v_template.currency, 'INR'),
        'grants',          v_grants,
        'credits_pending', COALESCE(v_template.total, 0) > 0
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'error_code', SQLSTATE);
END;
$function$;


-- ── 3. money in, credits out ─────────────────────────────────────────
-- Idempotent on the journal: one grant per purchase contract, enforced by
-- looking for the journal row that a previous grant would have written.
CREATE OR REPLACE FUNCTION public.fn_apply_topup_grants(p_contract_id UUID)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
DECLARE
    v_c      RECORD;
    v_buyer  UUID;
    v_grants JSONB;
    v_key    TEXT;
    v_val    INTEGER;
    v_n      INTEGER := 0;
BEGIN
    SELECT id, name, contract_number, metadata INTO v_c
    FROM t_contracts WHERE id = p_contract_id;

    IF NOT FOUND OR COALESCE(v_c.metadata->>'source', '') <> 'topup_purchase' THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'not_a_topup');
    END IF;

    IF EXISTS (SELECT 1 FROM t_credit_journal
               WHERE reference_type = 'topup_contract' AND reference_id = p_contract_id) THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'already_granted');
    END IF;

    v_buyer  := (v_c.metadata->>'buyer_tenant_id')::UUID;
    v_grants := COALESCE(v_c.metadata->'topup_grants', '{}'::JSONB);

    IF v_buyer IS NULL OR v_grants = '{}'::JSONB THEN
        RETURN jsonb_build_object('success', true, 'granted', false, 'reason', 'nothing_to_grant');
    END IF;

    FOR v_key, v_val IN SELECT key, value::INTEGER FROM jsonb_each_text(v_grants)
    LOOP
        CONTINUE WHEN v_val IS NULL OR v_val <= 0;

        -- A grant key that names a channel is notification credit; anything
        -- else (ai_report, and whatever comes next) is its own credit type
        -- with no channel, and lands in credits_other.
        PERFORM add_credits(
            v_buyer,
            CASE WHEN v_key IN ('whatsapp','sms','email','inapp')
                 THEN 'notification' ELSE v_key END,
            v_val,
            CASE WHEN v_key IN ('whatsapp','sms','email','inapp')
                 THEN v_key ELSE NULL END,
            'topup',
            p_contract_id::TEXT,
            'Credit pack ' || COALESCE(v_c.contract_number, '') || ': ' || COALESCE(v_c.name, ''),
            'topup_contract'
        );
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object('success', true, 'granted', TRUE,
        'contract_id', p_contract_id, 'pools', v_n);

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'topup grant failed for contract %: %', p_contract_id, SQLERRM;
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;


CREATE OR REPLACE FUNCTION public.trg_fn_topup_credits_on_payment()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
BEGIN
    IF NEW.status <> 'paid' OR COALESCE(OLD.status, '') = 'paid' THEN
        RETURN NULL;
    END IF;

    IF NEW.contract_id IS NULL THEN
        RETURN NULL;
    END IF;

    PERFORM fn_apply_topup_grants(NEW.contract_id);
    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    -- A payment must never fail because the credit grant did.
    RAISE WARNING 'topup grant on payment failed for invoice %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;

DROP TRIGGER IF EXISTS trg_topup_credits_on_payment ON public.t_invoices;
CREATE TRIGGER trg_topup_credits_on_payment
    AFTER UPDATE OF status ON public.t_invoices
    FOR EACH ROW EXECUTE FUNCTION public.trg_fn_topup_credits_on_payment();


-- ── 4. a pack is not a plan ──────────────────────────────────────────
-- get_tenant_context resolves "the plan" as the newest active platform
-- contract for the tenant. Without this, a pack bought after subscribing
-- would take the plan's place on the subscription page.
DO $do$
DECLARE v_src TEXT; v_old TEXT; v_new TEXT;
BEGIN
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_tenant_context';

    v_old := '          AND c.status IN (''active'', ''pending_acceptance'')
          AND ct.source_tenant_id = p_tenant_id';
    v_new := '          AND c.status IN (''active'', ''pending_acceptance'')
          AND COALESCE(c.metadata->>''source'', '''') <> ''topup_purchase''
          AND ct.source_tenant_id = p_tenant_id';

    IF position(v_old in v_src) = 0 THEN
        RAISE EXCEPTION 'plan-lookup anchor not found in get_tenant_context';
    END IF;

    EXECUTE replace(v_src, v_old, v_new);
END $do$;


-- An expiring PACK must not lapse the tenant's plan allowances.
CREATE OR REPLACE FUNCTION public.trg_fn_plan_contract_lapsed()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS
$function$
DECLARE
    v_platform_id UUID;
    v_subscriber  UUID;
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NULL;
    END IF;

    IF NEW.status NOT IN ('expired', 'cancelled', 'terminated') THEN
        RETURN NULL;
    END IF;

    -- A credit pack expiring is a completed sale, not a lapsed plan. The
    -- credits it delivered are already the tenant's and stay (D2).
    IF COALESCE(NEW.metadata->>'source', '') = 'topup_purchase' THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_platform_id FROM t_tenants WHERE is_admin = TRUE LIMIT 1;

    IF v_platform_id IS NULL OR NEW.tenant_id <> v_platform_id THEN
        RETURN NULL;
    END IF;

    SELECT ct.source_tenant_id INTO v_subscriber
    FROM t_contacts ct WHERE ct.id = NEW.buyer_id;

    IF v_subscriber IS NULL THEN
        RETURN NULL;
    END IF;

    UPDATE t_tenant_context
    SET limit_contracts = 0,
        limit_rfqs      = 0,
        updated_at      = NOW()
    WHERE tenant_id = v_subscriber
      AND product_code = 'contractnest';

    RETURN NULL;

EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'plan lapse handling failed for contract %: %', NEW.id, SQLERRM;
    RETURN NULL;
END;
$function$;


-- ── 5. close the free-credits hole ───────────────────────────────────
-- purchase_topup took a payment reference as free text and granted the
-- credits regardless — any caller holding a token could mint credits.
-- It is not dropped (that would 404 a live route with no explanation);
-- it now refuses and names its replacement.
CREATE OR REPLACE FUNCTION public.purchase_topup(
    p_tenant_id uuid, p_pack_id uuid, p_payment_reference text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS
$function$
BEGIN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Credit packs are bought as contracts. Use purchase_topup_template(template_id, buyer_tenant_id, user_id); credits are granted when the invoice is paid.',
        'error_code', 'RETIRED_USE_CONTRACT_PATH'
    );
END;
$function$;

COMMENT ON FUNCTION public.purchase_topup IS
'RETIRED (V4 Phase D). Granted credits on an unverified payment reference. Superseded by purchase_topup_template + payment.';
COMMENT ON FUNCTION public.purchase_topup_template IS
'Buys a credit pack as a contract. The pack is a catalog-studio template carrying a one_time metering block; grants are snapshot into contract metadata and released by fn_apply_topup_grants when the invoice is paid.';
COMMENT ON FUNCTION public.fn_apply_topup_grants IS
'Releases a purchase contract''s snapshot grants into the tenant pools. Idempotent on t_credit_journal (reference_type=topup_contract).';


-- =====================================================================
-- Verify:
--   -- a pack template must carry a one_time metering block
--   select purchase_topup_template('<template>','<tenant>','<user>');
--   -- credits must NOT move yet
--   select credits_whatsapp from t_tenant_context where tenant_id='<tenant>';
--   -- pay the invoice, then they must
--   select transaction_type, reference_type, quantity from t_credit_journal
--    where reference_type='topup_contract';
--   -- and the pack must not have become the plan
--   select get_tenant_context('contractnest','<tenant>')->'subscription'->>'contract_number';
-- =====================================================================
