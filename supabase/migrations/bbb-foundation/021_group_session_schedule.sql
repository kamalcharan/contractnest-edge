-- ============================================================================
-- bbb-foundation/021_group_session_schedule.sql
-- Phase B: ONE shared schedule per group-session block (not per member contract).
-- ----------------------------------------------------------------------------
-- t_group_session_schedule holds the dated occurrences for a block, keyed by
-- (tenant, source_block_id, is_live). Generated from the block's cadence
-- (m_cat_blocks.config.serviceCycles: days + anchorWeekday). Because it lives in
-- ONE place, a holiday reschedule is a single-row edit that every member sees —
-- exactly the requirement. Members' contracts still carry billing only.
--
-- RPCs: gs_generate_schedule, gs_schedule_move / _status / _add, gs_renumber.
-- gs_dash_occurrences now reads this table; gs_dash_sessions aggregates from it.
-- SECURITY DEFINER; RLS enabled with no policies (RPC-only). Idempotent.
-- Attendance links to these occurrences in Phase C (present stays 0 here).
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.t_group_session_schedule (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id       uuid NOT NULL,
  source_block_id uuid NOT NULL,
  is_live         boolean NOT NULL DEFAULT true,
  occurrence_date date NOT NULL,
  seq             int,
  status          text NOT NULL DEFAULT 'scheduled'
                    CHECK (status IN ('scheduled','held','skipped','cancelled')),
  note            text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tenant_id, source_block_id, is_live, occurrence_date)
);
CREATE INDEX IF NOT EXISTS ix_gss_block
  ON public.t_group_session_schedule (tenant_id, source_block_id, is_live, occurrence_date);
ALTER TABLE public.t_group_session_schedule ENABLE ROW LEVEL SECURITY;

