// supabase/functions/tax-settings/index.ts
// REFACTORED: Tax Settings Edge Function with Single RPC Calls, Caching, and DB-backed Idempotency
// Optimized for 500-600 parallel users

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import {
  createAuditLogger,
  validateEnvironmentConfig,
  AuditActions,
  AuditResources,
  AuditSeverity
} from "../_shared/audit.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-signature, idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

// ============================================================================
// IN-MEMORY CACHE FOR GET REQUESTS (15 second TTL)
// ============================================================================

interface CacheEntry {
  data: any;
  expires: number;
}

const taxSettingsCache = new Map<string, CacheEntry>();
const CACHE_TTL_MS = 15_000; // 15 seconds

function getCachedResponse(tenantId: string): any | null {
  const cached = taxSettingsCache.get(tenantId);
  if (cached && cached.expires > Date.now()) {
    console.log(`[Tax Settings] Cache HIT for tenant: ${tenantId}`);
    return cached.data;
  }
  if (cached) {
    taxSettingsCache.delete(tenantId);
  }
  console.log(`[Tax Settings] Cache MISS for tenant: ${tenantId}`);
  return null;
}

function setCachedResponse(tenantId: string, data: any): void {
  taxSettingsCache.set(tenantId, {
    data,
    expires: Date.now() + CACHE_TTL_MS
  });

  // Cleanup expired entries (keep cache size manageable)
  const now = Date.now();
  for (const [key, value] of taxSettingsCache.entries()) {
    if (value.expires < now) {
      taxSettingsCache.delete(key);
    }
  }
}

function invalidateCache(tenantId: string): void {
  taxSettingsCache.delete(tenantId);
  console.log(`[Tax Settings] Cache INVALIDATED for tenant: ${tenantId}`);
}

// ============================================================================
// RATE LIMITING (In-memory with per-minute window)
// ============================================================================

const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

function checkRateLimit(tenantId: string, userId: string): {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetTime: number;
} {
  const key = `${tenantId}:${userId}`;
  const now = Date.now();
  const windowMs = 60_000; // 1 minute window
  const maxRequests = 100; // 100 requests per minute

  // Clean up expired entries
  for (const [cacheKey, value] of rateLimitStore.entries()) {
    if (now > value.resetTime) {
      rateLimitStore.delete(cacheKey);
    }
  }

  const current = rateLimitStore.get(key) || { count: 0, resetTime: now + windowMs };

  if (now > current.resetTime) {
    current.count = 0;
    current.resetTime = now + windowMs;
  }

  current.count++;
  rateLimitStore.set(key, current);

  return {
    allowed: current.count <= maxRequests,
    limit: maxRequests,
    remaining: Math.max(0, maxRequests - current.count),
    resetTime: current.resetTime
  };
}

// ============================================================================
// INTERNAL SIGNATURE VERIFICATION
// ============================================================================

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
  if (!secret) {
    console.warn('[Tax Settings] Internal signature verification skipped - no secret configured');
    return true;
  }

  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');

    return signature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}

