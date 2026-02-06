// supabase/functions/admin-tenant-management/index.ts
// Admin Tenant Management Edge Function
// Pattern: matches plans/index.ts (simple auth, no signing)

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-is-admin, x-product',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

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
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const isAdmin = req.headers.get('x-is-admin');

    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (isAdmin !== 'true') {
      return new Response(
        JSON.stringify({ error: 'Admin access required' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Create client with service role key (same as plans/index.ts)
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: { 'x-tenant-id': tenantId }
      },
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // Routing
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const action = pathSegments.length > 1 ? pathSegments[pathSegments.length - 1] : '';

    // GET /stats
    if (req.method === 'GET' && action === 'stats') {
      const { data, error } = await supabase.rpc('get_admin_platform_stats');

      if (error) {
        console.error('Stats RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load platform stats', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // GET /tenants
    if (req.method === 'GET' && action === 'tenants') {
      const params = url.searchParams;

      const { data, error } = await supabase.rpc('get_admin_tenant_list', {
        p_page: parseInt(params.get('page') || '1'),
        p_limit: Math.min(parseInt(params.get('limit') || '20'), 100),
        p_status: params.get('status') || null,
        p_subscription_status: params.get('subscription_status') || null,
        p_search: params.get('search') || null,
        p_sort_by: params.get('sort_by') || 'created_at',
        p_sort_direction: params.get('sort_direction') || 'desc',
        p_is_test: params.get('is_test') || null
      });

      if (error) {
        console.error('Tenant list RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load tenant list', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({
          success: true,
          data: data.tenants,
          pagination: data.pagination
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // GET /data-summary?tenant_id=xxx
    if (req.method === 'GET' && action === 'data-summary') {
      const targetTenantId = url.searchParams.get('tenant_id');
      if (!targetTenantId) {
        return new Response(
          JSON.stringify({ error: 'tenant_id query parameter is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase.rpc('get_tenant_data_summary', {
        p_tenant_id: targetTenantId
      });

      if (error) {
        console.error('Data summary RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to load data summary', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // POST /reset-test-data
    if (req.method === 'POST' && action === 'reset-test-data') {
      const body = await req.json();
      const targetTenantId = body.tenant_id;
      if (!targetTenantId) {
        return new Response(
          JSON.stringify({ error: 'tenant_id is required in request body' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase.rpc('admin_reset_test_data', {
        p_tenant_id: targetTenantId
      });

      if (error) {
        console.error('Reset test data RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to reset test data', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Check RPC-level success (EXCEPTION handler returns {success: false})
      if (data?.success === false) {
        console.error('Reset test data RPC returned failure:', data.error);
        return new Response(
          JSON.stringify({ success: false, error: data.error || 'RPC execution failed', details: data }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // POST /reset-all-data
    if (req.method === 'POST' && action === 'reset-all-data') {
      const body = await req.json();
      const targetTenantId = body.tenant_id;
      if (!targetTenantId || !body.confirmed) {
        return new Response(
          JSON.stringify({ error: 'tenant_id and confirmed=true are required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase.rpc('admin_reset_all_data', {
        p_tenant_id: targetTenantId
      });

      if (error) {
        console.error('Reset all data RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to reset all data', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Check RPC-level success (EXCEPTION handler returns {success: false})
      if (data?.success === false) {
        console.error('Reset all data RPC returned failure:', data.error);
        return new Response(
          JSON.stringify({ success: false, error: data.error || 'RPC execution failed', details: data }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // POST /close-account
    if (req.method === 'POST' && action === 'close-account') {
      const body = await req.json();
      const targetTenantId = body.tenant_id;
      if (!targetTenantId || !body.confirmed) {
        return new Response(
          JSON.stringify({ error: 'tenant_id and confirmed=true are required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase.rpc('admin_close_tenant_account', {
        p_tenant_id: targetTenantId
      });

      if (error) {
        console.error('Close account RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to close account', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Check RPC-level success (EXCEPTION handler returns {success: false})
      if (data?.success === false) {
        console.error('Close account RPC returned failure:', data.error);
        return new Response(
          JSON.stringify({ success: false, error: data.error || 'RPC execution failed', details: data }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // 404
    return new Response(
      JSON.stringify({ error: `Unknown route: ${req.method} ${action}` }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Unexpected error:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
