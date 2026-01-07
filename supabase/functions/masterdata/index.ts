// supabase/functions/masterdata/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

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
    const tenantHeader = req.headers.get('x-tenant-id');
    
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
    
    const user = userData.user;
    
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
      
      // Get all categories for tenant
      return await getCategories(supabase, tenantId);
    } 
    else if (resourceType === 'category-details') {
      const tenantId = url.searchParams.get('tenantId');
      const categoryId = url.searchParams.get('categoryId');
      const detailId = url.searchParams.get('id');
      
      if (!tenantId) {
        return new Response(
          JSON.stringify({ error: 'tenantId is required' }),
          { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      if (req.method === 'GET') {
        if (url.searchParams.get('nextSequence') === 'true' && categoryId) {
          // Get next sequence number
          return await getNextSequenceNumber(supabase, categoryId, tenantId);
        } else if (categoryId) {
          // Get category details
          return await getCategoryDetails(supabase, categoryId, tenantId);
        }
      }
      else if (req.method === 'POST') {
        // Add new category detail
        const data = await req.json();
        return await addCategoryDetail(supabase, data);
      }
      else if (req.method === 'PATCH' && detailId) {
        // Update category detail
        const data = await req.json();
        return await updateCategoryDetail(supabase, detailId, data);
      }
      else if (req.method === 'DELETE' && detailId) {
        // Delete category detail
        return await softDeleteCategoryDetail(supabase, detailId, tenantId);
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

// Get all categories for a tenant
async function getCategories(supabase, tenantId) {
  try {
    const { data, error } = await supabase
      .from('t_category_master')
      .select('*')
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .eq('is_live', true)
      .order('order_sequence', { ascending: true, nullsLast: true });
    
    if (error) throw error;
    
    // Transform column names to match frontend expectations
    const transformedData = data.map(item => ({
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

// Get category details
async function getCategoryDetails(supabase, categoryId, tenantId) {
  try {
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
    const transformedData = data.map(item => ({
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

// Get next sequence number
async function getNextSequenceNumber(supabase, categoryId, tenantId) {
  try {
    const { data, error } = await supabase
      .from('t_category_details')
      .select('sequence_no')
      .eq('category_id', categoryId)
      .eq('tenant_id', tenantId)
      .eq('is_active', true)
      .eq('is_live', true);
    
    if (error) throw error;
    
    const maxSequence = data.length > 0 
      ? Math.max(...data.map(d => d.sequence_no || 0), 0)
      : 0;
    
    return new Response(
      JSON.stringify({ nextSequence: maxSequence + 1 }),
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

// Add new category detail
async function addCategoryDetail(supabase, detail) {
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

// Update category detail
async function updateCategoryDetail(supabase, detailId, updates) {
  try {
    // Transform the updates to match database column names
    const dbUpdates = {};
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

// Soft delete category detail
async function softDeleteCategoryDetail(supabase, detailId, tenantId) {
  try {
    const { error } = await supabase
      .from('t_category_details')
      .update({ is_active: false })
      .eq('id', detailId)
      .eq('tenant_id', tenantId);
    
    if (error) throw error;
    
    return new Response(
      JSON.stringify({ success: true }),
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
