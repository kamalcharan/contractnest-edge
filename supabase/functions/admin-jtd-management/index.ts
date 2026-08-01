// supabase/functions/admin-jtd-management/index.ts
// Admin JTD Management Edge Function — R1 (Observability) + R2 (Actions)
// Pattern: matches admin-tenant-management/index.ts (simple auth, single RPC per route)

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-is-admin, x-product',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, OPTIONS'
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

    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { headers: { 'x-tenant-id': tenantId } },
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Admin access is verified server-side from the caller's own JWT against
    // t_user_profiles.is_admin — the same signal auditMiddleware.ts trusts
    // elsewhere. The Express layer (adminJtdRoutes.ts) also gates on this,
    // but a client-supplied x-is-admin header (the previous check) proves
    // nothing on its own, so this function verifies independently rather
    // than trusting the caller.
    const token = authHeader.replace('Bearer ', '');
    const { data: { user: callingUser }, error: callerError } = await supabase.auth.getUser(token);

    if (callerError || !callingUser) {
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        { status: 401, headers: jsonHeaders }
      );
    }

    const { data: callerProfile, error: profileError } = await supabase
      .from('t_user_profiles')
      .select('is_admin')
      .eq('user_id', callingUser.id)
      .single();

    if (profileError || !callerProfile?.is_admin) {
      return new Response(
        JSON.stringify({ error: 'Admin access required' }),
        { status: 403, headers: jsonHeaders }
      );
    }

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

    // ================================================================
    // R2 — ACTION ENDPOINTS (POST)
    // ================================================================

    // Helper: parse JSON body
    const parseBody = async () => {
      try { return await req.json(); } catch { return {}; }
    };

    const adminName = req.headers.get('x-admin-name') || 'Admin';

    // ----------------------------------------------------------------
    // POST /retry-event
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'retry-event') {
      const body = await parseBody();
      if (!body.jtd_id) {
        return new Response(
          JSON.stringify({ error: 'jtd_id is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase.rpc('admin_retry_jtd_event', {
        p_jtd_id: body.jtd_id,
        p_admin_name: adminName,
        p_reason: body.reason || 'Admin manual retry'
      });

      if (error) {
        console.error('Retry event RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to retry event', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(JSON.stringify(data), {
        status: data?.success ? 200 : 400,
        headers: jsonHeaders
      });
    }

    // ----------------------------------------------------------------
    // POST /cancel-event
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'cancel-event') {
      const body = await parseBody();
      if (!body.jtd_id) {
        return new Response(
          JSON.stringify({ error: 'jtd_id is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase.rpc('admin_cancel_jtd_event', {
        p_jtd_id: body.jtd_id,
        p_admin_name: adminName,
        p_reason: body.reason || 'Admin manual cancellation'
      });

      if (error) {
        console.error('Cancel event RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to cancel event', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(JSON.stringify(data), {
        status: data?.success ? 200 : 400,
        headers: jsonHeaders
      });
    }

    // ----------------------------------------------------------------
    // POST /force-complete
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'force-complete') {
      const body = await parseBody();
      if (!body.jtd_id || !body.target_status) {
        return new Response(
          JSON.stringify({ error: 'jtd_id and target_status are required' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase.rpc('admin_force_complete_jtd_event', {
        p_jtd_id: body.jtd_id,
        p_admin_name: adminName,
        p_target_status: body.target_status,
        p_reason: body.reason || 'Admin force complete'
      });

      if (error) {
        console.error('Force complete RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to force-complete event', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(JSON.stringify(data), {
        status: data?.success ? 200 : 400,
        headers: jsonHeaders
      });
    }

    // ----------------------------------------------------------------
    // GET /dlq-messages
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'dlq-messages') {
      const params = url.searchParams;

      const { data, error } = await supabase.rpc('admin_list_dlq_messages', {
        p_page:  parseInt(params.get('page') || '1'),
        p_limit: Math.min(parseInt(params.get('limit') || '20'), 100)
      });

      if (error) {
        console.error('DLQ list RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load DLQ messages', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data: data.messages, pagination: data.pagination }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // POST /requeue-dlq
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'requeue-dlq') {
      const body = await parseBody();
      if (!body.msg_id) {
        return new Response(
          JSON.stringify({ error: 'msg_id is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase.rpc('admin_requeue_dlq_message', {
        p_msg_id: parseInt(body.msg_id),
        p_admin_name: adminName
      });

      if (error) {
        console.error('Requeue DLQ RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to requeue DLQ message', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(JSON.stringify(data), {
        status: data?.success ? 200 : 400,
        headers: jsonHeaders
      });
    }

    // ----------------------------------------------------------------
    // POST /purge-dlq
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'purge-dlq') {
      const { data, error } = await supabase.rpc('admin_purge_dlq', {
        p_admin_name: adminName
      });

      if (error) {
        console.error('Purge DLQ RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to purge DLQ', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(JSON.stringify(data), {
        status: data?.success ? 200 : 400,
        headers: jsonHeaders
      });
    }

    // ================================================================
    // TENANT TEMPLATE MAPPING (n_jtd_templates) — mandatory-tenant model
    // ================================================================
    // These endpoints back the admin UI that maps a (tenant, source_type,
    // channel) to an approved MSG91 template. Deliberately no support for
    // creating a tenant_id=NULL "open" system template through this
    // surface — every row created here is tied to exactly one tenant, so a
    // tenant with no row simply gets no template and fails visibly (see
    // 008_seed_group_session_source_types.sql for the reasoning).

    // ----------------------------------------------------------------
    // GET /templates — list, optionally filtered
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'templates') {
      const params = url.searchParams;
      let query = supabase
        .from('n_jtd_templates')
        .select('id, tenant_id, template_key, name, description, channel_code, source_type_code, content, provider_template_id, is_live, is_active, version, created_at, updated_at')
        .order('created_at', { ascending: false });

      const filterTenantId = params.get('tenant_id');
      const filterSourceType = params.get('source_type_code');
      const filterChannel = params.get('channel_code');
      if (filterTenantId) query = query.eq('tenant_id', filterTenantId);
      if (filterSourceType) query = query.eq('source_type_code', filterSourceType);
      if (filterChannel) query = query.eq('channel_code', filterChannel);

      const { data, error } = await query;

      if (error) {
        console.error('Templates list error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load templates', details: error.message }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // GET /template-options — active source types + channels, for the
    // tenant-mapping picker. Tenants themselves are listed via the
    // existing admin tenant endpoints, not duplicated here.
    // ----------------------------------------------------------------
    if (req.method === 'GET' && action === 'template-options') {
      const [sourceTypesRes, channelsRes] = await Promise.all([
        supabase.from('n_jtd_source_types').select('code, name').eq('is_active', true).order('name'),
        supabase.from('n_jtd_channels').select('code, name').eq('is_active', true).order('display_order'),
      ]);

      if (sourceTypesRes.error || channelsRes.error) {
        console.error('Template options error:', sourceTypesRes.error || channelsRes.error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load template options' }),
          { status: 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          data: { sourceTypes: sourceTypesRes.data, channels: channelsRes.data }
        }),
        { status: 200, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // POST /templates — create a tenant-scoped mapping. tenant_id is
    // mandatory; there is no path here to create an open/system row.
    // ----------------------------------------------------------------
    if (req.method === 'POST' && action === 'templates') {
      const body = await parseBody();

      if (!body.tenant_id) {
        return new Response(
          JSON.stringify({ error: 'tenant_id is required — this admin surface only creates tenant-scoped template mappings, never an open/system template' }),
          { status: 400, headers: jsonHeaders }
        );
      }
      if (!body.source_type_code || !body.channel_code) {
        return new Response(
          JSON.stringify({ error: 'source_type_code and channel_code are required' }),
          { status: 400, headers: jsonHeaders }
        );
      }
      if (!body.provider_template_id) {
        return new Response(
          JSON.stringify({ error: 'provider_template_id (the approved MSG91 template name) is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }
      if (!body.content) {
        return new Response(
          JSON.stringify({ error: 'content is required — documents what the mapped MSG91 template actually says (WhatsApp itself sends by provider_template_id, not this field)' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const insertData = {
        tenant_id: body.tenant_id,
        // One row per (tenant, source_type, channel, is_live) — template_key
        // mirrors source_type_code so it stays aligned with how
        // jtd-worker's getTemplate() actually looks templates up.
        template_key: body.source_type_code,
        name: body.name || body.source_type_code,
        description: body.description || null,
        channel_code: body.channel_code,
        source_type_code: body.source_type_code,
        content: body.content,
        provider_template_id: body.provider_template_id,
        is_live: body.is_live ?? true,
        is_active: body.is_active ?? true,
        created_by: body.admin_user_id || null,
        updated_by: body.admin_user_id || null,
      };

      const { data, error } = await supabase
        .from('n_jtd_templates')
        .insert(insertData)
        .select()
        .single();

      if (error) {
        console.error('Template create error:', error);
        const isDuplicate = error.code === '23505';
        return new Response(
          JSON.stringify({
            success: false,
            error: isDuplicate
              ? 'A template already exists for this tenant + source type + channel + environment'
              : 'Failed to create template',
            details: error.message
          }),
          { status: isDuplicate ? 409 : 500, headers: jsonHeaders }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 201, headers: jsonHeaders }
      );
    }

    // ----------------------------------------------------------------
    // PATCH /templates?id=xxx — remap to a different MSG91 template, or
    // toggle active. Content is deliberately NOT patchable here: it
    // should always reflect what's actually approved on MSG91, and a
    // wording change needs a fresh MSG91 approval — i.e. a fresh mapping,
    // not a silent edit of what this admin surface shows as read-only.
    // ----------------------------------------------------------------
    if (req.method === 'PATCH' && action === 'templates') {
      const templateId = url.searchParams.get('id');
      if (!templateId) {
        return new Response(
          JSON.stringify({ error: 'id query parameter is required' }),
          { status: 400, headers: jsonHeaders }
        );
      }
      const body = await parseBody();

      const updateData: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (body.provider_template_id !== undefined) updateData.provider_template_id = body.provider_template_id;
      if (body.is_active !== undefined) updateData.is_active = body.is_active;
      if (body.admin_user_id) updateData.updated_by = body.admin_user_id;

      if (Object.keys(updateData).length <= 1) {
        return new Response(
          JSON.stringify({ error: 'Nothing to update — only provider_template_id and is_active may be changed' }),
          { status: 400, headers: jsonHeaders }
        );
      }

      const { data, error } = await supabase
        .from('n_jtd_templates')
        .update(updateData)
        .eq('id', templateId)
        .select()
        .single();

      if (error) {
        console.error('Template update error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to update template', details: error.message }),
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
