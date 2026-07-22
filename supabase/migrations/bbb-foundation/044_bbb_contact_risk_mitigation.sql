-- BBB tenant risk mitigation: corrupt every stored mobile number and email
-- address so that even if a future bug bypasses every send-blocking layer
-- built earlier today (n_jtd_tenant_config, jtd-worker guardrails, the
-- Settings > Integrations toggle), any accidental send would fail to
-- reach a real inbox/phone. Owner-requested, explicitly scoped to BOTH
-- environments (test AND live) and explicitly reversible.
--
-- Transformation: append the value's own last character twice (matches
-- the owner's example verbatim: "gmail.com" -> "gmail.commm" — "m" is the
-- last char of "com", appended twice; the same rule applied to a mobile
-- number adds 2 digits, e.g. "...950" -> "...95000").
--
-- Scope note: t_contracts.buyer_email / buyer_phone (a snapshot field
-- some notification paths read before falling back to a live contact-
-- channel lookup) were checked and are empty for BBB's only contract —
-- nothing to corrupt there. t_contact_channels is the canonical source
-- every path ultimately falls back to, so it's the complete fix for this
-- tenant's current data.

CREATE TABLE IF NOT EXISTS t_contact_channel_risk_backup (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id uuid NOT NULL REFERENCES t_contact_channels(id),
  tenant_id uuid NOT NULL,
  channel_type text NOT NULL,
  original_value text NOT NULL,
  corrupted_value text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  restored_at timestamptz
);

-- Back up + corrupt in one pass. NOT EXISTS guard makes this safe to
-- re-run (won't back up an already-corrupted value as if it were
-- original, and won't double-corrupt).
WITH targets AS (
  SELECT ch.id AS channel_id, c.tenant_id, ch.channel_type, ch.value AS original_value,
    ch.value || right(ch.value, 1) || right(ch.value, 1) AS corrupted_value
  FROM t_contact_channels ch
  JOIN t_contacts c ON c.id = ch.contact_id
  WHERE c.tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f'
    AND ch.channel_type IN ('mobile', 'email')
    AND ch.value IS NOT NULL AND ch.value <> ''
    AND NOT EXISTS (
      SELECT 1 FROM t_contact_channel_risk_backup b
      WHERE b.channel_id = ch.id AND b.restored_at IS NULL
    )
),
backed_up AS (
  INSERT INTO t_contact_channel_risk_backup (channel_id, tenant_id, channel_type, original_value, corrupted_value)
  SELECT channel_id, tenant_id, channel_type, original_value, corrupted_value FROM targets
  RETURNING channel_id, corrupted_value
)
UPDATE t_contact_channels ch
SET value = b.corrupted_value, updated_at = now()
FROM backed_up b
WHERE ch.id = b.channel_id;

-- ═══════════════════════════════════════════════════════════════════
-- TO REVERSE (once BBB is confirmed ready for real messaging again):
--
-- UPDATE t_contact_channels ch
-- SET value = b.original_value, updated_at = now()
-- FROM t_contact_channel_risk_backup b
-- WHERE ch.id = b.channel_id
--   AND b.tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f'
--   AND b.restored_at IS NULL;
--
-- UPDATE t_contact_channel_risk_backup
-- SET restored_at = now()
-- WHERE tenant_id = 'dd194710-92b4-4110-80eb-0b492a0d2c1f' AND restored_at IS NULL;
-- ═══════════════════════════════════════════════════════════════════
