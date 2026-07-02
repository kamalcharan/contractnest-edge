-- ============================================================================
-- VaNi Agent — Migration 001: vn_interaction_log
-- ============================================================================
-- Purpose: Capture every VaNi LLM interaction as future fine-tuning data
--          (Vikuna LLM Strategy v1.0 §3). Written by contractnest-api via
--          SECURITY DEFINER RPCs only — the table has RLS enabled with NO
--          policies, so the Data API (anon/authenticated) cannot touch it
--          directly.
--
-- ⚠️ OWNER-APPLIED ONLY. Review before running. This migration only CREATES
--    new objects — it does not alter grants, RLS, or policies on any
--    existing table.
-- ============================================================================

-- ─── Table ───

CREATE TABLE IF NOT EXISTS vn_interaction_log (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  product           TEXT NOT NULL DEFAULT 'contractnest',  -- 'dristiq' | 'ki_prime' | 'contractnest'
  tenant_id         UUID,
  session_id        UUID,
  user_id           UUID,

  -- LLM call
  system_prompt     TEXT,
  user_input        TEXT NOT NULL,
  context_payload   JSONB,                -- compact structured context (incl. "skill")
  llm_response      TEXT NOT NULL,
  model_version     TEXT,                 -- 'qwen3-4b-q4km' | 'vikuna-llm-1.0' | ...

  -- Quality signals (the fine-tuning gold)
  user_rating       SMALLINT CHECK (user_rating BETWEEN 1 AND 5),
  was_edited        BOOLEAN DEFAULT FALSE,
  edited_response   TEXT,                 -- gold standard if the user corrected the output
  follow_up_query   TEXT,                 -- signals confusion / dissatisfaction
  was_accepted      BOOLEAN,              -- user acted on the response

  -- Performance
  prompt_tokens     INT,
  completion_tokens INT,
  latency_ms        INT,
  endpoint          TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Indexes for the monthly export pipeline (strategy doc §5.1)
CREATE INDEX IF NOT EXISTS idx_vil_product ON vn_interaction_log(product);
CREATE INDEX IF NOT EXISTS idx_vil_quality ON vn_interaction_log(user_rating, was_edited);
CREATE INDEX IF NOT EXISTS idx_vil_created ON vn_interaction_log(created_at);
CREATE INDEX IF NOT EXISTS idx_vil_tenant  ON vn_interaction_log(tenant_id);

-- Lock the table down: RLS on, no policies → no direct Data-API access.
-- (New table only; nothing existing is affected.)
ALTER TABLE vn_interaction_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON vn_interaction_log FROM anon, authenticated;

-- ─── RPC: insert one interaction ───

CREATE OR REPLACE FUNCTION log_vani_interaction(
  p_id                UUID,
  p_product           TEXT,
  p_tenant_id         UUID,
  p_session_id        UUID,
  p_user_id           UUID,
  p_system_prompt     TEXT,
  p_user_input        TEXT,
  p_context_payload   JSONB,
  p_llm_response      TEXT,
  p_model_version     TEXT,
  p_prompt_tokens     INT,
  p_completion_tokens INT,
  p_latency_ms        INT,
  p_endpoint          TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO vn_interaction_log (
    id, product, tenant_id, session_id, user_id,
    system_prompt, user_input, context_payload, llm_response, model_version,
    prompt_tokens, completion_tokens, latency_ms, endpoint
  ) VALUES (
    COALESCE(p_id, gen_random_uuid()), COALESCE(p_product, 'contractnest'),
    p_tenant_id, p_session_id, p_user_id,
    p_system_prompt, p_user_input, p_context_payload, p_llm_response, p_model_version,
    p_prompt_tokens, p_completion_tokens, p_latency_ms, p_endpoint
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN p_id;
END;
$$;

-- ─── RPC: record quality signals (thumbs / edit / accept / follow-up) ───

CREATE OR REPLACE FUNCTION vani_interaction_feedback(
  p_id              UUID,
  p_user_rating     SMALLINT,
  p_was_edited      BOOLEAN,
  p_edited_response TEXT,
  p_was_accepted    BOOLEAN,
  p_follow_up_query TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_found BOOLEAN;
BEGIN
  UPDATE vn_interaction_log SET
    user_rating     = COALESCE(p_user_rating, user_rating),
    was_edited      = COALESCE(p_was_edited, was_edited),
    edited_response = COALESCE(p_edited_response, edited_response),
    was_accepted    = COALESCE(p_was_accepted, was_accepted),
    follow_up_query = COALESCE(p_follow_up_query, follow_up_query),
    updated_at      = now()
  WHERE id = p_id;

  GET DIAGNOSTICS v_found = ROW_COUNT;
  RETURN v_found;
END;
$$;

-- The API layer authenticates with the anon key (auditService pattern),
-- so both roles need EXECUTE. The functions expose no read path.
GRANT EXECUTE ON FUNCTION log_vani_interaction(UUID, TEXT, UUID, UUID, UUID, TEXT, TEXT, JSONB, TEXT, TEXT, INT, INT, INT, TEXT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION vani_interaction_feedback(UUID, SMALLINT, BOOLEAN, TEXT, BOOLEAN, TEXT) TO anon, authenticated;

COMMENT ON TABLE vn_interaction_log IS 'VaNi LLM interaction log — fine-tuning data flywheel (Vikuna LLM Strategy v1.0). Write path: SECURITY DEFINER RPCs only.';
