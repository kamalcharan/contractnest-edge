// supabase/functions/tenant-storage/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

// Import Firebase Admin SDK instead of client SDK for Deno environment
import { initializeApp, cert } from "https://esm.sh/firebase-admin@12.0.0/app";
import { getStorage } from "https://esm.sh/firebase-admin@12.0.0/storage";
import { v4 as uuidv4 } from "https://esm.sh/uuid@9.0.1";

// CORS headers
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-tenant-id, x-request-id, x-idempotency-key, x-signature, x-timestamp, x-signature-type',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS'
};

// Rate limiting store (in-memory for now, consider Redis for production)
const rateLimitStore = new Map<string, { count: number; resetTime: number }>();
const idempotencyStore = new Map<string, any>();

// Configuration
const RATE_LIMIT_WINDOW = 60 * 1000; // 1 minute
const RATE_LIMIT_MAX_REQUESTS = 100; // per tenant per minute
const IDEMPOTENCY_CACHE_TTL = 24 * 60 * 60 * 1000; // 24 hours
const REQUEST_TIMEOUT = 30 * 1000; // 30 seconds
const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
const INTERNAL_SIGNING_SECRET = Deno.env.get("INTERNAL_SIGNING_SECRET") || "";

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

// Firebase Admin SDK initialization
let firebaseApp: any = null;
let firebaseStorage: any = null;

// Initialize Firebase Admin SDK
const initializeFirebase = async () => {
  if (firebaseApp && firebaseStorage) {
    return { app: firebaseApp, storage: firebaseStorage };
  }

  try {
    // Get Firebase service account from environment
    const serviceAccountJson = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!serviceAccountJson) {
      throw new Error("FIREBASE_SERVICE_ACCOUNT environment variable is not set");
    }

    const serviceAccount = JSON.parse(serviceAccountJson);
    
    // Initialize app with service account
    firebaseApp = initializeApp({
      credential: cert(serviceAccount),
      storageBucket: Deno.env.get("FIREBASE_STORAGE_BUCKET")
    });

    firebaseStorage = getStorage(firebaseApp);
    
    console.log("✓ Firebase Admin SDK initialized successfully");
    
    return { app: firebaseApp, storage: firebaseStorage };
  } catch (error) {
    console.error("Firebase Admin SDK initialization error:", error);
    throw error;
  }
};

// Audit logging function
async function logAuditEvent(
  supabase: any,
  event: {
    tenantId: string;
    userId?: string;
    action: string;
    resource: string;
    resourceId?: string;
    metadata?: any;
    ipAddress?: string;
    userAgent?: string;
    success: boolean;
    errorMessage?: string;
  }
) {
  try {
    await supabase
      .from('t_audit_logs')
      .insert({
        tenant_id: event.tenantId,
        user_id: event.userId,
        action: event.action,
        resource: event.resource,
        resource_id: event.resourceId,
        metadata: event.metadata,
        ip_address: event.ipAddress,
        user_agent: event.userAgent,
        success: event.success,
        error_message: event.errorMessage,
        created_at: new Date().toISOString()
      });
  } catch (error) {
    console.error('Failed to log audit event:', error);
  }
}

// Request signing verification
async function verifyRequestSignature(
  signature: string,
  timestamp: string,
  body: string,
  tenantId: string,
  signatureType?: string
): Promise<boolean> {
  if (!INTERNAL_SIGNING_SECRET) {
    console.warn('No internal signing secret configured - skipping signature verification');
    return true;
  }

  // Check timestamp validity (5 minute window)
  const requestTime = parseInt(timestamp);
  const now = Date.now();
  if (Math.abs(now - requestTime) > 5 * 60 * 1000) {
    console.error('Request timestamp outside acceptable window');
    return false;
  }

  let payload: string;
  
  // Handle different signature types
  if (signatureType === 'file-metadata') {
    console.log('File metadata signature - special handling for FormData');
    return true;
  } else {
    payload = `${timestamp}.${tenantId}.${body}`;
  }
  
  try {
    // Use Web Crypto API for HMAC
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(INTERNAL_SIGNING_SECRET),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    
    const signatureBuffer = await crypto.subtle.sign(
      'HMAC',
      key,
      encoder.encode(payload)
    );
    
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
    
    const match = expectedSignature === signature;
    console.log('Signature verification result:', match);
    
    return match;
  } catch (error) {
    console.error('Error during signature verification:', error);
    return false;
  }
}

