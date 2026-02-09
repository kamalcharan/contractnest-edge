-- ============================================================================
-- Migration 028: Audit Log RPC Functions
-- ============================================================================
-- Purpose: Query audit log entries with filtering and pagination
--
-- RPCs:
--   get_audit_log — Paginated, filterable by contract, category, entity, date
--
-- Depends on: 025 (t_audit_log)
-- ============================================================================


-- ============================================================================
-- RPC: get_audit_log
-- Paginated query with category/entity/date filters for contract-level audit
-- ============================================================================
CREATE OR REPLACE FUNCTION get_audit_log(
    p_tenant_id     UUID,
    p_contract_id   UUID DEFAULT NULL,
    p_entity_type   TEXT DEFAULT NULL,
    p_entity_id     UUID DEFAULT NULL,
    p_category      TEXT DEFAULT NULL,
    p_performed_by  UUID DEFAULT NULL,
    p_date_from     TEXT DEFAULT NULL,
    p_date_to       TEXT DEFAULT NULL,
    p_page          INT DEFAULT 1,
    p_per_page      INT DEFAULT 20
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_offset    INT;
    v_total     INT;
    v_result    JSONB;
BEGIN
    v_offset := (GREATEST(p_page, 1) - 1) * p_per_page;

    -- Count total matching
    SELECT COUNT(*) INTO v_total
    FROM t_audit_log al
    WHERE al.tenant_id = p_tenant_id
      AND (p_contract_id IS NULL OR al.contract_id = p_contract_id)
      AND (p_entity_type IS NULL OR al.entity_type = p_entity_type)
      AND (p_entity_id IS NULL OR al.entity_id = p_entity_id)
      AND (p_category IS NULL OR al.category = p_category)
      AND (p_performed_by IS NULL OR al.performed_by = p_performed_by)
      AND (p_date_from IS NULL OR al.created_at >= p_date_from::TIMESTAMPTZ)
      AND (p_date_to IS NULL OR al.created_at <= p_date_to::TIMESTAMPTZ);

    -- Fetch page
    SELECT jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'entries', COALESCE(jsonb_agg(entry_row ORDER BY entry_row->>'created_at' DESC), '[]'::jsonb),
            'pagination', jsonb_build_object(
                'page', p_page,
                'per_page', p_per_page,
                'total', v_total,
                'total_pages', CEIL(v_total::NUMERIC / p_per_page)
            ),
            'category_counts', (
                SELECT jsonb_object_agg(cat, cnt)
                FROM (
                    SELECT category AS cat, COUNT(*) AS cnt
                    FROM t_audit_log
                    WHERE tenant_id = p_tenant_id
                      AND (p_contract_id IS NULL OR contract_id = p_contract_id)
                    GROUP BY category
                ) cc
            )
        )
    ) INTO v_result
    FROM (
        SELECT jsonb_build_object(
            'id', al.id,
            'entity_type', al.entity_type,
            'entity_id', al.entity_id,
            'contract_id', al.contract_id,
            'category', al.category,
            'action', al.action,
            'description', al.description,
            'old_value', al.old_value,
            'new_value', al.new_value,
            'performed_by', al.performed_by,
            'performed_by_name', al.performed_by_name,
            'created_at', al.created_at
        ) AS entry_row
        FROM t_audit_log al
        WHERE al.tenant_id = p_tenant_id
          AND (p_contract_id IS NULL OR al.contract_id = p_contract_id)
          AND (p_entity_type IS NULL OR al.entity_type = p_entity_type)
          AND (p_entity_id IS NULL OR al.entity_id = p_entity_id)
          AND (p_category IS NULL OR al.category = p_category)
          AND (p_performed_by IS NULL OR al.performed_by = p_performed_by)
          AND (p_date_from IS NULL OR al.created_at >= p_date_from::TIMESTAMPTZ)
          AND (p_date_to IS NULL OR al.created_at <= p_date_to::TIMESTAMPTZ)
        ORDER BY al.created_at DESC
        LIMIT p_per_page OFFSET v_offset
    ) sub;

    RETURN COALESCE(v_result, jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'entries', '[]'::jsonb,
            'pagination', jsonb_build_object('page', p_page, 'per_page', p_per_page, 'total', 0, 'total_pages', 0),
            'category_counts', '{}'::jsonb
        )
    ));

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM, 'code', 'RPC_ERROR');
END;
$$;
