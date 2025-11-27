// supabase/functions/business-groups/index.ts
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
    
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Create supabase client with the service role key
    const supabase = createClient(supabaseUrl, supabaseKey, {
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
    
    // ✅ FIXED: Parse URL and strip base path BEFORE splitting
    const url = new URL(req.url);
    const fullPath = url.pathname;
    const basePath = '/functions/v1/business-groups';
    
    // Strip base path
    const path = fullPath.startsWith(basePath) 
      ? fullPath.substring(basePath.length) || '/'
      : fullPath;
    
    // NOW split the stripped path
    const pathParts = path.split('/').filter(part => part.length > 0);
    
    console.log('Request details:', {
      method: req.method,
      fullPath,
      strippedPath: path,
      pathParts,
      partsLength: pathParts.length
    });
    
    // ============================================
    // ROUTE 1: GET /business-groups (root)
    // Get all business groups (with optional filter)
    // ============================================
    if (req.method === 'GET' && pathParts.length === 0) {
      try {
        const groupType = url.searchParams.get('group_type') || 'all';
        
        console.log('Fetching groups with filter:', groupType);
        
        let query = supabase
          .from('t_business_groups')
          .select('id, group_name, group_type, description, settings, member_count, is_active, created_at')
          .eq('is_active', true)
          .order('group_name');
        
        // Apply type filter if not 'all'
        if (groupType !== 'all') {
          query = query.eq('group_type', groupType);
        }
        
        const { data, error } = await query;
        
        if (error) {
          console.error('Error fetching groups:', error);
          throw error;
        }
        
        // Transform data to include extracted fields from settings
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
          JSON.stringify({
            success: true,
            groups: transformedGroups
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /business-groups:', error);
        
        return new Response(
          JSON.stringify({ 
            success: false,
            error: 'Failed to fetch business groups', 
            details: error.message 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // ============================================
    // ROUTE 2: GET /business-groups/:groupId
    // Get specific group by ID
    // ============================================
    if (req.method === 'GET' && pathParts.length === 1 && pathParts[0].match(/^[a-f0-9-]{36}$/)) {
      try {
        const groupId = pathParts[0];
        
        console.log('Fetching group by ID:', groupId);
        
        const { data, error } = await supabase
          .from('t_business_groups')
          .select('*')
          .eq('id', groupId)
          .eq('is_active', true)
          .single();
        
        if (error) {
          console.error('Error fetching group:', error);
          
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ 
                success: false,
                error: 'Group not found' 
              }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          throw error;
        }
        
        return new Response(
          JSON.stringify({
            success: true,
            group: data
          }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } catch (error) {
        console.error('Error in GET /business-groups/:groupId:', error);
        
        return new Response(
          JSON.stringify({ 
            success: false,
            error: 'Failed to fetch group', 
            details: error.message 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // ============================================
    // ROUTE 3: POST /business-groups/verify-access
    // Verify group access with password
    // ============================================
    if (req.method === 'POST' && pathParts.length === 1 && pathParts[0] === 'verify-access') {
      try {
        const requestData = await req.json();
        
        // Validate required fields
        if (!requestData.group_id) {
          return new Response(
            JSON.stringify({ 
              success: false,
              error: 'group_id is required' 
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        if (!requestData.password) {
          return new Response(
            JSON.stringify({ 
              success: false,
              error: 'password is required' 
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        if (!requestData.access_type || !['user', 'admin'].includes(requestData.access_type)) {
          return new Response(
            JSON.stringify({ 
              success: false,
              error: 'access_type must be either "user" or "admin"' 
            }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { group_id, password, access_type } = requestData;
        
        console.log('Verifying access for group:', group_id, 'type:', access_type);
        
        // Fetch group settings
        const { data: group, error } = await supabase
          .from('t_business_groups')
          .select('id, group_name, settings')
          .eq('id', group_id)
          .eq('is_active', true)
          .single();
        
        if (error) {
          console.error('Error fetching group for verification:', error);
          
          if (error.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ 
                success: false,
                access_granted: false,
                error: 'Group not found' 
              }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          throw error;
        }
        
        // Extract passwords from settings
        const userPassword = group.settings?.access?.user_password;
        const adminPassword = group.settings?.access?.admin_password;
        
        console.log('Password check - has user password:', !!userPassword, 'has admin password:', !!adminPassword);
        
        // Verify password based on access type
        let accessGranted = false;
        let accessLevel: 'user' | 'admin' | null = null;
        let redirectTo = '';
        
        if (access_type === 'admin' && adminPassword && password === adminPassword) {
          accessGranted = true;
          accessLevel = 'admin';
          redirectTo = '/vani/channels/bbb/admin';
          console.log('Admin access granted');
        } else if (access_type === 'user' && userPassword && password === userPassword) {
          accessGranted = true;
          accessLevel = 'user';
          redirectTo = '/vani/channels/bbb/onboarding';
          console.log('User access granted');
        } else {
          console.log('Access denied - invalid password');
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
            JSON.stringify({
              success: false,
              access_granted: false,
              error: 'Invalid password'
            }),
            { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      } catch (error) {
        console.error('Error in POST /business-groups/verify-access:', error);
        
        return new Response(
          JSON.stringify({ 
            success: false,
            access_granted: false,
            error: 'Failed to verify access', 
            details: error.message 
          }),
          { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }
    
    // ============================================
    // No matching route found
    // ============================================
    return new Response(
      JSON.stringify({ 
        error: 'Invalid endpoint or method', 
        availableEndpoints: [
          'GET /business-groups?group_type=bbb_chapter (Get all groups with optional filter)',
          'GET /business-groups/:groupId (Get specific group by ID)',
          'POST /business-groups/verify-access (Verify group access password)'
        ],
        requestedMethod: req.method,
        requestedFullPath: fullPath,
        requestedPath: path,
        pathParts: pathParts
      }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error processing request:', error.message);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});