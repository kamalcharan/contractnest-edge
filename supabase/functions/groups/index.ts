// supabase/functions/groups/index.ts
// MEGA FILE: All group operations (memberships, profiles, search, admin)
// ✅ FIXED ROUTING: Properly strips /functions/v1/groups prefix
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS'
};

serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    // Get auth header
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
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
  tenant: tenantHeader
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
    const membershipGetMatch = path.match(/^\/memberships\/([a-f0-9-]{36})$/);
    if (method === 'GET' && membershipGetMatch) {
      try {
        const membershipId = membershipGetMatch[1];
        
        const { data, error } = await supabase
          .from('t_group_memberships')
          .select(`
            id,
            tenant_id,
            group_id,
            status,
            joined_at,
            profile_data,
            is_active,
            created_at,
            updated_at,
            tenant_profile:t_tenant_profiles!tenant_id (
              business_name,
              business_email,
              business_phone,
              business_whatsapp,
              business_whatsapp_country_code,
              city,
              state_code,
              industry_id,
              website_url,
              logo_url
            )
          `)
          .eq('id', membershipId)
          .eq('is_active', true)
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
            membership: {
              membership_id: data.id,
              tenant_id: data.tenant_id,
              group_id: data.group_id,
              status: data.status,
              joined_at: data.joined_at,
              profile_data: data.profile_data,
              tenant_profile: data.tenant_profile
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
    
    // POST /profiles/generate-clusters - Generate semantic clusters via n8n
    if (method === 'POST' && path === '/profiles/generate-clusters') {
      try {
        const requestData = await req.json();

        if (!requestData.membership_id || !requestData.profile_text) {
          return new Response(
            JSON.stringify({ error: 'membership_id and profile_text are required' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Get n8n webhook URL from environment
        const n8nWebhookUrl = Deno.env.get('N8N_WEBHOOK_URL') || 'https://n8n.yourdomain.com';
        const clusterWebhookUrl = `${n8nWebhookUrl}/webhook/generate-semantic-clusters`;

        console.log('🤖 Calling n8n for cluster generation:', {
          membershipId: requestData.membership_id,
          profileLength: requestData.profile_text.length
        });

        // Call n8n webhook
        const n8nResponse = await fetch(clusterWebhookUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            membership_id: requestData.membership_id,
            profile_text: requestData.profile_text,
            keywords: requestData.keywords || [],
            chapter: requestData.chapter || ''
          })
        });

        const n8nResult = await n8nResponse.json();

        if (!n8nResponse.ok || n8nResult.status === 'error') {
          console.error('n8n cluster generation failed:', n8nResult);
          return new Response(
            JSON.stringify({
              success: false,
              error: n8nResult.message || 'Cluster generation failed',
              errorCode: n8nResult.errorCode || 'N8N_ERROR',
              recoverable: n8nResult.recoverable !== false
            }),
            { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        console.log('✅ n8n cluster generation success:', {
          clustersGenerated: n8nResult.clusters_generated
        });

        return new Response(
          JSON.stringify({
            success: true,
            membership_id: requestData.membership_id,
            clusters_generated: n8nResult.clusters_generated || 0,
            clusters: n8nResult.clusters || [],
            tokens_used: n8nResult.tokens_used || 0
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
          'GET /admin/activity-logs/:groupId (Activity logs)'
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