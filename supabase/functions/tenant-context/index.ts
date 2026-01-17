// supabase/functions/tenant-context/index.ts
// TenantContext Edge Function - Provides tenant context for credit-gated operations
// Created: January 2025

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// CORS headers for browser requests
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-product-code',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

// Initialize Supabase client
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

/**
 * Handle GET /tenant-context - Get tenant context
 */
async function handleGetContext(req: Request): Promise<Response> {
  const productCode = req.headers.get('x-product-code');
  const tenantId = req.headers.get('x-tenant-id');

  // Validate required headers
  if (!productCode) {
    return new Response(
      JSON.stringify({
        success: false,
        error: 'x-product-code header is required'
      }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  if (!tenantId) {
    return new Response(
      JSON.stringify({
        success: false,
        error: 'x-tenant-id header is required'
      }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    // Call RPC function
    const { data, error } = await supabase.rpc('get_tenant_context', {
      p_product_code: productCode,
      p_tenant_id: tenantId
    });

    if (error) {
      console.error('Error calling get_tenant_context:', error);
      return new Response(
        JSON.stringify({
          success: false,
          error: error.message,
          product_code: productCode,
          tenant_id: tenantId
        }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    console.error('Unexpected error:', err);
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Internal server error'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Handle POST /tenant-context/init - Initialize tenant context
 */
async function handleInitContext(req: Request): Promise<Response> {
  const productCode = req.headers.get('x-product-code');
  const tenantId = req.headers.get('x-tenant-id');

  if (!productCode || !tenantId) {
    return new Response(
      JSON.stringify({
        success: false,
        error: 'x-product-code and x-tenant-id headers are required'
      }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    const body = await req.json().catch(() => ({}));
    const businessName = body.business_name || null;

    const { data, error } = await supabase.rpc('init_tenant_context', {
      p_product_code: productCode,
      p_tenant_id: tenantId,
      p_business_name: businessName
    });

    if (error) {
      console.error('Error calling init_tenant_context:', error);
      return new Response(
        JSON.stringify({ success: false, error: error.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    console.error('Unexpected error:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Handle GET /tenant-context/waiting-jtds - Get count of JTDs waiting for credits
 */
async function handleWaitingJtds(req: Request): Promise<Response> {
  const tenantId = req.headers.get('x-tenant-id');

  if (!tenantId) {
    return new Response(
      JSON.stringify({
        success: false,
        error: 'x-tenant-id header is required'
      }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    // Get channel from query params
    const url = new URL(req.url);
    const channel = url.searchParams.get('channel') || null;

    const { data, error } = await supabase.rpc('get_waiting_jtd_count', {
      p_tenant_id: tenantId,
      p_channel: channel
    });

    if (error) {
      console.error('Error calling get_waiting_jtd_count:', error);
      return new Response(
        JSON.stringify({ success: false, error: error.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    console.error('Unexpected error:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * Handle POST /tenant-context/release-jtds - Manually trigger JTD release
 */
async function handleReleaseJtds(req: Request): Promise<Response> {
  const tenantId = req.headers.get('x-tenant-id');

  if (!tenantId) {
    return new Response(
      JSON.stringify({
        success: false,
        error: 'x-tenant-id header is required'
      }),
      { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }

  try {
    const body = await req.json().catch(() => ({}));
    const channel = body.channel || 'all';
    const maxRelease = body.max_release || 100;

    const { data, error } = await supabase.rpc('release_waiting_jtds', {
      p_tenant_id: tenantId,
      p_channel: channel,
      p_max_release: maxRelease
    });

    if (error) {
      console.error('Error calling release_waiting_jtds:', error);
      return new Response(
        JSON.stringify({ success: false, error: error.message }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (err) {
    console.error('Unexpected error:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Main handler
serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const url = new URL(req.url);
  const path = url.pathname;

  // Route requests
  try {
    // GET /tenant-context - Get tenant context
    if (req.method === 'GET' && (path === '/' || path === '/tenant-context' || path === '')) {
      return await handleGetContext(req);
    }

    // POST /tenant-context/init - Initialize tenant context
    if (req.method === 'POST' && path.endsWith('/init')) {
      return await handleInitContext(req);
    }

    // GET /tenant-context/waiting-jtds - Get waiting JTD count
    if (req.method === 'GET' && path.endsWith('/waiting-jtds')) {
      return await handleWaitingJtds(req);
    }

    // POST /tenant-context/release-jtds - Release waiting JTDs
    if (req.method === 'POST' && path.endsWith('/release-jtds')) {
      return await handleReleaseJtds(req);
    }

    // 404 for unknown routes
    return new Response(
      JSON.stringify({ success: false, error: 'Not found' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (err) {
    console.error('Request handler error:', err);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
