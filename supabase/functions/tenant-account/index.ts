// supabase/functions/tenant-account/index.ts
// Tenant Account Management Edge Function (Owner-side)
// Handles: data summary + close account for the authenticated tenant owner
// Reuses existing RPCs: get_tenant_data_summary, admin_close_tenant_account
// Pattern: matches plans/index.ts (simple auth, no signing)

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-product',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS'
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

    // GET /data-summary - Owner's own tenant data summary
    if (req.method === 'GET' && action === 'data-summary') {
      const { data, error } = await supabase.rpc('get_tenant_data_summary', {
        p_tenant_id: tenantId
      });

      if (error) {
        console.error('Owner data summary RPC error:', error);
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

    // POST /reset-test-data - Owner resets their own test data
    if (req.method === 'POST' && action === 'reset-test-data') {
      const { data, error } = await supabase.rpc('admin_reset_test_data', {
        p_tenant_id: tenantId
      });

      if (error) {
        console.error('Owner reset test data RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to reset test data', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // POST /reset-all-data - Owner resets all their data (keeps account open)
    if (req.method === 'POST' && action === 'reset-all-data') {
      const { data, error } = await supabase.rpc('admin_reset_all_data', {
        p_tenant_id: tenantId
      });

      if (error) {
        console.error('Owner reset all data RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to reset all data', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ success: true, data }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // POST /close-account - Owner closes their own account
    if (req.method === 'POST' && action === 'close-account') {
      const body = await req.json();

      if (!body.confirmed) {
        return new Response(
          JSON.stringify({ error: 'confirmed=true is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      const { data, error } = await supabase.rpc('admin_close_tenant_account', {
        p_tenant_id: tenantId
      });

      if (error) {
        console.error('Owner close account RPC error:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to close account', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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
