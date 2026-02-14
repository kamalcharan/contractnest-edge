// supabase/functions/tenant-profile/index.ts
// UPDATED: Added caching for GET, fixed race condition with upsert for POST
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

// ✅ NEW: In-memory cache for tenant profiles (30 second TTL)
const profileCache = new Map<string, { data: any; expiry: number }>();
const CACHE_TTL_MS = 30000; // 30 seconds

// Helper to get cached profile
function getCachedProfile(tenantId: string): any | null {
  const cached = profileCache.get(tenantId);
  if (cached && Date.now() < cached.expiry) {
    console.log('Cache HIT for tenant:', tenantId);
    return cached.data;
  }
  if (cached) {
    profileCache.delete(tenantId); // Clean expired entry
  }
  console.log('Cache MISS for tenant:', tenantId);
  return null;
}

// Helper to set cached profile
function setCachedProfile(tenantId: string, data: any): void {
  profileCache.set(tenantId, {
    data,
    expiry: Date.now() + CACHE_TTL_MS
  });
  console.log('Cache SET for tenant:', tenantId);
}

// Helper to invalidate cache
function invalidateCache(tenantId: string): void {
  profileCache.delete(tenantId);
  console.log('Cache INVALIDATED for tenant:', tenantId);
}

// Helper to transform DB record to API response format
function transformProfileToResponse(data: any): any {
  if (!data) return null;
  return {
    id: data.id,
    tenant_id: data.tenant_id,
    business_type_id: data.profile_type, // Using profile_type for business_type_id
    industry_id: data.industry_id,
    business_name: data.business_name,
    logo_url: data.logo_url,
    address_line1: data.address_line1,
    address_line2: data.address_line2,
    city: data.city,
    state_code: data.state_code,
    country_code: data.country_code,
    postal_code: data.postal_code,
    business_phone_country_code: data.business_phone_country_code,
    business_phone: data.business_phone,
    business_email: data.business_email,
    website_url: data.website_url,
    business_whatsapp_country_code: data.business_whatsapp_country_code,
    business_whatsapp: data.business_whatsapp,
    booking_url: data.booking_url,
    contact_first_name: data.contact_first_name,
    contact_last_name: data.contact_last_name,
    primary_color: data.primary_color,
    secondary_color: data.secondary_color,
    created_at: data.created_at,
    updated_at: data.updated_at
  };
}

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
    const tenantHeader = req.headers.get('x-tenant-id');

    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!tenantHeader) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Verify the user is authenticated by checking their token
    const userToken = authHeader.replace('Bearer ', '');

    // Create a client with user's token to verify authentication
    const userClient = createClient(supabaseUrl, supabaseKey, {
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

    // Verify the user is authenticated
    const { data: { user }, error: authError } = await userClient.auth.getUser(userToken);

    if (authError || !user) {
      console.error('Auth verification failed:', authError);
      return new Response(
        JSON.stringify({ error: 'Invalid or expired authentication token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('Authenticated user:', user.id);

    // Verify user has access to this tenant
    const { data: userTenant, error: tenantAccessError } = await userClient
      .from('t_user_tenants')
      .select('id, status')
      .eq('user_id', user.id)
      .eq('tenant_id', tenantHeader)
      .single();

    if (tenantAccessError || !userTenant || userTenant.status !== 'active') {
      console.error('Tenant access check failed:', tenantAccessError);
      return new Response(
        JSON.stringify({ error: 'User does not have access to this tenant' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    console.log('User tenant access verified:', userTenant.id);

    // Create supabase client with service role key (bypasses RLS for operations)
    // This is safe because we've already verified user authentication and tenant access above
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Parse URL to determine sub-route
    const url = new URL(req.url);

    // Use both pathname and raw URL for robust sub-path detection
    // (Supabase Edge Runtime may rewrite the URL internally)
    const rawUrl = req.url;
    const pathname = url.pathname;
    const isServedIndustriesRoute = pathname.includes('/served-industries') || rawUrl.includes('/served-industries');
    const isLogoRoute = pathname.includes('/logo') || rawUrl.includes('/logo');
    const isUnlockPreviewRoute = pathname.includes('/unlock-preview') || rawUrl.includes('/unlock-preview');

    console.log('Request URL (raw):', rawUrl);
    console.log('Request path (parsed):', pathname);
    console.log('HTTP method:', req.method);
    console.log('Route detection:', { isServedIndustriesRoute, isLogoRoute, isUnlockPreviewRoute });
    console.log('Tenant header:', tenantHeader);

    // =========================================================================
    // SPECIFIC SUB-PATH ROUTES (checked FIRST, before generic profile CRUD)
    // =========================================================================

    // GET /served-industries/unlock-preview - Get template counts by served industries
    if (req.method === 'GET' && isServedIndustriesRoute && isUnlockPreviewRoute) {
      try {
        // Get the tenant's served industries first
        const { data: servedIndustries, error: siError } = await supabase
          .from('t_tenant_served_industries')
          .select('industry_id')
          .eq('tenant_id', tenantHeader);

        if (siError) throw siError;

        const industryIds = (servedIndustries || []).map((si: any) => si.industry_id);

        if (industryIds.length === 0) {
          return new Response(
            JSON.stringify({
              success: true,
              data: {
                total_templates: 0,
                by_industry: [],
                by_resource_type: []
              }
            }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Get resource template counts grouped by industry
        const { data: templatesByIndustry, error: tiError } = await supabase
          .from('m_catalog_resource_templates')
          .select('industry_id, resource_type_id, name, is_recommended')
          .in('industry_id', industryIds)
          .eq('is_active', true)
          .order('popularity_score', { ascending: false });

        if (tiError) throw tiError;

        const templates = templatesByIndustry || [];

        // Aggregate by industry
        const byIndustryMap: Record<string, { count: number; recommended: number; templates: string[] }> = {};
        const byResourceTypeMap: Record<string, { count: number; templates: string[] }> = {};

        for (const t of templates) {
          // By industry
          if (!byIndustryMap[t.industry_id]) {
            byIndustryMap[t.industry_id] = { count: 0, recommended: 0, templates: [] };
          }
          byIndustryMap[t.industry_id].count++;
          if (t.is_recommended) byIndustryMap[t.industry_id].recommended++;
          byIndustryMap[t.industry_id].templates.push(t.name);

          // By resource type
          if (!byResourceTypeMap[t.resource_type_id]) {
            byResourceTypeMap[t.resource_type_id] = { count: 0, templates: [] };
          }
          byResourceTypeMap[t.resource_type_id].count++;
          byResourceTypeMap[t.resource_type_id].templates.push(t.name);
        }

        const byIndustry = Object.entries(byIndustryMap).map(([id, data]) => ({
          industry_id: id,
          template_count: data.count,
          recommended_count: data.recommended,
          sample_templates: data.templates.slice(0, 5)
        }));

        const byResourceType = Object.entries(byResourceTypeMap).map(([id, data]) => ({
          resource_type_id: id,
          template_count: data.count,
          sample_templates: data.templates.slice(0, 5)
        }));

        return new Response(
          JSON.stringify({
            success: true,
            data: {
              total_templates: templates.length,
              by_industry: byIndustry,
              by_resource_type: byResourceType
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error in GET /served-industries/unlock-preview:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to get unlock preview', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // GET /served-industries - List industries this tenant serves
    if (req.method === 'GET' && isServedIndustriesRoute) {
      try {
        const { data, error } = await supabase
          .from('t_tenant_served_industries')
          .select(`
            id,
            industry_id,
            added_by,
            created_at,
            industry:m_catalog_industries (
              id,
              name,
              description,
              icon,
              is_active,
              sort_order,
              parent_id,
              level,
              segment_type
            )
          `)
          .eq('tenant_id', tenantHeader)
          .order('created_at', { ascending: true });

        if (error) {
          console.error('Error fetching served industries:', error);
          throw error;
        }

        const industries = data || [];
        return new Response(
          JSON.stringify({ success: true, data: industries, count: industries.length }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error in GET /served-industries:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to fetch served industries', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /served-industries - Add one or more served industries
    if (req.method === 'POST' && isServedIndustriesRoute) {
      try {
        const requestData = await req.json();
        const { industry_ids } = requestData;

        if (!industry_ids || !Array.isArray(industry_ids) || industry_ids.length === 0) {
          return new Response(
            JSON.stringify({ error: 'industry_ids must be a non-empty array' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Validate max selection (reasonable limit)
        if (industry_ids.length > 20) {
          return new Response(
            JSON.stringify({ error: 'Cannot add more than 20 industries at once' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Build records for upsert
        const records = industry_ids.map((industryId: string) => ({
          tenant_id: tenantHeader,
          industry_id: industryId,
          added_by: user.id
        }));

        // Use upsert to handle duplicates gracefully
        const { data, error } = await supabase
          .from('t_tenant_served_industries')
          .upsert(records, {
            onConflict: 'tenant_id,industry_id',
            ignoreDuplicates: true
          })
          .select(`
            id,
            industry_id,
            added_by,
            created_at,
            industry:m_catalog_industries (
              id,
              name,
              description,
              icon,
              is_active,
              sort_order,
              parent_id,
              level,
              segment_type
            )
          `);

        if (error) {
          console.error('Error adding served industries:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({ success: true, data: data || [], added_count: industry_ids.length }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error in POST /served-industries:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to add served industries', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // DELETE /served-industries - Remove a served industry
    if (req.method === 'DELETE' && isServedIndustriesRoute) {
      try {
        // Get industry_id from query param
        const industryId = url.searchParams.get('industry_id');

        if (!industryId) {
          return new Response(
            JSON.stringify({ error: 'industry_id query parameter is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { error } = await supabase
          .from('t_tenant_served_industries')
          .delete()
          .eq('tenant_id', tenantHeader)
          .eq('industry_id', industryId);

        if (error) {
          console.error('Error removing served industry:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({ success: true, removed_industry_id: industryId }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error in DELETE /served-industries:', error);
        return new Response(
          JSON.stringify({ error: 'Failed to remove served industry', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /logo - Update logo URL (receives URL from API layer after Firebase upload)
    // NOTE: Actual file upload is handled by API layer using Firebase Storage
    if (req.method === 'POST' && isLogoRoute) {
      try {
        const requestData = await req.json();
        const { logo_url } = requestData;

        if (!logo_url) {
          return new Response(
            JSON.stringify({ error: 'logo_url is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Update the profile with new logo URL
        const { error } = await supabase
          .from('t_tenant_profiles')
          .update({ logo_url })
          .eq('tenant_id', tenantHeader);

        if (error) throw error;

        // Invalidate cache
        invalidateCache(tenantHeader);

        return new Response(
          JSON.stringify({ success: true, url: logo_url }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error updating logo:', error);

        return new Response(
          JSON.stringify({ error: 'Failed to update logo', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // =========================================================================
    // GENERIC TENANT PROFILE CRUD (catch-all, checked LAST)
    // =========================================================================

    // GET - Fetch tenant profile (with caching)
    if (req.method === 'GET') {
      try {
        // ✅ NEW: Check cache first
        const cachedProfile = getCachedProfile(tenantHeader);
        if (cachedProfile !== null) {
          return new Response(
            JSON.stringify(cachedProfile),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Query the tenant profile for this tenant
        const { data, error } = await supabase
          .from('t_tenant_profiles')
          .select('*')
          .eq('tenant_id', tenantHeader)
          .single();

        if (error) {
          console.error('Error fetching tenant profile:', error);

          // If no rows found, it's not an error - just return null
          if (error.code === 'PGRST116') {
            // ✅ Cache null result too (to avoid repeated DB calls)
            setCachedProfile(tenantHeader, null);
            return new Response(
              JSON.stringify(null),
              { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }

          throw error;
        }

        // Transform and cache the result
        const transformedData = transformProfileToResponse(data);
        setCachedProfile(tenantHeader, transformedData);

        return new Response(
          JSON.stringify(transformedData),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (dbError: any) {
        console.error('Database error when fetching tenant profile:', dbError);

        return new Response(
          JSON.stringify({ error: 'Failed to fetch tenant profile', details: dbError.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST - Create new tenant profile (with atomic upsert to prevent race condition)
    if (req.method === 'POST') {
      try {
        // Parse request body
        const requestData = await req.json();

        // Validate required fields
        if (!requestData.business_name) {
          return new Response(
            JSON.stringify({ error: 'business_name is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Map request to database structure
        const dbRecord = {
          tenant_id: tenantHeader,
          profile_type: requestData.business_type_id,
          industry_id: requestData.industry_id,
          business_name: requestData.business_name,
          business_email: requestData.business_email,
          business_phone_country_code: requestData.business_phone_country_code,
          business_phone: requestData.business_phone,
          business_whatsapp_country_code: requestData.business_whatsapp_country_code,
          business_whatsapp: requestData.business_whatsapp,
          booking_url: requestData.booking_url,
          contact_first_name: requestData.contact_first_name,
          contact_last_name: requestData.contact_last_name,
          country_code: requestData.country_code,
          state_code: requestData.state_code,
          address_line1: requestData.address_line1,
          address_line2: requestData.address_line2,
          city: requestData.city,
          postal_code: requestData.postal_code,
          logo_url: requestData.logo_url,
          primary_color: requestData.primary_color,
          secondary_color: requestData.secondary_color,
          website_url: requestData.website_url
        };

        // ✅ FIX: Use atomic upsert instead of check-then-insert (prevents race condition)
        const { data, error } = await supabase
          .from('t_tenant_profiles')
          .upsert(dbRecord, {
            onConflict: 'tenant_id',
            ignoreDuplicates: false
          })
          .select();

        if (error) {
          console.error('Error upserting tenant profile:', error);
          throw error;
        }

        if (!data || data.length === 0) {
          throw new Error('No data returned from upsert');
        }

        const result = data[0];

        // ✅ Invalidate cache after write
        invalidateCache(tenantHeader);

        // Transform response to match frontend expectations
        const transformedData = transformProfileToResponse(result);

        return new Response(
          JSON.stringify(transformedData),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error creating tenant profile:', error);

        return new Response(
          JSON.stringify({ error: 'Failed to create tenant profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // PUT - Update tenant profile (with optimistic locking)
    if (req.method === 'PUT') {
      try {
        // Parse request body
        const requestData = await req.json();

        // Validate required fields
        if (!requestData.business_name) {
          return new Response(
            JSON.stringify({ error: 'business_name is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // ✅ Optimistic locking: Check if updated_at matches before updating
        const clientUpdatedAt = requestData.updated_at;
        if (clientUpdatedAt) {
          // Fetch current record to check version
          const { data: currentData, error: fetchError } = await supabase
            .from('t_tenant_profiles')
            .select('updated_at')
            .eq('tenant_id', tenantHeader)
            .single();

          if (fetchError && fetchError.code !== 'PGRST116') {
            throw fetchError;
          }

          if (currentData && currentData.updated_at !== clientUpdatedAt) {
            console.log('Optimistic lock conflict:', {
              clientVersion: clientUpdatedAt,
              serverVersion: currentData.updated_at
            });

            return new Response(
              JSON.stringify({
                error: 'Conflict: Profile was modified by another session',
                code: 'OPTIMISTIC_LOCK_CONFLICT',
                clientVersion: clientUpdatedAt,
                serverVersion: currentData.updated_at
              }),
              { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
        }

        // Map request to database structure (without tenant_id for update)
        const dbRecord = {
          profile_type: requestData.business_type_id,
          industry_id: requestData.industry_id,
          business_name: requestData.business_name,
          business_email: requestData.business_email,
          business_phone_country_code: requestData.business_phone_country_code,
          business_phone: requestData.business_phone,
          business_whatsapp_country_code: requestData.business_whatsapp_country_code,
          business_whatsapp: requestData.business_whatsapp,
          booking_url: requestData.booking_url,
          contact_first_name: requestData.contact_first_name,
          contact_last_name: requestData.contact_last_name,
          country_code: requestData.country_code,
          state_code: requestData.state_code,
          address_line1: requestData.address_line1,
          address_line2: requestData.address_line2,
          city: requestData.city,
          postal_code: requestData.postal_code,
          logo_url: requestData.logo_url,
          primary_color: requestData.primary_color,
          secondary_color: requestData.secondary_color,
          website_url: requestData.website_url
        };

        // Update the profile directly by tenant_id
        const { data, error } = await supabase
          .from('t_tenant_profiles')
          .update(dbRecord)
          .eq('tenant_id', tenantHeader)
          .select();

        if (error) throw error;

        if (!data || data.length === 0) {
          return new Response(
            JSON.stringify({ error: 'Tenant profile not found' }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // ✅ Invalidate cache after write
        invalidateCache(tenantHeader);

        // Transform response to match frontend expectations
        const result = data[0];
        const transformedData = transformProfileToResponse(result);

        return new Response(
          JSON.stringify(transformedData),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error: any) {
        console.error('Error updating tenant profile:', error);

        return new Response(
          JSON.stringify({ error: 'Failed to update tenant profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // If no matching endpoint is found
    return new Response(
      JSON.stringify({
        error: 'Invalid endpoint or method',
        availableEndpoints: [
          'GET / (Fetch tenant profile)',
          'POST / (Create tenant profile)',
          'PUT / (Update tenant profile)',
          'POST /logo (Update logo URL)',
          'GET /served-industries (List served industries)',
          'POST /served-industries (Add served industries)',
          'DELETE /served-industries?industry_id=X (Remove served industry)',
          'GET /served-industries/unlock-preview (Template counts)'
        ],
        requestedMethod: req.method,
        requestedPath: url.pathname
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error processing request:', error.message);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
