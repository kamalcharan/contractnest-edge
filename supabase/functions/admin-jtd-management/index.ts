// supabase/functions/admin-jtd-management/index.ts
// Admin JTD Management Edge Function — Release 1 (Observability)
// Pattern: matches admin-tenant-management/index.ts (simple auth, single RPC per route)

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-is-admin, x-product',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
};

const jsonHeaders = { ...corsHeaders, 'Content-Type': 'application/json' };

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        { status: 500, headers: jsonHeaders }
      );
    }

    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const isAdmin = req.headers.get('x-is-admin');

    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: jsonHeaders }
      );
    }

    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: jsonHeaders }
      );
    }

    if (isAdmin !== 'true') {
      return new Response(
        JSON.stringify({ error: 'Admin access required' }),
        { status: 403, headers: jsonHeaders }
      );
    }

    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { 'x-tenant-id': tenantId } },
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Routing
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    // Supports: /queue-metrics, /tenant-stats, /events, /event-detail, /worker-health
    const action = pathSegments.length > 1 ? pathSegments[pathSegments.length - 1] : '';

    // ----------------------------------------------------------------
    // GET /queue-metrics
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'queue-metrics') {
      const { data, error } = await supabase.rpc('get_admin_jtd_queue_metrics');

      if (error) {
        console.error('Queue metrics RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load queue metrics', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // GET /tenant-stats
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'tenant-stats') {
      const params = url.searchParams;

      const { data, error } = await supabase.rpc('get_admin_jtd_tenant_stats', {
        p_page:     parseInt(params.get('page') || '1'),
        p_limit:    Math.min(parseInt(params.get('limit') || '20'), 100),
        p_search:   params.get('search') || null,
        p_sort_by:  params.get('sort_by') || 'total_jtds',
        p_sort_dir: params.get('sort_dir') || 'desc'
      });

      if (error) {
        console.error('Tenant stats RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load tenant JTD stats', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          data: data.tenants,
          global: data.global,
          pagination: data.pagination
        }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // GET /events
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'events') {
      const params = url.searchParams;

      const { data, error } = await supabase.rpc('get_admin_jtd_events', {
        p_page:             parseInt(params.get('page') || '1'),
        p_limit:            Math.min(parseInt(params.get('limit') || '50'), 100),
        p_tenant_id:        params.get('tenant_id') || null,
        p_status_code:      params.get('status') || null,
        p_event_type_code:  params.get('event_type') || null,
        p_channel_code:     params.get('channel') || null,
        p_source_type_code: params.get('source_type') || null,
        p_search:           params.get('search') || null,
        p_date_from:        params.get('date_from') || null,
        p_date_to:          params.get('date_to') || null,
        p_sort_by:          params.get('sort_by') || 'created_at',
        p_sort_dir:         params.get('sort_dir') || 'desc'
      });

      if (error) {
        console.error('Events RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load JTD events', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          data: data.events,
          pagination: data.pagination
        }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // GET /event-detail?jtd_id=xxx
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'event-detail') {
      const jtdId = url.searchParams.get('jtd_id');
      if (!jtdId) {
        return new Response(
          JSON.stringify({ error: 'jtd_id query parameter is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase.rpc('get_admin_jtd_event_detail', {
        p_jtd_id: jtdId
      });

      if (error) {
        console.error('Event detail RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load JTD event detail', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      if (data?.error) {
        return new Response(
          JSON.stringify({ success: false, error: data.error }),
          { status: 404, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          data: data.event,
          status_history: data.status_history
        }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // GET /worker-health
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'worker-health') {
      const { data, error } = await supabase.rpc('get_admin_jtd_worker_health');

      if (error) {
        console.error('Worker health RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load worker health', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // 404 — Unknown route
    // ----------------------------------------------------------------
    return new Response(
      JSON.stringify({ error: `Unknown route: ${req.method} ${action}` }),
      { status: 404, headers: jsonHeaders }
    );

  } catch (error: any) {
    console.error('Unexpected error:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
