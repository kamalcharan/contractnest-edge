// supabase/functions/resources/index.ts
// SCALE-OPTIMIZED VERSION - 15s caching + database-backed idempotency
// Updated: January 2025

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-idempotency-key',
  'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS'
};

// ============================================
// IN-MEMORY CACHE (15-second TTL)
// ============================================
interface CacheEntry {
  data: any;
  timestamp: number;
}

const cache = new Map<string, CacheEntry>();
const CACHE_TTL_MS = 15 * 1000; // 15 seconds

function getCacheKey(type: string, tenantId: string, resourceTypeId?: string): string {
  if (resourceTypeId) {
    return `resources:${tenantId}:${type}:${resourceTypeId}`;
  }
  return `resources:${tenantId}:${type}`;
}

function getFromCache(key: string): any | null {
  const entry = cache.get(key);
  if (!entry) return null;

  if (Date.now() - entry.timestamp > CACHE_TTL_MS) {
    cache.delete(key);
    console.log(`Cache EXPIRED for key: ${key}`);
    return null;
  }

  console.log(`Cache HIT for key: ${key}`);
  return entry.data;
}

function setCache(key: string, data: any): void {
  cache.set(key, { data, timestamp: Date.now() });
  console.log(`Cache SET for key: ${key}`);
}

function invalidateCache(tenantId: string, resourceTypeId?: string): void {
  // Invalidate specific resource type cache
  if (resourceTypeId) {
    const resourcesKey = getCacheKey('list', tenantId, resourceTypeId);
    cache.delete(resourcesKey);
    console.log(`Cache INVALIDATED for resource type: ${resourceTypeId}`);
  }

  // Invalidate all resources cache for tenant
  const allResourcesKey = getCacheKey('all', tenantId);
  cache.delete(allResourcesKey);

  // Invalidate resource types cache
  const typesKey = getCacheKey('types', tenantId);
  cache.delete(typesKey);
}

// ============================================
// IDEMPOTENCY HELPERS (compatible with t_idempotency_cache schema)
// ============================================
async function checkIdempotency(supabase: any, idempotencyKey: string, tenantId: string): Promise<{ exists: boolean; response?: any }> {
  if (!idempotencyKey || !tenantId) {
    return { exists: false };
  }

  try {
    const { data, error } = await supabase
      .from('t_idempotency_cache')
      .select('response_data, expires_at')
      .eq('idempotency_key', idempotencyKey)
      .eq('tenant_id', tenantId)
      .single();

    if (error || !data) {
      return { exists: false };
    }

    // Check if entry is still valid (using expires_at field)
    const expiresAt = new Date(data.expires_at).getTime();
    if (Date.now() > expiresAt) {
      // Expired, delete and return not exists
      await supabase
        .from('t_idempotency_cache')
        .delete()
        .eq('idempotency_key', idempotencyKey)
        .eq('tenant_id', tenantId);
      return { exists: false };
    }

    console.log(`Idempotency HIT for key: ${idempotencyKey}`);
    return { exists: true, response: data.response_data };
  } catch (error) {
    // Table might not exist yet - fail silently
    console.warn('Idempotency check skipped (table may not exist):', error.message);
    return { exists: false };
  }
}

async function saveIdempotency(supabase: any, idempotencyKey: string, tenantId: string, responseData: any): Promise<void> {
  if (!idempotencyKey || !tenantId) return;

  try {
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString(); // 15 minutes TTL

    await supabase
      .from('t_idempotency_cache')
      .upsert({
        idempotency_key: idempotencyKey,
        tenant_id: tenantId,
        response_data: responseData,
        created_at: new Date().toISOString(),
        expires_at: expiresAt
      }, {
        onConflict: 'idempotency_key,tenant_id'
      });
    console.log(`Idempotency SAVED for key: ${idempotencyKey}`);
  } catch (error) {
    // Table might not exist yet - fail silently
    console.warn('Idempotency save skipped (table may not exist):', error.message);
  }
}

