// supabase/functions/masterdata/index.ts
// UPDATED: Added caching and idempotency for scale (no RPC consolidation)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, idempotency-key'
};

// ============================================
// IN-MEMORY CACHE (15 seconds TTL)
// ============================================
interface CacheEntry {
  data: any;
  timestamp: number;
}

const cache = new Map<string, CacheEntry>();
const CACHE_TTL_MS = 15 * 1000; // 15 seconds

function getCacheKey(type: string, tenantId: string, categoryId?: string): string {
  if (categoryId) {
    return `${type}:${tenantId}:${categoryId}`;
  }
  return `${type}:${tenantId}`;
}

function getFromCache(key: string): any | null {
  const entry = cache.get(key);
  if (entry && Date.now() - entry.timestamp < CACHE_TTL_MS) {
    console.log(`Cache HIT for key: ${key}`);
    return entry.data;
  }
  if (entry) {
    cache.delete(key); // Clean up expired entry
  }
  console.log(`Cache MISS for key: ${key}`);
  return null;
}

function setCache(key: string, data: any): void {
  cache.set(key, { data, timestamp: Date.now() });
  console.log(`Cache SET for key: ${key}`);
}

function invalidateCache(tenantId: string, categoryId?: string): void {
  // Invalidate specific category cache
  if (categoryId) {
    const detailsKey = getCacheKey('details', tenantId, categoryId);
    const sequenceKey = getCacheKey('sequence', tenantId, categoryId);
    cache.delete(detailsKey);
    cache.delete(sequenceKey);
    console.log(`Cache INVALIDATED for category: ${categoryId}`);
  }
  // Always invalidate categories list when data changes
  const categoriesKey = getCacheKey('categories', tenantId);
  cache.delete(categoriesKey);
}

