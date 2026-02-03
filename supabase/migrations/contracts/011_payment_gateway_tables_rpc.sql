-- =============================================================
-- PAYMENT GATEWAY TABLES & RPC FUNCTIONS
-- Migration: contracts/011_payment_gateway_tables_rpc.sql
-- Purpose:
--   T1: t_contract_payment_requests + t_contract_payment_events
--   T2: RPC functions for gateway-agnostic payment operations
--
-- Gateway-agnostic design: gateway_provider column identifies
-- the provider (razorpay, stripe, payu, cashfree). All gateway-
-- specific IDs use gateway_* prefix (gateway_order_id, etc.)
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- T1.1  t_contract_payment_requests
-- Tracks every payment collection attempt against an invoice.
-- One invoice can have many requests (resends, retries, partial).
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS t_contract_payment_requests (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    invoice_id              UUID NOT NULL,
    contract_id             UUID NOT NULL,
    tenant_id               UUID NOT NULL,

    -- Amount
    amount                  NUMERIC NOT NULL,
    currency                VARCHAR(3) NOT NULL DEFAULT 'INR',

    -- Collection method
    collection_mode         VARCHAR(20) NOT NULL,
                            -- 'terminal'       = Razorpay Checkout popup on seller's device
                            -- 'email_link'     = payment link sent via email
                            -- 'whatsapp_link'  = payment link sent via WhatsApp

    -- Gateway details (provider-agnostic)
    gateway_provider        VARCHAR(30) NOT NULL,              -- 'razorpay' | 'stripe' | 'payu' | 'cashfree'
    gateway_order_id        TEXT,                               -- provider's order/session ID
    gateway_payment_id      TEXT,                               -- provider's payment ID (set after payment)
    gateway_link_id         TEXT,                               -- provider's payment link ID (link modes)
    gateway_short_url       TEXT,                               -- short URL for payment link
    gateway_response        JSONB DEFAULT '{}'::JSONB,          -- full create-order/link response

    -- Status
    status                  VARCHAR(20) NOT NULL DEFAULT 'created',
                            -- 'created'  = order/link created, awaiting payment
                            -- 'sent'     = link delivered via email/whatsapp
                            -- 'viewed'   = buyer opened link (if trackable)
                            -- 'paid'     = payment confirmed
                            -- 'expired'  = order/link expired
                            -- 'failed'   = payment attempt failed

    -- Traceability
    attempt_number          INTEGER NOT NULL DEFAULT 1,         -- auto-calculated per invoice
    jtd_id                  UUID,                               -- FK → n_jtd (if sent via email/whatsapp)

    -- Timestamps
    paid_at                 TIMESTAMPTZ,                        -- when payment was confirmed
    expires_at              TIMESTAMPTZ,                        -- order/link expiry time

    -- Context
    metadata                JSONB DEFAULT '{}'::JSONB,          -- extra context (buyer info, notes, etc.)
    created_by              UUID,
    is_live                 BOOLEAN DEFAULT true,
    is_active               BOOLEAN DEFAULT true,
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW(),

    -- Foreign keys
    CONSTRAINT fk_pay_req_invoice
        FOREIGN KEY (invoice_id) REFERENCES t_invoices(id) ON DELETE CASCADE,
    CONSTRAINT fk_pay_req_contract
        FOREIGN KEY (contract_id) REFERENCES t_contracts(id) ON DELETE CASCADE
);


