-- ============================================================================
-- bbb-foundation/020_dashboard_block_centric.sql
-- Phase A: make the Group Sessions dashboard BLOCK-centric (not contract-centric).
-- ----------------------------------------------------------------------------
-- A "group session" = a catalog block whose config->>'audience'='group'
-- (m_cat_blocks). Its roster = the DISTINCT buyers of ACTIVE contracts that
-- carry that block (t_contract_blocks.source_block_id), scoped to is_live.
-- This replaces the earlier owner-contract model: identity is the block
-- (source_block_id), so one shared schedule/roster per block and multiple
-- member contracts hang off it. Reliable key is source_block_id — contract-level
-- category/audience markers drift (same block shows 'session' vs 'service').
--
-- Occurrences remain empty here (Phase B introduces the block-level schedule).
-- SECURITY DEFINER; RLS-on-no-policies. Idempotent / drift-safe.
-- ============================================================================

-- 1. sessions: one row per group-session BLOCK + block-scoped roster ----------
CREATE OR REPLACE FUNCTION gs_dash_sessions(p_tenant uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_total_roster int;
BEGIN
  -- distinct members across ALL group-session blocks (overview stat)
  SELECT count(DISTINCT c.buyer_id) INTO v_total_roster
  FROM t_contract_blocks cb
  JOIN t_contracts c   ON c.id = cb.contract_id
  JOIN m_cat_blocks b  ON b.id = cb.source_block_id
  WHERE c.tenant_id = p_tenant AND coalesce(c.is_live,true) = p_is_live
    AND c.status = 'active' AND b.config->>'audience' = 'group';

  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'block_id', blk.id,
      'name', coalesce(blk.name, 'Group Session'),
      'roster_size', (
        SELECT count(DISTINCT c2.buyer_id)
        FROM t_contract_blocks cb2
        JOIN t_contracts c2 ON c2.id = cb2.contract_id
        WHERE cb2.source_block_id = blk.id AND c2.tenant_id = p_tenant
          AND coalesce(c2.is_live,true) = p_is_live AND c2.status = 'active'
      ),
      -- occurrences / attendance / qr arrive in Phase B/C (block schedule + token)
      'occurrences_total', 0,
      'occurrences_done', 0,
      'next_occurrence', NULL,
      'qr_ready', false,
      'attendance_pct', NULL
    ) AS r
    FROM (
      SELECT DISTINCT b.id, b.name
      FROM t_contract_blocks cb
      JOIN t_contracts c  ON c.id = cb.contract_id
      JOIN m_cat_blocks b ON b.id = cb.source_block_id
      WHERE c.tenant_id = p_tenant AND coalesce(c.is_live,true) = p_is_live
        AND c.status = 'active' AND b.config->>'audience' = 'group'
    ) blk
  ) s;

  RETURN jsonb_build_object('sessions', v, 'roster_size', v_total_roster);
END $$;

-- 2. roster: distinct buyers of active contracts carrying the block -----------
-- New signature (adds p_is_live, p_block replaces p_contract) — drop the old one.
DROP FUNCTION IF EXISTS gs_dash_roster(uuid, uuid);

CREATE OR REPLACE FUNCTION gs_dash_roster(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb;
BEGIN
  SELECT coalesce(jsonb_agg(r ORDER BY r->>'name'), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'contact_id', m.buyer_id,
      'name', m.buyer_name,
      'membership_contract_id', m.contract_id,
      'contract_name', m.contract_name,
      'start_date', m.start_date,
      'end_date', m.end_date,
      -- attendance arrives in Phase B (block schedule + occurrence-linked attendance)
      'attended', 0,
      'dues_pending', exists(
        select 1 from t_contract_events be
        where be.contract_id = m.contract_id and be.event_type = 'billing'
          and coalesce(be.status,'') <> 'paid')
    ) AS r
    FROM (
      SELECT DISTINCT ON (c.buyer_id)
        c.buyer_id, c.buyer_name, c.id AS contract_id, c.name AS contract_name,
        c.start_date, c.end_date
      FROM t_contract_blocks cb
      JOIN t_contracts c ON c.id = cb.contract_id
      WHERE cb.source_block_id = p_block AND c.tenant_id = p_tenant
        AND coalesce(c.is_live,true) = p_is_live AND c.status = 'active'
      ORDER BY c.buyer_id, c.start_date DESC NULLS LAST
    ) m
  ) s;
  RETURN jsonb_build_object('roster', v);
END $$;

-- 3. occurrences: block-keyed; empty until Phase B builds the block schedule --
-- Rename p_contract -> p_block requires a drop (CREATE OR REPLACE can't rename).
DROP FUNCTION IF EXISTS gs_dash_occurrences(uuid, uuid);

CREATE OR REPLACE FUNCTION gs_dash_occurrences(p_tenant uuid, p_block uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  -- Phase B: read t_group_session_schedule for (p_tenant, p_block). None yet.
  RETURN jsonb_build_object('occurrences', '[]'::jsonb);
END $$;

GRANT EXECUTE ON FUNCTION gs_dash_sessions(uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_roster(uuid, uuid, boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_occurrences(uuid, uuid) TO authenticated, service_role;
