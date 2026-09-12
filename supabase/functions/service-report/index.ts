// supabase/functions/service-report/index.ts
// B3.6 (v1, 2026-09-12) — PUBLIC service report resolver.
// GET /service-report?token=<uuid> → get_service_ticket_report(token).
// verify_jwt=false: the unguessable per-ticket report_token IS the grant
// (same pattern as the public check-in page). Read-only, one RPC, and
// explicit no-store cache headers — public GETs get cached aggressively
// by mobile browsers/carrier proxies (the 2026-07-24 check-in lesson).
// DEPLOYED v1 2026-09-12 — this file is the source-of-record copy.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Content-Type': 'application/json',
  'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate',
  'Pragma': 'no-cache',
  'Expires': '0',
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers });
  }
  if (req.method !== 'GET') {
    return new Response(JSON.stringify({ success: false, error: 'Method not allowed' }), { status: 405, headers });
  }

  try {
    const url = new URL(req.url);
    const token = url.searchParams.get('token') || '';
    if (!UUID_RE.test(token)) {
      return new Response(JSON.stringify({ success: false, error: 'Invalid token' }), { status: 400, headers });
    }

    const db = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const { data, error } = await db.rpc('get_service_ticket_report', { p_token: token });
    if (error) {
      console.error('[service-report] RPC error:', JSON.stringify(error));
      return new Response(JSON.stringify({ success: false, error: 'Report unavailable' }), { status: 500, headers });
    }
    const status = data?.success ? 200 : data?.code === 'NOT_FOUND' ? 404 : 400;
    return new Response(JSON.stringify(data), { status, headers });
  } catch (e) {
    console.error('[service-report] error:', e);
    return new Response(JSON.stringify({ success: false, error: 'Internal error' }), { status: 500, headers });
  }
});
