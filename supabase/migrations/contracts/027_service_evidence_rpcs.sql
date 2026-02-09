-- ============================================================================
-- Migration 027: Service Evidence RPC Functions
-- ============================================================================
-- Purpose: CRUD operations for service evidence
--
-- RPCs:
--   create_service_evidence    — Create evidence record + audit entry
--   update_service_evidence    — Verify/reject/update evidence + audit
--   get_service_evidence_list  — List evidence for a ticket
--
-- Depends on: 022-025 (tables), 026 (ticket RPCs)
-- ============================================================================


-- ============================================================================
-- RPC: create_service_evidence
-- Creates one evidence record, writes audit entry
-- ============================================================================
CREATE OR REPLACE FUNCTION create_service_evidence(
    p_tenant_id         UUID,
    p_ticket_id         UUID,
    p_evidence_type     TEXT,
    p_event_id          UUID DEFAULT NULL,
    p_block_id          TEXT DEFAULT NULL,
    p_block_name        TEXT DEFAULT NULL,
    p_label             TEXT DEFAULT NULL,
    p_description       TEXT DEFAULT NULL,
    -- File fields (upload-form)
    p_file_url          TEXT DEFAULT NULL,
    p_file_name         TEXT DEFAULT NULL,
    p_file_size         BIGINT DEFAULT NULL,
    p_file_type         TEXT DEFAULT NULL,
    p_file_thumbnail_url TEXT DEFAULT NULL,
    -- OTP fields
    p_otp_code          TEXT DEFAULT NULL,
    p_otp_sent_to       TEXT DEFAULT NULL,
    -- Form fields (service-form)
    p_form_template_id  UUID DEFAULT NULL,
    p_form_template_name TEXT DEFAULT NULL,
    p_form_data         JSONB DEFAULT NULL,
    -- Meta
    p_uploaded_by       UUID DEFAULT NULL,
    p_uploaded_by_name  TEXT DEFAULT NULL,
    p_is_live           BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_evidence_id   UUID;
    v_ticket_rec    RECORD;
    v_status        TEXT := 'pending';
BEGIN
    -- ═══════════════════════════════════════════
    -- Validation
    -- ═══════════════════════════════════════════
    IF p_tenant_id IS NULL OR p_ticket_id IS NULL OR p_evidence_type IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id, ticket_id, and evidence_type are required');
    END IF;

    IF p_evidence_type NOT IN ('upload-form', 'otp', 'service-form') THEN
        RETURN jsonb_build_object('success', false, 'error', 'evidence_type must be: upload-form, otp, or service-form', 'code', 'VALIDATION_ERROR');
    END IF;

    -- Verify ticket exists and belongs to tenant
    SELECT id, ticket_number, contract_id INTO v_ticket_rec
    FROM t_service_tickets
    WHERE id = p_ticket_id AND tenant_id = p_tenant_id AND is_active = true;

    IF v_ticket_rec IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Service ticket not found', 'code', 'NOT_FOUND');
    END IF;

    -- Set initial status based on type
    IF p_evidence_type = 'upload-form' AND p_file_url IS NOT NULL THEN
        v_status := 'uploaded';
    ELSIF p_evidence_type = 'otp' THEN
        v_status := 'pending';
    ELSIF p_evidence_type = 'service-form' AND p_form_data IS NOT NULL THEN
        v_status := 'uploaded';
    END IF;

    -- ═══════════════════════════════════════════
    -- Insert evidence
    -- ═══════════════════════════════════════════
    INSERT INTO t_service_evidence (
        tenant_id, ticket_id, event_id,
        block_id, block_name,
        evidence_type, label, description,
        file_url, file_name, file_size, file_type, file_thumbnail_url,
        otp_code, otp_sent_to,
        form_template_id, form_template_name, form_data,
        status, uploaded_by, uploaded_by_name,
        is_live
    ) VALUES (
        p_tenant_id, p_ticket_id, p_event_id,
        p_block_id, p_block_name,
        p_evidence_type, p_label, p_description,
        p_file_url, p_file_name, p_file_size, p_file_type, p_file_thumbnail_url,
        p_otp_code, p_otp_sent_to,
        p_form_template_id, p_form_template_name, p_form_data,
        v_status, p_uploaded_by, p_uploaded_by_name,
        p_is_live
    ) RETURNING id INTO v_evidence_id;

    -- ═══════════════════════════════════════════
    -- Write audit entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_audit_log (
        tenant_id, entity_type, entity_id, contract_id,
        category, action, description,
        new_value, performed_by, performed_by_name
    ) VALUES (
        p_tenant_id, 'evidence', v_evidence_id, v_ticket_rec.contract_id,
        'evidence', 'evidence_uploaded',
        p_evidence_type || ' evidence uploaded for ' || v_ticket_rec.ticket_number,
        jsonb_build_object(
            'evidence_type', p_evidence_type,
            'label', p_label,
            'block_name', p_block_name,
            'status', v_status,
            'ticket_number', v_ticket_rec.ticket_number
        ),
        p_uploaded_by, p_uploaded_by_name
    );

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_evidence_id,
            'evidence_type', p_evidence_type,
            'status', v_status,
            'ticket_id', p_ticket_id
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;


-- ============================================================================
-- RPC: update_service_evidence
-- Verify, reject, or update evidence (e.g. OTP verification, re-upload)
-- ============================================================================
CREATE OR REPLACE FUNCTION update_service_evidence(
    p_evidence_id       UUID,
    p_tenant_id         UUID,
    p_action            TEXT,           -- 'verify' | 'reject' | 'update_file' | 'verify_otp' | 'update_form'
    p_payload           JSONB DEFAULT '{}'::JSONB,
    p_changed_by        UUID DEFAULT NULL,
    p_changed_by_name   TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current       RECORD;
    v_contract_id   UUID;
    v_ticket_number TEXT;
BEGIN
    -- Fetch current evidence
    SELECT se.*, st.contract_id AS _contract_id, st.ticket_number AS _ticket_number
    INTO v_current
    FROM t_service_evidence se
    JOIN t_service_tickets st ON st.id = se.ticket_id
    WHERE se.id = p_evidence_id AND se.tenant_id = p_tenant_id AND se.is_active = true;

    IF v_current IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Evidence not found', 'code', 'NOT_FOUND');
    END IF;

    v_contract_id := v_current._contract_id;
    v_ticket_number := v_current._ticket_number;

    -- ═══════════════════════════════════════════
    -- Handle action
    -- ═══════════════════════════════════════════
    CASE p_action
        WHEN 'verify' THEN
            UPDATE t_service_evidence
            SET status = 'verified', verified_by = p_changed_by, verified_by_name = p_changed_by_name, verified_at = NOW()
            WHERE id = p_evidence_id;

        WHEN 'reject' THEN
            UPDATE t_service_evidence
            SET status = 'rejected', rejection_reason = COALESCE(p_payload->>'reason', 'Rejected'),
                verified_by = p_changed_by, verified_by_name = p_changed_by_name, verified_at = NOW()
            WHERE id = p_evidence_id;

        WHEN 'verify_otp' THEN
            UPDATE t_service_evidence
            SET otp_verified = true, otp_verified_at = NOW(),
                otp_verified_by = p_changed_by, otp_verified_by_name = p_changed_by_name,
                status = 'verified'
            WHERE id = p_evidence_id;

        WHEN 'update_file' THEN
            UPDATE t_service_evidence
            SET file_url = COALESCE(p_payload->>'file_url', file_url),
                file_name = COALESCE(p_payload->>'file_name', file_name),
                file_size = COALESCE((p_payload->>'file_size')::BIGINT, file_size),
                file_type = COALESCE(p_payload->>'file_type', file_type),
                file_thumbnail_url = COALESCE(p_payload->>'file_thumbnail_url', file_thumbnail_url),
                status = 'uploaded'
            WHERE id = p_evidence_id;

        WHEN 'update_form' THEN
            UPDATE t_service_evidence
            SET form_data = COALESCE(p_payload->'form_data', form_data),
                status = 'uploaded'
            WHERE id = p_evidence_id;

        ELSE
            RETURN jsonb_build_object('success', false, 'error', 'Invalid action: ' || p_action, 'code', 'VALIDATION_ERROR');
    END CASE;

    -- ═══════════════════════════════════════════
    -- Audit entry
    -- ═══════════════════════════════════════════
    INSERT INTO t_audit_log (
        tenant_id, entity_type, entity_id, contract_id,
        category, action, description,
        old_value, new_value,
        performed_by, performed_by_name
    ) VALUES (
        p_tenant_id, 'evidence', p_evidence_id, v_contract_id,
        'evidence', 'evidence_' || p_action,
        v_current.evidence_type || ' evidence ' || p_action || ' for ' || v_ticket_number,
        jsonb_build_object('status', v_current.status),
        jsonb_build_object('action', p_action, 'payload', p_payload),
        p_changed_by, p_changed_by_name
    );

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', p_evidence_id,
            'action', p_action,
            'evidence_type', v_current.evidence_type
        )
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;


-- ============================================================================
-- RPC: get_service_evidence_list
-- List evidence for a ticket (or by contract via ticket join)
-- ============================================================================
CREATE OR REPLACE FUNCTION get_service_evidence_list(
    p_tenant_id     UUID,
    p_ticket_id     UUID DEFAULT NULL,
    p_contract_id   UUID DEFAULT NULL,
    p_evidence_type TEXT DEFAULT NULL,
    p_status        TEXT DEFAULT NULL,
    p_is_live       BOOLEAN DEFAULT true
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
            'evidence', COALESCE(jsonb_agg(ev_row ORDER BY ev_row->>'created_at' DESC), '[]'::jsonb),
            'total', COUNT(*)
        )
    ) INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'id', se.id,
            'ticket_id', se.ticket_id,
            'event_id', se.event_id,
            'evidence_type', se.evidence_type,
            'label', se.label,
            'description', se.description,
            'block_id', se.block_id,
            'block_name', se.block_name,
            'status', se.status,
            'file_url', se.file_url,
            'file_name', se.file_name,
            'file_size', se.file_size,
            'file_type', se.file_type,
            'file_thumbnail_url', se.file_thumbnail_url,
            'otp_verified', se.otp_verified,
            'otp_verified_at', se.otp_verified_at,
            'otp_verified_by_name', se.otp_verified_by_name,
            'form_template_name', se.form_template_name,
            'form_data', se.form_data,
            'rejection_reason', se.rejection_reason,
            'uploaded_by_name', se.uploaded_by_name,
            'verified_by_name', se.verified_by_name,
            'verified_at', se.verified_at,
            'created_at', se.created_at,
            'ticket_number', st.ticket_number
        ) AS ev_row
        FROM t_service_evidence se
        JOIN t_service_tickets st ON st.id = se.ticket_id
        WHERE se.tenant_id = p_tenant_id
          AND se.is_active = true
          AND se.is_live = p_is_live
          AND (p_ticket_id IS NULL OR se.ticket_id = p_ticket_id)
          AND (p_contract_id IS NULL OR st.contract_id = p_contract_id)
          AND (p_evidence_type IS NULL OR se.evidence_type = p_evidence_type)
          AND (p_status IS NULL OR se.status = p_status)
    ) sub;

    RETURN COALESCE(v_result, jsonb_build_object(
        'success', true,
        'data', jsonb_build_object('evidence', '[]'::jsonb, 'total', 0)
    ));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;