// ============================================
// MAIN HANDLER
// ============================================
serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantIdHeader = req.headers.get('x-tenant-id');
    const idempotencyKey = req.headers.get('x-idempotency-key');

    console.log(`[Resources] ${req.method} ${req.url}`);

    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!tenantIdHeader) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const tenantId = tenantIdHeader;

    // Create supabase client with service key
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      global: {
        headers: {
          Authorization: authHeader
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Parse URL to get path segments and query parameters
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const resourceSegment = pathSegments[pathSegments.length - 1];

    console.log('Request routing:', {
      pathSegments,
      resourceSegment,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // Health check endpoint
    if (resourceSegment === 'health') {
      return new Response(
        JSON.stringify({
          status: 'ok',
          message: 'Resources edge function is working',
          timestamp: new Date().toISOString(),
          tenantId: tenantId
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Resource types endpoint (with caching)
    if (resourceSegment === 'resource-types' && req.method === 'GET') {
      return await handleGetResourceTypes(supabase, tenantId);
    }

    // Main resources endpoints
    if (req.method === 'GET') {
      return await handleGetResources(supabase, tenantId, url.searchParams);
    }

    if (req.method === 'POST') {
      // Check idempotency first
      if (idempotencyKey) {
        const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, tenantId);
        if (idempotencyResult.exists) {
          return new Response(
            JSON.stringify(idempotencyResult.response),
            { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      return await handleCreateResource(supabase, tenantId, req, idempotencyKey);
    }

    if (req.method === 'PATCH') {
      const resourceId = url.searchParams.get('id');
      if (!resourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required for update' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      // Check idempotency first
      if (idempotencyKey) {
        const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, tenantId);
        if (idempotencyResult.exists) {
          return new Response(
            JSON.stringify(idempotencyResult.response),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      return await handleUpdateResource(supabase, tenantId, resourceId, req, idempotencyKey);
    }

    if (req.method === 'DELETE') {
      const resourceId = url.searchParams.get('id');
      if (!resourceId) {
        return new Response(
          JSON.stringify({ error: 'Resource ID is required for delete' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      // Check idempotency first
      if (idempotencyKey) {
        const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, tenantId);
        if (idempotencyResult.exists) {
          return new Response(
            JSON.stringify(idempotencyResult.response),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      return await handleDeleteResource(supabase, tenantId, resourceId, idempotencyKey);
    }

    // Invalid endpoint
    return new Response(
      JSON.stringify({
        error: 'Invalid endpoint or method',
        availableEndpoints: [
          'GET /resource-types',
          'GET /',
          'POST /',
          'PATCH /?id={id}',
          'DELETE /?id={id}'
        ],
        requestedMethod: req.method,
        requestedPath: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Resources edge function error:', error);

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
// HANDLER FUNCTIONS (with caching)
// ==========================================

async function handleGetResourceTypes(supabase: any, tenantId: string) {
  try {
    // Check cache first
    const cacheKey = getCacheKey('types', tenantId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify({
          success: true,
          data: cachedData,
          cached: true,
          timestamp: new Date().toISOString()
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('m_catalog_resource_types')
      .select('*')
      .eq('is_active', true)
      .order('sort_order', { ascending: true });

    if (error) {
      console.error('Error fetching resource types:', error);
      throw new Error(`Failed to fetch resource types: ${error.message}`);
    }

    // Set cache
    setCache(cacheKey, data);

    return new Response(
      JSON.stringify({
        success: true,
        data: data,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetResourceTypes:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_RESOURCE_TYPES_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetResources(supabase: any, tenantId: string, searchParams: URLSearchParams) {
  try {
    const resourceTypeId = searchParams.get('resourceTypeId');
    const nextSequence = searchParams.get('nextSequence') === 'true';
    const resourceId = searchParams.get('resourceId');

    // Handle next sequence request (no caching - needs fresh data)
    if (nextSequence && resourceTypeId) {
      return await handleGetNextSequence(supabase, tenantId, resourceTypeId);
    }

    // Handle single resource request (no caching - specific resource)
    if (resourceId) {
      return await handleGetSingleResource(supabase, tenantId, resourceId);
    }

    // Handle list request (with caching)
    if (resourceTypeId) {
      return await handleGetResourcesByType(supabase, tenantId, resourceTypeId);
    } else {
      return await handleGetAllResources(supabase, tenantId);
    }

  } catch (error: any) {
    console.error('Error in handleGetResources:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_RESOURCES_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetNextSequence(supabase: any, tenantId: string, resourceTypeId: string) {
  try {
    // First check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', resourceTypeId)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({
          error: 'Invalid resource type',
          code: 'INVALID_RESOURCE_TYPE'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({
          error: 'This resource type does not support manual entry - resources come from contacts',
          code: 'MANUAL_ENTRY_NOT_SUPPORTED'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_resources_master')
      .select('sequence_no')
      .eq('tenant_id', tenantId)
      .eq('resource_type_id', resourceTypeId)
      .eq('is_live', true)
      .eq('is_active', true)
      .order('sequence_no', { ascending: false, nullsLast: false })
      .limit(1);

    if (error) {
      console.error('Error fetching sequence for resource type:', resourceTypeId, error);
      throw new Error(`Failed to fetch sequence: ${error.message}`);
    }

    const maxSequence = data && data.length > 0 ? (data[0].sequence_no || 0) : 0;
    const nextSequence = maxSequence + 1;

    return new Response(
      JSON.stringify({
        success: true,
        data: { nextSequence },
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetNextSequence:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_NEXT_SEQUENCE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetSingleResource(supabase: any, tenantId: string, resourceId: string) {
  try {
    const { data, error } = await supabase
      .from('t_category_resources_master')
      .select('*')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();

    if (error) {
      if (error.code === 'PGRST116') {
        return new Response(
          JSON.stringify({
            error: 'Resource not found',
            code: 'RESOURCE_NOT_FOUND'
          }),
          { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      throw new Error(`Failed to fetch resource: ${error.message}`);
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: [transformResourceForFrontend(data)],
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleGetSingleResource:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_SINGLE_RESOURCE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetResourcesByType(supabase: any, tenantId: string, resourceTypeId: string) {
  try {
    console.log(`Fetching resources for type: ${resourceTypeId}`);

    // Check cache first
    const cacheKey = getCacheKey('list', tenantId, resourceTypeId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify({
          success: true,
          data: cachedData,
          cached: true,
          timestamp: new Date().toISOString()
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check if this resource type allows manual entry
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('*')
      .eq('id', resourceTypeId)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({
          error: 'Invalid resource type',
          code: 'INVALID_RESOURCE_TYPE'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // For contact-based resources, return empty array
    if (resourceType.requires_human_assignment) {
      console.log(`Contact-based resource type: ${resourceTypeId} - returning empty array`);
      const emptyResult: any[] = [];
      setCache(cacheKey, emptyResult);
      return new Response(
        JSON.stringify({
          success: true,
          data: emptyResult,
          message: 'Contact-based resources are handled by the UI',
          timestamp: new Date().toISOString()
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_resources_master')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('resource_type_id', resourceTypeId)
      .eq('is_live', true)
      .eq('is_active', true)
      .order('sequence_no', { ascending: true, nullsLast: true });

    if (error) {
      console.error('Error fetching manual resources:', error);
      throw new Error(`Failed to fetch resources: ${error.message}`);
    }

    console.log(`Found ${data.length} manual entry resources`);

    const transformedData = data.map(transformResourceForFrontend);

    // Set cache
    setCache(cacheKey, transformedData);

    return new Response(
      JSON.stringify({
        success: true,
        data: transformedData,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Error in handleGetResourcesByType:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_RESOURCES_BY_TYPE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetAllResources(supabase: any, tenantId: string) {
  try {
    // Check cache first
    const cacheKey = getCacheKey('all', tenantId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify({
          success: true,
          data: cachedData,
          cached: true,
          timestamp: new Date().toISOString()
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_resources_master')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .eq('is_active', true)
      .order('sequence_no', { ascending: true, nullsLast: true });

    if (error) {
      throw new Error(`Failed to fetch resources: ${error.message}`);
    }

    const transformedData = data.map(transformResourceForFrontend);

    // Set cache
    setCache(cacheKey, transformedData);

    return new Response(
      JSON.stringify({
        success: true,
        data: transformedData,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error: any) {
    console.error('Error in handleGetAllResources:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'GET_ALL_RESOURCES_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleCreateResource(supabase: any, tenantId: string, req: Request, idempotencyKey: string | null) {
  try {
    const requestData = await req.json();

    // First check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', requestData.resource_type_id)
      .single();

    if (typeError || !resourceType) {
      return new Response(
        JSON.stringify({
          error: 'Invalid resource type',
          code: 'INVALID_RESOURCE_TYPE'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({
          error: 'This resource type does not support manual entry. Resources are populated from contacts.',
          code: 'MANUAL_ENTRY_NOT_SUPPORTED'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate required fields
    if (!requestData.name || !requestData.display_name) {
      return new Response(
        JSON.stringify({
          error: 'Name and display_name are required',
          code: 'VALIDATION_ERROR'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check for duplicate names within tenant scope
    const { data: existingResource } = await supabase
      .from('t_category_resources_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('resource_type_id', requestData.resource_type_id)
      .eq('name', requestData.name.trim())
      .eq('is_live', true)
      .eq('is_active', true)
      .single();

    if (existingResource) {
      return new Response(
        JSON.stringify({
          error: 'A resource with this name already exists for this type',
          code: 'DUPLICATE_RESOURCE_NAME'
        }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Auto-generate sequence number if not provided
    if (!requestData.sequence_no) {
      const { data: maxSeqData } = await supabase
        .from('t_category_resources_master')
        .select('sequence_no')
        .eq('tenant_id', tenantId)
        .eq('resource_type_id', requestData.resource_type_id)
        .eq('is_live', true)
        .order('sequence_no', { ascending: false, nullsLast: false })
        .limit(1)
        .single();

      requestData.sequence_no = (maxSeqData?.sequence_no || 0) + 1;
    }

    // Create database record
    const dbRecord = {
      tenant_id: tenantId,
      resource_type_id: requestData.resource_type_id,
      name: requestData.name.trim(),
      display_name: requestData.display_name.trim(),
      description: requestData.description?.trim() || null,
      hexcolor: requestData.hexcolor || null,
      sequence_no: requestData.sequence_no,
      contact_id: requestData.contact_id || null,
      tags: requestData.tags || null,
      form_settings: requestData.form_settings || null,
      is_active: requestData.is_active !== false,
      is_deletable: requestData.is_deletable !== false,
      is_live: true,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString()
    };

    // Insert new record
    const { data, error } = await supabase
      .from('t_category_resources_master')
      .insert([dbRecord])
      .select()
      .single();

    if (error) {
      console.error('Error inserting resource:', error);
      throw new Error(`Failed to create resource: ${error.message}`);
    }

    console.log(`Created resource: ${data.name} for tenant ${tenantId}`);

    const responseData = {
      success: true,
      data: transformResourceForFrontend(data),
      message: 'Resource created successfully',
      timestamp: new Date().toISOString()
    };

    // Invalidate cache
    invalidateCache(tenantId, requestData.resource_type_id);

    // Save idempotency
    if (idempotencyKey) {
      await saveIdempotency(supabase, idempotencyKey, tenantId, responseData);
    }

    return new Response(
      JSON.stringify(responseData),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleCreateResource:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'CREATE_RESOURCE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleUpdateResource(supabase: any, tenantId: string, resourceId: string, req: Request, idempotencyKey: string | null) {
  try {
    const requestData = await req.json();

    // Verify resource belongs to tenant BEFORE update
    const { data: current, error: fetchError } = await supabase
      .from('t_category_resources_master')
      .select('*')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();

    if (fetchError || !current) {
      return new Response(
        JSON.stringify({
          error: 'Resource not found',
          code: 'RESOURCE_NOT_FOUND'
        }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', current.resource_type_id)
      .single();

    if (typeError || !resourceType || resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({
          error: 'This resource cannot be updated as it is managed by the contacts system',
          code: 'UPDATE_NOT_ALLOWED'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Build update data
    const updateData: any = {
      updated_at: new Date().toISOString()
    };

    if (requestData.name !== undefined) {
      if (!requestData.name.trim()) {
        return new Response(
          JSON.stringify({
            error: 'Name cannot be empty',
            code: 'VALIDATION_ERROR'
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.name = requestData.name.trim();
    }

    if (requestData.display_name !== undefined) {
      if (!requestData.display_name.trim()) {
        return new Response(
          JSON.stringify({
            error: 'Display name cannot be empty',
            code: 'VALIDATION_ERROR'
          }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      updateData.display_name = requestData.display_name.trim();
    }

    if (requestData.description !== undefined) {
      updateData.description = requestData.description?.trim() || null;
    }

    if (requestData.hexcolor !== undefined) {
      updateData.hexcolor = requestData.hexcolor || null;
    }

    if (requestData.sequence_no !== undefined) {
      updateData.sequence_no = requestData.sequence_no;
    }

    if (requestData.tags !== undefined) {
      updateData.tags = requestData.tags;
    }

    if (requestData.form_settings !== undefined) {
      updateData.form_settings = requestData.form_settings;
    }

    // Check for duplicate name within tenant scope if name is changing
    if (updateData.name && updateData.name !== current.name) {
      const { data: existingResource } = await supabase
        .from('t_category_resources_master')
        .select('id')
        .eq('tenant_id', tenantId)
        .eq('resource_type_id', current.resource_type_id)
        .eq('name', updateData.name)
        .eq('is_live', true)
        .eq('is_active', true)
        .neq('id', resourceId)
        .single();

      if (existingResource) {
        return new Response(
          JSON.stringify({
            error: 'A resource with this name already exists for this type',
            code: 'DUPLICATE_RESOURCE_NAME'
          }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Update record
    const { data, error } = await supabase
      .from('t_category_resources_master')
      .update(updateData)
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) {
      console.error('Error updating resource:', error);
      throw new Error(`Failed to update resource: ${error.message}`);
    }

    console.log(`Updated resource: ${data.name} for tenant ${tenantId}`);

    const responseData = {
      success: true,
      data: transformResourceForFrontend(data),
      message: 'Resource updated successfully',
      timestamp: new Date().toISOString()
    };

    // Invalidate cache
    invalidateCache(tenantId, current.resource_type_id);

    // Save idempotency
    if (idempotencyKey) {
      await saveIdempotency(supabase, idempotencyKey, tenantId, responseData);
    }

    return new Response(
      JSON.stringify(responseData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleUpdateResource:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'UPDATE_RESOURCE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleDeleteResource(supabase: any, tenantId: string, resourceId: string, idempotencyKey: string | null) {
  try {
    // Verify resource belongs to tenant BEFORE delete
    const { data: current, error: fetchError } = await supabase
      .from('t_category_resources_master')
      .select('*, resource_type_id')
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .eq('is_live', true)
      .single();

    if (fetchError || !current) {
      return new Response(
        JSON.stringify({
          error: 'Resource not found',
          code: 'RESOURCE_NOT_FOUND'
        }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!current.is_active) {
      return new Response(
        JSON.stringify({
          error: 'Resource is already deleted',
          code: 'RESOURCE_ALREADY_DELETED'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Check if this resource type requires human assignment
    const { data: resourceType, error: typeError } = await supabase
      .from('m_catalog_resource_types')
      .select('requires_human_assignment')
      .eq('id', current.resource_type_id)
      .single();

    if (typeError || !resourceType || resourceType.requires_human_assignment) {
      return new Response(
        JSON.stringify({
          error: 'This resource cannot be deleted as it is managed by the contacts system',
          code: 'DELETE_NOT_ALLOWED'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!current.is_deletable) {
      return new Response(
        JSON.stringify({
          error: 'This resource cannot be deleted',
          code: 'RESOURCE_NOT_DELETABLE'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Soft delete by setting is_active to false
    const { data, error } = await supabase
      .from('t_category_resources_master')
      .update({
        is_active: false,
        updated_at: new Date().toISOString()
      })
      .eq('id', resourceId)
      .eq('tenant_id', tenantId)
      .select()
      .single();

    if (error) {
      console.error('Error deleting resource:', error);
      throw new Error(`Failed to delete resource: ${error.message}`);
    }

    console.log(`Deleted resource: ${data.name} for tenant ${tenantId}`);

    const responseData = {
      success: true,
      message: 'Resource deleted successfully',
      data: {
        id: data.id,
        name: data.name
      },
      timestamp: new Date().toISOString()
    };

    // Invalidate cache
    invalidateCache(tenantId, current.resource_type_id);

    // Save idempotency
    if (idempotencyKey) {
      await saveIdempotency(supabase, idempotencyKey, tenantId, responseData);
    }

    return new Response(
      JSON.stringify(responseData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error in handleDeleteResource:', error);

    return new Response(
      JSON.stringify({
        error: error.message,
        code: 'DELETE_RESOURCE_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ==========================================
// UTILITY FUNCTIONS
// ==========================================

function transformResourceForFrontend(dbResource: any) {
  return {
    id: dbResource.id,
    tenant_id: dbResource.tenant_id,
    resource_type_id: dbResource.resource_type_id,
    name: dbResource.name,
    display_name: dbResource.display_name,
    description: dbResource.description,
    hexcolor: dbResource.hexcolor,
    sequence_no: dbResource.sequence_no,
    contact_id: dbResource.contact_id,
    tags: dbResource.tags,
    form_settings: dbResource.form_settings,
    is_active: dbResource.is_active,
    is_deletable: dbResource.is_deletable,
    is_live: dbResource.is_live,
    created_at: dbResource.created_at,
    updated_at: dbResource.updated_at,
    created_by: dbResource.created_by,
    updated_by: dbResource.updated_by,
    // Additional fields expected by UI
    status: dbResource.is_active ? 'active' : 'inactive'
  };
}