// ============================================
// IDEMPOTENCY HELPERS (compatible with tax-settings schema)
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
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    // Get auth header and extract token
    const authHeader = req.headers.get('Authorization');
    const token = authHeader?.replace('Bearer ', '');
    const tenantHeader = req.headers.get('x-tenant-id');
    const idempotencyKey = req.headers.get('idempotency-key');

    if (!authHeader || !token) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Create supabase client with the service role key
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          Authorization: authHeader,
          'x-tenant-id': tenantHeader || ''
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Get user from token
    const { data: userData, error: userError } = await supabase.auth.getUser(token);

    if (userError || !userData?.user) {
      console.error('User retrieval error:', userError?.message || 'User not found');
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Parse URL to get path segments and query parameters
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const resourceType = pathSegments.length > 1 ? pathSegments[1] : null;

    // Handle different resources
    if (resourceType === 'categories') {
      const tenantId = url.searchParams.get('tenantId');

      if (!tenantId) {
        return new Response(
          JSON.stringify({ error: 'tenantId is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      // Get all categories for tenant (with caching)
      return await getCategories(supabase, tenantId);
    }
    else if (resourceType === 'category-details') {
      const tenantId = url.searchParams.get('tenantId');
      const categoryId = url.searchParams.get('categoryId');
      const detailId = url.searchParams.get('id');

      if (req.method === 'GET') {
        // For GET requests, tenantId is required from URL
        if (!tenantId) {
          return new Response(
            JSON.stringify({ error: 'tenantId is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        if (url.searchParams.get('nextSequence') === 'true' && categoryId) {
          // Get next sequence number (with caching)
          return await getNextSequenceNumber(supabase, categoryId, tenantId);
        } else if (categoryId) {
          // Get category details (with caching)
          return await getCategoryDetails(supabase, categoryId, tenantId);
        }
      }
      else if (req.method === 'POST') {
        // Add new category detail
        // For POST, tenantId comes from request body or header, not URL
        const data = await req.json();
        const postTenantId = data.tenantid || tenantHeader || tenantId;

        // Validate tenantId is available
        if (!postTenantId) {
          return new Response(
            JSON.stringify({ error: 'tenantId is required (provide in body as tenantid or via x-tenant-id header)' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Ensure tenantid is set in data for the insert operation
        data.tenantid = postTenantId;

        // Check idempotency first
        if (idempotencyKey && postTenantId) {
          const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, postTenantId);
          if (idempotencyResult.exists) {
            return new Response(
              JSON.stringify(idempotencyResult.response),
              { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        }

        return await addCategoryDetail(supabase, data, idempotencyKey);
      }
      else if (req.method === 'PATCH' && detailId) {
        // Update category detail
        // For PATCH, tenantId comes from request body or header
        const data = await req.json();
        const patchTenantId = data.tenantid || tenantHeader || tenantId;

        // Check idempotency first
        if (idempotencyKey && patchTenantId) {
          const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, patchTenantId);
          if (idempotencyResult.exists) {
            return new Response(
              JSON.stringify(idempotencyResult.response),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        }

        return await updateCategoryDetail(supabase, detailId, data, idempotencyKey);
      }
      else if (req.method === 'DELETE' && detailId) {
        // For DELETE, tenantId comes from URL query param or header
        const deleteTenantId = tenantId || tenantHeader;

        // Validate tenantId is available
        if (!deleteTenantId) {
          return new Response(
            JSON.stringify({ error: 'tenantId is required (provide in URL query param or via x-tenant-id header)' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Check idempotency first
        if (idempotencyKey && deleteTenantId) {
          const idempotencyResult = await checkIdempotency(supabase, idempotencyKey, deleteTenantId);
          if (idempotencyResult.exists) {
            return new Response(
              JSON.stringify(idempotencyResult.response),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        }

        // Delete category detail
        return await softDeleteCategoryDetail(supabase, detailId, deleteTenantId, idempotencyKey);
      }
    }

    return new Response(
      JSON.stringify({ error: 'Invalid resource type or method' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error processing request:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// ============================================
// GET CATEGORIES (with caching)
// ============================================
async function getCategories(supabase: any, tenantId: string) {
  try {
    // Check cache first
    const cacheKey = getCacheKey('categories', tenantId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify(cachedData),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_master')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .eq('is_live', true)
      .order('order_sequence', { ascending: true, nullsLast: true });

    if (error) throw error;

    // Transform column names to match frontend expectations
    const transformedData = data.map((item: any) => ({
      id: item.id,
      CategoryName: item.category_name,
      DisplayName: item.display_name,
      is_active: item.is_active,
      Description: item.description,
      icon_name: item.icon_name,
      order_sequence: item.order_sequence,
      tenantid: item.tenant_id,
      created_at: item.created_at
    }));

    // Set cache
    setCache(cacheKey, transformedData);

    return new Response(
      JSON.stringify(transformedData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error fetching categories:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================
// GET CATEGORY DETAILS (with caching)
// ============================================
async function getCategoryDetails(supabase: any, categoryId: string, tenantId: string) {
  try {
    // Check cache first
    const cacheKey = getCacheKey('details', tenantId, categoryId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify(cachedData),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_details')
      .select('*')
      .eq('category_id', categoryId)
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .eq('is_live', true)
      .order('sequence_no', { ascending: true, nullsLast: true });

    if (error) throw error;

    // Transform column names to match frontend expectations
    const transformedData = data.map((item: any) => ({
      id: item.id,
      SubCatName: item.sub_cat_name,
      DisplayName: item.display_name,
      category_id: item.category_id,
      hexcolor: item.hexcolor,
      icon_name: item.icon_name,
      tags: item.tags,
      tool_tip: item.tool_tip,
      is_active: item.is_active,
      Sequence_no: item.sequence_no,
      Description: item.description,
      tenantid: item.tenant_id,
      is_deletable: item.is_deletable,
      form_settings: item.form_settings,
      created_at: item.created_at
    }));

    // Set cache
    setCache(cacheKey, transformedData);

    return new Response(
      JSON.stringify(transformedData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error fetching category details:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================
// GET NEXT SEQUENCE NUMBER (with caching)
// ============================================
async function getNextSequenceNumber(supabase: any, categoryId: string, tenantId: string) {
  try {
    // Check cache first
    const cacheKey = getCacheKey('sequence', tenantId, categoryId);
    const cachedData = getFromCache(cacheKey);
    if (cachedData) {
      return new Response(
        JSON.stringify(cachedData),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const { data, error } = await supabase
      .from('t_category_details')
      .select('sequence_no')
      .eq('category_id', categoryId)
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .eq('is_live', true);

    if (error) throw error;

    const maxSequence = data.length > 0
      ? Math.max(...data.map((d: any) => d.sequence_no || 0), 0)
      : 0;

    const responseData = { nextSequence: maxSequence + 1 };

    // Set cache
    setCache(cacheKey, responseData);

    return new Response(
      JSON.stringify(responseData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error calculating next sequence number:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================
// ADD CATEGORY DETAIL (with idempotency)
// ============================================
async function addCategoryDetail(supabase: any, detail: any, idempotencyKey: string | null) {
  try {
    const { data, error } = await supabase
      .from('t_category_details')
      .insert([{
        sub_cat_name: detail.SubCatName,
        display_name: detail.DisplayName,
        category_id: detail.category_id,
        hexcolor: detail.hexcolor,
        icon_name: detail.icon_name,
        tags: detail.tags,
        tool_tip: detail.tool_tip,
        is_active: detail.is_active !== undefined ? detail.is_active : true,
        sequence_no: detail.Sequence_no,
        description: detail.Description,
        tenant_id: detail.tenantid,
        is_deletable: detail.is_deletable !== undefined ? detail.is_deletable : true,
        form_settings: detail.form_settings,
        is_live: true
      }])
      .select();

    if (error) throw error;

    // Transform response to match frontend expectations
    const transformedData = {
      id: data[0].id,
      SubCatName: data[0].sub_cat_name,
      DisplayName: data[0].display_name,
      category_id: data[0].category_id,
      hexcolor: data[0].hexcolor,
      icon_name: data[0].icon_name,
      tags: data[0].tags,
      tool_tip: data[0].tool_tip,
      is_active: data[0].is_active,
      Sequence_no: data[0].sequence_no,
      Description: data[0].description,
      tenantid: data[0].tenant_id,
      is_deletable: data[0].is_deletable,
      form_settings: data[0].form_settings,
      created_at: data[0].created_at
    };

    // Invalidate cache for this category
    invalidateCache(detail.tenantid, detail.category_id);

    // Save idempotency
    if (idempotencyKey && detail.tenantid) {
      await saveIdempotency(supabase, idempotencyKey, detail.tenantid, transformedData);
    }

    return new Response(
      JSON.stringify(transformedData),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error adding category detail:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================
// UPDATE CATEGORY DETAIL (with idempotency)
// ============================================
async function updateCategoryDetail(supabase: any, detailId: string, updates: any, idempotencyKey: string | null) {
  try {
    // Transform the updates to match database column names
    const dbUpdates: any = {};
    if (updates.SubCatName !== undefined) dbUpdates.sub_cat_name = updates.SubCatName;
    if (updates.DisplayName !== undefined) dbUpdates.display_name = updates.DisplayName;
    if (updates.hexcolor !== undefined) dbUpdates.hexcolor = updates.hexcolor;
    if (updates.icon_name !== undefined) dbUpdates.icon_name = updates.icon_name;
    if (updates.tags !== undefined) dbUpdates.tags = updates.tags;
    if (updates.tool_tip !== undefined) dbUpdates.tool_tip = updates.tool_tip;
    if (updates.is_active !== undefined) dbUpdates.is_active = updates.is_active;
    if (updates.Sequence_no !== undefined) dbUpdates.sequence_no = updates.Sequence_no;
    if (updates.Description !== undefined) dbUpdates.description = updates.Description;
    if (updates.is_deletable !== undefined) dbUpdates.is_deletable = updates.is_deletable;
    if (updates.form_settings !== undefined) dbUpdates.form_settings = updates.form_settings;

    const { data, error } = await supabase
      .from('t_category_details')
      .update(dbUpdates)
      .eq('id', detailId)
      .select();

    if (error) throw error;

    // Transform response to match frontend expectations
    const transformedData = {
      id: data[0].id,
      SubCatName: data[0].sub_cat_name,
      DisplayName: data[0].display_name,
      category_id: data[0].category_id,
      hexcolor: data[0].hexcolor,
      icon_name: data[0].icon_name,
      tags: data[0].tags,
      tool_tip: data[0].tool_tip,
      is_active: data[0].is_active,
      Sequence_no: data[0].sequence_no,
      Description: data[0].description,
      tenantid: data[0].tenant_id,
      is_deletable: data[0].is_deletable,
      form_settings: data[0].form_settings,
      created_at: data[0].created_at
    };

    // Invalidate cache for this category
    invalidateCache(data[0].tenant_id, data[0].category_id);

    // Save idempotency
    if (idempotencyKey && data[0].tenant_id) {
      await saveIdempotency(supabase, idempotencyKey, data[0].tenant_id, transformedData);
    }

    return new Response(
      JSON.stringify(transformedData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error updating category detail:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ============================================
// SOFT DELETE CATEGORY DETAIL (with idempotency)
// ============================================
async function softDeleteCategoryDetail(supabase: any, detailId: string, tenantId: string, idempotencyKey: string | null) {
  try {
    // First get the category_id for cache invalidation
    const { data: existingData, error: fetchError } = await supabase
      .from('t_category_details')
      .select('category_id')
      .eq('id', detailId)
      .single();

    if (fetchError) throw fetchError;

    const { error } = await supabase
      .from('t_category_details')
      .update({ is_active: false })
      .eq('id', detailId)
      .eq('tenant_id', tenantId);

    if (error) throw error;

    const responseData = { success: true };

    // Invalidate cache for this category
    if (existingData?.category_id) {
      invalidateCache(tenantId, existingData.category_id);
    }

    // Save idempotency
    if (idempotencyKey && tenantId) {
      await saveIdempotency(supabase, idempotencyKey, tenantId, responseData);
    }

    return new Response(
      JSON.stringify(responseData),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error soft deleting category detail:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}
