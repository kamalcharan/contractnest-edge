-- ============================================================================
-- Migration 043: Fix buyer access for contracts list + stats
-- ============================================================================


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 1: get_contracts_list — add accessor (buyer) visibility
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_contracts_list(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true,
    p_record_type VARCHAR DEFAULT NULL,
    p_contract_type VARCHAR DEFAULT NULL,
    p_status VARCHAR DEFAULT NULL,
    p_search VARCHAR DEFAULT NULL,
    p_page INTEGER DEFAULT 1,
    p_per_page INTEGER DEFAULT 20,
    p_sort_by VARCHAR DEFAULT 'created_at',
    p_sort_order VARCHAR DEFAULT 'desc'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_total INTEGER;
    v_total_pages INTEGER;
    v_offset INTEGER;
    v_contracts JSONB;
    v_query TEXT;
    v_count_query TEXT;
    v_where TEXT := '';
    v_order TEXT;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    p_page := GREATEST(p_page, 1);
    p_per_page := LEAST(GREATEST(p_per_page, 1), 100);
    v_offset := (p_page - 1) * p_per_page;

    -- KEY FIX: owner OR accessor
    v_where := format(
        'WHERE c.is_live = %L AND c.is_active = true AND (
            c.tenant_id = %L
            OR EXISTS (
                SELECT 1 FROM t_contract_access ca
                WHERE ca.contract_id = c.id
                  AND ca.accessor_tenant_id = %L
                  AND ca.is_active = true
                  AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
            )
        )',
        p_is_live, p_tenant_id, p_tenant_id
    );

    IF p_record_type IS NOT NULL THEN
        v_where := v_where || format(' AND c.record_type = %L', p_record_type);
    END IF;
    IF p_contract_type IS NOT NULL THEN
        v_where := v_where || format(' AND c.contract_type = %L', p_contract_type);
    END IF;
    IF p_status IS NOT NULL THEN
        v_where := v_where || format(' AND c.status = %L', p_status);
    END IF;
    IF p_search IS NOT NULL AND TRIM(p_search) <> '' THEN
        v_where := v_where || format(
            ' AND (c.name ILIKE %L OR c.contract_number ILIKE %L OR c.rfq_number ILIKE %L OR c.buyer_name ILIKE %L)',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%',
            '%' || TRIM(p_search) || '%'
        );
    END IF;

    v_order := CASE p_sort_by
        WHEN 'name' THEN 'c.name'
        WHEN 'status' THEN 'c.status'
        WHEN 'total_value' THEN 'c.total_value'
        WHEN 'grand_total' THEN 'c.grand_total'
        ELSE 'c.created_at'
    END;
    v_order := v_order || CASE WHEN LOWER(p_sort_order) = 'asc' THEN ' ASC' ELSE ' DESC' END;

    v_count_query := 'SELECT COUNT(*) FROM t_contracts c ' || v_where;
    EXECUTE v_count_query INTO v_total;
    v_total_pages := CEIL(v_total::NUMERIC / p_per_page);

    v_query := format(
        'SELECT COALESCE(jsonb_agg(row_data ORDER BY rn), ''[]''::JSONB)
         FROM (
             SELECT
                 ROW_NUMBER() OVER (ORDER BY %s) as rn,
                 jsonb_build_object(
                     ''id'', c.id,
                     ''tenant_id'', c.tenant_id,
                     ''seller_id'', c.seller_id,
                     ''buyer_tenant_id'', c.buyer_tenant_id,
                     ''contract_number'', c.contract_number,
                     ''rfq_number'', c.rfq_number,
                     ''record_type'', c.record_type,
                     ''contract_type'', c.contract_type,
                     ''name'', c.name,
                     ''description'', c.description,
                     ''status'', c.status,
                     ''buyer_id'', c.buyer_id,
                     ''buyer_name'', c.buyer_name,
                     ''buyer_company'', c.buyer_company,
                     ''acceptance_method'', c.acceptance_method,
                     ''global_access_id'', c.global_access_id,
                     ''duration_value'', c.duration_value,
                     ''duration_unit'', c.duration_unit,
                     ''currency'', c.currency,
                     ''billing_cycle_type'', c.billing_cycle_type,
                     ''total_value'', c.total_value,
                     ''grand_total'', c.grand_total,
                     ''sent_at'', c.sent_at,
                     ''accepted_at'', c.accepted_at,
                     ''version'', c.version,
                     ''created_by'', c.created_by,
                     ''created_at'', c.created_at,
                     ''updated_at'', c.updated_at,
                     ''blocks_count'', (
                         SELECT COUNT(*)
                         FROM t_contract_blocks cb
                         WHERE cb.contract_id = c.id
                     ),
                     ''vendors_count'', (
                         SELECT COUNT(*)
                         FROM t_contract_vendors cv
                         WHERE cv.contract_id = c.id
                     ),
                     ''contact_classification'', c.contact_classification
                 ) AS row_data
             FROM t_contracts c
             %s
             ORDER BY %s
             LIMIT %s OFFSET %s
         ) sub',
        v_order, v_where, v_order, p_per_page, v_offset
    );

    EXECUTE v_query INTO v_contracts;

    RETURN jsonb_build_object(
        'success', true,
        'data', COALESCE(v_contracts, '[]'::JSONB),
        'pagination', jsonb_build_object(
            'page', p_page,
            'per_page', p_per_page,
            'total', v_total,
            'total_pages', v_total_pages
        ),
        'filters', jsonb_build_object(
            'record_type', p_record_type,
            'contract_type', p_contract_type,
            'status', p_status,
            'search', p_search,
            'sort_by', p_sort_by,
            'sort_order', p_sort_order
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contracts',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contracts_list(UUID, BOOLEAN, VARCHAR, VARCHAR, VARCHAR, VARCHAR, INTEGER, INTEGER, VARCHAR, VARCHAR) TO service_role;


-- ═══════════════════════════════════════════════════════════════════════════
-- PART 2: get_contract_stats — add accessor (buyer) visibility
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION get_contract_stats(
    p_tenant_id UUID,
    p_is_live BOOLEAN DEFAULT true
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_by_status JSONB;
    v_by_record_type JSONB;
    v_by_contract_type JSONB;
    v_totals RECORD;
BEGIN
    IF p_tenant_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'tenant_id is required');
    END IF;

    SELECT COALESCE(jsonb_object_agg(status, cnt), '{}'::JSONB)
    INTO v_by_status
    FROM (
        SELECT status, COUNT(*) AS cnt
        FROM t_contracts c
        WHERE c.is_live = p_is_live AND c.is_active = true
          AND (
              c.tenant_id = p_tenant_id
              OR EXISTS (
                  SELECT 1 FROM t_contract_access ca
                  WHERE ca.contract_id = c.id
                    AND ca.accessor_tenant_id = p_tenant_id
                    AND ca.is_active = true
                    AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
              )
          )
        GROUP BY status
    ) sub;

    SELECT COALESCE(jsonb_object_agg(record_type, cnt), '{}'::JSONB)
    INTO v_by_record_type
    FROM (
        SELECT record_type, COUNT(*) AS cnt
        FROM t_contracts c
        WHERE c.is_live = p_is_live AND c.is_active = true
          AND (
              c.tenant_id = p_tenant_id
              OR EXISTS (
                  SELECT 1 FROM t_contract_access ca
                  WHERE ca.contract_id = c.id
                    AND ca.accessor_tenant_id = p_tenant_id
                    AND ca.is_active = true
                    AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
              )
          )
        GROUP BY record_type
    ) sub;

    SELECT COALESCE(jsonb_object_agg(contract_type, cnt), '{}'::JSONB)
    INTO v_by_contract_type
    FROM (
        SELECT contract_type, COUNT(*) AS cnt
        FROM t_contracts c
        WHERE c.is_live = p_is_live AND c.is_active = true
          AND (
              c.tenant_id = p_tenant_id
              OR EXISTS (
                  SELECT 1 FROM t_contract_access ca
                  WHERE ca.contract_id = c.id
                    AND ca.accessor_tenant_id = p_tenant_id
                    AND ca.is_active = true
                    AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
              )
          )
        GROUP BY contract_type
    ) sub;

    SELECT
        COUNT(*) AS total_count,
        COALESCE(SUM(total_value), 0) AS sum_total_value,
        COALESCE(SUM(grand_total), 0) AS sum_grand_total,
        COALESCE(SUM(CASE WHEN status = 'active' THEN grand_total ELSE 0 END), 0) AS active_value,
        COALESCE(SUM(CASE WHEN status = 'draft' THEN grand_total ELSE 0 END), 0) AS draft_value
    INTO v_totals
    FROM t_contracts c
    WHERE c.is_live = p_is_live AND c.is_active = true
      AND (
          c.tenant_id = p_tenant_id
          OR EXISTS (
              SELECT 1 FROM t_contract_access ca
              WHERE ca.contract_id = c.id
                AND ca.accessor_tenant_id = p_tenant_id
                AND ca.is_active = true
                AND (ca.expires_at IS NULL OR ca.expires_at > NOW())
          )
      );

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'total_count', v_totals.total_count,
            'by_status', v_by_status,
            'by_record_type', v_by_record_type,
            'by_contract_type', v_by_contract_type,
            'financials', jsonb_build_object(
                'total_value', v_totals.sum_total_value,
                'grand_total', v_totals.sum_grand_total,
                'active_value', v_totals.active_value,
                'draft_value', v_totals.draft_value
            )
        ),
        'retrieved_at', NOW()
    );

EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object(
        'success', false,
        'error', 'Failed to fetch contract stats',
        'details', SQLERRM,
        'error_code', SQLSTATE
    );
END;
$$;

GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION get_contract_stats(UUID, BOOLEAN) TO service_role;
