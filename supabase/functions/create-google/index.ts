import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { name, workspace_code } = await req.json()
    const authHeader = req.headers.get('Authorization')!
    
    // Validate inputs
    if (!name || !workspace_code) {
      return new Response(
        JSON.stringify({ error: 'Workspace name and code are required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }
    
    // Create admin client with service role key to bypass RLS
    const supabaseAdmin = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      {
        auth: {
          autoRefreshToken: false,
          persistSession: false,
          detectSessionInUrl: false
        }
      }
    )
    
    // Get user from the regular token
    const supabaseAuth = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!
    )
    
    const token = authHeader.replace('Bearer ', '')
    const { data: { user }, error: authError } = await supabaseAuth.auth.getUser(token)
    
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }
    
    console.log('Creating/resuming tenant for Google user:', user.id)
    
    // Check if user already has a tenant (idempotency check)
    const { data: existingUserTenant } = await supabaseAdmin
      .from('t_user_tenants')
      .select(`
        id,
        tenant_id,
        t_tenants!inner (
          id,
          name,
          workspace_code,
          status,
          is_admin,
          created_by
        )
      `)
      .eq('user_id', user.id)
      .eq('status', 'active')
      .single()
    
    if (existingUserTenant) {
      console.log('User already has a tenant, returning existing data')
      
      // Update user metadata to mark registration as complete
      await supabaseAdmin.auth.admin.updateUserById(user.id, {
        user_metadata: {
          ...user.user_metadata,
          registration_status: 'complete'
        }
      })
      
      return new Response(
        JSON.stringify({
          tenant: {
            ...existingUserTenant.t_tenants,
            is_owner: existingUserTenant.t_tenants.created_by === user.id,
            is_default: true,
            is_admin: existingUserTenant.t_tenants.is_admin || false
          }
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200
        }
      )
    }
    
    // Check if the workspace code is already taken
    const { data: existingTenant } = await supabaseAdmin
      .from('t_tenants')
      .select('id, name')
      .eq('workspace_code', workspace_code)
      .single()
    
    if (existingTenant) {
      return new Response(
        JSON.stringify({ 
          error: 'Workspace code already exists. Please choose a different one.',
          code: 'WORKSPACE_CODE_EXISTS'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }
    
    // Start a manual "transaction" - track what we create
    let createdTenantId: string | null = null
    let createdUserTenantId: string | null = null
    let createdCategoryId: string | null = null
    
    try {
      // Step 1: Update user metadata to indicate registration in progress
      await supabaseAdmin.auth.admin.updateUserById(user.id, {
        user_metadata: {
          ...user.user_metadata,
          registration_status: 'pending_workspace',
          registration_attempt_at: new Date().toISOString()
        }
      })
      
      // Step 2: Create tenant
      const { data: newTenant, error: tenantError } = await supabaseAdmin
        .from('t_tenants')
        .insert({
          name,
          workspace_code,
          created_by: user.id,
          status: 'active',
          is_admin: false
        })
        .select()
        .single()
      
      if (tenantError || !newTenant) {
        console.error('Tenant creation error:', tenantError?.message || 'No data returned')
        throw new Error(tenantError?.message || 'Failed to create workspace')
      }
      
      createdTenantId = newTenant.id
      console.log('Tenant created successfully:', createdTenantId)
      
      // Step 3: Create user-tenant association
      const { data: userTenant, error: userTenantError } = await supabaseAdmin
        .from('t_user_tenants')
        .insert({
          user_id: user.id,
          tenant_id: newTenant.id,
          is_default: true,
          status: 'active'
        })
        .select()
        .single()
      
      if (userTenantError || !userTenant) {
        console.error('User-tenant association error:', userTenantError?.message || 'No data returned')
        throw new Error(userTenantError?.message || 'Failed to associate user with workspace')
      }
      
      createdUserTenantId = userTenant.id
      console.log('User-tenant association created successfully:', createdUserTenantId)
      
      // Step 4: Create or update user profile - USING UPSERT TO PREVENT DUPLICATES
      // First, try to get existing profile
      const { data: existingProfile } = await supabaseAdmin
        .from('t_user_profiles')
        .select('id, first_name, last_name, user_code')
        .eq('user_id', user.id)
        .maybeSingle()
      
      if (!existingProfile) {
        const firstName = user.user_metadata?.given_name || 
                         user.user_metadata?.first_name ||
                         user.user_metadata?.name?.split(' ')[0] ||
                         user.user_metadata?.full_name?.split(' ')[0] || 
                         '';
        const lastName = user.user_metadata?.family_name || 
                        user.user_metadata?.last_name ||
                        user.user_metadata?.name?.split(' ').slice(1).join(' ') ||
                        user.user_metadata?.full_name?.split(' ').slice(1).join(' ') || 
                        '';
        
        console.log('Extracted names:', { firstName, lastName, metadata: user.user_metadata });

        // Generate unique user code with duplicate check
        const userCode = await generateUserCode(supabaseAdmin, firstName, lastName)

        // Use upsert to handle race conditions
        const { error: profileError } = await supabaseAdmin
          .from('t_user_profiles')
          .upsert({
            user_id: user.id,
            first_name: firstName,
            last_name: lastName,
            email: user.email!,
            user_code: userCode,
            is_active: true
          }, {
            onConflict: 'user_id',
            ignoreDuplicates: false
          })
        
        if (profileError) {
          console.error('Profile upsert error:', profileError.message)
          // Don't fail the whole operation for profile creation
          // The profile might already exist from another concurrent request
        }
      } else if (existingProfile.user_code === '00000000' || !existingProfile.first_name || !existingProfile.last_name) {
        // Update incomplete profile
        const updates: any = {}
        
        if (!existingProfile.first_name || !existingProfile.last_name) {
          updates.first_name = existingProfile.first_name || user.user_metadata?.given_name || 
                              user.user_metadata?.first_name || '';
          updates.last_name = existingProfile.last_name || user.user_metadata?.family_name || 
                             user.user_metadata?.last_name || '';
        }
        
        if (existingProfile.user_code === '00000000') {
          updates.user_code = await generateUserCode(
            supabaseAdmin,
            updates.first_name || existingProfile.first_name || '',
            updates.last_name || existingProfile.last_name || ''
          )
        }
        
        if (Object.keys(updates).length > 0) {
          await supabaseAdmin
            .from('t_user_profiles')
            .update(updates)
            .eq('id', existingProfile.id)
        }
      }
      
      // Step 5: Create or update auth method entry - USING UPSERT
      const { data: existingAuthMethod } = await supabaseAdmin
        .from('t_user_auth_methods')
        .select('id')
        .eq('user_id', user.id)
        .eq('auth_type', 'google')
        .maybeSingle()

      if (!existingAuthMethod) {
        console.log('Creating Google auth method entry for user:', user.id)
        
        const { error: authMethodError } = await supabaseAdmin
          .from('t_user_auth_methods')
          .upsert({
            user_id: user.id,
            auth_type: 'google',
            auth_identifier: user.email!,
            is_primary: true,
            is_verified: true,
            linked_at: new Date().toISOString(),
            metadata: {
              provider: 'google',
              google_id: user.user_metadata?.sub || user.user_metadata?.google_id
            }
          }, {
            onConflict: 'user_id,auth_type',
            ignoreDuplicates: false
          })
        
        if (authMethodError) {
          console.error('Error creating auth method:', authMethodError)
          // Don't fail the whole operation
        }
      } else {
        console.log('Auth method already exists for user')
      }
      
      // Step 6: Create default roles for the tenant
      try {
        const { data: roleCategory, error: categoryError } = await supabaseAdmin
          .from('t_category_master')
          .insert({
            category_name: 'Roles',
            display_name: 'Roles',
            is_active: true,
            description: 'User roles in the system',
            tenant_id: newTenant.id
          })
          .select()
          .single()
        
        if (!categoryError && roleCategory) {
          createdCategoryId = roleCategory.id
          
          // Create Owner role
          const { data: ownerRole, error: roleError } = await supabaseAdmin
            .from('t_category_details')
            .insert({
              sub_cat_name: 'Owner',
              display_name: 'Owner',
              category_id: roleCategory.id,
              hexcolor: '#32e275',
              is_active: true,
              sequence_no: 1,
              tenant_id: newTenant.id,
              is_deletable: false
            })
            .select()
            .single()
          
          if (!roleError && ownerRole) {
            // Assign Owner role to user
            await supabaseAdmin
              .from('t_user_tenant_roles')
              .insert({
                user_tenant_id: userTenant.id,
                role_id: ownerRole.id
              })
          }
        }
      } catch (roleError) {
        console.error('Error creating default roles:', roleError)
        // Don't fail the tenant creation for role setup
      }
      
      // Step 7: Update user metadata to mark registration as complete
      await supabaseAdmin.auth.admin.updateUserById(user.id, {
        user_metadata: {
          ...user.user_metadata,
          registration_status: 'complete',
          registration_completed_at: new Date().toISOString()
        }
      })
      
      console.log('Tenant creation completed successfully')
      
      return new Response(
        JSON.stringify({
          tenant: {
            ...newTenant,
            is_owner: true,
            is_default: true,
            is_admin: false
          }
        }),
        {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 201
        }
      )
      
    } catch (error: any) {
      console.error('Error during tenant creation process:', error)
      
      // Cleanup logic - try to rollback what we created
      if (createdUserTenantId) {
        try {
          await supabaseAdmin
            .from('t_user_tenants')
            .delete()
            .eq('id', createdUserTenantId)
        } catch (cleanupError) {
          console.error('Failed to cleanup user-tenant:', cleanupError)
        }
      }
      
      if (createdCategoryId) {
        try {
          await supabaseAdmin
            .from('t_category_master')
            .delete()
            .eq('id', createdCategoryId)
        } catch (cleanupError) {
          console.error('Failed to cleanup category:', cleanupError)
        }
      }
      
      if (createdTenantId) {
        try {
          await supabaseAdmin
            .from('t_tenants')
            .delete()
            .eq('id', createdTenantId)
        } catch (cleanupError) {
          console.error('Failed to cleanup tenant:', cleanupError)
        }
      }
      
      // Update user metadata to indicate failure
      try {
        await supabaseAdmin.auth.admin.updateUserById(user.id, {
          user_metadata: {
            ...user.user_metadata,
            registration_status: 'pending_workspace',
            registration_last_error: error.message,
            registration_failed_at: new Date().toISOString()
          }
        })
      } catch (updateError) {
        console.error('Failed to update user status after error:', updateError)
      }
      
      throw error
    }
    
  } catch (error: any) {
    console.error('Unexpected error:', error)
    
    return new Response(
      JSON.stringify({ 
        error: error.message || 'An unexpected error occurred',
        code: 'TENANT_CREATION_FAILED',
        retry: true
      }),
      {
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
        status: 500
      }
    )
  }
})

// Helper to generate base user code from first and last name
function generateBaseUserCode(firstName: string, lastName: string): string {
  const cleanFirst = (firstName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();
  const cleanLast = (lastName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();

  if (!cleanFirst && !cleanLast) {
    const timestamp = Date.now().toString(36).slice(-4).toUpperCase();
    const random = Math.random().toString(36).substring(2, 6).toUpperCase();
    return timestamp + random;
  }

  const firstPart = cleanFirst.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());
  const lastPart = cleanLast.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());

  return firstPart + lastPart;
}

// Helper to generate a unique user code with duplicate check
async function generateUserCode(supabase: any, firstName: string, lastName: string): Promise<string> {
  const baseCode = generateBaseUserCode(firstName, lastName);

  // Check if base code exists
  const { data: existing } = await supabase
    .from('t_user_profiles')
    .select('user_code')
    .eq('user_code', baseCode)
    .maybeSingle();

  if (!existing) {
    return baseCode;
  }

  // Base code exists, try with suffix A, B, C...
  const suffixes = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  for (const suffix of suffixes) {
    const candidateCode = baseCode + suffix;
    const { data: existingSuffix } = await supabase
      .from('t_user_profiles')
      .select('user_code')
      .eq('user_code', candidateCode)
      .maybeSingle();

    if (!existingSuffix) {
      return candidateCode;
    }
  }

  // All single letter suffixes exhausted, add random suffix
  const random = Math.random().toString(36).substring(2, 5).toUpperCase();
  return baseCode + random;
}