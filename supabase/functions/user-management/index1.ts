// supabase/functions/user-management/index.ts

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
    
    // Get headers
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    const token = authHeader?.replace('Bearer ', '');
    
    if (!authHeader || !token) {
      return new Response(
        JSON.stringify({ error: 'Authorization header is required' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Create supabase client
    const supabase = createClient(supabaseUrl, supabaseKey);
    
    // Get user from token
    const { data: userData, error: userError } = await supabase.auth.getUser(token);
    
    if (userError || !userData?.user) {
      return new Response(
        JSON.stringify({ error: 'Invalid or expired token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    const currentUserId = userData.user.id;
    
    // Parse URL for routing
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    
    // Route: GET /user-management/me - Get current user profile
    if (req.method === 'GET' && pathSegments.length === 2 && pathSegments[1] === 'me') {
      return await getCurrentUserProfile(supabase, currentUserId, tenantId);
    }
    
    // Route: PATCH /user-management/me - Update current user profile
    if (req.method === 'PATCH' && pathSegments.length === 2 && pathSegments[1] === 'me') {
      const body = await req.json();
      return await updateCurrentUserProfile(supabase, currentUserId, body);
    }
    
    // All other routes require tenant ID
    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Route: GET /user-management - List all users
    if (req.method === 'GET' && pathSegments.length === 1) {
      return await listUsers(supabase, tenantId, url.searchParams);
    }
    
    // Route: GET /user-management/:id - Get single user
    if (req.method === 'GET' && pathSegments.length === 2) {
      const userId = pathSegments[1];
      return await getUser(supabase, tenantId, userId);
    }
    
    // Route: PATCH /user-management/:id - Update user
    if (req.method === 'PATCH' && pathSegments.length === 2) {
      const userId = pathSegments[1];
      const body = await req.json();
      return await updateUser(supabase, tenantId, userId, body, currentUserId);
    }
    
    // Route: POST /user-management/:id/suspend - Suspend user
    if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'suspend') {
      const userId = pathSegments[1];
      return await suspendUser(supabase, tenantId, userId, currentUserId);
    }
    
    // Route: POST /user-management/:id/activate - Activate user
    if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'activate') {
      const userId = pathSegments[1];
      return await activateUser(supabase, tenantId, userId, currentUserId);
    }
    
    // Route: POST /user-management/:id/reset-password - Reset password
    if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'reset-password') {
      const userId = pathSegments[1];
      return await resetUserPassword(supabase, tenantId, userId, currentUserId);
    }
    
    // Route: GET /user-management/:id/activity - Get user activity
    if (req.method === 'GET' && pathSegments.length === 3 && pathSegments[2] === 'activity') {
      const userId = pathSegments[1];
      return await getUserActivity(supabase, tenantId, userId, url.searchParams);
    }
    
    // Route: POST /user-management/:id/roles - Assign role
    if (req.method === 'POST' && pathSegments.length === 3 && pathSegments[2] === 'roles') {
      const userId = pathSegments[1];
      const body = await req.json();
      return await assignRole(supabase, tenantId, userId, body.role_id, currentUserId);
    }
    
    // Route: DELETE /user-management/:id/roles/:roleId - Remove role
    if (req.method === 'DELETE' && pathSegments.length === 4 && pathSegments[2] === 'roles') {
      const userId = pathSegments[1];
      const roleId = pathSegments[3];
      return await removeRole(supabase, tenantId, userId, roleId, currentUserId);
    }
    
    // Invalid route
    return new Response(
      JSON.stringify({ error: 'Invalid endpoint' }),
      { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error processing request:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Internal server error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// List users with filtering and pagination
async function listUsers(supabase: any, tenantId: string, params: URLSearchParams) {
  try {
    const page = parseInt(params.get('page') || '1');
    const limit = parseInt(params.get('limit') || '10');
    const status = params.get('status') || 'all';
    const role = params.get('role') || 'all';
    const search = params.get('search') || '';
    const offset = (page - 1) * limit;
    
    // First, get the role category ID for this tenant
    const { data: roleCategory } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Roles')
      .single();
    
    if (!roleCategory) {
      console.error('Role category not found for tenant:', tenantId);
    }
    
    // Get user-tenant relationships first
    let userTenantQuery = supabase
      .from('t_user_tenants')
      .select('*', { count: 'exact' })
      .eq('tenant_id', tenantId);
    
    // Apply status filter at tenant level
    if (status === 'active') {
      userTenantQuery = userTenantQuery.eq('status', 'active');
    } else if (status === 'suspended') {
      userTenantQuery = userTenantQuery.eq('status', 'suspended');
    }
    
    const { data: userTenants, error: utError, count } = await userTenantQuery;
    
    if (utError) {
      console.error('Error querying user_tenants:', utError);
      throw utError;
    }
    
    if (!userTenants || userTenants.length === 0) {
      return new Response(
        JSON.stringify({
          data: [],
          pagination: {
            page,
            limit,
            total: 0,
            totalPages: 0
          }
        }),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get user IDs
    const userIds = userTenants.map(ut => ut.user_id);
    
    // Get user profiles
    let profileQuery = supabase
      .from('t_user_profiles')
      .select('*')
      .in('user_id', userIds);
    
    // Apply search filter
    if (search) {
      profileQuery = profileQuery.or(`first_name.ilike.%${search}%,last_name.ilike.%${search}%,email.ilike.%${search}%,user_code.ilike.%${search}%`);
    }
    
    // Apply status filter at profile level
    if (status === 'inactive') {
      profileQuery = profileQuery.eq('is_active', false);
    }
    
    const { data: profiles, error: profileError } = await profileQuery;
    
    if (profileError) {
      console.error('Error querying profiles:', profileError);
      throw profileError;
    }
    
    // Create a map of user profiles
    const profileMap = new Map();
    (profiles || []).forEach(profile => {
      profileMap.set(profile.user_id, profile);
    });
    
    // Create a map of user tenants
    const userTenantMap = new Map();
    userTenants.forEach(ut => {
      userTenantMap.set(ut.user_id, ut);
    });
    
    // Filter to only include users with profiles
    const filteredUserIds = userIds.filter(id => profileMap.has(id));
    
    // Apply pagination
    const paginatedUserIds = filteredUserIds.slice(offset, offset + limit);
    
    // Now get additional data for paginated users
    const transformedData = await Promise.all(paginatedUserIds.map(async (userId) => {
      const profile = profileMap.get(userId);
      const userTenant = userTenantMap.get(userId);
      
      if (!profile || !userTenant) return null;
      
      // Get user's role
      let userRole = null;
      if (roleCategory && userTenant.id) {
        const { data: roleData } = await supabase
          .from('t_user_tenant_roles')
          .select(`
            role_id,
            role:t_category_details(
              id,
              display_name,
              sub_cat_name
            )
          `)
          .eq('user_tenant_id', userTenant.id)
          .single();
        
        if (roleData?.role) {
          userRole = roleData.role;
        }
      }
      
      // Get auth user info
      let authData = null;
      try {
        const { data } = await supabase.auth.admin.getUserById(userId);
        authData = data;
      } catch (e) {
        console.log('Failed to get auth data for user:', userId);
      }
      
      let userStatus = 'active';
      if (userTenant.status === 'suspended') {
        userStatus = 'suspended';
      } else if (!profile.is_active) {
        userStatus = 'inactive';
      }
      
      // Apply role filter
      if (role !== 'all' && (!userRole || userRole.display_name !== role)) {
        return null;
      }
      
      return {
        id: profile.id,
        user_id: profile.user_id,
        email: authData?.user?.email || profile.email,
        first_name: profile.first_name,
        last_name: profile.last_name,
        user_code: profile.user_code,
        mobile_number: profile.mobile_number,
        status: userStatus,
        role: userRole?.display_name || userRole?.sub_cat_name,
        role_id: userRole?.id,
        last_login: authData?.user?.last_sign_in_at,
        created_at: profile.created_at,
        updated_at: profile.updated_at
      };
    }));
    
    // Filter out nulls (from role filtering)
    const finalData = transformedData.filter(user => user !== null);
    
    return new Response(
      JSON.stringify({
        data: finalData,
        pagination: {
          page,
          limit,
          total: filteredUserIds.length,
          totalPages: Math.ceil(filteredUserIds.length / limit)
        }
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error listing users:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to list users' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Get single user details
async function getUser(supabase: any, tenantId: string, userId: string) {
  try {
    // Get user profile
    const { data: user, error } = await supabase
      .from('t_user_profiles')
      .select(`
        *,
        user_tenant:t_user_tenants!inner(
          id,
          tenant_id,
          is_default,
          status,
          created_at
        )
      `)
      .eq('user_id', userId)
      .eq('user_tenant.tenant_id', tenantId)
      .single();
    
    if (error) throw error;
    
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'User not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get auth user info
    const { data: authData } = await supabase.auth.admin.getUserById(userId);
    
    // Get user roles
    const { data: roleCategory } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Roles')
      .single();
    
    let assignedRoles = [];
    if (roleCategory) {
      const { data: rolesData } = await supabase
        .from('t_user_tenant_roles')
        .select(`
          role_id,
          role:t_category_details!inner(
            id,
            display_name,
            sub_cat_name,
            description
          )
        `)
        .eq('user_tenant_id', user.user_tenant.id)
        .eq('role.category_id', roleCategory.id);
      
      assignedRoles = (rolesData || []).map(r => ({
        id: r.role.id,
        name: r.role.display_name || r.role.sub_cat_name,
        description: r.role.description
      }));
    }
    
    // Get user statistics
    const stats = await getUserStats(supabase, userId);
    
    // Get recent activity (last 30 days)
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    
    const { data: activities } = await supabase
      .from('t_user_activity_logs')
      .select('*')
      .eq('user_id', userId)
      .gte('created_at', thirtyDaysAgo.toISOString())
      .order('created_at', { ascending: false })
      .limit(50);
    
    // Transform data
    const transformedUser = {
      id: user.id,
      user_id: user.user_id,
      email: authData?.user?.email || user.email,
      first_name: user.first_name,
      last_name: user.last_name,
      user_code: user.user_code,
      mobile_number: user.mobile_number,
      country_code: user.country_code,
      preferred_language: user.preferred_language,
      preferred_theme: user.preferred_theme,
      timezone: user.timezone,
      department: user.department,
      employee_id: user.employee_id,
      joining_date: user.joining_date,
      is_active: user.is_active,
      status: user.user_tenant.status === 'suspended' ? 'suspended' : 
              !user.is_active ? 'inactive' : 'active',
      last_login: authData?.user?.last_sign_in_at,
      created_at: user.created_at,
      updated_at: user.updated_at,
      profile: {
        country_code: user.country_code,
        preferred_language: user.preferred_language,
        timezone: user.timezone,
        department: user.department,
        employee_id: user.employee_id,
        joining_date: user.joining_date
      },
      stats,
      activity_log: activities || [],
      assigned_roles: assignedRoles
    };
    
    return new Response(
      JSON.stringify(transformedUser),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error fetching user:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to fetch user details' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Update user profile
async function updateUser(supabase: any, tenantId: string, userId: string, body: any, performedBy: string) {
  try {
    // Check if user has permission to update other users
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.update');
    
    if (!hasPermission && performedBy !== userId) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Validate that user belongs to tenant
    const { data: userTenant } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (!userTenant) {
      return new Response(
        JSON.stringify({ error: 'User not found in this tenant' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Update user profile
    const allowedFields = [
      'first_name', 'last_name', 'mobile_number', 'country_code',
      'preferred_language', 'preferred_theme', 'timezone',
      'department', 'employee_id'
    ];
    
    const updateData: any = {};
    allowedFields.forEach(field => {
      if (body[field] !== undefined) {
        updateData[field] = body[field];
      }
    });
    
    updateData.updated_at = new Date().toISOString();
    updateData.updated_by = performedBy;
    
    const { error } = await supabase
      .from('t_user_profiles')
      .update(updateData)
      .eq('user_id', userId);
    
    if (error) throw error;
    
    // Log activity
    await logUserActivity(supabase, userId, 'profile_updated', {
      updated_by: performedBy,
      fields_updated: Object.keys(updateData)
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'User updated successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error updating user:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to update user' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Suspend user
async function suspendUser(supabase: any, tenantId: string, userId: string, performedBy: string) {
  try {
    // Check permission
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.suspend');
    
    if (!hasPermission) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Cannot suspend yourself
    if (userId === performedBy) {
      return new Response(
        JSON.stringify({ error: 'Cannot suspend your own account' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Update user tenant status
    const { error } = await supabase
      .from('t_user_tenants')
      .update({ 
        status: 'suspended',
        updated_at: new Date().toISOString()
      })
      .eq('user_id', userId)
      .eq('tenant_id', tenantId);
    
    if (error) throw error;
    
    // Update user profile
    await supabase
      .from('t_user_profiles')
      .update({ 
        is_active: false,
        updated_at: new Date().toISOString()
      })
      .eq('user_id', userId);
    
    // Log activity
    await logUserActivity(supabase, userId, 'user_suspended', {
      suspended_by: performedBy,
      tenant_id: tenantId
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'User suspended successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error suspending user:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to suspend user' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Activate user
async function activateUser(supabase: any, tenantId: string, userId: string, performedBy: string) {
  try {
    // Check permission
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.activate');
    
    if (!hasPermission) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Update user tenant status
    const { error } = await supabase
      .from('t_user_tenants')
      .update({ 
        status: 'active',
        updated_at: new Date().toISOString()
      })
      .eq('user_id', userId)
      .eq('tenant_id', tenantId);
    
    if (error) throw error;
    
    // Update user profile
    await supabase
      .from('t_user_profiles')
      .update({ 
        is_active: true,
        updated_at: new Date().toISOString()
      })
      .eq('user_id', userId);
    
    // Log activity
    await logUserActivity(supabase, userId, 'user_activated', {
      activated_by: performedBy,
      tenant_id: tenantId
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'User activated successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error activating user:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to activate user' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Reset user password
async function resetUserPassword(supabase: any, tenantId: string, userId: string, performedBy: string) {
  try {
    // Check permission
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.reset_password');
    
    if (!hasPermission && performedBy !== userId) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get user email
    const { data: userData } = await supabase.auth.admin.getUserById(userId);
    
    if (!userData?.user?.email) {
      return new Response(
        JSON.stringify({ error: 'User email not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Send password reset email
    const { error } = await supabase.auth.resetPasswordForEmail(userData.user.email, {
      redirectTo: `${Deno.env.get('FRONTEND_URL')}/reset-password`
    });
    
    if (error) throw error;
    
    // Log activity
    await logUserActivity(supabase, userId, 'password_reset_requested', {
      requested_by: performedBy
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'Password reset email sent' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error resetting password:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to send password reset email' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Get user activity log
async function getUserActivity(supabase: any, tenantId: string, userId: string, params: URLSearchParams) {
  try {
    const days = parseInt(params.get('days') || '30');
    const limit = parseInt(params.get('limit') || '100');
    
    const startDate = new Date();
    startDate.setDate(startDate.getDate() - days);
    
    const { data: activities, error } = await supabase
      .from('t_user_activity_logs')
      .select('*')
      .eq('user_id', userId)
      .gte('created_at', startDate.toISOString())
      .order('created_at', { ascending: false })
      .limit(limit);
    
    if (error) throw error;
    
    return new Response(
      JSON.stringify({ data: activities || [] }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error fetching user activity:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to fetch activity log' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Assign role to user
async function assignRole(supabase: any, tenantId: string, userId: string, roleId: string, performedBy: string) {
  try {
    // Check permission
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.manage_roles');
    
    if (!hasPermission) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get user tenant record
    const { data: userTenant } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (!userTenant) {
      return new Response(
        JSON.stringify({ error: 'User not found in this tenant' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if role exists in category_details
    const { data: role } = await supabase
      .from('t_category_details')
      .select('id, display_name, sub_cat_name')
      .eq('id', roleId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (!role) {
      return new Response(
        JSON.stringify({ error: 'Role not found' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Assign role
    const { error } = await supabase
      .from('t_user_tenant_roles')
      .insert({
        user_tenant_id: userTenant.id,
        role_id: roleId,
        assigned_by: performedBy,
        assigned_at: new Date().toISOString()
      });
    
    if (error) {
      if (error.code === '23505') {
        return new Response(
          JSON.stringify({ error: 'User already has this role' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      throw error;
    }
    
    // Log activity
    await logUserActivity(supabase, userId, 'role_assigned', {
      role_id: roleId,
      role_name: role.display_name || role.sub_cat_name,
      assigned_by: performedBy
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'Role assigned successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error assigning role:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to assign role' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Remove role from user
async function removeRole(supabase: any, tenantId: string, userId: string, roleId: string, performedBy: string) {
  try {
    // Check permission
    const hasPermission = await checkUserPermission(supabase, performedBy, tenantId, 'users.manage_roles');
    
    if (!hasPermission) {
      return new Response(
        JSON.stringify({ error: 'Insufficient permissions' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get user tenant record
    const { data: userTenant } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (!userTenant) {
      return new Response(
        JSON.stringify({ error: 'User not found in this tenant' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Get role info for logging
    const { data: role } = await supabase
      .from('t_category_details')
      .select('display_name, sub_cat_name')
      .eq('id', roleId)
      .single();
    
    // Remove role
    const { error } = await supabase
      .from('t_user_tenant_roles')
      .delete()
      .eq('user_tenant_id', userTenant.id)
      .eq('role_id', roleId);
    
    if (error) throw error;
    
    // Log activity
    await logUserActivity(supabase, userId, 'role_removed', {
      role_id: roleId,
      role_name: role?.display_name || role?.sub_cat_name,
      removed_by: performedBy
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'Role removed successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error removing role:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to remove role' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Get current user profile
async function getCurrentUserProfile(supabase: any, userId: string, tenantId: string | null) {
  try {
    let query = supabase
      .from('t_user_profiles')
      .select('*')
      .eq('user_id', userId)
      .single();
    
    const { data: profile, error } = await query;
    
    if (error) throw error;
    
    // Get auth user info
    const { data: authData } = await supabase.auth.admin.getUserById(userId);
    
    // If tenant ID provided, get tenant-specific data
    let tenantData = null;
    let assignedRoles = [];
    
    if (tenantId) {
      const { data } = await supabase
        .from('t_user_tenants')
        .select(`
          *
        `)
        .eq('user_id', userId)
        .eq('tenant_id', tenantId)
        .single();
      
      tenantData = data;
      
      // Get roles if user belongs to tenant
      if (tenantData) {
        const { data: roleCategory } = await supabase
          .from('t_category_master')
          .select('id')
          .eq('tenant_id', tenantId)
          .eq('category_name', 'Roles')
          .single();
        
        if (roleCategory) {
          const { data: rolesData } = await supabase
            .from('t_user_tenant_roles')
            .select(`
              role_id,
              role:t_category_details!inner(
                id,
                display_name,
                sub_cat_name,
                description
              )
            `)
            .eq('user_tenant_id', tenantData.id)
            .eq('role.category_id', roleCategory.id);
          
          assignedRoles = (rolesData || []).map(r => ({
            id: r.role.id,
            name: r.role.display_name || r.role.sub_cat_name,
            description: r.role.description
          }));
        }
      }
    }
    
    // Get stats
    const stats = await getUserStats(supabase, userId);
    
    const response = {
      ...profile,
      email: authData?.user?.email || profile.email,
      last_login: authData?.user?.last_sign_in_at,
      stats,
      tenant_access: tenantData ? {
        id: tenantData.id,
        tenant_id: tenantData.tenant_id,
        is_default: tenantData.is_default,
        joined_at: tenantData.created_at
      } : null,
      assigned_roles: assignedRoles
    };
    
    return new Response(
      JSON.stringify(response),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error fetching current user profile:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to fetch profile' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Update current user profile
async function updateCurrentUserProfile(supabase: any, userId: string, body: any) {
  try {
    // Users can only update certain fields of their own profile
    const allowedFields = [
      'first_name', 'last_name', 'mobile_number', 'country_code',
      'preferred_language', 'preferred_theme', 'timezone'
    ];
    
    const updateData: any = {};
    allowedFields.forEach(field => {
      if (body[field] !== undefined) {
        updateData[field] = body[field];
      }
    });
    
    updateData.updated_at = new Date().toISOString();
    
    const { error } = await supabase
      .from('t_user_profiles')
      .update(updateData)
      .eq('user_id', userId);
    
    if (error) throw error;
    
    // Log activity
    await logUserActivity(supabase, userId, 'profile_updated', {
      fields_updated: Object.keys(updateData)
    });
    
    return new Response(
      JSON.stringify({ success: true, message: 'Profile updated successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error updating profile:', error);
    return new Response(
      JSON.stringify({ error: error.message || 'Failed to update profile' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Helper function to check user permissions
async function checkUserPermission(supabase: any, userId: string, tenantId: string, permission: string) {
  try {
    // For now, just check if user has admin/owner role
    // You can expand this to check specific permissions later
    
    const { data: userTenant } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (!userTenant) return false;
    
    // Get role category
    const { data: roleCategory } = await supabase
      .from('t_category_master')
      .select('id')
      .eq('tenant_id', tenantId)
      .eq('category_name', 'Roles')
      .single();
    
    if (!roleCategory) return false;
    
    // Check if user has admin or owner role
    const { data: userRole } = await supabase
      .from('t_user_tenant_roles')
      .select(`
        role:t_category_details!inner(
          sub_cat_name,
          display_name
        )
      `)
      .eq('user_tenant_id', userTenant.id)
      .eq('role.category_id', roleCategory.id)
      .in('role.sub_cat_name', ['Admin', 'Owner'])
      .single();
    
    return !!userRole;
  } catch (error) {
    console.error('Error checking permission:', error);
    return false;
  }
}

// Helper function to get user statistics
async function getUserStats(supabase: any, userId: string) {
  try {
    // Get login count
    const { count: loginCount } = await supabase
      .from('t_user_activity_logs')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('action', 'login');
    
    // Get last password change
    const { data: passwordChange } = await supabase
      .from('t_user_activity_logs')
      .select('created_at')
      .eq('user_id', userId)
      .eq('action', 'password_changed')
      .order('created_at', { ascending: false })
      .limit(1)
      .single();
    
    // Get failed login attempts
    const { count: failedLogins } = await supabase
      .from('t_user_activity_logs')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', userId)
      .eq('action', 'failed_login');
    
    // Get last failed login
    const { data: lastFailedLogin } = await supabase
      .from('t_user_activity_logs')
      .select('created_at')
      .eq('user_id', userId)
      .eq('action', 'failed_login')
      .order('created_at', { ascending: false })
      .limit(1)
      .single();
    
    return {
      total_logins: loginCount || 0,
      last_password_change: passwordChange?.created_at,
      failed_login_attempts: failedLogins || 0,
      last_failed_login: lastFailedLogin?.created_at
    };
  } catch (error) {
    console.error('Error getting user stats:', error);
    return {
      total_logins: 0,
      last_password_change: null,
      failed_login_attempts: 0,
      last_failed_login: null
    };
  }
}

// Helper function to log user activity
async function logUserActivity(supabase: any, userId: string, action: string, metadata: any = {}) {
  try {
    await supabase
      .from('t_user_activity_logs')
      .insert({
        user_id: userId,
        action,
        metadata,
        created_at: new Date().toISOString()
      });
  } catch (error) {
    console.error('Error logging activity:', error);
    // Don't throw - logging failure shouldn't break the main operation
  }
}