-- renumber seq by date (cancelled rows get null seq) --------------------------
CREATE OR REPLACE FUNCTION gs_renumber_schedule(p_tenant uuid, p_block uuid, p_is_live boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  WITH ordered AS (
    SELECT id, row_number() OVER (ORDER BY occurrence_date) AS rn
    FROM t_group_session_schedule
    WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live
      AND status <> 'cancelled')
  UPDATE t_group_session_schedule s SET seq = o.rn, updated_at = now()
  FROM ordered o WHERE s.id = o.id;
  UPDATE t_group_session_schedule
    SET seq = NULL
  WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live AND status='cancelled';
END $$;

-- occurrences for the dashboard (reads the shared schedule) -------------------
DROP FUNCTION IF EXISTS gs_dash_occurrences(uuid, uuid);
CREATE OR REPLACE FUNCTION gs_dash_occurrences(p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_total int;
BEGIN
  SELECT count(*) INTO v_total FROM t_group_session_schedule
   WHERE tenant_id=p_tenant AND source_block_id=p_block AND is_live=p_is_live AND status<>'cancelled';
  SELECT coalesce(jsonb_agg(r ORDER BY (r->>'date')), '[]'::jsonb) INTO v FROM (
    SELECT jsonb_build_object(
      'event_id', s.id,
      'date', s.occurrence_date,
      'seq', s.seq, 'total', v_total,
      'status', s.status,
      'is_past', s.occurrence_date < current_date,
      'note', s.note,
      'present', 0   -- attendance links to the schedule occurrence in Phase C
    ) AS r
    FROM t_group_session_schedule s
    WHERE s.tenant_id=p_tenant AND s.source_block_id=p_block AND s.is_live=p_is_live
  ) x;
  RETURN jsonb_build_object('occurrences', v);
END $$;

-- generate the schedule from the block cadence --------------------------------
CREATE OR REPLACE FUNCTION gs_generate_schedule(
  p_tenant uuid, p_block uuid, p_is_live boolean DEFAULT true,
  p_start date DEFAULT NULL, p_end date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_cfg jsonb; v_days int; v_anchor int; v_start date; v_end date; v_first date; v_d date;
BEGIN
  SELECT config->'serviceCycles' INTO v_cfg FROM m_cat_blocks WHERE id=p_block;
  v_days := coalesce((v_cfg->>'days')::int, 14);
  IF v_days < 1 THEN v_days := 14; END IF;
  v_anchor := (v_cfg->>'anchorWeekday')::int;  -- 0=Sun..6=Sat; may be null

  -- default window from the block's active contracts
  SELECT coalesce(p_start, min(c.start_date)::date),
         coalesce(p_end,   max(c.end_date)::date)
    INTO v_start, v_end
  FROM t_contract_blocks cb JOIN t_contracts c ON c.id=cb.contract_id
  WHERE cb.source_block_id=p_block AND c.tenant_id=p_tenant
    AND coalesce(c.is_live,true)=p_is_live AND c.status='active';

  v_start := coalesce(v_start, current_date);
  v_end   := coalesce(v_end, v_start + 365);

  -- align first occurrence to the anchor weekday
  IF v_anchor IS NOT NULL THEN
    v_first := v_start + ((v_anchor - extract(dow from v_start)::int + 7) % 7);
  ELSE
    v_first := v_start;
  END IF;

  v_d := v_first;
  WHILE v_d <= v_end LOOP
    INSERT INTO t_group_session_schedule (tenant_id, source_block_id, is_live, occurrence_date)
    VALUES (p_tenant, p_block, p_is_live, v_d)
    ON CONFLICT (tenant_id, source_block_id, is_live, occurrence_date) DO NOTHING;
    v_d := v_d + v_days;
  END LOOP;

  PERFORM gs_renumber_schedule(p_tenant, p_block, p_is_live);
  RETURN gs_dash_occurrences(p_tenant, p_block, p_is_live);
END $$;

-- move one occurrence to a new date (holiday reschedule) ----------------------
CREATE OR REPLACE FUNCTION gs_schedule_move(p_tenant uuid, p_id uuid, p_new_date date, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_block uuid; v_live boolean;
BEGIN
  SELECT source_block_id, is_live INTO v_block, v_live
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  UPDATE t_group_session_schedule
    SET occurrence_date=p_new_date, note=coalesce(p_note, note), updated_at=now()
  WHERE id=p_id AND tenant_id=p_tenant;
  PERFORM gs_renumber_schedule(p_tenant, v_block, v_live);
  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $$;

-- change one occurrence's status (skip / cancel / restore / held) -------------
CREATE OR REPLACE FUNCTION gs_schedule_status(p_tenant uuid, p_id uuid, p_status text, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v_block uuid; v_live boolean;
BEGIN
  IF p_status NOT IN ('scheduled','held','skipped','cancelled') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'bad_status');
  END IF;
  SELECT source_block_id, is_live INTO v_block, v_live
  FROM t_group_session_schedule WHERE id=p_id AND tenant_id=p_tenant;
  IF v_block IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'not_found'); END IF;
  UPDATE t_group_session_schedule
    SET status=p_status, note=coalesce(p_note, note), updated_at=now()
  WHERE id=p_id AND tenant_id=p_tenant;
  PERFORM gs_renumber_schedule(p_tenant, v_block, v_live);
  RETURN gs_dash_occurrences(p_tenant, v_block, v_live);
END $$;

-- add an ad-hoc occurrence ----------------------------------------------------
CREATE OR REPLACE FUNCTION gs_schedule_add(p_tenant uuid, p_block uuid, p_is_live boolean, p_date date, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
BEGIN
  INSERT INTO t_group_session_schedule (tenant_id, source_block_id, is_live, occurrence_date, note)
  VALUES (p_tenant, p_block, p_is_live, p_date, p_note)
  ON CONFLICT (tenant_id, source_block_id, is_live, occurrence_date) DO NOTHING;
  PERFORM gs_renumber_schedule(p_tenant, p_block, p_is_live);
  RETURN gs_dash_occurrences(p_tenant, p_block, p_is_live);
END $$;

-- sessions overview now aggregates from the shared schedule -------------------
CREATE OR REPLACE FUNCTION gs_dash_sessions(p_tenant uuid, p_is_live boolean DEFAULT true)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE v jsonb; v_total_roster int;
BEGIN
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
      'occurrences_total', (
        SELECT count(*) FROM t_group_session_schedule s
        WHERE s.tenant_id=p_tenant AND s.source_block_id=blk.id AND s.is_live=p_is_live
          AND s.status<>'cancelled'),
      'occurrences_done', (
        SELECT count(*) FROM t_group_session_schedule s
        WHERE s.tenant_id=p_tenant AND s.source_block_id=blk.id AND s.is_live=p_is_live
          AND s.status<>'cancelled' AND s.occurrence_date < current_date),
      'next_occurrence', (
        SELECT min(s.occurrence_date) FROM t_group_session_schedule s
        WHERE s.tenant_id=p_tenant AND s.source_block_id=blk.id AND s.is_live=p_is_live
          AND s.status='scheduled' AND s.occurrence_date >= current_date),
      'qr_ready', false,          -- Phase C (token per block)
      'attendance_pct', NULL      -- Phase C (attendance linked to schedule)
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

GRANT EXECUTE ON FUNCTION gs_renumber_schedule(uuid,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_occurrences(uuid,uuid,boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_generate_schedule(uuid,uuid,boolean,date,date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_schedule_move(uuid,uuid,date,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_schedule_status(uuid,uuid,text,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_schedule_add(uuid,uuid,boolean,date,text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION gs_dash_sessions(uuid,boolean) TO authenticated, service_role;
