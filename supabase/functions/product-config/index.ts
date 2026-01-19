// supabase/functions/product-config/index.ts
// Product Config Edge Function - Provides product billing configurations
// Created: January 2025

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// CORS headers for browser requests
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-product-code, x-internal-signature',
  'Access-Control-Allow-Methods': 'GET, PUT, OPTIONS',
};

// Initialize Supabase client
const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(supabaseUrl, supabaseServiceKey);

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

function jsonResponse(data: any, status: number = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

function errorResponse(message: string, status: number = 400): Response {
  return jsonResponse({ success: false, error: message }, status);
}

// ============================================================================
// GET /product-config - List all product configs
// ============================================================================
async function handleListConfigs(): Promise<Response> {
  try {
    const { data, error } = await supabase.rpc('list_product_configs');

    if (error) {
      console.error('Error calling list_product_configs:', error);
      return errorResponse(error.message, 500);
    }

    return jsonResponse(data);
  } catch (err) {
    console.error('Unexpected error in handleListConfigs:', err);
    return errorResponse('Internal server error', 500);
  }
}

// ============================================================================
// GET /product-config/:productCode - Get specific product config
// ============================================================================
async function handleGetConfig(productCode: string): Promise<Response> {
  if (!productCode) {
    return errorResponse('Product code is required');
  }

  try {
    const { data, error } = await supabase.rpc('get_product_config', {
      p_product_code: productCode
    });

    if (error) {
      console.error('Error calling get_product_config:', error);
      return errorResponse(error.message, 500);
    }

    if (!data?.success) {
      return errorResponse(data?.error || 'Product config not found', 404);
    }

    return jsonResponse(data);
  } catch (err) {
    console.error('Unexpected error in handleGetConfig:', err);
    return errorResponse('Internal server error', 500);
  }
}

// ============================================================================
// GET /product-config/:productCode/history - Get config version history
// ============================================================================
async function handleGetHistory(productCode: string): Promise<Response> {
  if (!productCode) {
    return errorResponse('Product code is required');
  }

  try {
    const { data, error } = await supabase.rpc('get_product_config_history', {
      p_product_code: productCode
    });

    if (error) {
      console.error('Error calling get_product_config_history:', error);
      return errorResponse(error.message, 500);
    }

    return jsonResponse(data);
  } catch (err) {
    console.error('Unexpected error in handleGetHistory:', err);
    return errorResponse('Internal server error', 500);
  }
}

// ============================================================================
// PUT /product-config/:productCode - Update product config
// ============================================================================
async function handleUpdateConfig(productCode: string, req: Request): Promise<Response> {
  if (!productCode) {
    return errorResponse('Product code is required');
  }

  try {
    const body = await req.json();
    const { billing_config, changelog, updated_by } = body;

    if (!billing_config) {
      return errorResponse('billing_config is required');
    }

    // Get current config to determine new version
    const { data: currentConfig, error: fetchError } = await supabase
      .from('t_bm_product_config')
      .select('config_version')
      .eq('product_code', productCode)
      .single();

    if (fetchError) {
      console.error('Error fetching current config:', fetchError);
      return errorResponse('Product config not found', 404);
    }

    // Increment version (1.0 -> 1.1, 1.9 -> 2.0)
    const currentVersion = currentConfig.config_version || '1.0';
    const [major, minor] = currentVersion.split('.').map(Number);
    const newVersion = minor >= 9 ? `${major + 1}.0` : `${major}.${minor + 1}`;

    // Update the config
    const { data, error } = await supabase
      .from('t_bm_product_config')
      .update({
        billing_config,
        config_version: newVersion,
        updated_by: updated_by || null,
        updated_at: new Date().toISOString()
      })
      .eq('product_code', productCode)
      .select()
      .single();

    if (error) {
      console.error('Error updating product config:', error);
      return errorResponse(error.message, 500);
    }

    return jsonResponse({
      success: true,
      message: 'Product config updated successfully',
      product_code: productCode,
      config_version: newVersion,
      previous_version: currentVersion,
      changelog: changelog || null
    });
  } catch (err) {
    console.error('Unexpected error in handleUpdateConfig:', err);
    return errorResponse('Internal server error', 500);
  }
}

// ============================================================================
// MAIN HANDLER
// ============================================================================
serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const url = new URL(req.url);
  const pathParts = url.pathname.split('/').filter(Boolean);

  // Remove 'product-config' from path if present (edge function name)
  const relevantParts = pathParts.filter(p => p !== 'product-config');

  try {
    // GET /product-config - List all configs
    if (req.method === 'GET' && relevantParts.length === 0) {
      return await handleListConfigs();
    }

    // GET /product-config/:productCode - Get specific config
    if (req.method === 'GET' && relevantParts.length === 1) {
      const productCode = relevantParts[0];
      return await handleGetConfig(productCode);
    }

    // GET /product-config/:productCode/history - Get version history
    if (req.method === 'GET' && relevantParts.length === 2 && relevantParts[1] === 'history') {
      const productCode = relevantParts[0];
      return await handleGetHistory(productCode);
    }

    // PUT /product-config/:productCode - Update config
    if (req.method === 'PUT' && relevantParts.length === 1) {
      const productCode = relevantParts[0];
      return await handleUpdateConfig(productCode, req);
    }

    // 404 for unknown routes
    return errorResponse('Not found', 404);

  } catch (err) {
    console.error('Request handler error:', err);
    return errorResponse('Internal server error', 500);
  }
});
