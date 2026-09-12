-- msg91_inbound_raw_capture.sql — APPLIED LIVE 2026-09-03 (source-of-record).
-- Durable capture of every payload posted to the msg91-webhook edge function
-- (delivery reports, inbound messages, Flow nfm_reply responses). Console
-- logs are ephemeral; this table is the observable record used to tighten
-- the extractor and to close the WhatsApp Flows POC.
CREATE TABLE IF NOT EXISTS n_webhook_inbound_raw (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source       text NOT NULL DEFAULT 'msg91',
    received_at  timestamptz NOT NULL DEFAULT now(),
    content_type text,
    body_raw     text,
    parsed       jsonb
);
CREATE INDEX IF NOT EXISTS ix_webhook_inbound_raw_received ON n_webhook_inbound_raw (received_at DESC);
ALTER TABLE n_webhook_inbound_raw ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE n_webhook_inbound_raw IS
  'Raw webhook payload capture (msg91-webhook v2+). No policies on purpose — service-role only.';