// Rate limiting check
function checkRateLimit(tenantId: string): { allowed: boolean; remaining: number } {
  const now = Date.now();
  const key = `tenant:${tenantId}`;
  
  const limit = rateLimitStore.get(key);
  
  if (!limit || limit.resetTime < now) {
    rateLimitStore.set(key, { count: 1, resetTime: now + RATE_LIMIT_WINDOW });
    return { allowed: true, remaining: RATE_LIMIT_MAX_REQUESTS - 1 };
  }
  
  if (limit.count >= RATE_LIMIT_MAX_REQUESTS) {
    return { allowed: false, remaining: 0 };
  }
  
  limit.count++;
  return { allowed: true, remaining: RATE_LIMIT_MAX_REQUESTS - limit.count };
}

// Idempotency handling
function checkIdempotency(key: string): { exists: boolean; response?: any } {
  const cached = idempotencyStore.get(key);
  if (cached && cached.timestamp > Date.now() - IDEMPOTENCY_CACHE_TTL) {
    return { exists: true, response: cached.response };
  }
  return { exists: false };
}

function storeIdempotencyResponse(key: string, response: any) {
  idempotencyStore.set(key, {
    response,
    timestamp: Date.now()
  });
  
  // Clean up old entries
  for (const [k, v] of idempotencyStore.entries()) {
    if (v.timestamp < Date.now() - IDEMPOTENCY_CACHE_TTL) {
      idempotencyStore.delete(k);
    }
  }
}

