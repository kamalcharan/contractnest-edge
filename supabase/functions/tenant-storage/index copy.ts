// supabase/functions/tenant-storage/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { initializeApp } from "https://www.gstatic.com/firebasejs/9.6.10/firebase-app.js";
import { 
  getStorage, 
  ref, 
  uploadBytes, 
  getDownloadURL, 
  listAll,
  deleteObject
} from "https://www.gstatic.com/firebasejs/9.6.10/firebase-storage.js";

// CORS headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS'
};

// Storage categories configuration
interface StorageCategory {
  id: string;
  name: string;
  path: string;
  allowedTypes: string[];
}

// Define default storage categories
const DEFAULT_STORAGE_CATEGORIES: StorageCategory[] = [
  {
    id: 'contact_photos',
    name: 'Contact Photos',
    path: 'contacts/photos',
    allowedTypes: ['image/jpeg', 'image/png', 'image/gif']
  },
  {
    id: 'contract_media',
    name: 'Contract Media',
    path: 'contracts/media',
    allowedTypes: ['image/jpeg', 'image/png', 'application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document']
  },
  {
    id: 'service_images',
    name: 'Service Images',
    path: 'services/images',
    allowedTypes: ['image/jpeg', 'image/png', 'image/svg+xml']
  },
  {
    id: 'documents',
    name: 'Documents',
    path: 'documents',
    allowedTypes: ['application/pdf', 'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'text/plain']
  }
];

// Initialize Firebase
const initializeFirebase = () => {
  try {
    const firebaseConfig = {
      apiKey: Deno.env.get("FIREBASE_API_KEY"),
      authDomain: Deno.env.get("FIREBASE_AUTH_DOMAIN"),
      projectId: Deno.env.get("FIREBASE_PROJECT_ID"),
      storageBucket: Deno.env.get("FIREBASE_STORAGE_BUCKET"),
      messagingSenderId: Deno.env.get("FIREBASE_MESSAGING_SENDER_ID"),
      appId: Deno.env.get("FIREBASE_APP_ID")
    };

    // Log detailed config (be careful with sensitive info)
    console.log("Firebase config:", {
      hasApiKey: !!firebaseConfig.apiKey,
      authDomain: firebaseConfig.authDomain,
      projectId: firebaseConfig.projectId,
      storageBucket: firebaseConfig.storageBucket,
      hasAppId: !!firebaseConfig.appId
    });

    // Log initialization info (remove in production)
    console.log("Initializing Firebase with bucket:", firebaseConfig.storageBucket);

    const app = initializeApp(firebaseConfig);
    const storage = getStorage(app);
    return { app, storage };
  } catch (error) {
    console.error("Error initializing Firebase:", error);
    throw error;
  }
};

// Create response helper
const createResponse = (data: any, status = 200) => {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
};

// Error response helper
const createErrorResponse = (message: string, status = 400) => {
  return createResponse({ error: message }, status);
};

// Get storage statistics for a tenant
const getStorageStats = async (supabase: any, tenantId: string) => {
  try {
    // Get tenant storage info
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .select('storage_quota, storage_consumed, storage_setup_complete')
      .eq('id', tenantId)
      .single();
    
    if (tenantError || !tenant) {
      throw new Error('Unable to fetch tenant storage information');
    }
    
    // Get file counts by category
    const { data: fileStats, error: fileError } = await supabase
      .from('t_tenant_files')
      .select('file_category, count(*)')
      .eq('tenant_id', tenantId)
      .group('file_category');
    
    if (fileError) {
      throw new Error('Unable to fetch file statistics');
    }
    
    // Format file stats by category
    const fileCategories = DEFAULT_STORAGE_CATEGORIES.map(category => {
      const stats = fileStats?.find(stat => stat.file_category === category.id);
      return {
        id: category.id,
        name: category.name,
        count: stats?.count || 0
      };
    });
    
    // Get total files count
    const { count: totalFiles, error: countError } = await supabase
      .from('t_tenant_files')
      .select('id', { count: 'exact', head: true })
      .eq('tenant_id', tenantId);
    
    if (countError) {
      throw new Error('Unable to count files');
    }
    
    return {
      storageSetupComplete: tenant.storage_setup_complete,
      quota: tenant.storage_quota * 1024 * 1024, // Convert MB to bytes
      used: tenant.storage_consumed,
      available: tenant.storage_quota * 1024 * 1024 - tenant.storage_consumed,
      usagePercentage: Math.round((tenant.storage_consumed / (tenant.storage_quota * 1024 * 1024)) * 100),
      totalFiles: totalFiles || 0,
      categories: fileCategories
    };
  } catch (error) {
    console.error('Error getting storage stats:', error);
    throw error;
  }
};

// Setup storage for a tenant
const setupTenantStorage = async (supabase: any, tenantId: string) => {
  try {
    // 1. Generate storage path using tenant id and timestamp
    const storagePath = `tenant_${tenantId.substring(0, 8)}_${Date.now()}`;
    console.log("Generated storage path:", storagePath);
    
    // 2. Initialize Firebase first to verify connection
    const { storage } = initializeFirebase();
    console.log("Firebase initialized successfully for setup");
    
    // 3. Verify storage by creating a test file or folder
    const testRef = ref(storage, `${storagePath}/.test`);
    await uploadBytes(testRef, new Uint8Array([1,2,3]), { contentType: 'text/plain' });
    console.log("Test file created in Firebase storage");
    
    // 4. Only update the database if Firebase operations succeeded
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
    
    if (error || !data) {
      throw new Error(`Failed to setup tenant storage: ${error?.message}`);
    }
    
    return {
      storageSetupComplete: true,
      quota: 40 * 1024 * 1024,
      used: 0,
      available: 40 * 1024 * 1024,
      usagePercentage: 0,
      path: storagePath
    };
  } catch (error) {
    console.error('Error setting up tenant storage:', error);
    throw error;
  }
};

// List files in a category
const listFiles = async (supabase: any, tenantId: string, category: string | null) => {
  try {
    // Build query
    let query = supabase
      .from('t_tenant_files')
      .select('*')
      .eq('tenant_id', tenantId);
    
    // Add category filter if provided
    if (category) {
      query = query.eq('file_category', category);
    }
    
    // Execute query
    const { data, error } = await query.order('created_at', { ascending: false });
    
    if (error) {
      throw new Error(`Failed to list files: ${error.message}`);
    }
    
    return data || [];
  } catch (error) {
    console.error('Error listing files:', error);
    throw error;
  }
};

// Upload file
const uploadFile = async (
  supabase: any, 
  tenant: any, 
  file: Uint8Array, 
  fileName: string, 
  fileSize: number, 
  fileType: string,
  category: string
) => {
  try {
    // Validate file size (5MB limit)
    const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB in bytes
    if (fileSize > MAX_FILE_SIZE) {
      throw new Error('File size exceeds the 5MB limit');
    }
    
    // Validate file type
    const categoryConfig = DEFAULT_STORAGE_CATEGORIES.find(c => c.id === category);
    if (!categoryConfig) {
      throw new Error(`Invalid category: ${category}`);
    }
    
    if (!categoryConfig.allowedTypes.includes(fileType)) {
      throw new Error(`File type ${fileType} is not allowed for this category`);
    }
    
    // Check if tenant has enough storage
    const availableStorage = tenant.storage_quota * 1024 * 1024 - tenant.storage_consumed;
    if (fileSize > availableStorage) {
      throw new Error('Not enough storage space available');
    }
    
    // Initialize Firebase
    const { storage } = initializeFirebase();
    
    // Create a reference to the file in Firebase Storage
    const storagePath = tenant.storage_path;
    const filePath = `${storagePath}/${category}/${fileName}`;
    const storageRef = ref(storage, filePath);
    
    // Upload file
    await uploadBytes(storageRef, file, { contentType: fileType });
    
    // Get download URL
    const downloadURL = await getDownloadURL(storageRef);
    
    // Save file record in database
    const { data, error } = await supabase
      .from('t_tenant_files')
      .insert([
        {
          tenant_id: tenant.id,
          file_name: fileName,
          file_path: filePath,
          file_size: fileSize,
          file_type: fileType.split('/')[1], // e.g., 'jpeg' from 'image/jpeg'
          file_category: category,
          mime_type: fileType,
          download_url: downloadURL
        }
      ])
      .select()
      .single();
    
    if (error) {
      // If database insert fails, try to delete the uploaded file
      try {
        const deleteRef = ref(storage, filePath);
        await deleteObject(deleteRef);
      } catch (deleteError) {
        console.error('Failed to delete file after database error:', deleteError);
      }
      
      throw new Error(`Failed to save file record: ${error.message}`);
    }
    
    // Update tenant's consumed storage
    const { error: updateError } = await supabase
      .from('t_tenants')
      .update({
        storage_consumed: tenant.storage_consumed + fileSize
      })
      .eq('id', tenant.id);
    
    if (updateError) {
      console.error('Failed to update tenant storage consumed:', updateError);
    }
    
    return data;
  } catch (error) {
    console.error('Error uploading file:', error);
    throw error;
  }
};

// Delete file
const deleteFile = async (supabase: any, tenantId: string, fileId: string) => {
  try {
    // Get file details
    const { data: file, error: fileError } = await supabase
      .from('t_tenant_files')
      .select('*')
      .eq('id', fileId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (fileError || !file) {
      throw new Error('File not found or you do not have permission to delete it');
    }
    
    // Initialize Firebase
    const { storage } = initializeFirebase();
    
    // Delete from Firebase
    const storageRef = ref(storage, file.file_path);
    await deleteObject(storageRef);
    
    // Delete record from database
    const { error: deleteError } = await supabase
      .from('t_tenant_files')
      .delete()
      .eq('id', fileId)
      .eq('tenant_id', tenantId);
    
    if (deleteError) {
      throw new Error(`Failed to delete file record: ${deleteError.message}`);
    }
    
    // Update tenant's consumed storage
    const { error: updateError } = await supabase
      .from('t_tenants')
      .update({
        storage_consumed: supabase.raw(`storage_consumed - ${file.file_size}`)
      })
      .eq('id', tenantId);
    
    if (updateError) {
      console.error('Failed to update tenant storage consumed:', updateError);
    }
    
    return { success: true, message: 'File deleted successfully' };
  } catch (error) {
    console.error('Error deleting file:', error);
    throw error;
  }
};

// Main request handler
serve(async (req) => {
  // Handle CORS preflight request
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: corsHeaders
    });
  }
  
  try {
    // Get Supabase credentials from environment
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    
    if (!supabaseUrl || !supabaseKey) {
      console.error('Missing Supabase configuration');
      return createErrorResponse('Missing Supabase configuration', 500);
    }
    
    // Get auth header
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      console.error('Missing Authorization header');
      return createErrorResponse('Authorization header is required', 401);
    }

    // Get tenant ID header - CRITICAL FIX
    const tenantHeader = req.headers.get('x-tenant-id');
    if (!tenantHeader) {
      console.error('Missing x-tenant-id header');
      return createErrorResponse('x-tenant-id header is required', 400);
    }

    console.log('Request with tenant ID:', tenantHeader);
    
    // Initialize Supabase client
    const supabase = createClient(supabaseUrl, supabaseKey, {
      auth: {
        persistSession: false,
        autoRefreshToken: false
      }
    });

    // Verify the tenant exists
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .select('id, storage_path, storage_quota, storage_consumed, storage_setup_complete')
      .eq('id', tenantHeader)
      .single();
    
    if (tenantError) {
      console.error('Error fetching tenant:', tenantError);
      if (tenantError.code === 'PGRST116') {
        return createErrorResponse('Tenant not found', 404);
      }
      return createErrorResponse('Error fetching tenant', 500);
    }
    
    console.log('Tenant found:', tenant.id, 'Storage setup:', tenant.storage_setup_complete);
    
    // Parse URL to get the path and query parameters
    const url = new URL(req.url);
    const path = url.pathname.split('/').filter(Boolean);
    
    // Handle base endpoint
    if (path.length === 1 && path[0] === 'tenant-storage') {
      // GET: Get storage statistics
      if (req.method === 'GET') {
        if (!tenant.storage_setup_complete) {
          console.log('Storage not set up for tenant:', tenant.id);
          return createErrorResponse('Storage not set up for this tenant', 404);
        }
        
        try {
          const stats = await getStorageStats(supabase, tenantHeader);
          return createResponse(stats);
        } catch (error) {
          console.error('Error getting storage stats:', error);
          return createErrorResponse(`Failed to get storage stats: ${error.message}`, 500);
        }
      }
      
      // POST: Setup storage for tenant
      if (req.method === 'POST') {
        if (tenant.storage_setup_complete) {
          return createErrorResponse('Storage already set up for this tenant', 400);
        }
        
        try {
          const setupResult = await setupTenantStorage(supabase, tenantHeader);
          return createResponse(setupResult);
        } catch (error) {
          console.error('Error setting up storage:', error);
          return createErrorResponse(`Failed to set up storage: ${error.message}`, 500);
        }
      }
    }
    
    // Handle files endpoint
    if (path.length === 2 && path[0] === 'tenant-storage' && path[1] === 'files') {
      // Check if storage is set up
      if (!tenant.storage_setup_complete) {
        return createErrorResponse('Storage not set up for this tenant. Please set up storage first.', 400);
      }
      
      // GET: List files
      if (req.method === 'GET') {
        const category = url.searchParams.get('category');
        
        try {
          const files = await listFiles(supabase, tenantHeader, category);
          return createResponse(files);
        } catch (error) {
          console.error('Error listing files:', error);
          return createErrorResponse(`Failed to list files: ${error.message}`, 500);
        }
      }
      
      // POST: Upload file
      if (req.method === 'POST') {
        try {
          const formData = await req.formData();
          const file = formData.get('file') as File;
          const category = formData.get('category') as string;
          
          if (!file) {
            return createErrorResponse('No file provided', 400);
          }
          
          if (!category) {
            return createErrorResponse('No category specified', 400);
          }
          
          const fileBytes = new Uint8Array(await file.arrayBuffer());
          
          try {
            const result = await uploadFile(
              supabase,
              tenant,
              fileBytes,
              file.name,
              file.size,
              file.type,
              category
            );
            
            return createResponse(result, 201);
          } catch (uploadError) {
            console.error('Error uploading file:', uploadError);
            return createErrorResponse(`Failed to upload file: ${uploadError.message}`, 400);
          }
        } catch (formError) {
          console.error('Error processing form data:', formError);
          return createErrorResponse(`Error processing form data: ${formError.message}`, 400);
        }
      }
    }
    
    // Handle specific file operations
    if (path.length === 3 && path[0] === 'tenant-storage' && path[1] === 'files') {
      const fileId = path[2];
      
      // Check if storage is set up
      if (!tenant.storage_setup_complete) {
        return createErrorResponse('Storage not set up for this tenant', 400);
      }
      
      // DELETE: Delete file
      if (req.method === 'DELETE') {
        try {
          const result = await deleteFile(supabase, tenantHeader, fileId);
          return createResponse(result);
        } catch (error) {
          console.error('Error deleting file:', error);
          return createErrorResponse(`Failed to delete file: ${error.message}`, 500);
        }
      }
    }
    
    // If no handler matched
    return createErrorResponse('Invalid endpoint or method', 404);
  } catch (error) {
    console.error('Unhandled error in request processing:', error);
    return createErrorResponse(`Internal server error: ${error.message}`, 500);
  }
});