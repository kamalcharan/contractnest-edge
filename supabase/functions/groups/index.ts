// supabase/functions/groups/index.ts
// MEGA FILE: All group operations (memberships, profiles, search, admin)
// ✅ FIXED ROUTING: Properly strips /functions/v1/groups prefix
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-internal-key, x-environment',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

// Helper function to extract keywords from text
function extractKeywords(text: string): string[] {
  if (!text) return [];

  // Common words to exclude
  const stopWords = new Set([
    'the', 'a', 'an', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of', 'with',
    'by', 'from', 'as', 'is', 'was', 'are', 'were', 'been', 'be', 'have', 'has', 'had',
    'do', 'does', 'did', 'will', 'would', 'could', 'should', 'may', 'might', 'must',
    'shall', 'can', 'need', 'dare', 'ought', 'used', 'it', 'its', 'this', 'that',
    'these', 'those', 'i', 'you', 'he', 'she', 'we', 'they', 'what', 'which', 'who',
    'whom', 'when', 'where', 'why', 'how', 'all', 'each', 'every', 'both', 'few',
    'more', 'most', 'other', 'some', 'such', 'no', 'nor', 'not', 'only', 'own',
    'same', 'so', 'than', 'too', 'very', 'just', 'our', 'your', 'their', 'my'
  ]);

  // Extract words (3+ chars), filter stopwords, get unique, capitalize
  const words = text.toLowerCase()
    .replace(/[^a-zA-Z\s]/g, ' ')
    .split(/\s+/)
    .filter(word => word.length >= 3 && !stopWords.has(word));

  const unique = [...new Set(words)];

  // Capitalize first letter and return top 10
  return unique.slice(0, 10).map(word =>
    word.charAt(0).toUpperCase() + word.slice(1)
  );
}

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const internalApiSecret = Deno.env.get('INTERNAL_SIGNING_SECRET') ?? '';

    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    const internalKeyHeader = req.headers.get('x-internal-key');
    const environmentHeader = req.headers.get('x-environment');

    // Validate authorization
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Validate internal API key for API-to-Edge communication
    // This ensures requests come from our API server, not direct external calls
    const isInternalRequest = internalKeyHeader && internalApiSecret && internalKeyHeader === internalApiSecret;

    // Log internal request status (for debugging, remove in production)
    if (internalKeyHeader) {
      console.log('🔐 Internal key provided:', isInternalRequest ? '✅ Valid' : '❌ Invalid');
    }
    
    // Create supabase client (with user auth for RLS)
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: {
        headers: {
          Authorization: authHeader,
          ...(tenantHeader && { 'x-tenant-id': tenantHeader })
        }
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Admin client (bypasses RLS for cross-tenant queries like fetching all tenant profiles)
    const supabaseAdmin = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    // ✅ FIXED: Parse URL and strip base path
    // ✅ CORRECT: Supabase already stripped /functions/v1/
const url = new URL(req.url);
const fullPath = url.pathname;

// Function receives path like: /groups/verify-access
// We need to strip just /groups to get: /verify-access
let path = fullPath;
if (path.startsWith('/groups/')) {
  path = path.substring(7); // Remove '/groups'
} else if (path === '/groups') {
  path = '/';
}

const method = req.method;

console.log('='.repeat(60));
console.log('🔍 Groups Edge Function - Request:', {
  method,
  fullPathReceived: fullPath,  // /groups/verify-access
  strippedPath: path,           // /verify-access
  tenant: tenantHeader,
  isInternalRequest,
  environment: environmentHeader || 'not-specified'
});
console.log('='.repeat(60));

    // ============================================
    // GROUP MANAGEMENT ROUTES
    // ============================================
    
    // GET / - Get all groups (with optional filter)
    if (method === 'GET' && path === '/') {
      try {
        const groupType = url.searchParams.get('group_type') || 'all';
        
        let query = supabase
          .from('t_business_groups')
          .select('id, group_name, group_type, description, settings, member_count, is_active, created_at')
          .eq('is_active', true)
          .order('group_name');
        
        if (groupType !== 'all') {
          query = query.eq('group_type', groupType);
        }
        
        const { data, error } = await query;
        
        if (error) throw error;
        
        const transformedGroups = data.map(group => ({
          id: group.id,
          group_name: group.group_name,
          group_type: group.group_type,
          description: group.description,
          chapter: group.settings?.chapter || null,
          branch: group.settings?.branch || null,
          member_count: group.member_count,
          is_active: group.is_active,
          created_at: group.created_at
        }));
        
        return new Response(
          JSON.stringify({ success: true, groups: transformedGroups }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to fetch groups', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /verify-access - Verify password
    if (method === 'POST' && path === '/verify-access') {
      try {
        const requestData = await req.json();
        
        if (!requestData.group_id || !requestData.password || !requestData.access_type) {
          return new Response(
            JSON.stringify({ success: false, error: 'group_id, password, and access_type are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        if (!['user', 'admin'].includes(requestData.access_type)) {
          return new Response(
            JSON.stringify({ success: false, error: 'access_type must be "user" or "admin"' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { group_id, password, access_type } = requestData;
        
        const { data: group, error } = await supabase
          .from('t_business_groups')
          .select('id, group_name, settings')
          .eq('id', group_id)
          .eq('is_active', true)
          .single();
        
        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, access_granted: false, error: 'Group not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }
        
        const userPassword = group.settings?.access?.user_password;
        const adminPassword = group.settings?.access?.admin_password;
        
        let accessGranted = false;
        let accessLevel: 'user' | 'admin' | null = null;
        let redirectTo = '';
        
        if (access_type === 'admin' && adminPassword && password === adminPassword) {
          accessGranted = true;
          accessLevel = 'admin';
          redirectTo = '/vani/channels/bbb/admin';
        } else if (access_type === 'user' && userPassword && password === userPassword) {
          accessGranted = true;
          accessLevel = 'user';
          redirectTo = '/vani/channels/bbb/onboarding';
        }
        
        if (accessGranted) {
          return new Response(
            JSON.stringify({
              success: true,
              access_granted: true,
              access_level: accessLevel,
              group_id: group.id,
              group_name: group.group_name,
              redirect_to: redirectTo
            }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        } else {
          return new Response(
            JSON.stringify({ success: false, access_granted: false, error: 'Invalid password' }),
            { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      } catch (error) {
        console.error('Error in POST /verify-access:', error);
        return new Response(
          JSON.stringify({ success: false, access_granted: false, error: 'Failed to verify access', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // GET /:groupId - Get specific group
    const groupIdMatch = path.match(/^\/([a-f0-9-]{36})$/);
    if (method === 'GET' && groupIdMatch) {
      try {
        const groupId = groupIdMatch[1];
        
        const { data, error } = await supabase
          .from('t_business_groups')
          .select('*')
          .eq('id', groupId)
          .eq('is_active', true)
          .single();
        
        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Group not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }
        
        return new Response(
          JSON.stringify({ success: true, group: data }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /:groupId:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to fetch group', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // MEMBERSHIP ROUTES
    // ============================================
    
    // POST /memberships - Create membership
    if (method === 'POST' && path === '/memberships') {
      try {
        if (!tenantHeader) {
          return new Response(
            JSON.stringify({ error: 'x-tenant-id header is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const requestData = await req.json();
        
        if (!requestData.group_id) {
          return new Response(
            JSON.stringify({ error: 'group_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Check if membership already exists
        const { data: existingMembership } = await supabase
          .from('t_group_memberships')
          .select('id')
          .eq('tenant_id', tenantHeader)
          .eq('group_id', requestData.group_id)
          .single();
        
        if (existingMembership) {
          return new Response(
            JSON.stringify({ error: 'Membership already exists', membership_id: existingMembership.id }),
            { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Create membership
        const { data, error } = await supabase
          .from('t_group_memberships')
          .insert({
            tenant_id: tenantHeader,
            group_id: requestData.group_id,
            profile_data: requestData.profile_data || {},
            status: 'draft',
            is_active: true
          })
          .select('id, tenant_id, group_id, status, created_at')
          .single();
        
        if (error) throw error;
        
        return new Response(
          JSON.stringify({
            success: true,
            membership_id: data.id,
            tenant_id: data.tenant_id,
            group_id: data.group_id,
            status: data.status,
            created_at: data.created_at
          }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /memberships:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to create membership', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // GET /memberships/:membershipId - Get membership with profile
    // Uses two separate queries (no FK constraint needed between t_group_memberships and t_tenant_profiles)
    const membershipGetMatch = path.match(/^\/memberships\/([a-f0-9-]{36})$/);
    if (method === 'GET' && membershipGetMatch) {
      try {
        const membershipId = membershipGetMatch[1];

        // Step 1: Get membership data
        const { data: membership, error: membershipError } = await supabase
          .from('t_group_memberships')
          .select('id, tenant_id, group_id, status, joined_at, profile_data, is_active, created_at, updated_at')
          .eq('id', membershipId)
          .eq('is_active', true)
          .single();

        if (membershipError) {
          if (membershipError.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Membership not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw membershipError;
        }

        // Step 2: Get tenant profile using tenant_id (separate query, no FK needed)
        const { data: tenantProfile } = await supabase
          .from('t_tenant_profiles')
          .select('business_name, business_email, business_phone, business_whatsapp, business_whatsapp_country_code, city, state_code, industry_id, website_url, logo_url')
          .eq('tenant_id', membership.tenant_id)
          .single();

        // Step 3: Return combined data
        return new Response(
          JSON.stringify({
            success: true,
            membership: {
              membership_id: membership.id,
              tenant_id: membership.tenant_id,
              group_id: membership.group_id,
              status: membership.status,
              joined_at: membership.joined_at,
              profile_data: membership.profile_data,
              tenant_profile: tenantProfile || null
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /memberships/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to fetch membership', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // PUT /memberships/:membershipId - Update membership
    const membershipPutMatch = path.match(/^\/memberships\/([a-f0-9-]{36})$/);
    if (method === 'PUT' && membershipPutMatch) {
      try {
        const membershipId = membershipPutMatch[1];
        const requestData = await req.json();
        
        const updateData: any = {
          updated_at: new Date().toISOString()
        };
        
        if (requestData.profile_data) {
          const { data: existing } = await supabase
            .from('t_group_memberships')
            .select('profile_data')
            .eq('id', membershipId)
            .single();
          
          if (existing) {
            updateData.profile_data = { ...existing.profile_data, ...requestData.profile_data };
          } else {
            updateData.profile_data = requestData.profile_data;
          }
        }
        
        if (requestData.status) {
          updateData.status = requestData.status;
        }
        
        const { data, error } = await supabase
          .from('t_group_memberships')
          .update(updateData)
          .eq('id', membershipId)
          .select('id, profile_data')
          .single();
        
        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Membership not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }
        
        return new Response(
          JSON.stringify({
            success: true,
            membership_id: data.id,
            updated_fields: Object.keys(updateData),
            profile_data: data.profile_data
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in PUT /memberships/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to update membership', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // GET /memberships/group/:groupId - List memberships by group
    const groupMembershipsMatch = path.match(/^\/memberships\/group\/([a-f0-9-]{36})$/);
    if (method === 'GET' && groupMembershipsMatch) {
      try {
        const groupId = groupMembershipsMatch[1];
        const status = url.searchParams.get('status') || 'all';
        const limit = parseInt(url.searchParams.get('limit') || '50');
        const offset = parseInt(url.searchParams.get('offset') || '0');

        // Query memberships without join (foreign key not set up)
        let query = supabase
          .from('t_group_memberships')
          .select(`
            id,
            tenant_id,
            group_id,
            status,
            joined_at,
            profile_data
          `, { count: 'exact' })
          .eq('group_id', groupId)
          .eq('is_active', true);

        if (status !== 'all') {
          query = query.eq('status', status);
        }

        query = query
          .order('joined_at', { ascending: false })
          .range(offset, offset + limit - 1);

        const { data, error, count } = await query;

        if (error) throw error;

        // Get tenant profiles separately using admin client (bypasses RLS)
        const tenantIds = data.map(m => m.tenant_id).filter(Boolean);
        let tenantProfiles: any[] = [];

        if (tenantIds.length > 0) {
          const { data: profiles } = await supabaseAdmin
            .from('t_tenant_profiles')
            .select('tenant_id, business_name, business_email, city, logo_url')
            .in('tenant_id', tenantIds);
          tenantProfiles = profiles || [];
        }

        const memberships = data.map(m => {
          const tenantProfile = tenantProfiles.find(p => p.tenant_id === m.tenant_id);
          return {
            id: m.id,
            membership_id: m.id,
            tenant_id: m.tenant_id,
            group_id: m.group_id || groupId,
            status: m.status,
            joined_at: m.joined_at,
            profile_data: m.profile_data,
            // Nested tenant_profile for UI compatibility
            tenant_profile: tenantProfile ? {
              business_name: tenantProfile.business_name || '',
              business_email: tenantProfile.business_email || '',
              city: tenantProfile.city || '',
              logo_url: tenantProfile.logo_url || null
            } : null
          };
        });
        
        return new Response(
          JSON.stringify({
            success: true,
            memberships,
            pagination: {
              total_count: count || 0,
              limit,
              offset,
              has_more: (count || 0) > (offset + limit)
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /memberships/group/:groupId:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to list memberships', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // DELETE /memberships/:membershipId - Soft delete
    const membershipDeleteMatch = path.match(/^\/memberships\/([a-f0-9-]{36})$/);
    if (method === 'DELETE' && membershipDeleteMatch) {
      try {
        const membershipId = membershipDeleteMatch[1];
        
        const { data, error } = await supabase
          .from('t_group_memberships')
          .update({
            is_active: false,
            status: 'inactive',
            updated_at: new Date().toISOString()
          })
          .eq('id', membershipId)
          .select('id, updated_at')
          .single();
        
        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Membership not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }
        
        return new Response(
          JSON.stringify({
            success: true,
            membership_id: data.id,
            deleted_at: data.updated_at
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in DELETE /memberships/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to delete membership', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // PROFILE ROUTES (AI Operations - STUBS for now)
    // ============================================
    
    // POST /profiles/enhance - AI enhancement (STUB)
    if (method === 'POST' && path === '/profiles/enhance') {
      try {
        const requestData = await req.json();
        
        if (!requestData.membership_id || !requestData.short_description) {
          return new Response(
            JSON.stringify({ error: 'membership_id and short_description are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const mockEnhanced = `${requestData.short_description} We are a leading provider in our industry with years of experience and a commitment to excellence. Our team of professionals delivers high-quality solutions tailored to meet your specific needs.`;
        const mockKeywords = ['Professional', 'Services', 'Quality', 'Experience', 'Solutions'];
        
        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: mockEnhanced,
            suggested_keywords: mockKeywords,
            processing_time_ms: 100
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /profiles/enhance:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to enhance profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /profiles/scrape-website - Website scraping (STUB)
    if (method === 'POST' && path === '/profiles/scrape-website') {
      try {
        const requestData = await req.json();
        
        if (!requestData.membership_id || !requestData.website_url) {
          return new Response(
            JSON.stringify({ error: 'membership_id and website_url are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const urlPattern = /^https?:\/\/.+\..+/;
        if (!urlPattern.test(requestData.website_url)) {
          return new Response(
            JSON.stringify({ error: 'Invalid URL format' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const mockEnhanced = `Based on the website analysis, this is a professional organization providing comprehensive services. Their online presence demonstrates commitment to quality and customer satisfaction.`;
        
        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: mockEnhanced,
            suggested_keywords: ['Professional', 'Services', 'Quality'],
            scraped_data: {
              title: 'Company Website',
              meta_description: 'Professional services provider',
              content_snippets: ['Service 1', 'Service 2']
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /profiles/scrape-website:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to scrape website', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /profiles/generate-clusters - Generate semantic clusters (STUB - mock data)
    // TODO: Replace with n8n webhook call when n8n is configured
    if (method === 'POST' && path === '/profiles/generate-clusters') {
      try {
        const requestData = await req.json();

        if (!requestData.membership_id || !requestData.profile_text) {
          return new Response(
            JSON.stringify({ error: 'membership_id and profile_text are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // STUB: Generate mock clusters from keywords
        const keywords = requestData.keywords || [];
        const mockClusters = keywords.slice(0, 5).map((keyword: string) => ({
          primary_term: keyword,
          related_terms: [keyword, `${keyword} services`, `${keyword} solutions`, `${keyword} provider`],
          category: 'general',
          confidence_score: 0.85 + Math.random() * 0.1
        }));

        // If no keywords provided, generate from profile text
        if (mockClusters.length === 0 && requestData.profile_text) {
          const words = requestData.profile_text.split(/\s+/).filter((w: string) => w.length > 4);
          const uniqueWords = [...new Set(words)].slice(0, 3) as string[];
          uniqueWords.forEach((word: string) => {
            mockClusters.push({
              primary_term: word,
              related_terms: [word, `${word} related`],
              category: 'auto-generated',
              confidence_score: 0.75
            });
          });
        }

        console.log('✅ Generated mock clusters:', {
          membershipId: requestData.membership_id,
          clustersGenerated: mockClusters.length
        });

        return new Response(
          JSON.stringify({
            success: true,
            membership_id: requestData.membership_id,
            clusters_generated: mockClusters.length,
            clusters: mockClusters,
            tokens_used: 0,
            source: 'stub' // Indicates this is mock data
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /profiles/generate-clusters:', error);
        return new Response(
          JSON.stringify({
            success: false,
            error: 'Failed to generate clusters',
            details: error.message,
            recoverable: true
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /profiles/clusters - Save semantic clusters
    if (method === 'POST' && path === '/profiles/clusters') {
      try {
        const requestData = await req.json();

        if (!requestData.membership_id || !requestData.clusters || !Array.isArray(requestData.clusters)) {
          return new Response(
            JSON.stringify({ error: 'membership_id and clusters array are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { membership_id, clusters } = requestData;

        // First, delete existing clusters for this membership
        await supabaseAdmin
          .from('t_semantic_clusters')
          .delete()
          .eq('membership_id', membership_id);

        // Prepare clusters for insertion
        const clustersToInsert = clusters.map((cluster: any) => ({
          membership_id,
          primary_term: cluster.primary_term,
          related_terms: cluster.related_terms || [],
          category: cluster.category || 'Services',
          confidence_score: cluster.confidence_score || 1.0,
          is_active: true
        }));

        // Insert new clusters
        const { data, error } = await supabaseAdmin
          .from('t_semantic_clusters')
          .insert(clustersToInsert)
          .select('id');

        if (error) throw error;

        console.log('✅ Saved clusters:', {
          membershipId: membership_id,
          count: data.length
        });

        return new Response(
          JSON.stringify({
            success: true,
            clusters_saved: data.length,
            cluster_ids: data.map((c: any) => c.id)
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /profiles/clusters:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to save clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // GET /profiles/clusters/:membershipId - Get semantic clusters
    const getClustersMatch = path.match(/^\/profiles\/clusters\/([a-f0-9-]{36})$/);
    if (method === 'GET' && getClustersMatch) {
      try {
        const membershipId = getClustersMatch[1];

        const { data, error } = await supabaseAdmin
          .from('t_semantic_clusters')
          .select('id, membership_id, primary_term, related_terms, category, confidence_score, is_active, created_at')
          .eq('membership_id', membershipId)
          .eq('is_active', true)
          .order('created_at', { ascending: false });

        if (error) throw error;

        return new Response(
          JSON.stringify({
            success: true,
            clusters: data || []
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /profiles/clusters/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // DELETE /profiles/clusters/:membershipId - Delete all clusters for a membership
    const deleteClustersMatch = path.match(/^\/profiles\/clusters\/([a-f0-9-]{36})$/);
    if (method === 'DELETE' && deleteClustersMatch) {
      try {
        const membershipId = deleteClustersMatch[1];

        const { data, error } = await supabaseAdmin
          .from('t_semantic_clusters')
          .delete()
          .eq('membership_id', membershipId)
          .select('id');

        if (error) throw error;

        return new Response(
          JSON.stringify({
            success: true,
            deleted_count: data?.length || 0
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in DELETE /profiles/clusters/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to delete clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // POST /profiles/save - Save profile with embedding
    if (method === 'POST' && path === '/profiles/save') {
      try {
        const requestData = await req.json();

        if (!requestData.membership_id || !requestData.profile_data) {
          return new Response(
            JSON.stringify({ error: 'membership_id and profile_data are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Build update object - include embedding if provided
        const updateData: any = {
          profile_data: requestData.profile_data,
          status: 'active',
          updated_at: new Date().toISOString()
        };

        // Add embedding if provided (from n8n)
        if (requestData.embedding && Array.isArray(requestData.embedding)) {
          updateData.embedding = requestData.embedding;
          console.log(`📊 Saving embedding with ${requestData.embedding.length} dimensions`);
        }

        const { data, error } = await supabase
          .from('t_group_memberships')
          .update(updateData)
          .eq('id', requestData.membership_id)
          .select()
          .single();

        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Membership not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }

        const embeddingGenerated = !!(requestData.embedding && Array.isArray(requestData.embedding));

        return new Response(
          JSON.stringify({
            success: true,
            membership_id: data.id,
            status: 'active',
            embedding_generated: embeddingGenerated
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /profiles/save:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to save profile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // SEARCH ROUTE (Basic keyword search for now)
    // ============================================
    
    // POST /search - Search group members
    if (method === 'POST' && path === '/search') {
      try {
        const requestData = await req.json();
        
        if (!requestData.group_id || !requestData.query) {
          return new Response(
            JSON.stringify({ error: 'group_id and query are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const limit = requestData.limit || 5;
        const queryLower = requestData.query.toLowerCase();
        
        const { data, error } = await supabase
          .from('t_group_memberships')
          .select(`
            id,
            tenant_id,
            profile_data,
            tenant_profile:t_tenant_profiles!tenant_id (
              business_name,
              business_email,
              city,
              industry_id,
              logo_url
            )
          `)
          .eq('group_id', requestData.group_id)
          .eq('status', 'active')
          .eq('is_active', true)
          .limit(limit * 3);
        
        if (error) throw error;
        
        const filteredResults = data
          .filter(member => {
            const businessName = member.tenant_profile?.business_name?.toLowerCase() || '';
            const industry = member.tenant_profile?.industry_id?.toLowerCase() || '';
            const city = member.tenant_profile?.city?.toLowerCase() || '';
            const description = member.profile_data?.ai_enhanced_description?.toLowerCase() || '';
            const keywords = (member.profile_data?.approved_keywords || []).join(' ').toLowerCase();
            
            const searchText = `${businessName} ${industry} ${city} ${description} ${keywords}`;
            return searchText.includes(queryLower);
          })
          .slice(0, limit)
          .map((member, index) => ({
            membership_id: member.id,
            tenant_id: member.tenant_id,
            business_name: member.tenant_profile?.business_name || '',
            business_email: member.tenant_profile?.business_email || '',
            mobile_number: member.profile_data?.mobile_number || '',
            city: member.tenant_profile?.city || '',
            industry: member.tenant_profile?.industry_id || '',
            profile_snippet: (member.profile_data?.ai_enhanced_description || '').substring(0, 200),
            similarity_score: 0.5 + (0.5 * (1 - index / limit)),
            match_type: 'keyword',
            logo_url: member.tenant_profile?.logo_url || null
          }));
        
        return new Response(
          JSON.stringify({
            success: true,
            query: requestData.query,
            results_count: filteredResults.length,
            from_cache: false,
            search_time_ms: 50,
            results: filteredResults
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /search:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to search', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // ADMIN ROUTES
    // ============================================
    
    // GET /admin/stats/:groupId - Get admin stats
    const adminStatsMatch = path.match(/^\/admin\/stats\/([a-f0-9-]{36})$/);
    if (method === 'GET' && adminStatsMatch) {
      try {
        const groupId = adminStatsMatch[1];
        
        const { data: memberships, error: statsError } = await supabase
          .from('t_group_memberships')
          .select('status, is_active')
          .eq('group_id', groupId);
        
        if (statsError) throw statsError;
        
        const stats = {
          total_members: memberships.filter(m => m.is_active).length,
          active_members: memberships.filter(m => m.status === 'active' && m.is_active).length,
          pending_members: memberships.filter(m => m.status === 'pending' && m.is_active).length,
          inactive_members: memberships.filter(m => m.status === 'inactive').length,
          suspended_members: memberships.filter(m => m.status === 'suspended').length
        };
        
        const { data: activity, error: activityError } = await supabase
          .from('t_group_activity_logs')
          .select(`
            activity_type,
            activity_data,
            created_at,
            tenant_profile:t_tenants!tenant_id (
              id
            )
          `)
          .eq('group_id', groupId)
          .order('created_at', { ascending: false })
          .limit(10);
        
        if (activityError) throw activityError;
        
        const recentActivity = (activity || []).map(log => ({
          activity_type: log.activity_type,
          tenant_name: 'Member',
          timestamp: log.created_at,
          details: log.activity_data?.details || ''
        }));
        
        return new Response(
          JSON.stringify({
            success: true,
            stats,
            recent_activity: recentActivity
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /admin/stats:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get stats', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // PUT /admin/memberships/:membershipId/status - Update membership status
    const adminStatusMatch = path.match(/^\/admin\/memberships\/([a-f0-9-]{36})\/status$/);
    if (method === 'PUT' && adminStatusMatch) {
      try {
        const membershipId = adminStatusMatch[1];
        const requestData = await req.json();
        
        if (!requestData.status || !['draft', 'active', 'inactive', 'suspended'].includes(requestData.status)) {
          return new Response(
            JSON.stringify({ error: 'status must be "draft", "active", "inactive", or "suspended"' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { data: oldData } = await supabase
          .from('t_group_memberships')
          .select('status, group_id')
          .eq('id', membershipId)
          .single();
        
        if (!oldData) {
          return new Response(
            JSON.stringify({ success: false, error: 'Membership not found' }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { data, error } = await supabase
          .from('t_group_memberships')
          .update({
            status: requestData.status,
            updated_at: new Date().toISOString()
          })
          .eq('id', membershipId)
          .select('id, status, updated_at')
          .single();
        
        if (error) throw error;
        
        await supabase
          .from('t_group_activity_logs')
          .insert({
            group_id: oldData.group_id,
            membership_id: membershipId,
            activity_type: 'status_change',
            activity_data: {
              old_status: oldData.status,
              new_status: requestData.status,
              reason: requestData.reason || null
            }
          });
        
        return new Response(
          JSON.stringify({
            success: true,
            membership_id: data.id,
            old_status: oldData.status,
            new_status: data.status,
            updated_at: data.updated_at
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in PUT /admin/memberships/:id/status:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to update status', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // GET /admin/activity-logs/:groupId - Get activity logs
    const adminLogsMatch = path.match(/^\/admin\/activity-logs\/([a-f0-9-]{36})$/);
    if (method === 'GET' && adminLogsMatch) {
      try {
        const groupId = adminLogsMatch[1];
        const activityType = url.searchParams.get('activity_type');
        const limit = parseInt(url.searchParams.get('limit') || '50');
        const offset = parseInt(url.searchParams.get('offset') || '0');
        
        let query = supabase
          .from('t_group_activity_logs')
          .select('id, activity_type, activity_data, created_at', { count: 'exact' })
          .eq('group_id', groupId);
        
        if (activityType) {
          query = query.eq('activity_type', activityType);
        }
        
        query = query
          .order('created_at', { ascending: false })
          .range(offset, offset + limit - 1);
        
        const { data, error, count } = await query;
        
        if (error) throw error;
        
        return new Response(
          JSON.stringify({
            success: true,
            logs: data || [],
            pagination: {
              total_count: count || 0,
              limit,
              offset
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /admin/activity-logs:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get activity logs', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // CHAT ROUTES (VaNi AI Assistant)
    // Session management, group activation, intent handling
    // ============================================

    // POST /chat/init - Get VaNi intro message with available groups
    if (method === 'POST' && path === '/chat/init') {
      try {
        console.log('💬 Chat init - Getting VaNi intro message');

        // Call the get_vani_intro_message() function
        const { data, error } = await supabaseAdmin.rpc('get_vani_intro_message');

        if (error) {
          console.error('Error calling get_vani_intro_message:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({
            success: true,
            ...data
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/init:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get intro message', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /chat/session - Get or create chat session
    // Requires internal API key for security
    if (method === 'POST' && path === '/chat/session') {
      try {
        // Validate internal API key
        if (!isInternalRequest) {
          console.warn('⚠️ Chat session attempted without valid internal key');
          return new Response(
            JSON.stringify({ error: 'Forbidden: Invalid or missing internal API key' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const requestData = await req.json();
        const channel = requestData.channel || 'web';

        console.log('💬 Chat session - Getting/creating session:', {
          userId: tenantHeader,
          channel
        });

        // Call get_or_create_session function
        const { data, error } = await supabaseAdmin.rpc('get_or_create_session', {
          p_user_id: tenantHeader || null,
          p_tenant_id: tenantHeader || null,
          p_channel: channel
        });

        if (error) {
          console.error('Error calling get_or_create_session:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({
            success: true,
            session: data
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/session:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get/create session', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /chat/activate - Activate group session with trigger phrase
    // Requires internal API key for security
    if (method === 'POST' && path === '/chat/activate') {
      try {
        // Validate internal API key
        if (!isInternalRequest) {
          console.warn('⚠️ Chat activate attempted without valid internal key');
          return new Response(
            JSON.stringify({ error: 'Forbidden: Invalid or missing internal API key' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const requestData = await req.json();

        if (!requestData.trigger_phrase && !requestData.group_id) {
          return new Response(
            JSON.stringify({ error: 'Either trigger_phrase or group_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('💬 Chat activate - Activating group:', requestData);

        let groupData = null;

        // Find group by trigger phrase
        if (requestData.trigger_phrase) {
          const { data, error } = await supabaseAdmin.rpc('find_group_by_trigger', {
            p_trigger_phrase: requestData.trigger_phrase
          });

          if (error) {
            console.error('Error calling find_group_by_trigger:', error);
            throw error;
          }

          if (data && data.length > 0) {
            groupData = data[0];
          }
        } else if (requestData.group_id) {
          // Direct group lookup
          const { data, error } = await supabaseAdmin
            .from('t_business_groups')
            .select('id, group_name, group_type')
            .eq('id', requestData.group_id)
            .eq('is_active', true)
            .single();

          if (error && error.code !== 'PGRST116') throw error;

          if (data) {
            // Get chat config
            const { data: chatConfig } = await supabaseAdmin.rpc('get_group_chat_config', {
              p_group_id: data.id
            });

            groupData = {
              group_id: data.id,
              group_name: data.group_name,
              group_type: data.group_type,
              chat_config: chatConfig
            };
          }
        }

        if (!groupData) {
          return new Response(
            JSON.stringify({
              success: false,
              error: 'Group not found',
              message: 'No group matches the provided trigger phrase or ID'
            }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // If session_id provided, activate the group in that session
        if (requestData.session_id) {
          const { data: sessionData, error: sessionError } = await supabaseAdmin.rpc('activate_group_session', {
            p_session_id: requestData.session_id,
            p_group_id: groupData.group_id,
            p_group_name: groupData.group_name
          });

          if (sessionError) {
            console.error('Error activating session:', sessionError);
          }
        }

        return new Response(
          JSON.stringify({
            success: true,
            group_id: groupData.group_id,
            group_name: groupData.group_name,
            group_type: groupData.group_type,
            chat_config: groupData.chat_config,
            message: `Welcome to ${groupData.group_name}! How can I help you today?`
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/activate:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to activate group', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /chat/intent - Set intent when user clicks a button
    // Requires internal API key for security
    if (method === 'POST' && path === '/chat/intent') {
      try {
        // Validate internal API key
        if (!isInternalRequest) {
          console.warn('⚠️ Chat intent attempted without valid internal key');
          return new Response(
            JSON.stringify({ error: 'Forbidden: Invalid or missing internal API key' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const requestData = await req.json();

        if (!requestData.session_id || !requestData.intent) {
          return new Response(
            JSON.stringify({ error: 'session_id and intent are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('💬 Chat intent - Setting intent:', requestData);

        const { data, error } = await supabaseAdmin.rpc('set_session_intent', {
          p_session_id: requestData.session_id,
          p_intent: requestData.intent,
          p_prompt: requestData.prompt || null
        });

        if (error) {
          console.error('Error calling set_session_intent:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({
            success: true,
            session: data,
            prompt: requestData.prompt || 'What are you looking for?'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/intent:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to set intent', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /chat/search - AI-powered search with caching (via n8n)
    // Requires internal API key for security
    if (method === 'POST' && path === '/chat/search') {
      try {
        // Validate internal API key - this endpoint requires API server authentication
        if (!isInternalRequest) {
          console.warn('⚠️ Chat search attempted without valid internal key');
          return new Response(
            JSON.stringify({ error: 'Forbidden: Invalid or missing internal API key' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const requestData = await req.json();

        if (!requestData.group_id || !requestData.query) {
          return new Response(
            JSON.stringify({ error: 'group_id and query are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const limit = requestData.limit || 5;
        const useCache = requestData.use_cache !== false;
        const similarityThreshold = requestData.similarity_threshold || 0.7;

        console.log('💬 Chat search:', {
          groupId: requestData.group_id,
          query: requestData.query,
          useCache
        });

        // Get n8n webhook URL for AI-powered search
        // Uses the /ai-search endpoint which handles:
        // 1. Cache check  2. Query embedding generation  3. Semantic cluster lookup
        // 4. Vector search  5. Cluster boost  6. Cache storage
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const searchWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/ai-search`;

        console.log('🔍 Calling n8n search:', searchWebhookUrl);

        // Call n8n which handles embedding generation and cached_vector_search
        const n8nResponse = await fetch(searchWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            group_id: requestData.group_id,
            query: requestData.query,
            limit,
            use_cache: useCache,
            similarity_threshold: similarityThreshold,
            session_id: requestData.session_id || null,
            intent: requestData.intent || null,
            channel: requestData.channel || 'web'
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('n8n search failed:', errorText);
          throw new Error(`n8n search failed: ${n8nResponse.status}`);
        }

        const n8nResult = await n8nResponse.json();

        console.log('✅ Search completed:', {
          resultsCount: n8nResult.results_count,
          fromCache: n8nResult.from_cache
        });

        // Update session message count if session_id provided
        if (requestData.session_id) {
          await supabaseAdmin.rpc('increment_session_messages', {
            p_session_id: requestData.session_id
          });
        }

        return new Response(
          JSON.stringify({
            success: true,
            query: requestData.query,
            results_count: n8nResult.results_count || 0,
            from_cache: n8nResult.from_cache || false,
            cache_hit_count: n8nResult.cache_hit_count || 0,
            results: n8nResult.results || []
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/search:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to search', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // GET /chat/session/:sessionId - Get session state
    const getSessionMatch = path.match(/^\/chat\/session\/([a-f0-9-]{36})$/);
    if (method === 'GET' && getSessionMatch) {
      try {
        const sessionId = getSessionMatch[1];

        const { data, error } = await supabaseAdmin
          .from('t_chat_sessions')
          .select('*')
          .eq('id', sessionId)
          .single();

        if (error) {
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ success: false, error: 'Session not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw error;
        }

        // Check if session is expired
        const isExpired = new Date(data.expires_at) < new Date();

        return new Response(
          JSON.stringify({
            success: true,
            session: data,
            is_expired: isExpired
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /chat/session/:id:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get session', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /chat/end - End chat session
    // Requires internal API key for security
    if (method === 'POST' && path === '/chat/end') {
      try {
        // Validate internal API key
        if (!isInternalRequest) {
          console.warn('⚠️ Chat end attempted without valid internal key');
          return new Response(
            JSON.stringify({ error: 'Forbidden: Invalid or missing internal API key' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const requestData = await req.json();

        if (!requestData.session_id) {
          return new Response(
            JSON.stringify({ error: 'session_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('💬 Chat end - Ending session:', requestData.session_id);

        const { error } = await supabaseAdmin.rpc('end_chat_session', {
          p_session_id: requestData.session_id
        });

        if (error) {
          console.error('Error calling end_chat_session:', error);
          throw error;
        }

        return new Response(
          JSON.stringify({
            success: true,
            message: 'Session ended successfully'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /chat/end:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to end session', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // TENANT DASHBOARD ROUTES
    // Stats, NLP Search, and Intents for admin dashboard
    // ============================================

    // POST /tenants/stats - Get tenant statistics (calculated dynamically)
    if (method === 'POST' && path === '/tenants/stats') {
      try {
        const requestData = await req.json();
        const groupId = requestData.group_id || null;

        console.log('📊 Getting tenant stats (dynamic):', { groupId });

        // Build base query for memberships
        let membershipsQuery = supabaseAdmin
          .from('t_group_memberships')
          .select('id, tenant_id, group_id, status')
          .eq('status', 'active')
          .eq('is_active', true);

        if (groupId) {
          membershipsQuery = membershipsQuery.eq('group_id', groupId);
        }

        const { data: memberships, error: membershipsError } = await membershipsQuery;
        if (membershipsError) throw membershipsError;

        // Get unique tenant IDs
        const tenantIds = [...new Set(memberships.map(m => m.tenant_id).filter(Boolean))];
        const groupIds = [...new Set(memberships.map(m => m.group_id).filter(Boolean))];

        // Get tenant profiles for profile_type
        let tenantProfiles: any[] = [];
        if (tenantIds.length > 0) {
          const { data: profiles } = await supabaseAdmin
            .from('t_tenant_profiles')
            .select('tenant_id, industry_id, profile_type')
            .in('tenant_id', tenantIds);
          tenantProfiles = profiles || [];
        }

        // Get group names
        let groups: any[] = [];
        if (groupIds.length > 0) {
          const { data: groupData } = await supabaseAdmin
            .from('t_business_groups')
            .select('id, group_name')
            .in('id', groupIds);
          groups = groupData || [];
        }

        // Calculate stats
        const totalTenants = tenantIds.length;

        // By group
        const byGroup = groups.map(g => {
          const count = memberships.filter(m => m.group_id === g.id).length;
          return { group_id: g.id, group_name: g.group_name, count };
        }).filter(g => g.count > 0);

        // By industry
        const industryMap: Record<string, number> = {};
        tenantProfiles.forEach(p => {
          const industry = p.industry_id || 'Unknown';
          industryMap[industry] = (industryMap[industry] || 0) + 1;
        });
        const byIndustry = Object.entries(industryMap).map(([industry_id, count]) => ({
          industry_id,
          industry_name: industry_id,
          count
        }));

        // By profile type
        let buyers = 0, sellers = 0, both = 0;
        tenantProfiles.forEach(p => {
          if (p.profile_type === 'buyer') buyers++;
          else if (p.profile_type === 'seller') sellers++;
          else if (p.profile_type === 'both') both++;
        });

        const stats = {
          total_tenants: totalTenants,
          by_group: byGroup,
          by_industry: byIndustry,
          by_profile_type: { buyers, sellers, both }
        };

        return new Response(
          JSON.stringify({
            success: true,
            stats
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /tenants/stats:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get tenant stats', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /tenants/search - NLP-based tenant search via n8n AI Search
    // Routes to n8n /ai-search webhook which handles:
    // 1. Cache check  2. Query embedding generation  3. Semantic cluster lookup
    // 4. Vector search  5. Cluster boost (+15%)  6. Cache storage
    if (method === 'POST' && path === '/tenants/search') {
      try {
        const requestData = await req.json();

        if (!requestData.query) {
          return new Response(
            JSON.stringify({ error: 'query is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const query = requestData.query;
        const groupId = requestData.group_id || null;
        const intentCode = requestData.intent_code || null;
        const limit = requestData.limit || 20;
        const useCache = requestData.use_cache !== false;

        console.log('🔍 Tenant search (n8n AI):', { query, groupId, intentCode, useCache });

        // Get n8n webhook URL for AI-powered search
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const searchWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/ai-search`;

        console.log('🔗 Calling n8n AI search:', searchWebhookUrl);

        // Build search payload for n8n
        const searchPayload: any = {
          query: query,
          limit: limit,
          use_cache: useCache,
          similarity_threshold: 0.7,
          channel: 'web',
          user_role: 'admin'
        };

        // Add group_id if provided (scoped search)
        if (groupId) {
          searchPayload.group_id = groupId;
          searchPayload.scope = 'group';
        } else {
          searchPayload.scope = 'product'; // Search across all groups
        }

        // Map intent codes to search intents
        if (intentCode) {
          const intentMap: Record<string, string> = {
            'all_tenants': 'list_all',
            'by_group': 'list_by_group',
            'buyers': 'find_buyer',
            'sellers': 'search_offering'
          };
          searchPayload.intent = intentMap[intentCode] || 'general_search';
        }

        // Call n8n AI search webhook
        const n8nResponse = await fetch(searchWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(searchPayload)
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n AI search failed:', n8nResponse.status, errorText);

          // Fallback to basic search if n8n fails
          console.log('⚠️ Falling back to basic search...');
          return await fallbackBasicSearch(supabaseAdmin, requestData, corsHeaders);
        }

        const n8nResult = await n8nResponse.json();

        console.log('✅ AI Search completed:', {
          resultsCount: n8nResult.results_count,
          fromCache: n8nResult.from_cache,
          status: n8nResult.status
        });

        // Transform results to match expected format
        const results = (n8nResult.results || []).map((r: any) => ({
          membership_id: r.membership_id,
          tenant_id: r.tenant_id,
          group_id: r.group_id,
          group_name: r.group_name || '',
          business_name: r.business_name || '',
          business_email: r.business_email || '',
          mobile_number: r.mobile_number || '',
          city: r.city || '',
          industry: r.industry || '',
          profile_snippet: r.profile_snippet || r.ai_enhanced_description?.substring(0, 200) || '',
          ai_enhanced_description: r.ai_enhanced_description || '',
          approved_keywords: r.approved_keywords || [],
          logo_url: r.logo_url || null,
          // Real AI confidence scores from unified_search
          similarity: r.similarity || 0,
          similarity_original: r.similarity_original || r.similarity || 0,
          boost_applied: r.boost_applied || null,
          match_type: r.match_type || 'vector'
        }));

        return new Response(
          JSON.stringify({
            success: true,
            query: query,
            results_count: results.length,
            from_cache: n8nResult.from_cache || false,
            cache_hit_count: n8nResult.cache_hit_count || 0,
            search_type: 'ai_vector',
            results: results
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /tenants/search:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Tenant search failed', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // Fallback basic search function (when n8n is unavailable)
    async function fallbackBasicSearch(supabaseClient: any, requestData: any, headers: any) {
      const query = requestData.query.toLowerCase();
      const groupId = requestData.group_id || null;
      const intentCode = requestData.intent_code || null;

      console.log('📋 Fallback basic search:', { query, groupId, intentCode });

      // Build search query
      let membershipsQuery = supabaseClient
        .from('t_group_memberships')
        .select(`id, tenant_id, group_id, profile_data, status`)
        .eq('status', 'active')
        .eq('is_active', true);

      if (groupId) {
        membershipsQuery = membershipsQuery.eq('group_id', groupId);
      }

      const { data: memberships, error: membershipsError } = await membershipsQuery.limit(100);
      if (membershipsError) throw membershipsError;

      // Get tenant profiles
      const tenantIds = memberships.map((m: any) => m.tenant_id).filter(Boolean);
      let tenantProfiles: any[] = [];
      let groupsMap: Record<string, string> = {};

      if (tenantIds.length > 0) {
        const { data: profiles } = await supabaseClient
          .from('t_tenant_profiles')
          .select('tenant_id, business_name, business_email, city, industry_id, logo_url, profile_type')
          .in('tenant_id', tenantIds);
        tenantProfiles = profiles || [];

        const groupIds = [...new Set(memberships.map((m: any) => m.group_id))];
        const { data: groups } = await supabaseClient
          .from('t_business_groups')
          .select('id, group_name')
          .in('id', groupIds);

        if (groups) {
          groups.forEach((g: any) => { groupsMap[g.id] = g.group_name; });
        }
      }

      // Build results with text matching
      let filteredResults = memberships.map((m: any) => {
        const profile = tenantProfiles.find((p: any) => p.tenant_id === m.tenant_id);
        return {
          membership_id: m.id,
          tenant_id: m.tenant_id,
          group_id: m.group_id,
          group_name: groupsMap[m.group_id] || '',
          business_name: profile?.business_name || '',
          business_email: profile?.business_email || '',
          city: profile?.city || '',
          industry: profile?.industry_id || '',
          profile_snippet: m.profile_data?.ai_enhanced_description?.substring(0, 200) || '',
          logo_url: profile?.logo_url || null,
          profile_type: profile?.profile_type || 'unknown',
          similarity: 0,
          similarity_original: 0,
          boost_applied: null,
          match_type: 'fallback_text'
        };
      });

      // Apply intent-based filtering
      if (intentCode === 'buyers' || query.includes('buyer')) {
        filteredResults = filteredResults.filter((r: any) => r.profile_type === 'buyer' || r.profile_type === 'both');
      } else if (intentCode === 'sellers' || query.includes('seller')) {
        filteredResults = filteredResults.filter((r: any) => r.profile_type === 'seller' || r.profile_type === 'both');
      } else if (intentCode !== 'all_tenants' && intentCode !== 'by_group') {
        filteredResults = filteredResults.filter((r: any) => {
          const searchText = `${r.business_name} ${r.industry} ${r.city}`.toLowerCase();
          return searchText.includes(query);
        });
      }

      // Basic relevance scoring for fallback
      filteredResults = filteredResults.map((r: any, i: number) => ({
        ...r,
        similarity: Math.max(0.5, 0.8 - (i * 0.02))
      })).slice(0, 20);

      return new Response(
        JSON.stringify({
          success: true,
          query: requestData.query,
          results_count: filteredResults.length,
          from_cache: false,
          search_type: 'fallback_text',
          results: filteredResults
        }),
        { status: 200, headers: { ...headers, 'Content-Type': 'application/json' } }
      );
    }

    // GET /intents - Get resolved intents
    if (method === 'GET' && path === '/intents') {
      try {
        const groupId = url.searchParams.get('group_id');
        const userRole = url.searchParams.get('user_role') || 'member';
        const channel = url.searchParams.get('channel') || 'web';

        console.log('📋 Getting intents:', { groupId, userRole, channel });

        // Get intents from t_intent_definitions
        const { data, error } = await supabaseAdmin
          .from('t_intent_definitions')
          .select('intent_code, intent_name, description, default_label, default_icon, default_prompt, intent_type')
          .contains('default_roles', [userRole])
          .contains('default_channels', [channel])
          .eq('is_active', true);

        if (error) throw error;

        return new Response(
          JSON.stringify({
            success: true,
            intents: data || []
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /intents:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get intents', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // SMARTPROFILE ROUTES
    // Tenant-level AI-enhanced profiles
    // ============================================

    // GET /smartprofiles/:tenantId - Get tenant's smartprofile
    if (method === 'GET' && path.match(/^\/smartprofiles\/[^\/]+$/)) {
      try {
        const tenantId = path.split('/')[2];
        console.log('📋 Getting smartprofile for tenant:', tenantId);

        const { data, error } = await supabaseAdmin
          .from('t_tenant_smartprofiles')
          .select('*')
          .eq('tenant_id', tenantId)
          .single();

        if (error && error.code !== 'PGRST116') throw error;

        if (!data) {
          return new Response(
            JSON.stringify({ success: true, exists: false, smartprofile: null }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Get clusters for this tenant
        const { data: clusters } = await supabaseAdmin
          .from('t_semantic_clusters')
          .select('id, primary_term, related_terms, category, confidence_score')
          .eq('tenant_id', tenantId)
          .eq('is_active', true);

        return new Response(
          JSON.stringify({
            success: true,
            exists: true,
            smartprofile: {
              ...data,
              clusters: clusters || []
            }
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /smartprofiles/:tenantId:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get smartprofile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles - Create/update smartprofile (basic save without AI)
    if (method === 'POST' && path === '/smartprofiles') {
      try {
        const requestData = await req.json();

        if (!requestData.tenant_id) {
          return new Response(
            JSON.stringify({ error: 'tenant_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('💾 Saving smartprofile for tenant:', requestData.tenant_id);

        // Validate profile_type - database constraint allows: 'seller', 'buyer'
        const validProfileTypes = ['seller', 'buyer'];
        let profileType = requestData.profile_type || 'seller';
        if (!validProfileTypes.includes(profileType)) {
          // Map invalid types to 'seller' (default for business profiles)
          profileType = 'seller';
        }

        // Build upsert data with all fields from UI
        const upsertData: any = {
          tenant_id: requestData.tenant_id,
          short_description: requestData.short_description || null,
          profile_type: profileType,
          approved_keywords: requestData.approved_keywords || [],
          status: requestData.status || 'active',
          is_active: requestData.is_active !== false,
          updated_at: new Date().toISOString()
        };

        // Add optional fields if provided
        if (requestData.ai_enhanced_description) {
          upsertData.ai_enhanced_description = requestData.ai_enhanced_description;
        }
        if (requestData.website_url) {
          upsertData.website_url = requestData.website_url;
        }
        if (requestData.generation_method) {
          upsertData.generation_method = requestData.generation_method;
        }

        console.log('📝 Upserting smartprofile:', Object.keys(upsertData));

        const { data, error } = await supabaseAdmin
          .from('t_tenant_smartprofiles')
          .upsert(upsertData, { onConflict: 'tenant_id' })
          .select()
          .single();

        if (error) throw error;

        return new Response(
          JSON.stringify({ success: true, smartprofile: data }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to save smartprofile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/enhance - AI enhancement for tenant profiles
    if (method === 'POST' && path === '/smartprofiles/enhance') {
      try {
        const requestData = await req.json();

        if (!requestData.tenant_id || !requestData.short_description) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and short_description are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('🤖 Enhancing SmartProfile for tenant:', requestData.tenant_id);

        // Get n8n webhook URL
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const enhanceWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/smartprofile-enhance`;

        console.log('🔗 Calling n8n enhance:', enhanceWebhookUrl);

        // Call n8n for AI enhancement
        const n8nResponse = await fetch(enhanceWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tenant_id: requestData.tenant_id,
            short_description: requestData.short_description,
            profile_type: requestData.profile_type || 'seller'
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n enhance failed:', n8nResponse.status, errorText);

          // Fallback: Return a basic enhancement if n8n fails
          const fallbackEnhanced = `${requestData.short_description}\n\nWe are a professional organization committed to delivering high-quality services and solutions to our clients. Our team brings expertise and innovation to every project.`;

          return new Response(
            JSON.stringify({
              success: true,
              ai_enhanced_description: fallbackEnhanced,
              suggested_keywords: extractKeywords(requestData.short_description),
              source: 'fallback'
            }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ SmartProfile enhanced:', { hasDescription: !!n8nResult.ai_enhanced_description });

        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: n8nResult.ai_enhanced_description || n8nResult.enhanced_description || requestData.short_description,
            suggested_keywords: n8nResult.suggested_keywords || n8nResult.keywords || [],
            source: 'n8n'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/enhance:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to enhance SmartProfile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/scrape-website - Website scraping for tenant profiles
    if (method === 'POST' && path === '/smartprofiles/scrape-website') {
      try {
        const requestData = await req.json();

        if (!requestData.tenant_id || !requestData.website_url) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and website_url are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Validate URL format
        const urlPattern = /^https?:\/\/.+\..+/;
        if (!urlPattern.test(requestData.website_url)) {
          return new Response(
            JSON.stringify({ error: 'Invalid URL format. URL must start with http:// or https://' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('🌐 Scraping website for SmartProfile:', requestData.website_url);

        // Get n8n webhook URL
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const scrapeWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/smartprofile-scrape`;

        console.log('🔗 Calling n8n scrape:', scrapeWebhookUrl);

        // Call n8n for website scraping
        const n8nResponse = await fetch(scrapeWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tenant_id: requestData.tenant_id,
            website_url: requestData.website_url,
            profile_type: requestData.profile_type || 'seller'
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n scrape failed:', n8nResponse.status, errorText);

          // Fallback: Return a basic response if n8n fails
          return new Response(
            JSON.stringify({
              success: true,
              ai_enhanced_description: `Professional organization with online presence at ${requestData.website_url}. We are committed to delivering value to our clients through our products and services.`,
              suggested_keywords: ['Professional', 'Services', 'Quality'],
              scraped_data: {
                title: 'Website Analysis',
                url: requestData.website_url,
                error: 'n8n processing unavailable'
              },
              source: 'fallback'
            }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ Website scraped:', { hasDescription: !!n8nResult.ai_enhanced_description });

        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: n8nResult.ai_enhanced_description || n8nResult.enhanced_description || '',
            suggested_keywords: n8nResult.suggested_keywords || n8nResult.keywords || [],
            scraped_data: n8nResult.scraped_data || {},
            source: 'n8n'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/scrape-website:', error);
        // Return fallback instead of error
        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: `Professional organization with online presence at ${requestData.website_url}. We are committed to delivering value to our clients through our products and services.`,
            suggested_keywords: extractKeywords(requestData.website_url.replace(/https?:\/\//, '').replace(/[\/\.\-_]/g, ' ')),
            scraped_data: {
              title: 'Website Analysis',
              url: requestData.website_url,
              error: 'Processing error'
            },
            source: 'fallback'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/generate-clusters - Generate semantic clusters for tenant profiles
    if (method === 'POST' && path === '/smartprofiles/generate-clusters') {
      try {
        const requestData = await req.json();

        if (!requestData.tenant_id || !requestData.profile_text) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and profile_text are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('🧠 Generating clusters for SmartProfile:', requestData.tenant_id);

        // Get n8n webhook URL
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const clustersWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/smartprofile-clusters`;

        console.log('🔗 Calling n8n clusters:', clustersWebhookUrl);

        // Call n8n for cluster generation
        const n8nResponse = await fetch(clustersWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tenant_id: requestData.tenant_id,
            profile_text: requestData.profile_text,
            keywords: requestData.keywords || []
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n clusters failed:', n8nResponse.status, errorText);

          // Fallback: Generate basic clusters from keywords
          const keywords = requestData.keywords || [];
          const fallbackClusters = keywords.slice(0, 5).map((keyword: string, idx: number) => ({
            primary_term: keyword,
            related_terms: [keyword.toLowerCase(), `${keyword.toLowerCase()} services`, `${keyword.toLowerCase()} solutions`],
            category: 'Services',
            confidence_score: 0.85 + (Math.random() * 0.1)
          }));

          // If no keywords, extract from profile text
          if (fallbackClusters.length === 0) {
            const textKeywords = extractKeywords(requestData.profile_text);
            textKeywords.slice(0, 3).forEach((kw: string) => {
              fallbackClusters.push({
                primary_term: kw,
                related_terms: [kw.toLowerCase()],
                category: 'Services',
                confidence_score: 0.75
              });
            });
          }

          return new Response(
            JSON.stringify({
              success: true,
              clusters_generated: fallbackClusters.length,
              clusters: fallbackClusters,
              source: 'fallback'
            }),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ Clusters generated:', { count: n8nResult.clusters?.length || 0 });

        return new Response(
          JSON.stringify({
            success: true,
            clusters_generated: n8nResult.clusters_generated || n8nResult.clusters?.length || 0,
            clusters: n8nResult.clusters || [],
            source: 'n8n'
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/generate-clusters:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to generate clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/generate - Generate embedding + clusters via n8n
    if (method === 'POST' && path === '/smartprofiles/generate') {
      try {
        const requestData = await req.json();

        if (!requestData.tenant_id) {
          return new Response(
            JSON.stringify({ error: 'tenant_id is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        let shortDescription = requestData.short_description;
        let keywords = requestData.keywords || [];
        let profileType = requestData.profile_type || 'seller';

        // If no short_description provided, fetch from tenant profile
        if (!shortDescription) {
          console.log('📋 Fetching tenant profile for:', requestData.tenant_id);
          const { data: tenantProfile, error: profileError } = await supabase
            .from('t_tenant_profiles')
            .select('business_name, description, industry, city, state, country')
            .eq('tenant_id', requestData.tenant_id)
            .single();

          if (profileError || !tenantProfile) {
            console.error('❌ Failed to fetch tenant profile:', profileError);
            return new Response(
              JSON.stringify({ error: 'Tenant profile not found. Please complete your Business Profile first.' }),
              { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }

          // Build short description from tenant profile
          const parts = [];
          if (tenantProfile.business_name) parts.push(tenantProfile.business_name);
          if (tenantProfile.industry) parts.push(tenantProfile.industry);
          if (tenantProfile.description) parts.push(tenantProfile.description);
          if (tenantProfile.city) parts.push(tenantProfile.city);

          shortDescription = parts.join(' - ') || 'Business Profile';
          console.log('📝 Built description from profile:', shortDescription.substring(0, 100));
        }

        console.log('🤖 Generating smartprofile via n8n for tenant:', requestData.tenant_id);

        // Get n8n webhook URL
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const generateWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/smartprofile-generate`;

        console.log('🔗 Calling n8n:', generateWebhookUrl);

        // Call n8n to generate embedding + clusters
        const n8nResponse = await fetch(generateWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            tenant_id: requestData.tenant_id,
            short_description: shortDescription,
            keywords: keywords,
            profile_type: profileType
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n generate failed:', n8nResponse.status, errorText);
          return new Response(
            JSON.stringify({ success: false, error: 'AI generation failed', details: errorText }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ SmartProfile generated:', n8nResult);

        return new Response(
          JSON.stringify({
            success: true,
            tenant_id: requestData.tenant_id,
            embedding_generated: n8nResult.embedding_generated || false,
            clusters_count: n8nResult.clusters_count || 0
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/generate:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to generate smartprofile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/search - Search smartprofiles via n8n
    if (method === 'POST' && path === '/smartprofiles/search') {
      try {
        const requestData = await req.json();

        if (!requestData.query) {
          return new Response(
            JSON.stringify({ error: 'query is required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const query = requestData.query;
        const scope = requestData.scope || 'product';
        const scopeId = requestData.scope_id || null;
        const limit = requestData.limit || 10;
        const useCache = requestData.use_cache !== false;

        console.log('🔍 SmartProfile search:', { query, scope, scopeId, limit, useCache });

        // Get n8n webhook URL
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        const webhookPrefix = xEnvironment === 'live' ? '/webhook' : '/webhook-test';
        const searchWebhookUrl = `${n8nWebhookUrl}${webhookPrefix}/smartprofile-search`;

        console.log('🔗 Calling n8n SmartProfile search:', searchWebhookUrl);

        // Call n8n for AI-powered search
        const n8nResponse = await fetch(searchWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            query,
            scope,
            scope_id: scopeId,
            limit,
            use_cache: useCache
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n smartprofile search failed:', n8nResponse.status, errorText);
          return new Response(
            JSON.stringify({ success: false, error: 'SmartProfile search failed', details: errorText }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();

        console.log('✅ SmartProfile search completed:', {
          resultsCount: n8nResult.results_count,
          fromCache: n8nResult.from_cache
        });

        // Transform results
        const results = (n8nResult.results || []).map((r: any) => ({
          tenant_id: r.tenant_id,
          business_name: r.business_name || '',
          business_email: r.business_email || '',
          city: r.city || '',
          industry: r.industry || '',
          profile_type: r.profile_type || 'seller',
          profile_snippet: r.profile_snippet || r.ai_enhanced_description?.substring(0, 200) || '',
          ai_enhanced_description: r.ai_enhanced_description || '',
          approved_keywords: r.approved_keywords || [],
          similarity: r.similarity || 0,
          similarity_original: r.similarity_original || r.similarity || 0,
          boost_applied: r.boost_applied || null,
          match_type: r.match_type || 'vector'
        }));

        return new Response(
          JSON.stringify({
            success: true,
            query,
            scope,
            results_count: results.length,
            from_cache: n8nResult.from_cache || false,
            cache_hit_count: n8nResult.cache_hit_count || 0,
            search_type: 'smartprofile_vector',
            results
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/search:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'SmartProfile search failed', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/enhance - AI enhance SmartProfile description via n8n /process-profile
    if (method === 'POST' && path === '/smartprofiles/enhance') {
      try {
        const requestData = await req.json();
        if (!requestData.tenant_id || !requestData.short_description) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and short_description are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        console.log('🤖 Enhancing SmartProfile for tenant:', requestData.tenant_id);

        // Call n8n /process-profile webhook with type=manual
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        // Use /webhook for active workflows (default), /webhook-test only when explicitly in test mode
        const webhookPrefix = xEnvironment === 'test' ? '/webhook-test' : '/webhook';
        const processProfileUrl = `${n8nWebhookUrl}${webhookPrefix}/process-profile`;

        console.log('🔗 Calling n8n process-profile (manual):', processProfileUrl);

        const n8nResponse = await fetch(processProfileUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            type: 'manual',
            content: requestData.short_description,
            userId: requestData.tenant_id,
            groupId: requestData.group_id || ''
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n process-profile failed:', n8nResponse.status, errorText);
          return new Response(
            JSON.stringify({ success: false, error: 'AI enhancement failed', details: errorText }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ SmartProfile enhanced via n8n:', n8nResult.status);

        // Handle error response from n8n
        if (n8nResult.status === 'error') {
          return new Response(
            JSON.stringify({ success: false, error: n8nResult.message, details: n8nResult.details, suggestion: n8nResult.suggestion, recoverable: n8nResult.recoverable }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: n8nResult.enhancedContent,
            original_description: n8nResult.originalContent,
            suggested_keywords: []
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/enhance:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to enhance SmartProfile', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/scrape-website - Scrape website for SmartProfile via n8n /process-profile
    if (method === 'POST' && path === '/smartprofiles/scrape-website') {
      try {
        const requestData = await req.json();
        if (!requestData.tenant_id || !requestData.website_url) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and website_url are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        const urlPattern = /^https?:\/\/.+\..+/;
        if (!urlPattern.test(requestData.website_url)) {
          return new Response(
            JSON.stringify({ error: 'Invalid URL format' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        console.log('🌐 Scraping website for SmartProfile:', requestData.website_url);

        // Call n8n /process-profile webhook with type=website (uses Jina Reader + AI extraction)
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        // Use /webhook for active workflows (default), /webhook-test only when explicitly in test mode
        const webhookPrefix = xEnvironment === 'test' ? '/webhook-test' : '/webhook';
        const processProfileUrl = `${n8nWebhookUrl}${webhookPrefix}/process-profile`;

        console.log('🔗 Calling n8n process-profile (website):', processProfileUrl);

        const n8nResponse = await fetch(processProfileUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            type: 'website',
            websiteUrl: requestData.website_url,
            userId: requestData.tenant_id,
            groupId: requestData.group_id || ''
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n process-profile failed:', n8nResponse.status, errorText);
          return new Response(
            JSON.stringify({ success: false, error: 'Website scraping failed', details: errorText }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ SmartProfile website scraped via n8n:', n8nResult.status);

        // Handle error response from n8n
        if (n8nResult.status === 'error') {
          return new Response(
            JSON.stringify({ success: false, error: n8nResult.message, details: n8nResult.details, suggestion: n8nResult.suggestion, recoverable: n8nResult.recoverable }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({
            success: true,
            ai_enhanced_description: n8nResult.enhancedContent,
            original_description: n8nResult.originalContent,
            source_url: n8nResult.sourceUrl,
            suggested_keywords: []
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/scrape-website:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to scrape website', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/generate-clusters - Generate semantic clusters via n8n /generate-semantic-clusters
    if (method === 'POST' && path === '/smartprofiles/generate-clusters') {
      try {
        const requestData = await req.json();
        if (!requestData.tenant_id || !requestData.profile_text) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and profile_text are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        console.log('🧠 Generating clusters for SmartProfile tenant:', requestData.tenant_id);

        // Call n8n /generate-semantic-clusters webhook
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.srv1096269.hstgr.cloud';
        const xEnvironment = req.headers.get('x-environment');
        // Use /webhook for active workflows (default), /webhook-test only when explicitly in test mode
        const webhookPrefix = xEnvironment === 'test' ? '/webhook-test' : '/webhook';
        const clustersUrl = `${n8nWebhookUrl}${webhookPrefix}/generate-semantic-clusters`;

        console.log('🔗 Calling n8n generate-semantic-clusters:', clustersUrl);

        const n8nResponse = await fetch(clustersUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            membership_id: requestData.tenant_id,
            profile_text: requestData.profile_text,
            keywords: requestData.keywords || [],
            chapter: requestData.chapter || ''
          })
        });

        if (!n8nResponse.ok) {
          const errorText = await n8nResponse.text();
          console.error('❌ n8n generate-semantic-clusters failed:', n8nResponse.status, errorText);
          return new Response(
            JSON.stringify({ success: false, error: 'Cluster generation failed', details: errorText }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const n8nResult = await n8nResponse.json();
        console.log('✅ SmartProfile clusters generated via n8n:', n8nResult.status, 'count:', n8nResult.clusters_generated);

        // Handle error response from n8n
        if (n8nResult.status === 'error') {
          return new Response(
            JSON.stringify({ success: false, error: n8nResult.message, details: n8nResult.details, suggestion: n8nResult.suggestion, recoverable: n8nResult.recoverable }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({
            success: true,
            clusters: n8nResult.clusters || [],
            clusters_generated: n8nResult.clusters_generated || 0,
            tokens_used: n8nResult.tokens_used || 0
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/generate-clusters:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to generate clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // POST /smartprofiles/clusters - Save SmartProfile clusters
    if (method === 'POST' && path === '/smartprofiles/clusters') {
      try {
        const requestData = await req.json();
        if (!requestData.tenant_id || !requestData.clusters) {
          return new Response(
            JSON.stringify({ error: 'tenant_id and clusters are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        const { tenant_id, clusters } = requestData;
        console.log('💾 Saving SmartProfile clusters for tenant:', tenant_id, 'Count:', clusters.length);

        // First, delete existing clusters for this tenant
        await supabaseAdmin
          .from('t_semantic_clusters')
          .delete()
          .eq('tenant_id', tenant_id);

        // Prepare clusters for insertion with tenant_id
        const clustersToInsert = clusters.map((cluster: any) => ({
          tenant_id,
          primary_term: cluster.primary_term,
          related_terms: cluster.related_terms || [],
          category: cluster.category || 'Services',
          confidence_score: cluster.confidence_score || 1.0,
          is_active: true
        }));

        // Insert new clusters
        const { data, error: saveError } = await supabaseAdmin
          .from('t_semantic_clusters')
          .insert(clustersToInsert)
          .select('id');

        if (saveError) throw saveError;

        console.log('✅ Saved SmartProfile clusters:', {
          tenantId: tenant_id,
          count: data.length
        });

        return new Response(
          JSON.stringify({
            success: true,
            clusters_saved: data.length,
            cluster_ids: data.map((c: any) => c.id)
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in POST /smartprofiles/clusters:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to save clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // GET /smartprofiles/clusters/:tenantId - Get SmartProfile clusters
    if (method === 'GET' && path.match(/^\/smartprofiles\/clusters\/[^\/]+$/)) {
      try {
        const tenantId = path.split('/').pop();
        console.log('📋 Getting SmartProfile clusters for tenant:', tenantId);
        const { data, error: fetchError } = await supabaseAdmin
          .from('t_semantic_clusters')
          .select('id, primary_term, related_terms, category, confidence_score')
          .eq('tenant_id', tenantId)
          .eq('is_active', true);
        if (fetchError) throw fetchError;
        return new Response(
          JSON.stringify({ success: true, clusters: data || [] }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /smartprofiles/clusters/:tenantId:', error);
        return new Response(
          JSON.stringify({ success: false, error: 'Failed to get clusters', details: error.message }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ============================================
    // No matching route found - 404
    // ============================================
    console.log('❌ No route matched:', { path, method });
    return new Response(
      JSON.stringify({
        success: false,
        error: 'Endpoint not found',
        availableEndpoints: [
          'GET / (List groups)',
          'GET /:id (Get group)',
          'POST /verify-access (Verify password)',
          'POST /memberships (Create membership)',
          'GET /memberships/:id (Get membership)',
          'PUT /memberships/:id (Update membership)',
          'GET /memberships/group/:groupId (List memberships)',
          'DELETE /memberships/:id (Delete membership)',
          'POST /profiles/enhance (AI enhance)',
          'POST /profiles/scrape-website (Scrape website)',
          'POST /profiles/generate-clusters (Generate clusters via n8n)',
          'POST /profiles/clusters (Save clusters)',
          'GET /profiles/clusters/:membershipId (Get clusters)',
          'DELETE /profiles/clusters/:membershipId (Delete clusters)',
          'POST /profiles/save (Save profile)',
          'POST /search (Search members)',
          'GET /admin/stats/:groupId (Admin stats)',
          'PUT /admin/memberships/:id/status (Update status)',
          'GET /admin/activity-logs/:groupId (Activity logs)',
          'POST /chat/init (VaNi intro message)',
          'POST /chat/session (Get/create session)',
          'POST /chat/activate (Activate group)',
          'POST /chat/intent (Set intent)',
          'POST /chat/search (AI search with cache)',
          'GET /chat/session/:id (Get session)',
          'POST /chat/end (End session)',
          'POST /tenants/stats (Get tenant statistics)',
          'POST /tenants/search (NLP tenant search)',
          'GET /intents (Get resolved intents)',
          'GET /smartprofiles/:tenantId (Get smartprofile)',
          'POST /smartprofiles (Save smartprofile)',
          'POST /smartprofiles/generate (Generate via AI)',
          'POST /smartprofiles/search (Search smartprofiles)'
        ],
        requestedMethod: method,
        requestedPath: path,
        requestedFullPath: fullPath
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('❌ Edge Function error:', error.message);
    return new Response(
      JSON.stringify({ success: false, error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});