-- ─────────────────────────────────────────────────────────────
-- T1.2  t_contract_payment_events
-- Webhook events from payment gateways (idempotent processing).
-- Every event from every provider lands here for audit.
-- ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS t_contract_payment_events (
    id                      UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    payment_request_id      UUID,                               -- FK → t_contract_payment_requests (nullable for unmatched events)
    invoice_id              UUID,                               -- denormalized for quick lookups
    tenant_id               UUID,

    -- Gateway details (provider-agnostic)
    gateway_provider        VARCHAR(30) NOT NULL,               -- 'razorpay' | 'stripe' | etc.
    gateway_event_id        TEXT NOT NULL,                      -- provider's event ID (idempotency key)
    gateway_payment_id      TEXT,                               -- provider's payment ID
    gateway_signature       TEXT,                               -- webhook signature (audit trail)

    -- Event details
    event_type              VARCHAR(50) NOT NULL,               -- 'payment.captured' | 'payment.failed' | 'charge.succeeded' etc.
    event_data              JSONB DEFAULT '{}'::JSONB,          -- full webhook payload

    -- Processing
    processed               BOOLEAN DEFAULT false,              -- whether we acted on this event
    processed_at            TIMESTAMPTZ,                        -- when we processed it
    processing_error        TEXT,                               -- error if processing failed

    -- Audit
    created_at              TIMESTAMPTZ DEFAULT NOW(),

    -- Foreign keys
    CONSTRAINT fk_pay_evt_request
        FOREIGN KEY (payment_request_id) REFERENCES t_contract_payment_requests(id) ON DELETE SET NULL
);


-- ─────────────────────────────────────────────────────────────
-- T1.3  Indexes
-- ─────────────────────────────────────────────────────────────

-- Payment requests
CREATE INDEX IF NOT EXISTS idx_pay_req_invoice
    ON t_contract_payment_requests (invoice_id) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_pay_req_contract
    ON t_contract_payment_requests (contract_id) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_pay_req_tenant_status
    ON t_contract_payment_requests (tenant_id, status) WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_pay_req_gateway_order
    ON t_contract_payment_requests (gateway_provider, gateway_order_id)
    WHERE gateway_order_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pay_req_gateway_link
    ON t_contract_payment_requests (gateway_provider, gateway_link_id)
    WHERE gateway_link_id IS NOT NULL;

-- Payment events
CREATE UNIQUE INDEX IF NOT EXISTS idx_pay_evt_idempotency
    ON t_contract_payment_events (gateway_provider, gateway_event_id);

CREATE INDEX IF NOT EXISTS idx_pay_evt_request
    ON t_contract_payment_events (payment_request_id)
    WHERE payment_request_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_pay_evt_gateway_payment
    ON t_contract_payment_events (gateway_provider, gateway_payment_id)
    WHERE gateway_payment_id IS NOT NULL;


-- ─────────────────────────────────────────────────────────────
-- T1.4  RLS Policies
-- ─────────────────────────────────────────────────────────────

ALTER TABLE t_contract_payment_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE t_contract_payment_events ENABLE ROW LEVEL SECURITY;

-- Payment requests: tenant members can view
CREATE POLICY "Tenant members can view payment requests"
    ON t_contract_payment_requests FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Payment requests: tenant members can create
