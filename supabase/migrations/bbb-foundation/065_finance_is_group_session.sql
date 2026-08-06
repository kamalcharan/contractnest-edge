-- ============================================================================
-- 065_finance_is_group_session.sql
-- Finance can separate group-session receivables from the rest
-- ============================================================================
-- ⚠️ ALREADY APPLIED TO LIVE on 6 Aug 2026. Source of record — do not re-run
-- (it is idempotent and returns early if the key is already present, but there
-- is no reason to).
--
-- WHY
-- ---
-- The Finance Worklist and the Group Sessions Dues grid are deliberately
-- different SHAPES answering different questions: a prioritised collections
-- queue ordered by who owes most, versus a month-by-month register of a
-- cohort's position across the year. Neither replaces the other.
--
-- What Finance lacked was any way to say which of its rows are group-session
-- membership fees, so the two surfaces could not be filtered apart or
-- reconciled by eye. This adds that one flag. It does NOT move the dues grid
-- into Finance, and it does not change any amount.
--
-- WHY NOT block_name, WHICH IS ALREADY IN THE PAYLOAD
-- ---------------------------------------------------
-- Because it is the wrong block. Billing events hang off the FEE block — on
-- BBB every event reads "BBB Yearly Cadance workout", and the group-session
-- block "Saturday Network Meeting" never appears in the receivables payload at
-- all. Filtering on block_name would be keying on the fee block by coincidence
-- and would break on any tenant that names its blocks differently.
--
-- A contract is a group-session contract when ANY of its blocks carries
-- config.audience = 'group' — the same test gs_dash_sessions uses to decide
-- what a group is. The flag is therefore a property of the CONTRACT, repeated
-- onto each of its events for the caller's convenience.
--
-- COST
-- ----
-- One correlated EXISTS per returned event. The payload is capped at 1000
-- events and t_contract_blocks is indexed on contract_id, so this is cheap at
-- present volumes. If the receivables payload ever grows a lot, hoist it into
-- the first_open_inv CTE (which is already per-contract) instead.
--
-- METHOD
-- ------
-- Substitute into the LIVE definition rather than retyping it (the 048/064
-- approach — retyping a 200-line function is how a second bug gets introduced
-- while fixing the first). Two guards, both learned the hard way here:
--
--   * The signature is read from pg_get_function_arguments rather than typed
--     out. It carries "p_is_live boolean DEFAULT true", and CREATE OR REPLACE
--     refuses to drop a parameter default — the first attempt at this migration
--     failed on exactly that.
--   * The rewrite is ASSERTED afterwards. A substitution whose literal does not
--     match is a SILENT no-op; migration 058 lost two of four rewrites that way
--     and nobody noticed until the messages went out wrong.
-- ============================================================================
DO $mig$
DECLARE
  v_src  text;
  v_args text;
  v_from text := E'        ''block_name'',         x.block_name,\n';
  v_to   text := E'        ''block_name'',         x.block_name,\n'
              || E'        ''is_group_session'',   EXISTS (SELECT 1 FROM t_contract_blocks gcb\n'
              || E'                                         WHERE gcb.contract_id = x.contract_id\n'
              || E'                                           AND gcb.custom_fields->''config''->>''audience'' = ''group''),\n';
BEGIN
  SELECT prosrc, pg_get_function_arguments(oid)
    INTO v_src, v_args
    FROM pg_proc WHERE proname = 'get_tenant_receivables';

  IF v_src IS NULL THEN
    RAISE EXCEPTION 'get_tenant_receivables not found';
  END IF;
  IF position('is_group_session' in v_src) > 0 THEN
    RAISE NOTICE 'is_group_session already present — nothing to do';
    RETURN;
  END IF;
  IF position(v_from in v_src) = 0 THEN
    RAISE EXCEPTION 'anchor not found — refusing to rewrite blind';
  END IF;

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION get_tenant_receivables(%s) '
    'RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS %L',
    v_args, replace(v_src, v_from, v_to)
  );

  SELECT prosrc INTO v_src FROM pg_proc WHERE proname = 'get_tenant_receivables';
  IF position('is_group_session' in v_src) = 0 THEN
    RAISE EXCEPTION 'rewrite did not land — is_group_session absent after CREATE OR REPLACE';
  END IF;
  RAISE NOTICE 'is_group_session added to get_tenant_receivables';
END
$mig$;

-- ── Verification run against live BBB after applying ────────────────────────
--   356 events, every one is_group_session = true  (BBB runs only the group
--   session, so an all-true result is expected and proves nothing on its own).
--   The predicate was therefore checked separately across tenants: Trinity
--   Tecnitions' 13 active contracts all evaluate false, so it discriminates.
--   Overdue totalled 105,000 — matching gs_dues_matrix's due_total exactly,
--   which is the point of migration 064's shared open-rule.
