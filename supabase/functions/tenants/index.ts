// supabase/functions/tenants/index.ts

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id'
};

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
          Authorization: authHeader 
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
    
    const user = userData.user;
    console.log('User authenticated successfully:', user.id);
    
    // Parse URL to get path segments
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const tenantId = pathSegments.length > 1 ? pathSegments[1] : null;
    
    // Route based on method and path
    if (req.method === 'GET') {
      if (tenantId) {
        // Get single tenant
        return await getTenantById(supabase, user.id, tenantId);
      } else {
        // Get all user's tenants
        return await getUserTenants(supabase, user.id);
      }
    } else if (req.method === 'POST') {
      // Create a new tenant
      const data = await req.json();
      return await createTenant(supabase, user.id, data);
    } else if (req.method === 'PUT' && tenantId) {
      // Update a tenant
      const data = await req.json();
      return await updateTenant(supabase, user.id, tenantId, data);
    } else if (req.method === 'DELETE' && tenantId) {
      // Delete a tenant
      return await deleteTenant(supabase, user.id, tenantId);
    } else {
      return new Response(
        JSON.stringify({ error: 'Method not supported or missing tenant ID' }),
        { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
  } catch (error) {
    console.error('Error processing request:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});

// Get all tenants for a user
async function getUserTenants(supabase, userId) {
  try {
    console.log('Fetching tenants for user:', userId);
    
    // Query user_tenants table to get tenant IDs for this user
    const { data: userTenants, error: userTenantsError } = await supabase
      .from('t_user_tenants')
      .select(`
        tenant_id,
        is_default,
        t_tenants (
          id,
          name,
          workspace_code,
          domain,
          status,
          is_admin
        )
      `)
      .eq('user_id', userId)
      .eq('status', 'active');
    
    if (userTenantsError) {
      console.error('Error fetching user tenants:', userTenantsError.message);
      throw userTenantsError;
    }
    
    // Format the response
    const tenants = userTenants.map(ut => ({
      id: ut.t_tenants.id,
      name: ut.t_tenants.name,
      workspace_code: ut.t_tenants.workspace_code,
      domain: ut.t_tenants.domain,
      status: ut.t_tenants.status,
      is_admin: ut.t_tenants.is_admin || false,
      is_default: ut.is_default
    }));
    
    console.log(`Found ${tenants.length} tenants for user ${userId}`);
    
    return new Response(
      JSON.stringify(tenants),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in getUserTenants:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Get a specific tenant by ID
async function getTenantById(supabase, userId, tenantId) {
  try {
    console.log(`Fetching tenant ${tenantId} for user ${userId}`);
    
    // Check if user has access to this tenant
    const { data: userTenant, error: userTenantError } = await supabase
      .from('t_user_tenants')
      .select(`
        tenant_id,
        is_default,
        t_tenants (
          id,
          name,
          workspace_code,
          domain,
          status,
          is_admin
        )
      `)
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .eq('status', 'active')
      .single();
    
    if (userTenantError) {
      console.error('Error fetching tenant access:', userTenantError.message);
      return new Response(
        JSON.stringify({ error: 'Tenant not found or access denied' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Format the tenant data
    const tenant = {
      id: userTenant.t_tenants.id,
      name: userTenant.t_tenants.name,
      workspace_code: userTenant.t_tenants.workspace_code,
      domain: userTenant.t_tenants.domain,
      status: userTenant.t_tenants.status,
      is_admin: userTenant.t_tenants.is_admin || false,
      is_default: userTenant.is_default
    };
    
    console.log('Tenant fetched successfully');
    
    return new Response(
      JSON.stringify(tenant),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in getTenantById:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Create a new tenant
async function createTenant(supabase, userId, data) {
  try {
    console.log('Creating new tenant for user:', userId);
    
    const { name, domain } = data;
    
    if (!name) {
      return new Response(
        JSON.stringify({ error: 'Tenant name is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Generate workspace code
    const workspaceCode = generateWorkspaceCode(name);
    
    // Check if workspace name already exists
    const { data: existingTenants, error: checkError } = await supabase
      .from('t_tenants')
      .select('id')
      .ilike('name', name)
      .limit(1);
    
    if (checkError) {
      console.error('Error checking existing tenants:', checkError.message);
      throw checkError;
    }
    
    if (existingTenants && existingTenants.length > 0) {
      return new Response(
        JSON.stringify({ error: 'A workspace with this name already exists' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Create the tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .insert({
        name,
        workspace_code: workspaceCode,
        domain: domain || null,
        status: 'active',
        created_by: userId,
        is_admin: false
      })
      .select()
      .single();
    
    if (tenantError) {
      console.error('Error creating tenant:', tenantError.message);
      throw tenantError;
    }
    
    console.log('Tenant created successfully:', tenant.id);
    
    // Link user to the tenant
    const { data: userTenant, error: linkError } = await supabase
      .from('t_user_tenants')
      .insert({
        user_id: userId,
        tenant_id: tenant.id,
        is_default: true,
        status: 'active'
      })
      .select()
      .single();
    
    if (linkError) {
      console.error('Error linking user to tenant:', linkError.message);
      throw linkError;
    }
    
    console.log('User linked to tenant successfully');
    
    // Set up default roles
    await setupDefaultRoles(supabase, userId, tenant.id);
    
    return new Response(
      JSON.stringify({
        ...tenant,
        is_admin: tenant.is_admin || false,
        is_default: true
      }),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in createTenant:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Update a tenant
async function updateTenant(supabase, userId, tenantId, data) {
  try {
    console.log(`Updating tenant ${tenantId} for user ${userId}`);
    
    // Check if user has access to this tenant
    const { data: userTenant, error: accessError } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .eq('status', 'active')
      .single();
    
    if (accessError) {
      console.error('Access error:', accessError.message);
      return new Response(
        JSON.stringify({ error: 'Tenant not found or access denied' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if user has owner/admin role for this tenant
    const hasAdminRole = await checkUserRole(supabase, userId, tenantId, ['Owner', 'Admin']);
    if (!hasAdminRole) {
      return new Response(
        JSON.stringify({ error: 'You do not have permission to update this tenant' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Update the tenant
    const { data: updatedTenant, error: updateError } = await supabase
      .from('t_tenants')
      .update({
        name: data.name,
        domain: data.domain,
        status: data.status,
        updated_at: new Date().toISOString()
      })
      .eq('id', tenantId)
      .select()
      .single();
    
    if (updateError) {
      console.error('Update error:', updateError.message);
      throw updateError;
    }
    
    console.log('Tenant updated successfully');
    
    return new Response(
      JSON.stringify({
        ...updatedTenant,
        is_admin: updatedTenant.is_admin || false
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in updateTenant:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Delete a tenant
async function deleteTenant(supabase, userId, tenantId) {
  try {
    console.log(`Deleting tenant ${tenantId} for user ${userId}`);
    
    // Check if user has access to this tenant
    const { data: userTenant, error: accessError } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .eq('status', 'active')
      .single();
    
    if (accessError) {
      console.error('Access error:', accessError.message);
      return new Response(
        JSON.stringify({ error: 'Tenant not found or access denied' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Check if user has owner role for this tenant
    const hasOwnerRole = await checkUserRole(supabase, userId, tenantId, ['Owner']);
    if (!hasOwnerRole) {
      return new Response(
        JSON.stringify({ error: 'Only workspace owners can delete workspaces' }),
        { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // Instead of actually deleting, set status to 'inactive'
    const { error: updateError } = await supabase
      .from('t_tenants')
      .update({
        status: 'inactive',
        updated_at: new Date().toISOString()
      })
      .eq('id', tenantId);
    
    if (updateError) {
      console.error('Delete error:', updateError.message);
      throw updateError;
    }
    
    console.log('Tenant marked as inactive successfully');
    
    return new Response(
      JSON.stringify({ success: true, message: 'Workspace deleted successfully' }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error) {
    console.error('Error in deleteTenant:', error.message);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// Helper to check if user has a specific role in a tenant
async function checkUserRole(supabase, userId, tenantId, roleNames) {
  try {
    // Get user-tenant ID
    const { data: userTenant, error: utError } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (utError) return false;
    
    // Check for roles
    const { data: roles, error: rolesError } = await supabase
      .from('t_user_tenant_roles')
      .select(`
        role_id,
        t_category_details!inner (
          sub_cat_name
        )
      `)
      .eq('user_tenant_id', userTenant.id);
    
    if (rolesError) return false;
    
    // Check if user has any of the specified roles
    return roles.some(role => 
      roleNames.includes(role.t_category_details.sub_cat_name)
    );
  } catch (error) {
    console.error('Error checking user role:', error.message);
    return false;
  }
}

// Setup default roles for a new tenant
async function setupDefaultRoles(supabase, userId, tenantId) {
  try {
    console.log(`Setting up default roles for tenant ${tenantId}`);
    
    // Create Roles category
    const { data: category, error: categoryError } = await supabase
      .from('t_category_master')
      .insert({
        category_name: 'Roles',
        display_name: 'Roles',
        is_active: true,
        description: 'User roles in the system',
        tenant_id: tenantId
      })
      .select()
      .single();
    
    if (categoryError) {
      console.error('Error creating roles category:', categoryError.message);
      throw categoryError;
    }
    
    // Create Owner role
    const { data: ownerRole, error: ownerError } = await supabase
      .from('t_category_details')
      .insert({
        sub_cat_name: 'Owner',
        display_name: 'Owner',
        category_id: category.id,
        hexcolor: '#32e275',
        is_active: true,
        sequence_no: 1,
        tenant_id: tenantId,
        is_deletable: false
      })
      .select()
      .single();
    
    if (ownerError) {
      console.error('Error creating owner role:', ownerError.message);
      throw ownerError;
    }
    
    // Assign Owner role to user
    const { data: userTenant } = await supabase
      .from('t_user_tenants')
      .select('id')
      .eq('user_id', userId)
      .eq('tenant_id', tenantId)
      .single();
    
    const { error: assignError } = await supabase
      .from('t_user_tenant_roles')
      .insert({
        user_tenant_id: userTenant.id,
        role_id: ownerRole.id
      });
    
    if (assignError) {
      console.error('Error assigning role:', assignError.message);
      throw assignError;
    }
    
    console.log('Default roles set up successfully');
    return true;
  } catch (error) {
    console.error('Error in setupDefaultRoles:', error.message);
    return false;
  }
}

// Helper to generate a workspace code
function generateWorkspaceCode(name) {
  // Create a code of 4-6 characters from the name
  // Remove special chars, keep alphanumeric, make lowercase
  let base = name.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();
  
  // Add some randomness
  const random = Math.floor(Math.random() * 10000).toString().padStart(4, '0');
  
  // Take first 2 chars of base + 4 random digits
  return (base.substring(0, 2) + random).substring(0, 6);
}