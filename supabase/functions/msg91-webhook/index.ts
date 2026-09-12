// supabase/functions/msg91-webhook/index.ts
//
// Delivery-status receiver for MSG91 (WhatsApp, SMS, Email).
//
// WHY THIS EXISTS
// ---------------
// Until now nothing ever moved an n_jtd row past status='sent'. 'sent' only
// means MSG91 ACCEPTED the request and returned a request_id — it says nothing
// about whether WhatsApp actually delivered the message. On 4 Aug 2026 two
// templates (attendance_ack, payment_thankyou) were found to have been failing
// silently since 1 Aug: every row read 'sent', every message was rejected by
// WhatsApp on delivery with "Parameter name is missing or empty". The only
// reason it surfaced was a human checking a handset.
//
// This endpoint closes that blind spot: MSG91 posts delivery events here, and
// we move the row to delivered / read / failed accordingly.
//
// v2 (2026-09-03): DURABLE RAW CAPTURE. Every payload posted here — delivery
// reports, inbound messages, Flow responses (nfm_reply) — is stored verbatim
// in n_webhook_inbound_raw before any processing. Console logs are ephemeral;
// the table is the observable record the extractor gets tightened against.
// Added for the WhatsApp Flows POC (service-proof Flow submissions must land
// somewhere queryable) and permanently useful for T2 inbound handling.
//
// PAYLOAD SHAPE — DELIBERATELY TOLERANT
// -------------------------------------
// MSG91's exact webhook body for WhatsApp has never been observed in this
// system. The MSG91WhatsAppWebhook interface in jtd-worker/handlers/whatsapp.ts
// is a guess that has never been exercised, and building strictly against a
// guess would just replace one silent failure with another.
//
// So this handler does NOT assume a shape. It walks the entire JSON body,
// collects every object that carries something id-like AND something
// status-like, and acts on each. It logs the raw body on every call. Once a
// real payload has been observed, this can be tightened to exact paths — but
// it will keep working either way.
//
// STATUS IS MONOTONIC
// -------------------
// Delivery callbacks can arrive out of order (a late 'delivered' after 'read'
// is common). Statuses are ranked and a row is only ever moved FORWARD, so a
// stale callback cannot walk a message backwards. 'failed' is allowed from any
// non-terminal state.
//
// AUTH
// ----
// MSG91 delivery callbacks carry no signature (unlike Razorpay, which
// payment-webhook verifies). If MSG91_WEBHOOK_SECRET is set, a matching
// ?token= is required. If it is not set, requests are accepted and a warning is
// logged — so the endpoint works the moment it is deployed and can be hardened
// without a redeploy. The blast radius is small either way: this endpoint can
// only advance the status of rows that already exist.
//
// Always returns 200. Providers retry aggressively on non-2xx, and a retry
// storm over a payload we could not parse helps nobody — the log is the record.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const WEBHOOK_SECRET = Deno.env.get('MSG91_WEBHOOK_SECRET');

const supabase = createClient(supabaseUrl, supabaseServiceKey);

// Forward-only ordering. Higher wins; a callback may never lower a row.
const STATUS_RANK: Record<string, number> = {
  created: 0,
  pending: 1,
  queued: 2,
  processing: 3,
  sent: 4,
  delivered: 5,
  read: 6,
};

// Every provider spelling we might see, across all three channels, mapped onto
// the n_jtd status vocabulary. WhatsApp: sent/delivered/read/failed.
// SMS: DELIVRD/FAILED/EXPIRED/UNDELIV/REJECTD. Email: delivered/opened/
// clicked/bounced/dropped/spam.
const STATUS_MAP: Record<string, string> = {
  sent: 'sent',
  send: 'sent',
  submitted: 'sent',
  delivered: 'delivered',
  delivrd: 'delivered',
  read: 'read',
  opened: 'read',
  clicked: 'read',
  failed: 'failed',
  failure: 'failed',
  undeliv: 'failed',
  undelivered: 'failed',
  rejectd: 'failed',
  rejected: 'failed',
  expired: 'failed',
  bounced: 'failed',
  dropped: 'failed',
  spam: 'failed',
  deleted: 'failed',
};

const ID_KEYS = [
  'message_id', 'messageid', 'msg_id', 'msgid',
  'request_id', 'requestid', 'id',
];
const STATUS_KEYS = [
  'status', 'event', 'event_type', 'eventtype', 'state',
  'delivery_status', 'deliverystatus',
];
const ERROR_KEYS = [
  'error_message', 'errormessage', 'error', 'description',
  'reason', 'error_text', 'failure_reason',
];

interface Extracted {
  providerId: string;
  status: string;
  raw: string;
  error?: string;
}

/** Case-insensitive lookup of the first present key whose value is a scalar. */
function pick(obj: Record<string, unknown>, keys: string[]): string | undefined {
  const lower: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) lower[k.toLowerCase()] = v;
  for (const k of keys) {
    const v = lower[k];
    if (v !== undefined && v !== null && (typeof v === 'string' || typeof v === 'number')) {
      const s = String(v).trim();
      if (s !== '') return s;
    }
  }
  return undefined;
}

/**
 * Walk the whole body and pull out every {id, status} pair we can find,
 * regardless of nesting. Handles: flat object, array at root, {data:[...]},
 * {messages:[...]}, and anything else MSG91 might send.
 */