CREATE POLICY "Tenant members can create payment requests"
    ON t_contract_payment_requests FOR INSERT
    WITH CHECK (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Payment requests: tenant members can update
CREATE POLICY "Tenant members can update payment requests"
    ON t_contract_payment_requests FOR UPDATE
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Payment events: tenant members can view
CREATE POLICY "Tenant members can view payment events"
    ON t_contract_payment_events FOR SELECT
    USING (
        tenant_id IN (
            SELECT ut.tenant_id FROM t_user_tenants ut WHERE ut.user_id = auth.uid()
        )
    );

-- Payment events: service_role can insert (webhooks come unauthenticated)
CREATE POLICY "Service role can insert payment events"
    ON t_contract_payment_events FOR INSERT
    WITH CHECK (true);

-- Payment events: service_role can update
CREATE POLICY "Service role can update payment events"
    ON t_contract_payment_events FOR UPDATE
    USING (true);


-- ─────────────────────────────────────────────────────────────
-- T1.5  Grants
-- ─────────────────────────────────────────────────────────────

GRANT ALL ON t_contract_payment_requests TO service_role;
GRANT SELECT, INSERT, UPDATE ON t_contract_payment_requests TO authenticated;

GRANT ALL ON t_contract_payment_events TO service_role;
GRANT SELECT ON t_contract_payment_events TO authenticated;


-- =============================================================
-- T2: RPC FUNCTIONS
-- =============================================================


-- ─────────────────────────────────────────────────────────────
-- T2.1  get_tenant_gateway_credentials
-- Fetches active payment gateway credentials for a tenant.
-- Returns provider name + encrypted credentials.
-- Decryption happens in the Edge function (needs encryption key).
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_tenant_gateway_credentials(
    p_tenant_id UUID,
    p_provider   TEXT DEFAULT NULL       -- optional: filter by specific provider
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_result JSONB;
BEGIN
    SELECT jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'integration_id', ti.id,
            'provider', ip.name,
            'display_name', ip.display_name,
            'credentials', ti.credentials,        -- still encrypted; Edge decrypts
            'is_live', ti.is_live,
            'is_active', ti.is_active,
            'connection_status', ti.connection_status,
            'last_verified', ti.last_verified
        )
    ) INTO v_result
    FROM t_tenant_integrations ti
    JOIN t_integration_providers ip ON ti.master_integration_id = ip.id
    JOIN t_integration_types it ON ip.type_id = it.id
    WHERE ti.tenant_id = p_tenant_id
      AND it.name = 'payment_gateway'
      AND ti.is_active = true
      AND (p_provider IS NULL OR ip.name = p_provider)
    ORDER BY ti.updated_at DESC
    LIMIT 1;

    IF v_result IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'No active payment gateway found for this tenant'
        );
    END IF;

    RETURN v_result;
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- T2.2  create_payment_request
-- Creates a payment request record and calculates attempt_number.
-- Called by Edge after creating order/link with the gateway.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION create_payment_request(
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoice_id        UUID;
    v_contract_id       UUID;
    v_tenant_id         UUID;
    v_amount            NUMERIC;
    v_currency          VARCHAR(3);
    v_collection_mode   VARCHAR(20);
    v_gateway_provider  VARCHAR(30);
    v_gateway_order_id  TEXT;
    v_gateway_link_id   TEXT;
    v_gateway_short_url TEXT;
    v_gateway_response  JSONB;
    v_expires_at        TIMESTAMPTZ;
    v_created_by        UUID;
    v_is_live           BOOLEAN;
    v_metadata          JSONB;

    v_invoice           RECORD;
    v_attempt_number    INTEGER;
    v_request_id        UUID;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Extract inputs
    -- ═══════════════════════════════════════════
    v_invoice_id       := (p_payload->>'invoice_id')::UUID;
    v_contract_id      := (p_payload->>'contract_id')::UUID;
    v_tenant_id        := (p_payload->>'tenant_id')::UUID;
    v_amount           := (p_payload->>'amount')::NUMERIC;
    v_currency         := COALESCE(p_payload->>'currency', 'INR');
    v_collection_mode  := p_payload->>'collection_mode';
    v_gateway_provider := p_payload->>'gateway_provider';
    v_gateway_order_id := p_payload->>'gateway_order_id';
    v_gateway_link_id  := p_payload->>'gateway_link_id';
    v_gateway_short_url:= p_payload->>'gateway_short_url';
    v_gateway_response := COALESCE(p_payload->'gateway_response', '{}'::JSONB);
    v_expires_at       := (p_payload->>'expires_at')::TIMESTAMPTZ;
    v_created_by       := (p_payload->>'created_by')::UUID;
    v_is_live          := COALESCE((p_payload->>'is_live')::BOOLEAN, true);
    v_metadata         := COALESCE(p_payload->'metadata', '{}'::JSONB);

    -- ═══════════════════════════════════════════
    -- STEP 1: Validate
    -- ═══════════════════════════════════════════
    IF v_invoice_id IS NULL OR v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'invoice_id and tenant_id are required'
        );
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'amount must be a positive number'
        );
    END IF;

    IF v_collection_mode IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'collection_mode is required (terminal, email_link, whatsapp_link)'
        );
    END IF;

    IF v_gateway_provider IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'gateway_provider is required'
        );
    END IF;

    -- Verify invoice exists and belongs to tenant
    SELECT * INTO v_invoice
    FROM t_invoices
    WHERE id = v_invoice_id
      AND tenant_id = v_tenant_id
      AND is_active = true;

    IF v_invoice IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice not found'
        );
    END IF;

    IF v_invoice.status IN ('paid', 'cancelled') THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Invoice is already ' || v_invoice.status
        );
    END IF;

    -- Validate amount doesn't exceed balance
    IF v_amount > v_invoice.balance THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Payment amount exceeds invoice balance',
            'balance', v_invoice.balance,
            'attempted', v_amount
        );
    END IF;

    -- Use contract_id from invoice if not provided
    IF v_contract_id IS NULL THEN
        v_contract_id := v_invoice.contract_id;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Calculate attempt number
    -- ═══════════════════════════════════════════
    SELECT COALESCE(MAX(attempt_number), 0) + 1 INTO v_attempt_number
    FROM t_contract_payment_requests
    WHERE invoice_id = v_invoice_id
      AND is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 3: Insert payment request
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_payment_requests (
        invoice_id, contract_id, tenant_id,
        amount, currency, collection_mode,
        gateway_provider, gateway_order_id, gateway_link_id,
        gateway_short_url, gateway_response,
        status, attempt_number, expires_at,
        metadata, created_by, is_live
    ) VALUES (
        v_invoice_id, v_contract_id, v_tenant_id,
        v_amount, v_currency, v_collection_mode,
        v_gateway_provider, v_gateway_order_id, v_gateway_link_id,
        v_gateway_short_url, v_gateway_response,
        'created', v_attempt_number, v_expires_at,
        v_metadata, v_created_by, v_is_live
    )
    RETURNING id INTO v_request_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Return
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'request_id', v_request_id,
            'invoice_id', v_invoice_id,
            'contract_id', v_contract_id,
            'amount', v_amount,
            'currency', v_currency,
            'collection_mode', v_collection_mode,
            'gateway_provider', v_gateway_provider,
            'gateway_order_id', v_gateway_order_id,
            'gateway_link_id', v_gateway_link_id,
            'gateway_short_url', v_gateway_short_url,
            'attempt_number', v_attempt_number,
            'status', 'created',
            'expires_at', v_expires_at,
            'invoice_balance', v_invoice.balance,
            'invoice_status', v_invoice.status
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to create payment request',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- T2.3  verify_gateway_payment
-- Called after Razorpay Checkout success callback (terminal mode).
-- Verifies the payment and creates receipt + updates invoice.
-- Uses record_invoice_payment() internally for consistency.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION verify_gateway_payment(
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_request_id         UUID;
    v_tenant_id          UUID;
    v_gateway_payment_id TEXT;
    v_gateway_provider   VARCHAR(30);

    v_request            RECORD;
    v_receipt_result     JSONB;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Extract inputs
    -- ═══════════════════════════════════════════
    v_request_id         := (p_payload->>'request_id')::UUID;
    v_tenant_id          := (p_payload->>'tenant_id')::UUID;
    v_gateway_payment_id := p_payload->>'gateway_payment_id';
    v_gateway_provider   := p_payload->>'gateway_provider';

    IF v_request_id IS NULL OR v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'request_id and tenant_id are required'
        );
    END IF;

    IF v_gateway_payment_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'gateway_payment_id is required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Fetch and lock payment request
    -- ═══════════════════════════════════════════
    SELECT * INTO v_request
    FROM t_contract_payment_requests
    WHERE id = v_request_id
      AND tenant_id = v_tenant_id
      AND is_active = true
    FOR UPDATE;

    IF v_request IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Payment request not found'
        );
    END IF;

    -- Idempotent: already paid
    IF v_request.status = 'paid' THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'request_id', v_request_id,
                'status', 'paid',
                'message', 'Payment already recorded',
                'gateway_payment_id', v_request.gateway_payment_id
            )
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Update payment request
    -- ═══════════════════════════════════════════
    UPDATE t_contract_payment_requests
    SET gateway_payment_id = v_gateway_payment_id,
        status = 'paid',
        paid_at = NOW(),
        updated_at = NOW()
    WHERE id = v_request_id;

    -- ═══════════════════════════════════════════
    -- STEP 3: Create receipt via existing RPC
    -- ═══════════════════════════════════════════
    v_receipt_result := record_invoice_payment(jsonb_build_object(
        'invoice_id', v_request.invoice_id,
        'contract_id', v_request.contract_id,
        'tenant_id', v_tenant_id,
        'amount', v_request.amount,
        'payment_method', v_request.gateway_provider,       -- 'razorpay', 'stripe', etc.
        'payment_date', CURRENT_DATE,
        'reference_number', v_gateway_payment_id,
        'notes', format('Online payment via %s (order: %s)', v_request.gateway_provider, v_request.gateway_order_id),
        'is_live', v_request.is_live
    ));

    -- Override is_offline to false for the receipt we just created
    IF (v_receipt_result->>'success')::BOOLEAN THEN
        UPDATE t_invoice_receipts
        SET is_offline = false,
            is_verified = true,
            verified_at = NOW()
        WHERE id = (v_receipt_result->'data'->>'receipt_id')::UUID;
    END IF;

    RETURN jsonb_build_object(
        'success', (v_receipt_result->>'success')::BOOLEAN,
        'data', jsonb_build_object(
            'request_id', v_request_id,
            'gateway_payment_id', v_gateway_payment_id,
            'receipt', v_receipt_result->'data',
            'status', 'paid'
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to verify payment',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- T2.4  process_payment_webhook
-- Called by payment-webhook Edge function.
-- Idempotent: checks gateway_event_id before processing.
-- On payment.captured: creates receipt + updates invoice.
-- On payment.failed: updates request status.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION process_payment_webhook(
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_gateway_provider   VARCHAR(30);
    v_gateway_event_id   TEXT;
    v_gateway_payment_id TEXT;
    v_gateway_order_id   TEXT;
    v_gateway_signature  TEXT;
    v_event_type         VARCHAR(50);
    v_event_data         JSONB;

    v_gateway_link_id    TEXT;
    v_tenant_id          UUID;

    v_existing_event     UUID;
    v_event_id           UUID;
    v_request            RECORD;
    v_receipt_result     JSONB;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Extract inputs
    -- ═══════════════════════════════════════════
    v_gateway_provider   := p_payload->>'gateway_provider';
    v_gateway_event_id   := p_payload->>'gateway_event_id';
    v_gateway_payment_id := p_payload->>'gateway_payment_id';
    v_gateway_order_id   := p_payload->>'gateway_order_id';
    v_gateway_signature  := p_payload->>'gateway_signature';
    v_event_type         := p_payload->>'event_type';
    v_event_data         := COALESCE(p_payload->'event_data', '{}'::JSONB);
    v_gateway_link_id    := p_payload->>'gateway_link_id';
    v_tenant_id          := (p_payload->>'tenant_id')::UUID;

    IF v_gateway_provider IS NULL OR v_gateway_event_id IS NULL OR v_event_type IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'gateway_provider, gateway_event_id, and event_type are required'
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Idempotency check
    -- ═══════════════════════════════════════════
    SELECT id INTO v_existing_event
    FROM t_contract_payment_events
    WHERE gateway_provider = v_gateway_provider
      AND gateway_event_id = v_gateway_event_id;

    IF v_existing_event IS NOT NULL THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'message', 'Event already processed',
                'event_id', v_existing_event,
                'duplicate', true
            )
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Find matching payment request
    -- ═══════════════════════════════════════════
    IF v_gateway_order_id IS NOT NULL THEN
        SELECT * INTO v_request
        FROM t_contract_payment_requests
        WHERE gateway_provider = v_gateway_provider
          AND gateway_order_id = v_gateway_order_id
          AND is_active = true
        FOR UPDATE;
    END IF;

    -- Fallback: match by gateway_link_id (payment link events)
    IF v_request IS NULL AND v_gateway_link_id IS NOT NULL THEN
        SELECT * INTO v_request
        FROM t_contract_payment_requests
        WHERE gateway_provider = v_gateway_provider
          AND gateway_link_id = v_gateway_link_id
          AND is_active = true
        FOR UPDATE;
    END IF;

    -- Final fallback: recent unpaid link request for same tenant
    IF v_request IS NULL AND v_tenant_id IS NOT NULL AND v_gateway_payment_id IS NOT NULL THEN
        SELECT * INTO v_request
        FROM t_contract_payment_requests
        WHERE gateway_provider = v_gateway_provider
          AND tenant_id = v_tenant_id
          AND gateway_link_id IS NOT NULL
          AND status NOT IN ('paid', 'failed', 'expired')
          AND is_active = true
        ORDER BY created_at DESC
        LIMIT 1
        FOR UPDATE;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 3: Insert event record (idempotency marker)
    -- ═══════════════════════════════════════════
    INSERT INTO t_contract_payment_events (
        payment_request_id, invoice_id, tenant_id,
        gateway_provider, gateway_event_id, gateway_payment_id,
        gateway_signature, event_type, event_data,
        processed
    ) VALUES (
        v_request.id,
        v_request.invoice_id,
        COALESCE(v_request.tenant_id, v_tenant_id),
        v_gateway_provider, v_gateway_event_id, v_gateway_payment_id,
        v_gateway_signature, v_event_type, v_event_data,
        false
    )
    RETURNING id INTO v_event_id;

    -- ═══════════════════════════════════════════
    -- STEP 4: Process based on event type
    -- ═══════════════════════════════════════════
    IF v_request IS NULL THEN
        -- No matching request found — log event but don't process
        UPDATE t_contract_payment_events
        SET processed = true,
            processed_at = NOW(),
            processing_error = 'No matching payment request found'
        WHERE id = v_event_id;

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'event_id', v_event_id,
                'message', 'Event logged but no matching request found',
                'processed', false
            )
        );
    END IF;

    -- payment.captured / payment_link.paid / charge.succeeded → record payment
    IF v_event_type IN ('payment.captured', 'payment_link.paid', 'charge.succeeded', 'order.paid') THEN

        -- Skip if already paid (idempotent)
        IF v_request.status = 'paid' THEN
            UPDATE t_contract_payment_events
            SET processed = true, processed_at = NOW()
            WHERE id = v_event_id;

            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'event_id', v_event_id,
                    'message', 'Payment request already paid',
                    'duplicate', true
                )
            );
        END IF;

        -- Update payment request
        UPDATE t_contract_payment_requests
        SET gateway_payment_id = COALESCE(v_gateway_payment_id, gateway_payment_id),
            status = 'paid',
            paid_at = NOW(),
            updated_at = NOW()
        WHERE id = v_request.id;

        -- Create receipt via existing RPC
        v_receipt_result := record_invoice_payment(jsonb_build_object(
            'invoice_id', v_request.invoice_id,
            'contract_id', v_request.contract_id,
            'tenant_id', v_request.tenant_id,
            'amount', v_request.amount,
            'payment_method', v_request.gateway_provider,
            'payment_date', CURRENT_DATE,
            'reference_number', v_gateway_payment_id,
            'notes', format('Webhook: %s via %s (order: %s)', v_event_type, v_request.gateway_provider, v_request.gateway_order_id),
            'is_live', v_request.is_live
        ));

        -- Mark receipt as online + verified
        IF (v_receipt_result->>'success')::BOOLEAN THEN
            UPDATE t_invoice_receipts
            SET is_offline = false,
                is_verified = true,
                verified_at = NOW()
            WHERE id = (v_receipt_result->'data'->>'receipt_id')::UUID;
        END IF;

        -- Mark event processed
        UPDATE t_contract_payment_events
        SET processed = true, processed_at = NOW()
        WHERE id = v_event_id;

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'event_id', v_event_id,
                'request_id', v_request.id,
                'receipt', v_receipt_result->'data',
                'status', 'paid'
            )
        );

    -- payment.failed → update request status
    ELSIF v_event_type IN ('payment.failed', 'charge.failed') THEN
        UPDATE t_contract_payment_requests
        SET status = 'failed',
            updated_at = NOW()
        WHERE id = v_request.id;

        UPDATE t_contract_payment_events
        SET processed = true, processed_at = NOW()
        WHERE id = v_event_id;

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'event_id', v_event_id,
                'request_id', v_request.id,
                'status', 'failed'
            )
        );

    ELSE
        -- Unknown event type — log but don't act
        UPDATE t_contract_payment_events
        SET processed = true,
            processed_at = NOW(),
            processing_error = 'Unhandled event type: ' || v_event_type
        WHERE id = v_event_id;

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'event_id', v_event_id,
                'message', 'Event logged, unhandled type: ' || v_event_type
            )
        );
    END IF;

