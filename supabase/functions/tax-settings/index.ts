// supabase/functions/tax-settings/index.ts
// Complete Tax Settings Edge Function with enhanced audit integration and security
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

// Rate limiting storage (in-memory for Edge functions)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();

// Idempotency cache (in-memory for Edge functions)
const idempotencyCache = new Map<string, { data: any; expiresAt: number }>();

serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // Validate environment and create audit logger
    const envConfig = validateEnvironmentConfig(Deno.env);
    const auditLogger = createAuditLogger(req, Deno.env, 'tax-settings');
    
    // Log function invocation for debugging
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
        metadata: { 
          reason: 'missing_auth_header',
          endpoint: req.url,
          method: req.method
        }
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
        metadata: { 
          reason: 'missing_tenant_id',
          endpoint: req.url,
          method: req.method
        }
      });
      
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Verify internal signature for API calls
    if (internalSignature) {
      const requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValidSignature = await verifyInternalSignature(requestBody, internalSignature, envConfig.internalSecret || '');
      
      if (!isValidSignature) {
        await auditLogger.log({
          tenantId,
          action: AuditActions.INVALID_SIGNATURE,
          resource: AuditResources.TAX_SETTINGS,
          success: false,
          severity: AuditSeverity.ERROR,
          metadata: { 
            source: 'internal_api',
            endpoint: 'tax-settings',
            hasSignature: true,
            method: req.method
          }
        });
        
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      // Re-parse body for JSON requests
      if (req.method !== 'GET' && requestBody) {
        try {
          req.json = () => Promise.resolve(JSON.parse(requestBody));
        } catch (e) {
          // If not JSON, leave as is
        }
      }
    }
    
    // Rate limiting check
    const rateLimitResult = await checkRateLimit(tenantId, auditLogger.getStatus().context.userId || 'anonymous');
    if (!rateLimitResult.allowed) {
      await auditLogger.log({
        tenantId,
        action: AuditActions.RATE_LIMIT_EXCEEDED,
        resource: AuditResources.TAX_SETTINGS,
        success: false,
        severity: AuditSeverity.WARNING,
        metadata: { 
          limit: rateLimitResult.limit,
          remaining: rateLimitResult.remaining,
          resetTime: new Date(rateLimitResult.resetTime).toISOString(),
          method: req.method
        }
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
    
    // Route handling
    switch (req.method) {
      case 'GET':
        return await handleGetRequest(supabase, auditLogger, tenantId, lastSegment);
        
      case 'POST':
        if (lastSegment === 'settings') {
          return await handleCreateUpdateSettings(supabase, auditLogger, tenantId, req, idempotencyKey);
        } else if (lastSegment === 'rates') {
          return await handleCreateRate(supabase, auditLogger, tenantId, req, idempotencyKey);
        }
        break;
        
      case 'PUT':
        if (pathSegments.includes('rates')) {
          const rateId = pathSegments[pathSegments.length - 1];
          return await handleUpdateRate(supabase, auditLogger, tenantId, rateId, req, idempotencyKey);
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
    await auditLogger.log({
      tenantId,
      action: AuditActions.NOT_FOUND,
      resource: AuditResources.TAX_SETTINGS,
      success: false,
      severity: AuditSeverity.WARNING,
      metadata: { 
        method: req.method,
        path: url.pathname,
        availableEndpoints: [
          'GET /',
          'POST /settings',
          'POST /rates',
          'PUT /rates/{id}',
          'DELETE /rates/{id}'
        ]
      }
    });
    
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint or method',
        availableEndpoints: [
          'GET /',
          'POST /settings',
          'POST /rates',
          'PUT /rates/{id}',
          'DELETE /rates/{id}'
        ],
        requestedMethod: req.method,
        requestedPath: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error: any) {
    console.error('Tax settings edge function error:', error);
    
    // Try to log the error if possible
    try {
      const auditLogger = createAuditLogger(req, Deno.env, 'tax-settings');
      await auditLogger.log({
        tenantId: req.headers.get('x-tenant-id') || 'unknown',
        action: AuditActions.SYSTEM_ERROR,
        resource: AuditResources.TAX_SETTINGS,
        success: false,
        severity: AuditSeverity.CRITICAL,
        errorMessage: error.message,
        metadata: { 
          stack: error.stack,
          method: req.method,
          url: req.url,
          function_name: 'tax-settings'
        }
      });
    } catch (auditError) {
      console.error('Failed to log audit error:', auditError);
    }
    
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

// ==========================================
// REQUEST HANDLERS
// ==========================================

async function handleGetRequest(
  supabase: any, 
  auditLogger: any, 
  tenantId: string, 
  lastSegment: string
) {
  try {
    // Fetch tax settings
    const { data: settings, error: settingsError } = await supabase
      .from('t_tax_settings')
      .select('*')
      .eq('tenant_id', tenantId)
      .single();
      
    if (settingsError && settingsError.code !== 'PGRST116') {
      throw new Error(`Failed to fetch tax settings: ${settingsError.message}`);
    }
    
    // Fetch tax rates
    const { data: rates, error: ratesError } = await supabase
      .from('t_tax_rates')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .order('sequence_no', { ascending: true, nullsLast: true });
      
    if (ratesError) {
      throw new Error(`Failed to fetch tax rates: ${ratesError.message}`);
    }
    
    const response = {
      settings: settings || {
        tenant_id: tenantId,
        display_mode: 'excluding_tax',
        default_tax_rate_id: null,
        version: 1
      },
      rates: rates || []
    };
    
    // Log successful fetch
    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_SETTINGS_VIEW,
      resource: AuditResources.TAX_SETTINGS,
      success: true,
      metadata: { 
        operation: 'fetch_all',
        rate_count: response.rates.length,
        has_settings: !!settings,
        display_mode: response.settings.display_mode
      }
    });
    
    return new Response(
      JSON.stringify(response),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetRequest:', error);
    
    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_SETTINGS_VIEW,
      resource: AuditResources.TAX_SETTINGS,
      success: false,
      errorMessage: error.message,
      metadata: { 
        operation: 'fetch_all',
        error: error.message
      }
    });
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleCreateUpdateSettings(
  supabase: any, 
  auditLogger: any, 
  tenantId: string, 
  req: Request, 
  idempotencyKey: string | null
) {
  try {
    const requestData = await req.json();
    
    // Handle idempotency
    if (idempotencyKey) {
      const cached = getIdempotencyCache(idempotencyKey, tenantId);
      if (cached) {
        return new Response(
          JSON.stringify(cached),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Validate input
    if (!requestData.display_mode || !['including_tax', 'excluding_tax'].includes(requestData.display_mode)) {
      return new Response(
        JSON.stringify({ error: 'Invalid display_mode. Must be "including_tax" or "excluding_tax"' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if settings exist
    const { data: existing } = await supabase
      .from('t_tax_settings')
      .select('id, version, display_mode')
      .eq('tenant_id', tenantId)
      .single();
      
    let result;
    let isUpdate = !!existing;
    
    if (existing) {
      // Update with optimistic locking
      const { data, error } = await supabase
        .from('t_tax_settings')
        .update({
          display_mode: requestData.display_mode,
          default_tax_rate_id: requestData.default_tax_rate_id || null,
          version: existing.version + 1,
          updated_at: new Date().toISOString()
        })
        .eq('id', existing.id)
        .eq('version', existing.version)
        .select()
        .single();
        
      if (error) {
        if (error.code === 'PGRST116') {
          return new Response(
            JSON.stringify({ error: 'Settings were modified by another user. Please refresh and try again.' }),
            { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        throw new Error(`Failed to update settings: ${error.message}`);
      }
      
      result = data;
    } else {
      // Create new settings
      const { data, error } = await supabase
        .from('t_tax_settings')
        .insert({
          tenant_id: tenantId,
          display_mode: requestData.display_mode,
          default_tax_rate_id: requestData.default_tax_rate_id || null,
          version: 1
        })
        .select()
        .single();
        
      if (error) {
        throw new Error(`Failed to create settings: ${error.message}`);
      }
      
      result = data;
    }
    
    // Cache for idempotency
    if (idempotencyKey) {
      setIdempotencyCache(idempotencyKey, tenantId, result);
    }
    
    await auditLogger.log({
      tenantId,
      action: isUpdate ? AuditActions.TAX_SETTINGS_UPDATE : AuditActions.TAX_SETTINGS_CREATE,
      resource: AuditResources.TAX_SETTINGS,
      resourceId: result.id,
      success: true,
      metadata: { 
        operation: isUpdate ? 'update_settings' : 'create_settings',
        changes: requestData
      }
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
      errorMessage: error.message,
      metadata: { 
        operation: 'create_or_update_settings',
        error: error.message
      }
    });
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleCreateRate(
  supabase: any, 
  auditLogger: any, 
  tenantId: string, 
  req: Request, 
  idempotencyKey: string | null
) {
  try {
    const requestData = await req.json();
    
    // Remove sequence_no from user input
    delete requestData.sequence_no;
    
    // Handle idempotency
    if (idempotencyKey) {
      const cached = getIdempotencyCache(idempotencyKey, tenantId);
      if (cached) {
        return new Response(
          JSON.stringify(cached),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Validate input
    if (!requestData.name || typeof requestData.name !== 'string' || requestData.name.trim().length === 0) {
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
    
    // Check for duplicate name + rate combination
    const { data: existingRate } = await supabase
      .from('t_tax_rates')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('name', requestData.name.trim())
      .eq('rate', rate)
      .eq('is_active', true)
      .single();
      
    if (existingRate) {
      return new Response(
        JSON.stringify({ 
          error: 'Duplicate tax rate',
          message: `A tax rate "${requestData.name.trim()}" with ${rate}% already exists`
        }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // If this rate is being set as default, unset any existing default
    if (requestData.is_default) {
      await supabase
        .from('t_tax_rates')
        .update({ is_default: false })
        .eq('tenant_id', tenantId)
        .eq('is_default', true)
        .eq('is_active', true);
    }
    
    // Auto-generate sequence number
    const { data: maxSeq } = await supabase
      .from('t_tax_rates')
      .select('sequence_no')
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .order('sequence_no', { ascending: false, nullsLast: false })
      .limit(1)
      .single();
      
    const sequenceNo = (maxSeq?.sequence_no || 0) + 10;
    
    // Insert new rate
    const { data, error } = await supabase
      .from('t_tax_rates')
      .insert({
        tenant_id: tenantId,
        name: requestData.name.trim(),
        rate: rate,
        is_default: requestData.is_default || false,
        sequence_no: sequenceNo,
        description: requestData.description?.trim() || null,
        version: 1,
        is_active: true
      })
      .select()
      .single();
      
    if (error) {
      throw new Error(`Failed to create tax rate: ${error.message}`);
    }
    
    // Cache for idempotency
    if (idempotencyKey) {
      setIdempotencyCache(idempotencyKey, tenantId, data);
    }
    
    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_CREATE,
      resource: AuditResources.TAX_RATES,
      resourceId: data.id,
      success: true,
      metadata: { 
        operation: 'create_rate',
        rate_name: data.name,
        rate_value: data.rate
      }
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
      errorMessage: error.message,
      metadata: { 
        operation: 'create_rate',
        error: error.message
      }
    });
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleUpdateRate(
  supabase: any, 
  auditLogger: any, 
  tenantId: string, 
  rateId: string, 
  req: Request, 
  idempotencyKey: string | null
) {
  try {
    const requestData = await req.json();
    
    // Remove sequence_no from user input
    delete requestData.sequence_no;
    
    // Handle idempotency
    if (idempotencyKey) {
      const cached = getIdempotencyCache(idempotencyKey, tenantId);
      if (cached) {
        return new Response(
          JSON.stringify(cached),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // Validate rate ID
    if (!rateId || rateId === 'rates') {
      return new Response(
        JSON.stringify({ error: 'Invalid rate ID' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get current rate
    const { data: current, error: fetchError } = await supabase
      .from('t_tax_rates')
      .select('*')
      .eq('id', rateId)
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .single();
      
    if (fetchError || !current) {
      return new Response(
        JSON.stringify({ error: 'Tax rate not found or has been deleted' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Build update data
    const updateData: any = {
      version: current.version + 1,
      updated_at: new Date().toISOString()
    };
    
    // Track changes
    const changes: any = {};
    
    // Validate and set fields
    if (requestData.name !== undefined) {
      if (!requestData.name || requestData.name.trim().length === 0) {
        return new Response(
          JSON.stringify({ error: 'Name cannot be empty' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.name = requestData.name.trim();
      if (current.name !== requestData.name.trim()) {
        changes.name = { old: current.name, new: requestData.name.trim() };
      }
    }
    
    if (requestData.rate !== undefined) {
      const rate = Number(requestData.rate);
      if (isNaN(rate) || rate < 0 || rate > 100) {
        return new Response(
          JSON.stringify({ error: 'Rate must be a number between 0 and 100' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.rate = rate;
      if (current.rate !== rate) {
        changes.rate = { old: current.rate, new: rate };
      }
    }
    
    // Check for duplicate name + rate combination when either changes
    if (changes.name || changes.rate) {
      const checkName = updateData.name || current.name;
      const checkRate = updateData.rate !== undefined ? updateData.rate : current.rate;
      
      const { data: existingRate } = await supabase
        .from('t_tax_rates')
        .select('id')
        .eq('tenant_id', tenantId)
        .eq('name', checkName)
        .eq('rate', checkRate)
        .eq('is_active', true)
        .neq('id', rateId)
        .single();
        
      if (existingRate) {
        return new Response(
          JSON.stringify({ 
            error: 'Duplicate tax rate',
            message: `A tax rate "${checkName}" with ${checkRate}% already exists`
          }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    if (requestData.description !== undefined) {
      updateData.description = requestData.description?.trim() || null;
    }
    
    if (requestData.is_default !== undefined) {
      updateData.is_default = Boolean(requestData.is_default);
      
      // If setting as default, unset any other defaults
      if (updateData.is_default) {
        await supabase
          .from('t_tax_rates')
          .update({ is_default: false })
          .eq('tenant_id', tenantId)
          .eq('is_default', true)
          .eq('is_active', true)
          .neq('id', rateId);
      }
    }
    
    // Update with optimistic locking
    const { data, error } = await supabase
      .from('t_tax_rates')
      .update(updateData)
      .eq('id', rateId)
      .eq('tenant_id', tenantId)
      .eq('version', current.version)
      .select()
      .single();
      
    if (error) {
      if (error.code === 'PGRST116') {
        return new Response(
          JSON.stringify({ error: 'Tax rate was modified by another user. Please refresh and try again.' }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      throw new Error(`Failed to update tax rate: ${error.message}`);
    }
    
    // Cache for idempotency
    if (idempotencyKey) {
      setIdempotencyCache(idempotencyKey, tenantId, data);
    }
    
    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_UPDATE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: true,
      metadata: { 
        operation: 'update_rate',
        changes: changes,
        rate_name: data.name
      }
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
      errorMessage: error.message,
      metadata: { 
        operation: 'update_rate',
        error: error.message
      }
    });
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

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
    
    // Check if rate exists and get its details
    const { data: existing, error: fetchError } = await supabase
      .from('t_tax_rates')
      .select('id, name, rate, is_active, is_default')
      .eq('id', rateId)
      .eq('tenant_id', tenantId)
      .single();
      
    if (fetchError || !existing) {
      return new Response(
        JSON.stringify({ error: 'Tax rate not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    if (!existing.is_active) {
      return new Response(
        JSON.stringify({ error: 'Tax rate is already deleted' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if this is a default rate
    if (existing.is_default) {
      return new Response(
        JSON.stringify({ error: 'Cannot delete the default tax rate. Please set another rate as default first.' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Soft delete by setting is_active to false
    const { data, error } = await supabase
      .from('t_tax_rates')
      .update({ 
        is_active: false,
        updated_at: new Date().toISOString()
      })
      .eq('id', rateId)
      .eq('tenant_id', tenantId)
      .select()
      .single();
      
    if (error) {
      throw new Error(`Failed to delete tax rate: ${error.message}`);
    }
    
    await auditLogger.log({
      tenantId,
      action: AuditActions.TAX_RATE_DELETE,
      resource: AuditResources.TAX_RATES,
      resourceId: rateId,
      success: true,
      severity: AuditSeverity.CRITICAL,
      metadata: { 
        operation: 'soft_delete_completed',
        deleted_rate: {
          name: existing.name,
          rate: existing.rate,
          was_default: existing.is_default
        }
      }
    });
    
    return new Response(
      JSON.stringify({ 
        success: true, 
        message: 'Tax rate deleted successfully',
        deletedRate: {
          id: data.id,
          name: data.name
        }
      }),
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
      errorMessage: error.message,
      metadata: { 
        operation: 'delete_rate',
        error: error.message
      }
    });
    
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

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

async function checkRateLimit(tenantId: string, userId: string): Promise<{
  allowed: boolean;
  limit: number;
  remaining: number;
  resetTime: number;
}> {
  const key = `${tenantId}:${userId}`;
  const now = Date.now();
  const windowMs = 60000; // 1 minute window
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

function getIdempotencyCache(key: string, tenantId: string): any | null {
  const cacheKey = `${tenantId}:${key}`;
  const cached = idempotencyCache.get(cacheKey);
  
  if (cached && Date.now() < cached.expiresAt) {
    return cached.data;
  }
  
  if (cached) {
    idempotencyCache.delete(cacheKey);
  }
  
  return null;
}

function setIdempotencyCache(key: string, tenantId: string, data: any): void {
  const cacheKey = `${tenantId}:${key}`;
  const expiresAt = Date.now() + (15 * 60 * 1000); // 15 minutes
  
  idempotencyCache.set(cacheKey, { data, expiresAt });
  
  // Clean up expired entries
  for (const [entryKey, value] of idempotencyCache.entries()) {
    if (Date.now() >= value.expiresAt) {
      idempotencyCache.delete(entryKey);
    }
  }
}