// ============================================================================
// MAIN HANDLER
// ============================================================================

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Validate environment and create audit logger
    const envConfig = validateEnvironmentConfig(Deno.env);
    const auditLogger = createAuditLogger(req, Deno.env, 'tax-settings');

    // Log function invocation
    console.log(`[Tax Settings] ${req.method} ${req.url}`);

    // Extract headers
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const internalSignature = req.headers.get('x-internal-signature');
    const idempotencyKey = req.headers.get('idempotency-key');

    // Basic validation
    if (!authHeader) {
      await auditLogger.log({
        tenantId: tenantId || 'unknown',
        action: AuditActions.UNAUTHORIZED_ACCESS,
        resource: AuditResources.TAX_SETTINGS,
        success: false,
        severity: AuditSeverity.WARNING,
        metadata: { reason: 'missing_auth_header' }
      });

      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!tenantId) {
      await auditLogger.log({
        tenantId: 'unknown',
        action: AuditActions.UNAUTHORIZED_ACCESS,
        resource: AuditResources.TAX_SETTINGS,
        success: false,
        severity: AuditSeverity.WARNING,
        metadata: { reason: 'missing_tenant_id' }
      });

      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify internal signature for API calls
    let requestBody = '';
    if (internalSignature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValidSignature = await verifyInternalSignature(
        requestBody,
        internalSignature,
        envConfig.internalSecret || ''
      );

      if (!isValidSignature) {
        await auditLogger.log({
          tenantId,
          action: AuditActions.INVALID_SIGNATURE,
          resource: AuditResources.TAX_SETTINGS,
          success: false,
          severity: AuditSeverity.ERROR,
          metadata: { source: 'internal_api' }
        });

        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Rate limiting check
    const rateLimitResult = checkRateLimit(tenantId, auditLogger.getStatus().context.userId || 'anonymous');
    if (!rateLimitResult.allowed) {
      await auditLogger.log({
        tenantId,
        action: AuditActions.RATE_LIMIT_EXCEEDED,
        resource: AuditResources.TAX_SETTINGS,
        success: false,
        severity: AuditSeverity.WARNING,
        metadata: { limit: rateLimitResult.limit, remaining: rateLimitResult.remaining }
      });

      return new Response(
        JSON.stringify({
          error: 'Rate limit exceeded',
          retryAfter: Math.ceil((rateLimitResult.resetTime - Date.now()) / 1000)
        }),
        {
          status: 429,
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json',
            'Retry-After': Math.ceil((rateLimitResult.resetTime - Date.now()) / 1000).toString()
          }
        }
      );
    }

    // Create Supabase client
    const supabase = createClient(envConfig.supabaseUrl, envConfig.supabaseServiceKey, {
      global: {
        headers: {
          Authorization: authHeader,
          'x-tenant-id': tenantId
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Parse URL for routing
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    // Get request body for non-GET requests
    let bodyData: any = null;
    if (req.method !== 'GET' && requestBody) {
      try {
        bodyData = JSON.parse(requestBody);
      } catch (e) {
        bodyData = null;
      }
    } else if (req.method !== 'GET' && !requestBody) {
      try {
        bodyData = await req.json();
      } catch (e) {
        bodyData = null;
      }
    }

    // Route handling
    switch (req.method) {
      case 'GET':
        return await handleGetRequest(supabase, auditLogger, tenantId);

      case 'POST':
        if (lastSegment === 'settings') {
          return await handleCreateUpdateSettings(supabase, auditLogger, tenantId, bodyData, idempotencyKey);
        } else if (lastSegment === 'rates') {
          return await handleCreateRate(supabase, auditLogger, tenantId, bodyData, idempotencyKey);
        }
        break;

      case 'PUT':
        if (pathSegments.includes('rates')) {
          const rateId = pathSegments[pathSegments.length - 1];
          return await handleUpdateRate(supabase, auditLogger, tenantId, rateId, bodyData, idempotencyKey);
        }
        break;

      case 'DELETE':
        if (pathSegments.includes('rates')) {
          const rateId = pathSegments[pathSegments.length - 1];
          return await handleDeleteRate(supabase, auditLogger, tenantId, rateId);
        }
        break;
    }

    // Invalid endpoint
    return new Response(
      JSON.stringify({
        error: 'Invalid endpoint or method',
        availableEndpoints: ['GET /', 'POST /settings', 'POST /rates', 'PUT /rates/{id}', 'DELETE /rates/{id}']
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Tax settings edge function error:', error);

    return new Response(
      JSON.stringify({
        error: 'Internal server error',
        message: error.message,
        requestId: crypto.randomUUID()
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// ============================================================================
// REQUEST HANDLERS - Using Single RPC Calls
// ============================================================================

/**
 * GET /tax-settings - Fetch settings and rates
 * OPTIMIZED: Single RPC call + caching
 */
async function handleGetRequest(
  supabase: any,
  auditLogger: any,
  tenantId: string
) {
  try {
    // Check cache first
    const cached = getCachedResponse(tenantId);
    if (cached) {
      await auditLogger.log({
        tenantId,
        action: AuditActions.TAX_SETTINGS_VIEW,
        resource: AuditResources.TAX_SETTINGS,
        success: true,
        metadata: { operation: 'fetch_all', cache_hit: true }
      });

      return new Response(
        JSON.stringify(cached),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // SINGLE RPC CALL - fetches both settings and rates
    const { data, error } = await supabase.rpc('get_tax_settings_with_rates', {
      p_tenant_id: tenantId
    });

    if (error) {
      throw new Error(`Failed to fetch tax settings: ${error.message}`);
    }

    // Cache the response
    setCachedResponse(tenantId, data);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_SETTINGS_VIEW,
      resource: AuditResources.TAX_SETTINGS,
      success: true,
      metadata: {
        operation: 'fetch_all',
        cache_hit: false,
        rate_count: data?.rates?.length || 0
      }
    });

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetRequest:', error);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_SETTINGS_VIEW,
      resource: AuditResources.TAX_SETTINGS,
      success: false,
      errorMessage: error.message
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * POST /tax-settings/settings - Create or update settings
 * OPTIMIZED: Single RPC call + DB-backed idempotency
 */
async function handleCreateUpdateSettings(
  supabase: any,
  auditLogger: any,
  tenantId: string,
  requestData: any,
  idempotencyKey: string | null
) {
  try {
    // Check idempotency (database-backed)
    if (idempotencyKey) {
      const { data: cachedResponse } = await supabase.rpc('get_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey
      });

      if (cachedResponse) {
        console.log(`[Tax Settings] Idempotency HIT for key: ${idempotencyKey}`);
        return new Response(
          JSON.stringify(cachedResponse),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Validate input
    if (!requestData?.display_mode || !['including_tax', 'excluding_tax'].includes(requestData.display_mode)) {
      return new Response(
        JSON.stringify({ error: 'Invalid display_mode. Must be "including_tax" or "excluding_tax"' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // SINGLE RPC CALL - handles check + insert/update atomically
    const { data, error } = await supabase.rpc('create_or_update_tax_settings', {
      p_tenant_id: tenantId,
      p_display_mode: requestData.display_mode,
      p_default_tax_rate_id: requestData.default_tax_rate_id || null
    });

    if (error) {
      throw new Error(`Failed to save settings: ${error.message}`);
    }

    const result = data.settings;
    const isUpdate = data.is_update;

    // Invalidate cache
    invalidateCache(tenantId);

    // Store idempotency response
    if (idempotencyKey) {
      await supabase.rpc('set_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey,
        p_response_data: result,
        p_ttl_minutes: 15
      });
    }

    await auditLogger.log({
      tenantId,
      action: isUpdate ? AuditActions.TAX_SETTINGS_UPDATE : AuditActions.TAX_SETTINGS_CREATE,
      resource: AuditResources.TAX_SETTINGS,
      resourceId: result.id,
      success: true,
      metadata: { operation: isUpdate ? 'update_settings' : 'create_settings', changes: requestData }
    });

    return new Response(
      JSON.stringify(result),
      { status: isUpdate ? 200 : 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCreateUpdateSettings:', error);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_SETTINGS_UPDATE,
      resource: AuditResources.TAX_SETTINGS,
      success: false,
      errorMessage: error.message
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * POST /tax-settings/rates - Create new tax rate
 * OPTIMIZED: Single RPC call with atomic validation
 */
async function handleCreateRate(
  supabase: any,
  auditLogger: any,
  tenantId: string,
  requestData: any,
  idempotencyKey: string | null
) {
  try {
    // Check idempotency (database-backed)
    if (idempotencyKey) {
      const { data: cachedResponse } = await supabase.rpc('get_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey
      });

      if (cachedResponse) {
        console.log(`[Tax Settings] Idempotency HIT for key: ${idempotencyKey}`);
        return new Response(
          JSON.stringify(cachedResponse),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Basic validation
    if (!requestData?.name || typeof requestData.name !== 'string' || requestData.name.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: 'Name is required and cannot be empty' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (requestData.rate === undefined || requestData.rate === null || isNaN(Number(requestData.rate))) {
      return new Response(
        JSON.stringify({ error: 'Rate is required and must be a number' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const rate = Number(requestData.rate);
    if (rate < 0 || rate > 100) {
      return new Response(
        JSON.stringify({ error: 'Rate must be between 0 and 100' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // SINGLE RPC CALL - handles duplicate check, sequence gen, default switch, insert atomically
    const { data, error } = await supabase.rpc('create_tax_rate_atomic', {
      p_tenant_id: tenantId,
      p_name: requestData.name.trim(),
      p_rate: rate,
      p_is_default: requestData.is_default || false,
      p_description: requestData.description?.trim() || null
    });

    if (error) {
      // Parse duplicate error
      if (error.message.includes('DUPLICATE_TAX_RATE')) {
        try {
          const match = error.message.match(/DUPLICATE_TAX_RATE:(\{.*\})/);
          if (match) {
            const errorData = JSON.parse(match[1]);
            return new Response(
              JSON.stringify({
                error: `Tax rate '${requestData.name.trim().toUpperCase()}' with ${rate}% already exists and cannot be duplicated`,
                code: 'DUPLICATE_TAX_RATE',
                existing_rate: errorData.existing_rate,
                user_input: {
                  name: requestData.name.trim(),
                  normalized_name: requestData.name.trim().toUpperCase(),
                  rate: rate
                }
              }),
              { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        } catch (e) {
          // Fall through to generic error
        }
      }
      throw new Error(`Failed to create tax rate: ${error.message}`);
    }

    // Invalidate cache
    invalidateCache(tenantId);

    // Store idempotency response
    if (idempotencyKey) {
      await supabase.rpc('set_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey,
        p_response_data: data,
        p_ttl_minutes: 15
      });
    }

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_CREATE,
      resource: AuditResources.TAX_RATES,
      resourceId: data.id,
      success: true,
      metadata: { operation: 'create_rate', rate_name: data.name, rate_value: data.rate }
    });

    return new Response(
      JSON.stringify(data),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCreateRate:', error);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_CREATE,
      resource: AuditResources.TAX_RATES,
      success: false,
      errorMessage: error.message
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * PUT /tax-settings/rates/:id - Update tax rate
 * OPTIMIZED: Single RPC call with atomic validation
 */
async function handleUpdateRate(
  supabase: any,
  auditLogger: any,
  tenantId: string,
  rateId: string,
  requestData: any,
  idempotencyKey: string | null
) {
  try {
    // Validate rate ID
    if (!rateId || rateId === 'rates') {
      return new Response(
        JSON.stringify({ error: 'Invalid rate ID' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check idempotency (database-backed)
    if (idempotencyKey) {
      const { data: cachedResponse } = await supabase.rpc('get_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey
      });

      if (cachedResponse) {
        console.log(`[Tax Settings] Idempotency HIT for key: ${idempotencyKey}`);
        return new Response(
          JSON.stringify(cachedResponse),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Validate rate if provided
    if (requestData?.rate !== undefined) {
      const rate = Number(requestData.rate);
      if (isNaN(rate) || rate < 0 || rate > 100) {
        return new Response(
          JSON.stringify({ error: 'Rate must be a number between 0 and 100' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // SINGLE RPC CALL - handles fetch, validate, duplicate check, update atomically
    const { data, error } = await supabase.rpc('update_tax_rate_atomic', {
      p_tenant_id: tenantId,
      p_rate_id: rateId,
      p_name: requestData?.name?.trim() || null,
      p_rate: requestData?.rate !== undefined ? Number(requestData.rate) : null,
      p_is_default: requestData?.is_default !== undefined ? requestData.is_default : null,
      p_description: requestData?.description !== undefined ? (requestData.description?.trim() || null) : null,
      p_expected_version: requestData?.version || null
    });

    if (error) {
      // Handle specific errors
      if (error.code === 'P0002' || error.message.includes('not found')) {
        return new Response(
          JSON.stringify({ error: 'Tax rate not found or has been deleted' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (error.code === '40001' || error.message.includes('modified by another user')) {
        return new Response(
          JSON.stringify({ error: 'Tax rate was modified by another user. Please refresh and try again.' }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Parse duplicate error
      if (error.message.includes('DUPLICATE_TAX_RATE')) {
        try {
          const match = error.message.match(/DUPLICATE_TAX_RATE:(\{.*\})/);
          if (match) {
            const errorData = JSON.parse(match[1]);
            return new Response(
              JSON.stringify({
                error: `Tax rate '${requestData?.name || 'Unknown'}' with ${requestData?.rate}% already exists`,
                code: 'DUPLICATE_TAX_RATE',
                existing_rate: errorData.existing_rate
              }),
              { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        } catch (e) {
          // Fall through
        }
      }

      throw new Error(`Failed to update tax rate: ${error.message}`);
    }

    // Invalidate cache
    invalidateCache(tenantId);

    // Store idempotency response
    if (idempotencyKey) {
      await supabase.rpc('set_idempotency_response', {
        p_tenant_id: tenantId,
        p_idempotency_key: idempotencyKey,
        p_response_data: data,
        p_ttl_minutes: 15
      });
    }

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_UPDATE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: true,
      metadata: { operation: 'update_rate', changes: requestData, rate_name: data.name }
    });

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleUpdateRate:', error);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_UPDATE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: false,
      errorMessage: error.message
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

/**
 * DELETE /tax-settings/rates/:id - Delete tax rate (soft delete)
 * OPTIMIZED: Single RPC call
 */
async function handleDeleteRate(
  supabase: any,
  auditLogger: any,
  tenantId: string,
  rateId: string
) {
  try {
    // Validate rate ID
    if (!rateId || rateId === 'rates') {
      return new Response(
        JSON.stringify({ error: 'Invalid rate ID' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // SINGLE RPC CALL - handles fetch, validate, soft delete atomically
    const { data, error } = await supabase.rpc('delete_tax_rate_atomic', {
      p_tenant_id: tenantId,
      p_rate_id: rateId
    });

    if (error) {
      // Handle specific errors
      if (error.code === 'P0002' || error.message.includes('not found')) {
        return new Response(
          JSON.stringify({ error: 'Tax rate not found' }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (error.message.includes('already deleted')) {
        return new Response(
          JSON.stringify({ error: 'Tax rate is already deleted' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      if (error.message.includes('default tax rate')) {
        return new Response(
          JSON.stringify({ error: 'Cannot delete the default tax rate. Please set another rate as default first.' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      throw new Error(`Failed to delete tax rate: ${error.message}`);
    }

    // Invalidate cache
    invalidateCache(tenantId);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_DELETE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: true,
      severity: AuditSeverity.CRITICAL,
      metadata: { operation: 'soft_delete_completed', deleted_rate: data.deletedRate }
    });

    return new Response(
      JSON.stringify(data),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleDeleteRate:', error);

    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_DELETE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: false,
      errorMessage: error.message
    });

    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}