function extractEvents(node: unknown, found: Extracted[] = [], depth = 0): Extracted[] {
  if (depth > 8 || node === null || typeof node !== 'object') return found;

  if (Array.isArray(node)) {
    for (const item of node) extractEvents(item, found, depth + 1);
    return found;
  }

  const obj = node as Record<string, unknown>;
  const providerId = pick(obj, ID_KEYS);
  const rawStatus = pick(obj, STATUS_KEYS);

  if (providerId && rawStatus) {
    const mapped = STATUS_MAP[rawStatus.toLowerCase()];
    if (mapped) {
      found.push({
        providerId,
        status: mapped,
        raw: rawStatus,
        error: pick(obj, ERROR_KEYS),
      });
    } else {
      console.warn(`[MSG91 webhook] Unrecognised status "${rawStatus}" for id ${providerId} — ignored`);
    }
  }

  // Recurse regardless: a wrapper object may hold both a summary and the events.
  for (const v of Object.values(obj)) extractEvents(v, found, depth + 1);
  return found;
}

async function applyEvent(ev: Extracted): Promise<string> {
  const { data: row, error: selErr } = await supabase
    .from('n_jtd')
    .select('id, status_code, source_type_code, channel_code')
    .eq('provider_message_id', ev.providerId)
    .maybeSingle();

  if (selErr) {
    console.error(`[MSG91 webhook] lookup failed for ${ev.providerId}:`, selErr);
    return 'lookup_error';
  }
  if (!row) {
    // Normal and harmless: callbacks for messages sent by other systems, or
    // for rows already cleaned up.
    console.log(`[MSG91 webhook] no n_jtd row for provider id ${ev.providerId} (status ${ev.raw})`);
    return 'no_match';
  }

  const currentRank = STATUS_RANK[row.status_code] ?? -1;
  const newRank = STATUS_RANK[ev.status] ?? -1;

  // 'failed' is terminal — always record it. Otherwise only move forward.
  if (ev.status !== 'failed' && newRank <= currentRank) {
    console.log(`[MSG91 webhook] ${row.id} ignoring ${ev.status} (already ${row.status_code})`);
    return 'stale';
  }
  if (row.status_code === 'failed' && ev.status !== 'failed') {
    console.log(`[MSG91 webhook] ${row.id} ignoring ${ev.status} (already failed)`);
    return 'stale';
  }

  const update: Record<string, unknown> = {
    status_code: ev.status,
    updated_at: new Date().toISOString(),
  };
  if (ev.status === 'delivered' || ev.status === 'read') {
    update.completed_at = new Date().toISOString();
  }
  if (ev.status === 'failed') {
    update.error_message = ev.error
      ? `MSG91 delivery: ${ev.error}`
      : `MSG91 delivery reported "${ev.raw}"`;
  }

  const { error: updErr } = await supabase.from('n_jtd').update(update).eq('id', row.id);
  if (updErr) {
    console.error(`[MSG91 webhook] update failed for ${row.id}:`, updErr);
    return 'update_error';
  }

  console.log(
    `[MSG91 webhook] ${row.id} (${row.source_type_code}/${row.channel_code}) ` +
    `${row.status_code} → ${ev.status}${ev.error ? ` — ${ev.error}` : ''}`
  );
  return 'updated';
}

serve(async (req) => {
  const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  };
  const ok = (body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  // Some providers probe with GET before enabling a callback URL.
  if (req.method === 'GET') return ok({ ok: true, service: 'msg91-webhook' });

  try {
    if (WEBHOOK_SECRET) {
      const token = new URL(req.url).searchParams.get('token');
      if (token !== WEBHOOK_SECRET) {
        console.warn('[MSG91 webhook] rejected: bad or missing token');
        // 200 on purpose — do not give a probing caller a signal to retry.
        return ok({ ok: false, reason: 'unauthorized' });
      }
    } else {
      console.warn('[MSG91 webhook] MSG91_WEBHOOK_SECRET is not set — accepting unauthenticated callbacks');
    }

    const rawBody = await req.text();

    // THE important line while the real payload shape is still unknown.
    console.log(`[MSG91 webhook] RAW BODY: ${rawBody}`);

    // v2: durable capture — every payload becomes a queryable row BEFORE any
    // processing, so Flow responses / inbound messages are never lost even
    // when the extractor below finds nothing it recognises.
    try {
      let parsedForCapture: unknown = null;
      try { parsedForCapture = JSON.parse(rawBody); } catch { /* leave null */ }
      await supabase.from('n_webhook_inbound_raw').insert({
        source: 'msg91',
        content_type: req.headers.get('content-type'),
        body_raw: rawBody,
        parsed: parsedForCapture,
      });
    } catch (capErr) {
      console.error('[MSG91 webhook] raw capture failed:', capErr);
    }

    let parsed: unknown;
    try {
      parsed = JSON.parse(rawBody);
    } catch {
      // MSG91 can post form-encoded on some channels.
      try {
        parsed = Object.fromEntries(new URLSearchParams(rawBody));
        console.log('[MSG91 webhook] parsed as form-encoded');
      } catch {
        console.error('[MSG91 webhook] body is neither JSON nor form-encoded');
        return ok({ ok: true, parsed: false });
      }
    }

    const events = extractEvents(parsed);
    if (events.length === 0) {
      console.warn('[MSG91 webhook] no {id,status} pairs found in body — see RAW BODY above and tighten extraction');
      return ok({ ok: true, events: 0 });
    }

    const results: Record<string, number> = {};
    for (const ev of events) {
      const outcome = await applyEvent(ev);
      results[outcome] = (results[outcome] || 0) + 1;
    }

    console.log(`[MSG91 webhook] processed ${events.length} event(s):`, JSON.stringify(results));
    return ok({ ok: true, events: events.length, results });

  } catch (error) {
    // Never 500 — a retry storm over an unparseable payload helps nobody.
    console.error('[MSG91 webhook] unexpected error:', error);
    return ok({ ok: false, error: error instanceof Error ? error.message : 'unknown' });
  }
});
