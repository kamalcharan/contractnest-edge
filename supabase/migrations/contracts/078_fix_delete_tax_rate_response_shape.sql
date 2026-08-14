-- ═══════════════════════════════════════════════════════════════
-- Migration 078: Fix delete_tax_rate_atomic response shape
-- ═══════════════════════════════════════════════════════════════
-- ROOT CAUSE: migration 077's delete_tax_rate_atomic returned
-- {deletedRate: {...}} only. contractnest-api's taxSettingsService.
-- deleteTaxRate (services/taxSettingsService.ts:210) requires BOTH
-- response.data.success and response.data.deletedRate to be truthy,
-- else it throws 'Invalid delete response format' itself — even
-- though the edge function call succeeded and the row was already
-- soft-deleted in the database. Surfaced as "Delete Failed: Invalid
-- delete response format" in the UI, and because the row really was
-- deleted despite the error, a second click on the same row then hit
-- the (correct) "Tax rate is already deleted" guard, compounding the
-- confusion. The API's return type annotation
-- (Promise<{ success: boolean; message: string; deletedRate: {...} }>)
-- shows this was always the intended shape — 077 just didn't match it.
--
-- No changes needed to create_tax_rate_atomic / update_tax_rate_atomic:
-- the API's validateTaxRate() only requires fields both already return
-- (id, tenant_id, name, rate, is_active, sequence_no, version),
-- verified against the same live test data used to confirm 077.
-- ═══════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION delete_tax_rate_atomic(
    p_tenant_id UUID,
    p_rate_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_current RECORD;
    v_deleted RECORD;
BEGIN
    SELECT * INTO v_current
    FROM t_tax_rates
    WHERE id = p_rate_id AND tenant_id = p_tenant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tax rate not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_current.is_active = false THEN
        RAISE EXCEPTION 'Tax rate is already deleted';
    END IF;

    IF v_current.is_default = true THEN
        RAISE EXCEPTION 'Cannot delete the default tax rate. Please set another rate as default first.';
    END IF;

    UPDATE t_tax_rates
    SET is_active = false, version = version + 1, updated_at = now()
    WHERE id = p_rate_id
    RETURNING * INTO v_deleted;

    RETURN jsonb_build_object(
        'success', true,
        'message', 'Tax rate deleted successfully',
        'deletedRate', to_jsonb(v_deleted)
    );
END;
$$;

GRANT EXECUTE ON FUNCTION delete_tax_rate_atomic(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION delete_tax_rate_atomic(UUID, UUID) TO service_role;