EXCEPTION WHEN OTHERS THEN
    -- Mark event as failed if it was inserted
    IF v_event_id IS NOT NULL THEN
        UPDATE t_contract_payment_events
        SET processed = true,
            processed_at = NOW(),
            processing_error = SQLERRM
        WHERE id = v_event_id;
    END IF;

    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to process webhook',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- T2.5  get_payment_requests
-- Returns payment requests for an invoice with event history.
-- ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_payment_requests(
    p_payload JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_invoice_id  UUID;
    v_contract_id UUID;
    v_tenant_id   UUID;
    v_requests    JSONB;
    v_summary     JSONB;
BEGIN
    v_invoice_id  := (p_payload->>'invoice_id')::UUID;
    v_contract_id := (p_payload->>'contract_id')::UUID;
    v_tenant_id   := (p_payload->>'tenant_id')::UUID;

    IF v_tenant_id IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'tenant_id is required'
        );
    END IF;

    -- Build request list with event counts
    SELECT COALESCE(jsonb_agg(req_row ORDER BY req_row->>'created_at' DESC), '[]'::JSONB)
    INTO v_requests
    FROM (
        SELECT jsonb_build_object(
            'id', pr.id,
            'invoice_id', pr.invoice_id,
            'amount', pr.amount,
            'currency', pr.currency,
            'collection_mode', pr.collection_mode,
            'gateway_provider', pr.gateway_provider,
            'gateway_order_id', pr.gateway_order_id,
            'gateway_payment_id', pr.gateway_payment_id,
            'gateway_short_url', pr.gateway_short_url,
            'status', pr.status,
            'attempt_number', pr.attempt_number,
            'paid_at', pr.paid_at,
            'expires_at', pr.expires_at,
            'created_by', pr.created_by,
            'created_at', pr.created_at,
            'events_count', (
                SELECT COUNT(*) FROM t_contract_payment_events pe
                WHERE pe.payment_request_id = pr.id
            )
        ) AS req_row
        FROM t_contract_payment_requests pr
        WHERE pr.tenant_id = v_tenant_id
          AND pr.is_active = true
          AND (v_invoice_id IS NULL OR pr.invoice_id = v_invoice_id)
          AND (v_contract_id IS NULL OR pr.contract_id = v_contract_id)
    ) sub;

    -- Summary
    SELECT jsonb_build_object(
        'total_requests', COUNT(*),
        'paid_count', COUNT(*) FILTER (WHERE status = 'paid'),
        'failed_count', COUNT(*) FILTER (WHERE status = 'failed'),
        'pending_count', COUNT(*) FILTER (WHERE status IN ('created', 'sent')),
        'expired_count', COUNT(*) FILTER (WHERE status = 'expired'),
        'total_collected', COALESCE(SUM(amount) FILTER (WHERE status = 'paid'), 0)
    ) INTO v_summary
    FROM t_contract_payment_requests
    WHERE tenant_id = v_tenant_id
      AND is_active = true
      AND (v_invoice_id IS NULL OR invoice_id = v_invoice_id)
      AND (v_contract_id IS NULL OR contract_id = v_contract_id);

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'requests', v_requests,
            'summary', v_summary
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch payment requests',
        'details', SQLERRM
    );
END;
$$;


-- ─────────────────────────────────────────────────────────────
-- T2.6  Grants for RPC functions
-- ─────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION get_tenant_gateway_credentials(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_tenant_gateway_credentials(UUID, TEXT) TO service_role;

GRANT EXECUTE ON FUNCTION create_payment_request(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION create_payment_request(JSONB) TO service_role;

GRANT EXECUTE ON FUNCTION verify_gateway_payment(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION verify_gateway_payment(JSONB) TO service_role;

GRANT EXECUTE ON FUNCTION process_payment_webhook(JSONB) TO service_role;

GRANT EXECUTE ON FUNCTION get_payment_requests(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION get_payment_requests(JSONB) TO service_role;
