
// /supabase/functions/plans/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { 
  validatePlanData, 
  validateVersionData,
  transformPlanForEdit, 
  createVersionFromEdit,
  checkVersionExists,
  getNextVersionNumber,
  checkPlanHasActiveTenants
} from "../utils/business-model.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-user-id, x-product',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS'
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    if (!supabaseUrl || !supabaseKey) {
      return new Response(
        JSON.stringify({ error: 'Server configuration error' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    const userId = req.headers.get('x-user-id') || 'system';
    const productCode = req.headers.get('x-product') || 'contractnest'; // Default to contractnest for backward compatibility

    console.log('Product context:', productCode);

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
    
    const supabase = createClient(supabaseUrl, supabaseKey, {
      global: { 
        headers: { 
          Authorization: authHeader,
          'x-tenant-id': tenantHeader
        } 
      },
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(segment => segment);
    
    console.log('Processing request:', req.method, url.pathname);
    
    // GET - Fetch plans
    if (req.method === 'GET') {
      // Get specific plan
      if (pathSegments.length > 1 && pathSegments[1]) {
        const planId = pathSegments[1];
        const isEdit = pathSegments.length > 2 && pathSegments[2] === 'edit';
        
        console.log(`Fetching plan ${planId}${isEdit ? ' for edit' : ''}`);
        
        const { data: plan, error: planError } = await supabase
          .from('t_bm_pricing_plan')
          .select('*')
          .eq('plan_id', planId)
          .single();
          
        if (planError) {
          if (planError.code === 'PGRST116') {
            return new Response(
              JSON.stringify({ error: 'Plan not found' }),
              { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          throw planError;
        }
        
        if (plan.is_archived) {
          return new Response(
            JSON.stringify({ error: 'Cannot access archived plan' }),
            { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        const { data: activeVersion, error: versionError } = await supabase
          .from('t_bm_plan_version')
          .select('*')
          .eq('plan_id', planId)
          .eq('is_active', true)
          .single();
          
        if (versionError && versionError.code !== 'PGRST116') {
          throw versionError;
        }
        
        if (!activeVersion) {
          return new Response(
            JSON.stringify({ error: 'Plan has no active version' }),
            { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Get product name
        let productName = null;
        if (plan.product_code) {
          const { data: product } = await supabase
            .from('m_products')
            .select('name')
            .eq('code', plan.product_code)
            .single();
          if (product) {
            productName = product.name;
          }
        }

        if (isEdit) {
          const editData = transformPlanForEdit(plan, activeVersion);
          const suggestedVersion = await getNextVersionNumber(supabase, planId);
          editData.next_version_number = suggestedVersion;
          editData.product_name = productName;

          return new Response(
            JSON.stringify(editData),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response(
          JSON.stringify({ ...plan, activeVersion, product_name: productName }),
          { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      } 
      
      // List plans
      const showArchived = url.searchParams.get('showArchived') === 'true';
      const planType = url.searchParams.get('planType');
      const filterProduct = url.searchParams.get('product_code') || productCode; // Use header or query param

      let query = supabase
        .from('t_bm_pricing_plan')
        .select('*')
        .eq('product_code', filterProduct); // Filter by product

      if (!showArchived) {
        query = query.eq('is_archived', false);
      }

      if (planType) {
        query = query.eq('plan_type', planType);
      }

      console.log(`Listing plans for product: ${filterProduct}`);

      const { data: plans, error } = await query.order('created_at', { ascending: false });
      
      if (error) throw error;
      
      // Enrich with version info and product names
      if (plans.length > 0) {
        const planIds = plans.map(p => p.plan_id);
        const { data: versions } = await supabase
          .from('t_bm_plan_version')
          .select('plan_id, version_id, version_number, is_active')
          .in('plan_id', planIds);

        // Get unique product codes and fetch product names
        const uniqueProductCodes = [...new Set(plans.map(p => p.product_code).filter(Boolean))];
        let productNameMap: Record<string, string> = {};

        if (uniqueProductCodes.length > 0) {
          const { data: products } = await supabase
            .from('m_products')
            .select('code, name')
            .in('code', uniqueProductCodes);

          if (products) {
            products.forEach(p => {
              productNameMap[p.code] = p.name;
            });
          }
        }

        if (versions) {
          const versionCountMap: Record<string, number> = {};
          const activeVersionMap: Record<string, any> = {};

          versions.forEach(v => {
            versionCountMap[v.plan_id] = (versionCountMap[v.plan_id] || 0) + 1;
            if (v.is_active) {
              activeVersionMap[v.plan_id] = {
                version_id: v.version_id,
                version_number: v.version_number
              };
            }
          });

          const enrichedPlans = plans.map(plan => ({
            ...plan,
            version_count: versionCountMap[plan.plan_id] || 0,
            active_version: activeVersionMap[plan.plan_id] || null,
            subscriber_count: 0,
            product_name: productNameMap[plan.product_code] || null
          }));

          return new Response(
            JSON.stringify(enrichedPlans),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      
      return new Response(
        JSON.stringify(plans),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // POST - Create plan or edit (create version)
    if (req.method === 'POST') {
      const requestData = await req.json();
      
      // Edit operation (has plan_id)
      if (requestData.plan_id) {
        console.log('Creating new version from edit');
        
        // FIX: Handle the updatedBy/updated_by field properly
        const createdBy = requestData.updatedBy || requestData.updated_by || userId;
        
        // Validate version data
        const versionData = {
          plan_id: requestData.plan_id,
          version_number: requestData.next_version_number,
          created_by: createdBy, // Use the updatedBy as created_by
          changelog: requestData.changelog,
          tiers: requestData.tiers,
          features: requestData.features,
          notifications: requestData.notifications
        };
        
        const validation = validateVersionData(versionData);
        if (!validation.valid) {
          console.error('Validation errors:', validation.errors);
          return new Response(
            JSON.stringify({ error: 'Validation failed', details: validation.errors }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Check version doesn't exist
        const versionExists = await checkVersionExists(
          supabase, 
          requestData.plan_id, 
          requestData.next_version_number
        );
        
        if (versionExists) {
          return new Response(
            JSON.stringify({ error: `Version ${requestData.next_version_number} already exists` }),
            { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Create new version with proper created_by
        const newVersionData = {
          plan_id: requestData.plan_id,
          version_number: requestData.next_version_number,
          is_active: false, // New versions start as inactive
          effective_date: requestData.effective_date || new Date().toISOString(),
          changelog: requestData.changelog,
          created_by: createdBy, // Use the correct created_by
          tiers: requestData.tiers,
          features: requestData.features,
          notifications: requestData.notifications
        };
        
        const { data: newVersion, error: versionError } = await supabase
          .from('t_bm_plan_version')
          .insert(newVersionData)
          .select()
          .single();
          
        if (versionError) {
          console.error('Database error creating version:', versionError);
          throw versionError;
        }
        
        // Update plan metadata if provided
        if (requestData.name || requestData.description || requestData.trial_duration !== undefined || requestData.is_visible !== undefined) {
          const updateData: any = {};
          if (requestData.name) updateData.name = requestData.name;
          if (requestData.description !== undefined) updateData.description = requestData.description;
          if (requestData.trial_duration !== undefined) updateData.trial_duration = requestData.trial_duration;
          if (requestData.is_visible !== undefined) updateData.is_visible = requestData.is_visible;
          
          updateData.updated_at = new Date().toISOString();
          
          await supabase
            .from('t_bm_pricing_plan')
            .update(updateData)
            .eq('plan_id', requestData.plan_id);
        }
        
        const { data: updatedPlan } = await supabase
          .from('t_bm_pricing_plan')
          .select()
          .eq('plan_id', requestData.plan_id)
          .single();
          
        return new Response(
          JSON.stringify({ ...updatedPlan, newVersion }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      // Create new plan
      console.log('Creating new plan');
      
      const validation = validatePlanData(requestData);
      if (!validation.valid) {
        return new Response(
          JSON.stringify({ error: 'Validation failed', details: validation.errors }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      // Use product_code from request body, or fall back to header
      const planProductCode = requestData.product_code || productCode;
      console.log(`Creating plan for product: ${planProductCode}`);

      const { data: plan, error: planError } = await supabase
        .from('t_bm_pricing_plan')
        .insert({
          name: requestData.name,
          description: requestData.description,
          plan_type: requestData.plan_type,
          trial_duration: requestData.trial_duration || 0,
          is_visible: requestData.is_visible || false,
          is_archived: false,
          default_currency_code: requestData.default_currency_code,
          supported_currencies: requestData.supported_currencies,
          product_code: planProductCode // Associate plan with product
        })
        .select()
        .single();
        
      if (planError) throw planError;
      
      // Create initial version if provided
      if (requestData.initial_version) {
        const versionData = {
          plan_id: plan.plan_id,
          version_number: requestData.initial_version.version_number || '1.0',
          is_active: true,
          effective_date: requestData.initial_version.effective_date || new Date().toISOString(),
          changelog: requestData.initial_version.changelog || 'Initial version',
          created_by: requestData.created_by || requestData.createdBy || userId,
          tiers: requestData.initial_version.tiers || [],
          features: requestData.initial_version.features || [],
          notifications: requestData.initial_version.notifications || []
        };
        
        const { data: version, error: versionError } = await supabase
          .from('t_bm_plan_version')
          .insert(versionData)
          .select()
          .single();
          
        if (versionError) {
          await supabase.from('t_bm_pricing_plan').delete().eq('plan_id', plan.plan_id);
          throw versionError;
        }
        
        return new Response(
          JSON.stringify({ ...plan, activeVersion: version }),
          { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      return new Response(
        JSON.stringify(plan),
        { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    // PUT - Update operations
    if (req.method === 'PUT') {
      if (pathSegments.length < 2) {
        return new Response(
          JSON.stringify({ error: 'Plan ID is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      const planId = pathSegments[1];
      
      if (pathSegments.length > 2) {
        const operation = pathSegments[2];
        
        // Toggle visibility
        if (operation === 'visibility') {
          const { is_visible } = await req.json();
          
          const { data, error } = await supabase
            .from('t_bm_pricing_plan')
            .update({ is_visible, updated_at: new Date().toISOString() })
            .eq('plan_id', planId)
            .select()
            .single();
            
          if (error) throw error;
          
          return new Response(
            JSON.stringify(data),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        
        // Archive plan
        if (operation === 'archive') {
          const hasActiveTenants = await checkPlanHasActiveTenants(supabase, planId);
          
          if (hasActiveTenants) {
            return new Response(
              JSON.stringify({ error: 'Cannot archive plan with active tenants' }),
              { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }
          
          const { data, error } = await supabase
            .from('t_bm_pricing_plan')
            .update({ 
              is_archived: true,
              is_visible: false,
              updated_at: new Date().toISOString() 
            })
            .eq('plan_id', planId)
            .select()
            .single();
            
          if (error) throw error;
          
          return new Response(
            JSON.stringify(data),
            { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
      }
      
      // Basic metadata update
      const updateData = await req.json();
      const allowedFields = ['name', 'description', 'trial_duration'];
      const updates: any = {};
      
      for (const field of allowedFields) {
        if (updateData[field] !== undefined) {
          updates[field] = updateData[field];
        }
      }
      
      if (Object.keys(updates).length === 0) {
        return new Response(
          JSON.stringify({ error: 'No valid fields to update' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      updates.updated_at = new Date().toISOString();
      
      const { data, error } = await supabase
        .from('t_bm_pricing_plan')
        .update(updates)
        .eq('plan_id', planId)
        .select()
        .single();
        
      if (error) throw error;
      
      return new Response(
        JSON.stringify(data),
        { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }
    
    return new Response(
      JSON.stringify({ error: 'Method not supported' }),
      { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
    
  } catch (error) {
    console.error('Error:', error);
    return new Response(
      JSON.stringify({ error: 'Internal server error', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
