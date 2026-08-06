-- ============================================================
-- BUSINESS MODEL V3 — 014 : D4 second layer — event_source NOT NULL
-- ============================================================
-- Migration 012 fixed purchase_topup's `processed` -> `status` column error.
-- The Step 4 regression test then revealed a SECOND NOT NULL column the
-- original never reached: t_bm_billing_event.event_source.
--
-- Two defects were stacked in one INSERT. Only running the function surfaced
-- the second — a good argument for the regression step existing at all.
--
-- Supersedes the purchase_topup body in 012. Apply 012 -> 013 -> 014 in order.
--
-- VERIFIED after this migration (in a rolled-back transaction):
--   purchase_topup succeeds
--   a WhatsApp pack credits channel = 'whatsapp' (500), not the pooled bucket
--   a journal row is written with reference_type = 'topup_pack'
--   the billing event is written with status = 'completed'
-- ============================================================

CREATE OR REPLACE FUNCTION public.purchase_topup(
    p_tenant_id uuid, p_pack_id uuid, p_payment_reference text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
    v_pack RECORD;
    v_expiry TIMESTAMPTZ;
    v_result JSONB;
BEGIN
    SELECT * INTO v_pack FROM t_bm_topup_pack WHERE id = p_pack_id AND is_active = true;

    IF v_pack IS NULL THEN
        RETURN jsonb_build_object('success', false,
            'error', 'Topup pack not found or inactive', 'pack_id', p_pack_id);
    END IF;

    -- Retained for the response payload only. Credits do not expire (owner
    -- decision 2026-08-05) and add_credits has no expiry parameter. Step 5
    -- sets expiry_days = NULL on every surviving pack.
    IF v_pack.expiry_days IS NOT NULL THEN
        v_expiry := NOW() + (v_pack.expiry_days || ' days')::INTERVAL;
    END IF;

    v_result := add_credits(
        p_tenant_id, v_pack.credit_type, v_pack.quantity,
        v_pack.channel,                    -- D5: was hardcoded NULL
        'topup', p_pack_id::text,
        'Purchased: ' || v_pack.name, 'topup_pack'
    );

    IF NOT (v_result->>'success')::BOOLEAN THEN
        RETURN v_result;
    END IF;

    -- D4: `status` not `processed`, and event_source is NOT NULL.
    INSERT INTO t_bm_billing_event (
        tenant_id, event_type, event_source, event_data, status, processed_at
    ) VALUES (
        p_tenant_id, 'credits_purchased', 'purchase_topup',
        jsonb_build_object(
            'pack_id', p_pack_id, 'pack_name', v_pack.name,
            'credit_type', v_pack.credit_type, 'channel', v_pack.channel,
            'quantity', v_pack.quantity, 'price', v_pack.price,
            'currency', v_pack.currency_code, 'payment_reference', p_payment_reference
        ),
        'completed', NOW()
    );

    RETURN jsonb_build_object(
        'success', true,
        'pack', jsonb_build_object('id', v_pack.id, 'name', v_pack.name,
            'credit_type', v_pack.credit_type, 'channel', v_pack.channel,
            'quantity', v_pack.quantity, 'price', v_pack.price,
            'currency', v_pack.currency_code),
        'credits_added', v_pack.quantity,
        'new_balance', v_result->'new_balance',
        'expires_at', v_expiry
    );
END;
$function$;