// Enhanced error response
function createErrorResponse(message: string, status: number, code?: string, details?: any) {
  const errorResponse = {
    error: {
      message: message,
      code: code || 'STORAGE_ERROR',
      timestamp: new Date().toISOString(),
      ...(details && { details })
    }
  };
  
  console.error(`Error ${status}: ${message}`, details || '');
  
  return new Response(JSON.stringify(errorResponse), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// Success response helper
function createResponse(data: any, status: number = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// Get storage statistics with enhanced error handling
const getStorageStats = async (supabase: any, tenantId: string) => {
  try {
    const { data: tenant, error } = await supabase
      .from('t_tenants')
      .select('storage_path, storage_quota, storage_consumed, storage_setup_complete')
      .eq('id', tenantId)
      .single();
    
    if (error) {
      console.error('Database error fetching tenant:', error);
      throw new Error(`Database error: ${error.message}`);
    }
    
    if (!tenant) {
      throw new Error('Tenant not found');
    }
    
    if (!tenant.storage_setup_complete) {
      return {
        storageSetupComplete: false,
        quota: 0,
        used: 0,
        available: 0,
        usagePercentage: 0,
        totalFiles: 0,
        categories: []
      };
    }
    
    const { data: files, error: filesError } = await supabase
      .from('t_tenant_files')
      .select('file_category')
      .eq('tenant_id', tenantId);
    
    if (filesError) {
      console.error('Error fetching files:', filesError);
    }
    
    const categoryCount = (files || []).reduce((acc: any, file: any) => {
      acc[file.file_category] = (acc[file.file_category] || 0) + 1;
      return acc;
    }, {});
    
    const categories = DEFAULT_STORAGE_CATEGORIES.map(cat => ({
      id: cat.id,
      name: cat.name,
      count: categoryCount[cat.id] || 0
    }));
    
    return {
      storageSetupComplete: true,
      quota: tenant.storage_quota * 1024 * 1024,
      used: tenant.storage_consumed,
      available: (tenant.storage_quota * 1024 * 1024) - tenant.storage_consumed,
      usagePercentage: Math.round((tenant.storage_consumed / (tenant.storage_quota * 1024 * 1024)) * 100),
      totalFiles: files?.length || 0,
      categories
    };
  } catch (error) {
    console.error('Error in getStorageStats:', error);
    throw error;
  }
};

// Setup storage with transaction-like behavior
const setupTenantStorage = async (supabase: any, tenantId: string) => {
  let storagePath: string | null = null;
  
  try {
    // Check if already setup
    const { data: existingTenant, error: checkError } = await supabase
      .from('t_tenants')
      .select('storage_setup_complete, storage_path')
      .eq('id', tenantId)
      .single();
    
    if (checkError) {
      console.error('Error checking existing setup:', checkError);
      throw new Error(`Failed to check existing setup: ${checkError.message}`);
    }
    
    if (existingTenant?.storage_setup_complete) {
      console.log('Storage already set up for tenant');
      throw { code: 'STORAGE_EXISTS', message: 'Storage already set up for this tenant' };
    }
    
    storagePath = `tenant_${tenantId.substring(0, 8)}_${Date.now()}`;
    console.log("Generated storage path:", storagePath);
    
    // Initialize Firebase Admin SDK
    const { storage } = await initializeFirebase();
    const bucket = storage.bucket();
    
    // Create folder structure
    console.log('Creating folder structure in Firebase...');
    const placeholderContent = Buffer.from('placeholder');
    
    // Create root folder placeholder
    const rootFile = bucket.file(`${storagePath}/.placeholder`);
    await rootFile.save(placeholderContent, {
      metadata: {
        contentType: 'text/plain'
      }
    });
    console.log('✓ Root folder created');
    
    // Create category folders
    for (const category of DEFAULT_STORAGE_CATEGORIES) {
      const categoryFile = bucket.file(`${storagePath}/${category.id}/.placeholder`);
      await categoryFile.save(placeholderContent, {
        metadata: {
          contentType: 'text/plain'
        }
      });
      console.log(`✓ Category folder created: ${category.id}`);
    }
    
    // Update database
    console.log('Updating database...');
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
      throw new Error(`Failed to update tenant record: ${error.message}`);
    }
    
    if (!data || data.length === 0) {
      throw new Error('No data returned after update');
    }
    
    console.log('✓ Storage setup complete');
    
    return {
      storageSetupComplete: true,
      quota: 40 * 1024 * 1024,
      used: 0,
      available: 40 * 1024 * 1024,
      usagePercentage: 0,
      path: storagePath
    };
  } catch (error: any) {
    console.error('Error in setupTenantStorage:', error);
    
    // Rollback attempt if needed
    if (storagePath && error.code !== 'STORAGE_EXISTS') {
      try {
        console.log('Attempting rollback...');
        const { storage } = await initializeFirebase();
        const bucket = storage.bucket();
        const rootFile = bucket.file(`${storagePath}/.placeholder`);
        await rootFile.delete();
        console.log('✓ Rollback completed');
      } catch (rollbackError) {
        console.error('Rollback failed:', rollbackError);
      }
    }
    
    throw error;
  }
};

// Enhanced file listing with pagination support
const listFiles = async (supabase: any, tenantId: string, category: string | null, page: number = 1, pageSize: number = 50) => {
  try {
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
      throw new Error(`Failed to list files: ${error.message}`);
    }
    
    // For backward compatibility, return array if no pagination params
    if (page === 1 && pageSize === 50 && !category) {
      return data || [];
    }
    
    return {
      files: data || [],
      pagination: {
        page,
        pageSize,
        total: count || 0,
        totalPages: Math.ceil((count || 0) / pageSize)
      }
    };
  } catch (error) {
    console.error('Error listing files:', error);
    throw error;
  }
};

// Upload file with enhanced validation and error handling
const uploadFile = async (
  supabase: any, 
  tenant: any, 
  file: Uint8Array, 
  fileName: string, 
  fileSize: number, 
  fileType: string,
  category: string,
  metadata?: any
) => {
  // Sanitize filename
  const sanitizedFileName = fileName.replace(/[^a-zA-Z0-9.-]/g, '_');
  const fileId = uuidv4();
  
  try {
    // Comprehensive validation
    if (fileSize > MAX_FILE_SIZE) {
      throw new Error(`File size ${fileSize} exceeds the ${MAX_FILE_SIZE} byte limit`);
    }
    
    const categoryConfig = DEFAULT_STORAGE_CATEGORIES.find(c => c.id === category);
    if (!categoryConfig) {
      throw new Error(`Invalid category: ${category}`);
    }
    
    if (!categoryConfig.allowedTypes.includes(fileType)) {
      throw new Error(`File type ${fileType} is not allowed for category ${category}`);
    }
    
    const availableStorage = tenant.storage_quota * 1024 * 1024 - tenant.storage_consumed;
    if (fileSize > availableStorage) {
      throw new Error(`Insufficient storage: ${fileSize} bytes requested, ${availableStorage} bytes available`);
    }
    
    const { storage } = await initializeFirebase();
    const bucket = storage.bucket();
    const filePath = `${tenant.storage_path}/${category}/${fileId}_${sanitizedFileName}`;
    
    // Upload file using Admin SDK
    const bucketFile = bucket.file(filePath);
    await bucketFile.save(file, {
      metadata: {
        contentType: fileType,
        metadata: metadata
      }
    });
    
    // Generate signed URL for download (valid for 7 days)
    const [downloadURL] = await bucketFile.getSignedUrl({
      action: 'read',
      expires: Date.now() + 7 * 24 * 60 * 60 * 1000 // 7 days
    });
    
    // Save file record
    const { data, error } = await supabase
      .from('t_tenant_files')
      .insert([
        {
          id: fileId,
          tenant_id: tenant.id,
          file_name: fileName,
          file_path: filePath,
          file_size: fileSize,
          file_type: fileType.split('/')[1] || 'unknown',
          file_category: category,
          mime_type: fileType,
          download_url: downloadURL,
          metadata: metadata
        }
      ])
      .select()
      .single();
    
    if (error) {
      // Cleanup on failure
      try {
        await bucketFile.delete();
      } catch (cleanupError) {
        console.error('Failed to cleanup file after database error:', cleanupError);
      }
      throw new Error(`Database error: ${error.message}`);
    }
    
    // Update consumed storage
    await supabase
      .from('t_tenants')
      .update({
        storage_consumed: tenant.storage_consumed + fileSize
      })
      .eq('id', tenant.id);
    
    return data;
  } catch (error) {
    console.error('Error uploading file:', error);
    throw error;
  }
};

// Delete file with proper cleanup
const deleteFile = async (supabase: any, tenantId: string, fileId: string) => {
  try {
    const { data: file, error: fileError } = await supabase
      .from('t_tenant_files')
      .select('*')
      .eq('id', fileId)
      .eq('tenant_id', tenantId)
      .single();
    
    if (fileError || !file) {
      throw new Error('File not found or access denied');
    }
    
    const { storage } = await initializeFirebase();
    const bucket = storage.bucket();
    const bucketFile = bucket.file(file.file_path);
    
    await bucketFile.delete();
    
    const { error: deleteError } = await supabase
      .from('t_tenant_files')
      .delete()
      .eq('id', fileId)
      .eq('tenant_id', tenantId);
    
    if (deleteError) {
      throw new Error(`Failed to delete file record: ${deleteError.message}`);
    }
    
    await supabase
      .from('t_tenants')
      .update({
        storage_consumed: supabase.raw(`GREATEST(0, storage_consumed - ${file.file_size})`)
      })
      .eq('id', tenantId);
    
    return { success: true, message: 'File deleted successfully', fileId };
  } catch (error) {
    console.error('Error deleting file:', error);
    throw error;
  }
};

// Main request handler
serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      status: 204,
      headers: corsHeaders
    });
  }
  
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), REQUEST_TIMEOUT);
  
  try {
    console.log('=== Incoming Request ===');
    console.log('Method:', req.method);
    console.log('URL:', req.url);
    
    const requestId = req.headers.get('x-request-id') || uuidv4();
    const ipAddress = req.headers.get('x-forwarded-for') || req.headers.get('x-real-ip') || 'unknown';
    const userAgent = req.headers.get('user-agent') || 'unknown';
    
    const authHeader = req.headers.get('Authorization');
    const tenantHeader = req.headers.get('x-tenant-id');
    const idempotencyKey = req.headers.get('x-idempotency-key');
    const signature = req.headers.get('x-signature');
    const timestamp = req.headers.get('x-timestamp');
    const signatureType = req.headers.get('x-signature-type');
    
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 401, 'AUTH_REQUIRED');
    }
    
    if (!tenantHeader) {
      return createErrorResponse('x-tenant-id header is required', 400, 'TENANT_REQUIRED');
    }
    
    // Rate limiting
    const { allowed, remaining } = checkRateLimit(tenantHeader);
    if (!allowed) {
      return createErrorResponse('Rate limit exceeded', 429, 'RATE_LIMIT_EXCEEDED');
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
    
    // Verify tenant
    const { data: tenant, error: tenantError } = await supabase
      .from('t_tenants')
      .select('id, storage_path, storage_quota, storage_consumed, storage_setup_complete')
      .eq('id', tenantHeader)
      .single();
    
    if (tenantError) {
      console.error('Tenant verification error:', tenantError);
      return createErrorResponse('Failed to verify tenant', 500, 'TENANT_VERIFICATION_ERROR');
    }
    
    if (!tenant) {
      return createErrorResponse('Tenant not found', 404, 'TENANT_NOT_FOUND');
    }
    
    const url = new URL(req.url);
    const path = url.pathname.split('/').filter(Boolean);
    
    // Signature verification for modifying operations
    if (['POST', 'PUT', 'DELETE'].includes(req.method) && signature && timestamp) {
      let isValidSignature = false;
      
      if (signatureType === 'file-metadata') {
        isValidSignature = true;
      } else {
        const body = await req.clone().text();
        isValidSignature = await verifyRequestSignature(signature, timestamp, body, tenantHeader, signatureType);
      }
      
      if (!isValidSignature) {
        await logAuditEvent(supabase, {
          tenantId: tenantHeader,
          action: 'INVALID_SIGNATURE',
          resource: 'storage',
          metadata: { path: url.pathname },
          ipAddress,
          userAgent,
          success: false,
          errorMessage: 'Invalid request signature'
        });
        return createErrorResponse('Invalid request signature', 403, 'INVALID_SIGNATURE');
      }
    }
    
    // Idempotency check
    if (idempotencyKey && ['POST', 'PUT'].includes(req.method)) {
      const { exists, response } = checkIdempotency(idempotencyKey);
      if (exists) {
        console.log('Returning cached response for idempotency key:', idempotencyKey);
        return createResponse(response);
      }
    }
    
    let response: any;
    
    // Route handling
    
    // Base endpoint - GET stats or POST setup
    if (path.length === 1 && path[0] === 'tenant-storage') {
      if (req.method === 'GET') {
        response = await getStorageStats(supabase, tenantHeader);
      } else if (req.method === 'POST') {
        try {
          response = await setupTenantStorage(supabase, tenantHeader);
          
          await logAuditEvent(supabase, {
            tenantId: tenantHeader,
            action: 'STORAGE_SETUP',
            resource: 'storage',
            metadata: { storagePath: response.path },
            ipAddress,
            userAgent,
            success: true
          });
        } catch (error: any) {
          if (error.code === 'STORAGE_EXISTS') {
            return createErrorResponse(error.message, 400, error.code);
          }
          throw error;
        }
      }
    }
    
    // Files endpoint
    else if (path.length === 2 && path[0] === 'tenant-storage' && path[1] === 'files') {
      if (!tenant.storage_setup_complete) {
        return createErrorResponse('Storage not set up', 400, 'STORAGE_NOT_SETUP');
      }
      
      if (req.method === 'GET') {
        const category = url.searchParams.get('category');
        const page = parseInt(url.searchParams.get('page') || '1');
        const pageSize = parseInt(url.searchParams.get('pageSize') || '50');
        
        response = await listFiles(supabase, tenantHeader, category, page, pageSize);
      } else if (req.method === 'POST') {
        const formData = await req.formData();
        const file = formData.get('file') as File;
        const category = formData.get('category') as string;
        const metadataStr = formData.get('metadata') as string;
        const metadata = metadataStr ? JSON.parse(metadataStr) : {};
        
        if (!file || !category) {
          return createErrorResponse('File and category are required', 400, 'MISSING_PARAMS');
        }
        
        const fileBytes = new Uint8Array(await file.arrayBuffer());
        response = await uploadFile(
          supabase,
          tenant,
          fileBytes,
          file.name,
          file.size,
          file.type,
          category,
          metadata
        );
        
        await logAuditEvent(supabase, {
          tenantId: tenantHeader,
          action: 'FILE_UPLOAD',
          resource: 'storage',
          resourceId: response.id,
          metadata: { fileName: file.name, category, size: file.size },
          ipAddress,
          userAgent,
          success: true
        });
      }
    }
    
    // Specific file operations
    else if (path.length === 3 && path[0] === 'tenant-storage' && path[1] === 'files') {
      if (!tenant.storage_setup_complete) {
        return createErrorResponse('Storage not set up', 400, 'STORAGE_NOT_SETUP');
      }
      
      const fileId = path[2];
      
      if (req.method === 'DELETE') {
        response = await deleteFile(supabase, tenantHeader, fileId);
        
        await logAuditEvent(supabase, {
          tenantId: tenantHeader,
          action: 'FILE_DELETE',
          resource: 'storage',
          resourceId: fileId,
          ipAddress,
          userAgent,
          success: true
        });
      }
    }
    
    if (!response) {
      return createErrorResponse('Not found', 404, 'NOT_FOUND');
    }
    
    // Store idempotency response
    if (idempotencyKey && ['POST', 'PUT'].includes(req.method)) {
      storeIdempotencyResponse(idempotencyKey, response);
    }
    
    // Create final response
    const finalResponse = createResponse(response);
    finalResponse.headers.set('X-RateLimit-Remaining', remaining.toString());
    finalResponse.headers.set('X-Request-Id', requestId);
    
    return finalResponse;
  } catch (error: any) {
    console.error('Unhandled error:', error);
    
    if (req.headers.get('x-tenant-id')) {
      const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
      const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
      
      if (supabaseUrl && supabaseKey) {
        const supabase = createClient(supabaseUrl, supabaseKey);
        await logAuditEvent(supabase, {
          tenantId: req.headers.get('x-tenant-id')!,
          action: req.method,
          resource: 'storage',
          metadata: { error: error.message },
          ipAddress: req.headers.get('x-forwarded-for') || 'unknown',
          userAgent: req.headers.get('user-agent') || 'unknown',
          success: false,
          errorMessage: error.message
        });
      }
    }
    
    return createErrorResponse(
      'An error occurred processing your request', 
      500, 
      'INTERNAL_ERROR'
    );
  } finally {
    clearTimeout(timeoutId);
  }
});