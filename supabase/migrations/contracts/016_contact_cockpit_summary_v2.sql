-- =============================================================
-- CONTACT COCKPIT SUMMARY RPC - V2 ENHANCED
-- Migration: contracts/016_contact_cockpit_summary_v2.sql
--
-- BACKUP: Original in 015_contact_cockpit_summary_rpc_BACKUP.sql
--         Run 015 to rollback if needed.
--
-- ENHANCEMENTS over v1:
--   1. Multi-role contracts (buyer + CNAK accessor)
--   2. contact_role per contract (as_vendor / as_client / as_partner)
--   3. CNAK data per contract (global_access_id, cnak_status)
--   4. Real outstanding from t_invoices (was hardcoded 0)
--   5. Invoice list for Financials column
--   6. Urgency score + level
--   7. contract_type per contract
--   8. Payment pattern (collection rate from invoices)
-- =============================================================

CREATE OR REPLACE FUNCTION get_contact_cockpit_summary(
    p_contact_id    UUID,
    p_tenant_id     UUID,
    p_is_live       BOOLEAN DEFAULT true,
    p_days_ahead    INT DEFAULT 7
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_contracts_summary     JSONB;
    v_events_summary        JSONB;
    v_overdue_events        JSONB;
    v_upcoming_events       JSONB;
    v_invoices              JSONB;
    v_ltv                   NUMERIC;
    v_outstanding           NUMERIC;
    v_health_score          NUMERIC;
    v_urgency_score         NUMERIC;
    v_urgency_level         TEXT;
    v_total_events          INT;
    v_completed_events      INT;
    v_overdue_count         INT;
    v_overdue_invoice_count INT;
    v_today_event_count     INT;
    v_soon_event_count      INT;
    v_total_invoiced        NUMERIC;
    v_total_paid            NUMERIC;
    v_invoice_count         INT;
    v_paid_on_time_count    INT;
BEGIN
    -- ═══════════════════════════════════════════
    -- STEP 0: Input validation
    -- ═══════════════════════════════════════════
    IF p_contact_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'contact_id is required');
    END IF;
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 1: Contracts Summary (Multi-Role)
    --   Finds contracts where:
    --   a) buyer_id = contact_id (I created contract for this contact)
    --   b) t_contract_access.accessor_contact_id = contact_id (CNAK connected)
    --   Deduplicates by contract ID.
    -- ═══════════════════════════════════════════
    SELECT jsonb_build_object(
        'total', COUNT(*),
        'by_status', COALESCE((
            SELECT jsonb_object_agg(status, cnt)
            FROM (
                SELECT status, COUNT(*) as cnt
                FROM (
                    -- Contracts where contact is buyer
                    SELECT c.id, c.status
                    FROM t_contracts c
                    WHERE c.buyer_id = p_contact_id
                      AND c.tenant_id = p_tenant_id
                      AND c.is_live = p_is_live
                      AND c.is_active = true
                      AND c.record_type = 'contract'

                    UNION

                    -- Contracts where contact is CNAK accessor
                    SELECT c.id, c.status
                    FROM t_contracts c
                    JOIN t_contract_access ca ON ca.contract_id = c.id
                    WHERE ca.accessor_contact_id = p_contact_id
                      AND c.tenant_id = p_tenant_id
                      AND c.is_live = p_is_live
                      AND c.is_active = true
                      AND c.record_type = 'contract'
                      AND ca.is_active = true
                ) deduped
                GROUP BY status
            ) s
        ), '{}'::JSONB),
        'by_role', COALESCE((
            SELECT jsonb_object_agg(contact_role, cnt)
            FROM (
                SELECT contact_role, COUNT(*) as cnt
                FROM (
                    SELECT c.id,
                        CASE WHEN c.buyer_id = p_contact_id THEN
                            CASE c.contract_type
                                WHEN 'vendor' THEN 'as_vendor'
                                WHEN 'partner' THEN 'as_partner'
                                ELSE 'as_client'
                            END
                        ELSE COALESCE('as_' || ca.accessor_role, 'as_client')
                        END as contact_role
                    FROM t_contracts c
                    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
                        AND ca.accessor_contact_id = p_contact_id
                        AND ca.is_active = true
                    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
                      AND c.tenant_id = p_tenant_id
                      AND c.is_live = p_is_live
                      AND c.is_active = true
                      AND c.record_type = 'contract'
                ) deduped
                GROUP BY contact_role
            ) s
        ), '{}'::JSONB),
        'contracts', COALESCE((
            SELECT jsonb_agg(contract_data ORDER BY created_at DESC)
            FROM (
                SELECT DISTINCT ON (c.id)
                    c.id,
                    c.created_at,
                    jsonb_build_object(
                        'id', c.id,
                        'contract_number', c.contract_number,
                        'name', c.name,
                        'status', c.status,
                        'contract_type', c.contract_type,
                        'grand_total', c.grand_total,
                        'currency', c.currency,
                        'created_at', c.created_at,
                        'acceptance_method', c.acceptance_method,
                        'duration_value', c.duration_value,
                        'duration_unit', c.duration_unit,
                        -- Contact role in this contract
                        'contact_role', CASE
                            WHEN c.buyer_id = p_contact_id THEN
                                CASE c.contract_type
                                    WHEN 'vendor' THEN 'as_vendor'
                                    WHEN 'partner' THEN 'as_partner'
                                    ELSE 'as_client'
                                END
                            ELSE COALESCE('as_' || ca.accessor_role, 'as_client')
                        END,
                        -- CNAK data
                        'global_access_id', c.global_access_id,
                        'cnak_status', COALESCE(ca.status,
                            CASE WHEN c.global_access_id IS NOT NULL THEN 'not_connected' ELSE NULL END
                        )
                    ) as contract_data
                FROM t_contracts c
                LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
                    AND ca.is_active = true
                    AND (ca.accessor_contact_id = p_contact_id OR c.buyer_id = p_contact_id)
                WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
                  AND c.tenant_id = p_tenant_id
                  AND c.is_live = p_is_live
                  AND c.is_active = true
                  AND c.record_type = 'contract'
                ORDER BY c.id, c.created_at DESC
            ) sub
        ), '[]'::JSONB)
    )
    INTO v_contracts_summary;

    -- Handle NULL case (no contracts)
    IF v_contracts_summary IS NULL THEN
        v_contracts_summary := jsonb_build_object(
            'total', 0,
            'by_status', '{}'::JSONB,
            'by_role', '{}'::JSONB,
            'contracts', '[]'::JSONB
        );
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 2: Events Summary
    --   Aggregates events from ALL contracts for this contact
    --   (multi-role: buyer + accessor)
    -- ═══════════════════════════════════════════
    SELECT
        COUNT(*),
        COUNT(*) FILTER (WHERE ce.status = 'completed'),
        COUNT(*) FILTER (WHERE ce.status NOT IN ('completed', 'cancelled') AND ce.scheduled_date < NOW()),
        COUNT(*) FILTER (WHERE ce.status NOT IN ('completed', 'cancelled') AND DATE(ce.scheduled_date) = CURRENT_DATE),
        COUNT(*) FILTER (WHERE ce.status NOT IN ('completed', 'cancelled') AND ce.scheduled_date > NOW() AND ce.scheduled_date <= NOW() + INTERVAL '3 days')
    INTO v_total_events, v_completed_events, v_overdue_count, v_today_event_count, v_soon_event_count
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true;

    SELECT jsonb_build_object(
        'total', COALESCE(v_total_events, 0),
        'completed', COALESCE(v_completed_events, 0),
        'overdue', COALESCE(v_overdue_count, 0),
        'by_status', COALESCE((
            SELECT jsonb_object_agg(status, cnt)
            FROM (
                SELECT ce.status, COUNT(*) as cnt
                FROM t_contract_events ce
                JOIN t_contracts c ON ce.contract_id = c.id
                LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
                    AND ca.accessor_contact_id = p_contact_id
                    AND ca.is_active = true
                WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
                  AND ce.tenant_id = p_tenant_id
                  AND ce.is_live = p_is_live
                  AND ce.is_active = true
                GROUP BY ce.status
            ) s
        ), '{}'::JSONB),
        'by_type', COALESCE((
            SELECT jsonb_object_agg(event_type, cnt)
            FROM (
                SELECT ce.event_type, COUNT(*) as cnt
                FROM t_contract_events ce
                JOIN t_contracts c ON ce.contract_id = c.id
                LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
                    AND ca.accessor_contact_id = p_contact_id
                    AND ca.is_active = true
                WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
                  AND ce.tenant_id = p_tenant_id
                  AND ce.is_live = p_is_live
                  AND ce.is_active = true
                GROUP BY ce.event_type
            ) s
        ), '{}'::JSONB)
    )
    INTO v_events_summary;

    -- ═══════════════════════════════════════════
    -- STEP 3: Overdue Events (detailed list)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ce.id,
            'contract_id', ce.contract_id,
            'contract_number', c.contract_number,
            'contract_name', c.name,
            'event_type', ce.event_type,
            'block_name', ce.block_name,
            'scheduled_date', ce.scheduled_date,
            'days_overdue', EXTRACT(DAY FROM NOW() - ce.scheduled_date)::INT,
            'status', ce.status,
            'amount', ce.amount,
            'currency', ce.currency,
            'assigned_to', ce.assigned_to,
            'assigned_to_name', ce.assigned_to_name,
            'sequence_number', ce.sequence_number,
            'total_occurrences', ce.total_occurrences
        ) ORDER BY ce.scheduled_date ASC
    ), '[]'::JSONB)
    INTO v_overdue_events
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true
      AND ce.status NOT IN ('completed', 'cancelled')
      AND ce.scheduled_date < NOW();

    -- ═══════════════════════════════════════════
    -- STEP 4: Upcoming Events (next N days)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', ce.id,
            'contract_id', ce.contract_id,
            'contract_number', c.contract_number,
            'contract_name', c.name,
            'event_type', ce.event_type,
            'block_name', ce.block_name,
            'scheduled_date', ce.scheduled_date,
            'days_until', EXTRACT(DAY FROM ce.scheduled_date - NOW())::INT,
            'is_today', DATE(ce.scheduled_date) = CURRENT_DATE,
            'status', ce.status,
            'amount', ce.amount,
            'currency', ce.currency,
            'assigned_to', ce.assigned_to,
            'assigned_to_name', ce.assigned_to_name,
            'sequence_number', ce.sequence_number,
            'total_occurrences', ce.total_occurrences
        ) ORDER BY ce.scheduled_date ASC
    ), '[]'::JSONB)
    INTO v_upcoming_events
    FROM t_contract_events ce
    JOIN t_contracts c ON ce.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND ce.tenant_id = p_tenant_id
      AND ce.is_live = p_is_live
      AND ce.is_active = true
      AND ce.status NOT IN ('completed', 'cancelled')
      AND ce.scheduled_date >= NOW()
      AND ce.scheduled_date <= NOW() + (p_days_ahead || ' days')::INTERVAL;

    -- ═══════════════════════════════════════════
    -- STEP 5: Calculate LTV (Lifetime Value)
    --   Sum of grand_total from all contracts (multi-role)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(SUM(DISTINCT c.grand_total), 0)
    INTO v_ltv
    FROM t_contracts c
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND c.record_type = 'contract';

    -- ═══════════════════════════════════════════
    -- STEP 6: Outstanding from t_invoices
    --   Sum of balance from unpaid/partially_paid/overdue invoices
    -- ═══════════════════════════════════════════
    SELECT
        COALESCE(SUM(inv.balance), 0),
        COUNT(*) FILTER (WHERE inv.status = 'overdue')
    INTO v_outstanding, v_overdue_invoice_count
    FROM t_invoices inv
    JOIN t_contracts c ON inv.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND inv.is_active = true
      AND inv.status IN ('unpaid', 'partially_paid', 'overdue');

    -- ═══════════════════════════════════════════
    -- STEP 7: Invoice list (recent, for Financials column)
    -- ═══════════════════════════════════════════
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', inv.id,
            'invoice_number', inv.invoice_number,
            'contract_id', inv.contract_id,
            'contract_number', c.contract_number,
            'contract_name', c.name,
            'invoice_type', inv.invoice_type,
            'total_amount', inv.total_amount,
            'amount_paid', inv.amount_paid,
            'balance', inv.balance,
            'status', inv.status,
            'due_date', inv.due_date,
            'currency', inv.currency,
            'payment_mode', inv.payment_mode,
            'issued_at', inv.issued_at,
            'paid_at', inv.paid_at
        ) ORDER BY inv.issued_at DESC
    ), '[]'::JSONB)
    INTO v_invoices
    FROM t_invoices inv
    JOIN t_contracts c ON inv.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND inv.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 8: Payment Pattern (from invoices)
    -- ═══════════════════════════════════════════
    SELECT
        COALESCE(SUM(inv.total_amount), 0),
        COALESCE(SUM(inv.amount_paid), 0),
        COUNT(*),
        COUNT(*) FILTER (WHERE inv.status = 'paid' AND (inv.paid_at IS NULL OR inv.paid_at <= inv.due_date + INTERVAL '1 day'))
    INTO v_total_invoiced, v_total_paid, v_invoice_count, v_paid_on_time_count
    FROM t_invoices inv
    JOIN t_contracts c ON inv.contract_id = c.id
    LEFT JOIN t_contract_access ca ON ca.contract_id = c.id
        AND ca.accessor_contact_id = p_contact_id
        AND ca.is_active = true
    WHERE (c.buyer_id = p_contact_id OR ca.accessor_contact_id = p_contact_id)
      AND c.tenant_id = p_tenant_id
      AND c.is_live = p_is_live
      AND c.is_active = true
      AND inv.is_active = true;

    -- ═══════════════════════════════════════════
    -- STEP 9: Calculate Health Score
    --   Based on: events completion rate, overdue ratio
    -- ═══════════════════════════════════════════
    IF v_total_events > 0 THEN
        v_health_score := GREATEST(0, LEAST(100,
            (v_completed_events::NUMERIC / v_total_events * 100) - (v_overdue_count * 10)
        ));
    ELSE
        v_health_score := 100;
    END IF;

    -- ═══════════════════════════════════════════
    -- STEP 10: Calculate Urgency Score
    --   Formula:
    --   (overdue_events * 15) + (overdue_invoices * 20) +
    --   (today_events * 10) + (events_in_3_days * 5)
    --   Level: 0-25 low, 26-50 medium, 51-75 high, 76+ critical
    -- ═══════════════════════════════════════════
    v_urgency_score := LEAST(100,
        (COALESCE(v_overdue_count, 0) * 15) +
        (COALESCE(v_overdue_invoice_count, 0) * 20) +
        (COALESCE(v_today_event_count, 0) * 10) +
        (COALESCE(v_soon_event_count, 0) * 5)
    );

    v_urgency_level := CASE
        WHEN v_urgency_score >= 76 THEN 'critical'
        WHEN v_urgency_score >= 51 THEN 'high'
        WHEN v_urgency_score >= 26 THEN 'medium'
        ELSE 'low'
    END;

    -- ═══════════════════════════════════════════
    -- STEP 11: Build and return response
    -- ═══════════════════════════════════════════
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'contact_id', p_contact_id,
            'contracts', v_contracts_summary,
            'events', v_events_summary,
            'overdue_events', v_overdue_events,
            'upcoming_events', v_upcoming_events,
            'invoices', v_invoices,
            'ltv', v_ltv,
            'outstanding', v_outstanding,
            'health_score', ROUND(v_health_score, 1),
            'urgency_score', v_urgency_score,
            'urgency_level', v_urgency_level,
            'payment_pattern', jsonb_build_object(
                'total_invoiced', v_total_invoiced,
                'total_paid', v_total_paid,
                'invoice_count', v_invoice_count,
                'paid_on_time', v_paid_on_time_count,
                'collection_rate', CASE WHEN v_total_invoiced > 0
                    THEN ROUND((v_total_paid / v_total_invoiced * 100), 1)
                    ELSE 0
                END,
                'on_time_rate', CASE WHEN v_invoice_count > 0
                    THEN ROUND((v_paid_on_time_count::NUMERIC / v_invoice_count * 100), 1)
                    ELSE 0
                END
            ),
            'days_ahead', p_days_ahead
        ),
        'generated_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to generate cockpit summary',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

-- Grants (same as v1)
GRANT EXECUTE ON FUNCTION get_contact_cockpit_summary(UUID, UUID, BOOLEAN, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contact_cockpit_summary(UUID, UUID, BOOLEAN, INT) TO service_role;

COMMENT ON FUNCTION get_contact_cockpit_summary IS 'V2: Enhanced contact cockpit with multi-role contracts, CNAK status, real outstanding, invoices, urgency score, and payment pattern';
