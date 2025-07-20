// supabase/functions/tenant-storage/index.ts
// Simplified Edge Function - Database operations only, NO Firebase imports

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

// CORS headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-request-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS'
};

// Storage categories configuration
const DEFAULT_STORAGE_CATEGORIES = [
  {
    id: 'contact_photos',
    name: 'Contact Photos',
    count: 0
  },
  {
    id: 'contract_media',
    name: 'Contract Media',
    count: 0
  },
  {
    id: 'service_images',
    name: 'Service Images',
    count: 0
  },
  {
    id: 'documents',
    name: 'Documents',
    count: 0
  }
];

// Helper functions
function createErrorResponse(message: string, status: number, code?: string) {
  return new Response(
    JSON.stringify({
      error: {
        message: message,
        code: code || 'STORAGE_ERROR',
        timestamp: new Date().toISOString()
      }
    }),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

function createResponse(data: any, status: number = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// Main handler - NO Firebase code at all
serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: corsHeaders
    });
  }

  try {
    console.log('=== Incoming Request ===');
    console.log('Method:', req.method);
    console.log('URL:', req.url);
    
    const authHeader = req.headers.get('Authorization');
    const tenantId = req.headers.get('x-tenant-id');
    
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 401, 'AUTH_REQUIRED');
    }
    
    if (!tenantId) {
      return createErrorResponse('x-tenant-id header is required', 400, 'TENANT_REQUIRED');
    }
    
    // Initialize Supabase client
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    if (!supabaseUrl || !supabaseKey) {
      return createErrorResponse('Service configuration error', 500, 'CONFIG_ERROR');
    }
    
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });
    
    const url = new URL(req.url);
    const path = url.pathname.replace('/tenant-storage', '').replace(/^\//, '');
    
    console.log('Processed path:', path);
    
    // Route: GET /tenant-storage/stats
    if (req.method === 'GET' && path === 'stats') {
      const { data: tenant, error } = await supabase
        .from('t_tenants')
        .select('storage_path, storage_quota, storage_consumed, storage_setup_complete')
        .eq('id', tenantId)
        .single();
      
      if (error) {
        console.error('Database error:', error);
        return createErrorResponse('Failed to fetch tenant data', 500);
      }
      
      if (!tenant) {
        return createErrorResponse('Tenant not found', 404);
      }
      
      if (!tenant.storage_setup_complete) {
        return createResponse({
          storageSetupComplete: false,
          quota: 0,
          used: 0,
          available: 0,
          usagePercentage: 0,
          totalFiles: 0,
          categories: []
        });
      }
      
      // Get file counts by category
      const { data: files, error: filesError } = await supabase
        .from('t_tenant_files')
        .select('file_category')
        .eq('tenant_id', tenantId);
      
      const categoryCount = (files || []).reduce((acc: any, file: any) => {
        acc[file.file_category] = (acc[file.file_category] || 0) + 1;
        return acc;
      }, {});
      
      const categories = DEFAULT_STORAGE_CATEGORIES.map(cat => ({
        ...cat,
        count: categoryCount[cat.id] || 0
      }));
      
      return createResponse({
        storageSetupComplete: true,
        quota: tenant.storage_quota * 1024 * 1024,
        used: tenant.storage_consumed,
        available: (tenant.storage_quota * 1024 * 1024) - tenant.storage_consumed,
        usagePercentage: Math.round((tenant.storage_consumed / (tenant.storage_quota * 1024 * 1024)) * 100),
        totalFiles: files?.length || 0,
        categories
      });
    }
    
    // Route: POST /tenant-storage/setup-complete
    if (req.method === 'POST' && path === 'setup-complete') {
      const body = await req.json();
      const { storagePath } = body;
      
      if (!storagePath) {
        return createErrorResponse('Storage path is required', 400);
      }
      
      // Check if already setup
      const { data: existing } = await supabase
        .from('t_tenants')
        .select('storage_setup_complete')
        .eq('id', tenantId)
        .single();
      
      if (existing?.storage_setup_complete) {
        return createResponse({
          success: false,
          message: 'Storage already set up'
        });
      }
      
      const { data, error } = await supabase
        .from('t_tenants')
        .update({
          storage_path: storagePath,
          storage_quota: 40,
          storage_consumed: 0,
          storage_provider: 'firebase',
          storage_setup_complete: true
        })
        .eq('id', tenantId)
        .select();
      
      if (error) {
        console.error('Database update error:', error);
        return createErrorResponse('Failed to update tenant', 500);
      }
      
      return createResponse({
        success: true,
        message: 'Storage setup completed'
      });
    }
    
    // Route: GET /tenant-storage/files
    if (req.method === 'GET' && path === 'files') {
      const category = url.searchParams.get('category');
      const page = parseInt(url.searchParams.get('page') || '1');
      const pageSize = parseInt(url.searchParams.get('pageSize') || '50');
      const offset = (page - 1) * pageSize;
      
      let query = supabase
        .from('t_tenant_files')
        .select('*', { count: 'exact' })
        .eq('tenant_id', tenantId);
      
      if (category) {
        query = query.eq('file_category', category);
      }
      
      const { data, error, count } = await query
        .order('created_at', { ascending: false })
        .range(offset, offset + pageSize - 1);
      
      if (error) {
        console.error('Database error:', error);
        return createErrorResponse('Failed to fetch files', 500);
      }
      
      return createResponse(data || []);
    }
    
    // Route: POST /tenant-storage/files
    if (req.method === 'POST' && path === 'files') {
      const body = await req.json();
      const { file_name, file_path, file_size, file_type, file_category, mime_type, download_url, metadata } = body;
      
      // Validate required fields
      if (!file_name || !file_path || !file_size || !file_type || !file_category || !mime_type || !download_url) {
        return createErrorResponse('Missing required fields', 400);
      }
      
      // Create file record
      const { data, error } = await supabase
        .from('t_tenant_files')
        .insert([{
          tenant_id: tenantId,
          file_name,
          file_path,
          file_size,
          file_type,
          file_category,
          mime_type,
          download_url,
          metadata: metadata || {}
        }])
        .select()
        .single();
      
      if (error) {
        console.error('Database error:', error);
        return createErrorResponse('Failed to create file record', 500);
      }
      
      // Update storage consumed
      const { error: updateError } = await supabase
        .from('t_tenants')
        .update({
          storage_consumed: supabase.raw(`storage_consumed + ${file_size}`)
        })
        .eq('id', tenantId);
      
      if (updateError) {
        console.error('Failed to update storage consumed:', updateError);
      }
      
      return createResponse(data, 201);
    }
    
    // Route: DELETE /tenant-storage/files/:id
    if (req.method === 'DELETE' && path.startsWith('files/')) {
      const fileId = path.replace('files/', '');
      
      // Get file info first
      const { data: file, error: fetchError } = await supabase
        .from('t_tenant_files')
        .select('file_size')
        .eq('id', fileId)
        .eq('tenant_id', tenantId)
        .single();
      
      if (fetchError || !file) {
        return createErrorResponse('File not found', 404);
      }
      
      // Delete file record
      const { error } = await supabase
        .from('t_tenant_files')
        .delete()
        .eq('id', fileId)
        .eq('tenant_id', tenantId);
      
      if (error) {
        console.error('Database error:', error);
        return createErrorResponse('Failed to delete file', 500);
      }
      
      // Update storage consumed
      const { error: updateError } = await supabase
        .from('t_tenants')
        .update({
          storage_consumed: supabase.raw(`GREATEST(0, storage_consumed - ${file.file_size})`)
        })
        .eq('id', tenantId);
      
      if (updateError) {
        console.error('Failed to update storage consumed:', updateError);
      }
      
      return createResponse({
        success: true,
        message: 'File deleted successfully'
      });
    }
    
    return createErrorResponse('Not found', 404);
  } catch (error) {
    console.error('Unhandled error:', error);
    return createErrorResponse('Internal server error', 500);
  }
});