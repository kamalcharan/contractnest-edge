// supabase/functions/contacts/index.ts - UPDATED FOR RPC FUNCTIONS
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';
import { 
  createContactAuditLogger,
  ContactAuditActions,
  ContactAuditResources 
} from '../_shared/contactAudit.ts';
import { ContactService } from '../_shared/contacts/contactService.ts';
import { ContactValidationService } from '../_shared/contacts/contactValidation.ts';

serve(async (req: Request) => {
  // Handle CORS
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  let auditLogger: any = null;
  const tenantId = req.headers.get('x-tenant-id');
  // FIXED: Extract is_live from x-environment header
  const environment = req.headers.get('x-environment') || 'live';
  const isLive = environment === 'live';

  try {
    // Validate environment
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    if (!internalSigningSecret) {
      console.warn('⚠️  INTERNAL_SIGNING_SECRET not set. Internal API signature verification will be disabled.');
    }

    // Validate tenant ID
    if (!tenantId) {
      return new Response(
        JSON.stringify({ error: 'x-tenant-id header is required' }),
        { status: 400, headers: corsHeaders }
      );
    }

    // Validate HMAC signature for internal API calls
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return new Response(
        JSON.stringify({ error: 'Missing internal signature' }),
        { status: 401, headers: corsHeaders }
      );
    }

    // Verify signature if both secret and signature exist
    if (internalSigningSecret && signature) {
      const requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValidSignature = await verifyInternalSignature(requestBody, signature, internalSigningSecret);
      
      if (!isValidSignature) {
        return new Response(
          JSON.stringify({ error: 'Invalid internal signature' }),
          { status: 403, headers: corsHeaders }
        );
      }
      
      // Re-parse body for JSON requests
      if (req.method !== 'GET' && requestBody) {
        try {
          req = new Request(req.url, {
            method: req.method,
            headers: req.headers,
            body: requestBody
          });
        } catch (e) {
          // If not JSON, leave as is
        }
      }
    }

    // Initialize Supabase client
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Initialize audit logger with proper environment object
    auditLogger = createContactAuditLogger(req, Deno.env, 'contacts');
    
    // FIXED: Initialize services with audit constants and is_live parameter
    const contactService = new ContactService(supabase, auditLogger, ContactAuditActions, ContactAuditResources, isLive);
    const validationService = new ContactValidationService(supabase);

    // Parse request
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(segment => segment);
    
    // Better endpoint detection
    const isStatsRequest = pathSegments.includes('stats');
    const isConstantsRequest = pathSegments.includes('constants');
    const isSearchRequest = pathSegments.includes('search');
    const isDuplicatesRequest = pathSegments.includes('duplicates');
    const isInviteRequest = pathSegments.includes('invite');
    
    // Extract contact ID if present (but not for special endpoints)
    const contactId = pathSegments[pathSegments.length - 1];
    const isContactIdRequest = contactId && 
      contactId.length === 36 && 
      !isStatsRequest && 
      !isConstantsRequest && 
      !isSearchRequest && 
      !isDuplicatesRequest;

    // Route to appropriate handler
    switch (method) {
      case 'GET':
        if (isStatsRequest) {
          return await handleGetStats(contactService, url.searchParams, tenantId, auditLogger);
        } else if (isConstantsRequest) {
          return await handleGetConstants(contactService, tenantId, auditLogger);
        } else if (isContactIdRequest) {
          return await handleGetContact(contactService, contactId, tenantId, auditLogger);
        } else {
          return await handleListContacts(contactService, url.searchParams, tenantId, auditLogger);
        }

      case 'POST':
        if (isSearchRequest) {
          return await handleSearchContacts(contactService, req, tenantId, auditLogger);
        } else if (isDuplicatesRequest) {
          return await handleCheckDuplicates(contactService, req, tenantId, auditLogger);
        } else if (isInviteRequest) {
          return await handleSendInvitation(contactService, contactId, req, tenantId, auditLogger);
        } else {
          return await handleCreateContact(contactService, validationService, req, tenantId, auditLogger);
        }

      case 'PUT':
        if (isContactIdRequest) {
          return await handleUpdateContact(contactService, validationService, contactId, req, tenantId, auditLogger);
        }
        break;

      case 'PATCH':
        if (isContactIdRequest) {
          return await handleUpdateContactStatus(contactService, contactId, req, tenantId, auditLogger);
        }
        break;

      case 'DELETE':
        if (isContactIdRequest) {
          return await handleDeleteContact(contactService, contactId, req, tenantId, auditLogger);
        }
        break;

      default:
        return new Response(
          JSON.stringify({ error: 'Method not allowed' }),
          { status: 405, headers: corsHeaders }
        );
    }

    return new Response(
      JSON.stringify({ error: 'Invalid request' }),
      { status: 400, headers: corsHeaders }
    );

  } catch (error: any) {
    console.error('Error in contacts function:', error);
    
    // Try to log the error if possible
    if (auditLogger && tenantId) {
      try {
        await auditLogger.log({
          tenantId,
          action: ContactAuditActions.SYSTEM_ERROR || 'system.error',
          resource: ContactAuditResources.CONTACT || 'contact',
          success: false,
          errorMessage: error.message,
          metadata: { 
            stack: error.stack,
            method: req.method,
            url: req.url,
            environment: isLive ? 'live' : 'test'
          }
        });
      } catch (auditError) {
        console.error('Failed to log audit error:', auditError);
      }
    }
    
    return new Response(
      JSON.stringify({ 
        error: error.message || 'Internal server error',
        code: 'INTERNAL_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
});

// ==========================================================
// Handler Functions
// ==========================================================

async function handleListContacts(
  contactService: ContactService, 
  searchParams: URLSearchParams, 
  tenantId: string,
  auditLogger: any
) {
  try {
    const filters = {
      page: parseInt(searchParams.get('page') || '1'),
      limit: parseInt(searchParams.get('limit') || '20'),
      search: searchParams.get('search'),
      status: searchParams.get('status'),
      type: searchParams.get('type'),
      sort_by: searchParams.get('sort_by') || 'created_at',
      sort_order: searchParams.get('sort_order') || 'desc',
      classifications: searchParams.get('classifications')?.split(',').filter(Boolean),
      user_status: searchParams.get('user_status'),
      show_duplicates: searchParams.get('show_duplicates') === 'true',
      includeInactive: searchParams.get('includeInactive') === 'true',
      includeArchived: searchParams.get('includeArchived') === 'true'
    };

    // Log the list operation
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.LIST || 'contact.list',
      resource: ContactAuditResources.CONTACT || 'contact',
      success: true,
      metadata: { filters }
    });

    const result = await contactService.listContacts(filters);

    return new Response(
      JSON.stringify({
        success: true,
        data: result.contacts,
        pagination: result.pagination,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error listing contacts:', error);
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.LIST || 'contact.list',
      resource: ContactAuditResources.CONTACT || 'contact',
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'LIST_CONTACTS_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

async function handleGetContact(
  contactService: ContactService, 
  contactId: string, 
  tenantId: string,
  auditLogger: any
) {
  try {
    const contact = await contactService.getContactById(contactId);

    if (!contact) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.VIEW || 'contact.view',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: 'not_found' }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Contact not found',
          code: 'CONTACT_NOT_FOUND'
        }),
        { status: 404, headers: corsHeaders }
      );
    }

    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.VIEW || 'contact.view',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: true
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error getting contact:', error);
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.VIEW || 'contact.view',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'GET_CONTACT_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

// UPDATED: Handle RPC-based creation
async function handleCreateContact(
  contactService: ContactService, 
  validationService: ContactValidationService, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const requestData = await req.json();
    
    // Add tenant_id to request data
    requestData.tenant_id = tenantId;

    // Validate request data
    const validationResult = await validationService.validateCreateRequest(requestData);
    if (!validationResult.isValid) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.CREATE || 'contact.create',
        resource: ContactAuditResources.CONTACT || 'contact',
        success: false,
        metadata: { reason: 'validation_failed', errors: validationResult.errors }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Validation failed',
          code: 'VALIDATION_ERROR',
          validation_errors: validationResult.errors
        }),
        { status: 400, headers: corsHeaders }
      );
    }

    // UPDATED: Check for duplicates and handle new response format
    const duplicateCheck = await contactService.checkForDuplicates(requestData);
    if (duplicateCheck.hasDuplicates && !requestData.force_create) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.DUPLICATE_FLAG || 'contact.duplicate.flag',
        resource: ContactAuditResources.CONTACT || 'contact',
        success: true,
        metadata: { duplicates: duplicateCheck.duplicates }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Potential duplicate contacts found',
          code: 'DUPLICATE_CONTACTS_FOUND',
          duplicates: duplicateCheck.duplicates,
          warning: true // Allow user to proceed if they want
        }),
        { status: 409, headers: corsHeaders }
      );
    }

    // UPDATED: Create contact (now uses RPC internally)
    const contact = await contactService.createContact(requestData);

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: 'Contact created successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 201, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error creating contact:', error);
    
    // UPDATED: Handle RPC-specific errors
    let errorCode = 'CREATE_CONTACT_ERROR';
    let statusCode = 500;
    
    if (error.message.includes('DUPLICATE_CONTACTS_FOUND')) {
      errorCode = 'DUPLICATE_CONTACTS_FOUND';
      statusCode = 409;
    } else if (error.message.includes('VALIDATION_ERROR')) {
      errorCode = 'VALIDATION_ERROR';
      statusCode = 400;
    }
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.CREATE || 'contact.create',
      resource: ContactAuditResources.CONTACT || 'contact',
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: errorCode
      }),
      { status: statusCode, headers: corsHeaders }
    );
  }
}

// UPDATED: Handle RPC-based updates
async function handleUpdateContact(
  contactService: ContactService, 
  validationService: ContactValidationService, 
  contactId: string, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const requestData = await req.json();

    // Validate request data
    const validationResult = await validationService.validateUpdateRequest(contactId, requestData);
    if (!validationResult.isValid) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.UPDATE || 'contact.update',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: 'validation_failed', errors: validationResult.errors }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Validation failed',
          code: 'VALIDATION_ERROR',
          validation_errors: validationResult.errors
        }),
        { status: 400, headers: corsHeaders }
      );
    }

    // UPDATED: Update contact (now uses RPC internally)
    const contact = await contactService.updateContact(contactId, requestData);

    if (!contact) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.UPDATE || 'contact.update',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: 'not_found' }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Contact not found',
          code: 'CONTACT_NOT_FOUND'
        }),
        { status: 404, headers: corsHeaders }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: 'Contact updated successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error updating contact:', error);
    
    // UPDATED: Handle RPC-specific errors
    let errorCode = 'UPDATE_CONTACT_ERROR';
    let statusCode = 500;
    
    if (error.message.includes('Contact not found')) {
      errorCode = 'CONTACT_NOT_FOUND';
      statusCode = 404;
    } else if (error.message.includes('Cannot update archived contact')) {
      errorCode = 'CONTACT_ARCHIVED';
      statusCode = 400;
    }
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.UPDATE || 'contact.update',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: errorCode
      }),
      { status: statusCode, headers: corsHeaders }
    );
  }
}

async function handleUpdateContactStatus(
  contactService: ContactService, 
  contactId: string, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const { status } = await req.json();

    // Validate status
    const validStatuses = ['active', 'inactive', 'archived'];
    if (!validStatuses.includes(status)) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.UPDATE || 'contact.update',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: 'invalid_status', provided_status: status }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Invalid status',
          code: 'INVALID_STATUS',
          valid_statuses: validStatuses
        }),
        { status: 400, headers: corsHeaders }
      );
    }

    // Update contact status
    const contact = await contactService.updateContactStatus(contactId, status);

    if (!contact) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.UPDATE || 'contact.update',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: 'not_found' }
      });
      
      return new Response(
        JSON.stringify({ 
          error: 'Contact not found',
          code: 'CONTACT_NOT_FOUND'
        }),
        { status: 404, headers: corsHeaders }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: `Contact ${status} successfully`,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error updating contact status:', error);
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.UPDATE || 'contact.update',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'UPDATE_STATUS_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

// UPDATED: Handle RPC-based deletion
async function handleDeleteContact(
  contactService: ContactService, 
  contactId: string, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const { force = false } = await req.json().catch(() => ({}));

    // UPDATED: Delete contact (now uses RPC internally)
    const result = await contactService.deleteContact(contactId, force);

    if (!result.success) {
      await auditLogger.log({
        tenantId,
        action: ContactAuditActions.DELETE || 'contact.delete',
        resource: ContactAuditResources.CONTACT || 'contact',
        resourceId: contactId,
        success: false,
        metadata: { reason: result.error, force }
      });
      
      // UPDATED: Handle specific error codes from RPC
      let statusCode = 400;
      if (result.error?.includes('not found')) {
        statusCode = 404;
      }
      
      return new Response(
        JSON.stringify({ 
          error: result.error,
          code: result.code || 'DELETE_CONTACT_ERROR'
        }),
        { status: statusCode, headers: corsHeaders }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Contact deleted successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error deleting contact:', error);
    
    await auditLogger.log({
      tenantId,
      action: ContactAuditActions.DELETE || 'contact.delete',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'DELETE_CONTACT_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

async function handleGetStats(
  contactService: ContactService, 
  searchParams: URLSearchParams, 
  tenantId: string,
  auditLogger: any
) {
  try {
    // Get the same filters used for listing
    const filters = {
      search: searchParams.get('search'),
      type: searchParams.get('type'),
      classifications: searchParams.get('classifications')?.split(',').filter(Boolean),
      user_status: searchParams.get('user_status'),
      show_duplicates: searchParams.get('show_duplicates') === 'true'
    };

    const stats = await contactService.getContactStats(filters);

    await auditLogger.log({
      tenantId,
      action: 'contact.stats',
      resource: 'contact',
      success: true,
      metadata: { filters }
    });

    return new Response(
      JSON.stringify({
        success: true,
        data: stats,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error getting stats:', error);
    
    await auditLogger.log({
      tenantId,
      action: 'contact.stats',
      resource: 'contact',
      success: false,
      errorMessage: error.message
    });
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'GET_STATS_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

// FIXED: Constants handler with team_member added
async function handleGetConstants(
  contactService: ContactService, 
  tenantId: string,
  auditLogger: any
) {
  try {
    const constants = {
      types: ['individual', 'corporate'],
      statuses: ['active', 'inactive', 'archived'],
      classifications: ['buyer', 'seller', 'vendor', 'partner', 'team_member'], // FIXED: Added team_member
      channel_types: ['mobile', 'email', 'whatsapp', 'linkedin', 'website', 'telegram', 'skype'],
      address_types: ['home', 'office', 'billing', 'shipping', 'factory', 'warehouse', 'other']
    };

    return new Response(
      JSON.stringify({
        success: true,
        data: constants,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error getting constants:', error);
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'GET_CONSTANTS_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

async function handleSearchContacts(
  contactService: ContactService, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const { query, filters } = await req.json();
    
    if (!query || query.trim().length === 0) {
      return new Response(
        JSON.stringify({ 
          error: 'Search query is required',
          code: 'SEARCH_QUERY_REQUIRED'
        }),
        { status: 400, headers: corsHeaders }
      );
    }

    const result = await contactService.searchContacts(query.trim(), filters || {});

    return new Response(
      JSON.stringify({
        success: true,
        data: result.contacts,
        pagination: result.pagination,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error searching contacts:', error);
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'SEARCH_CONTACTS_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

// UPDATED: Handle new duplicate check response format
async function handleCheckDuplicates(
  contactService: ContactService, 
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const contactData = await req.json();
    
    // UPDATED: checkForDuplicates now returns direct format instead of RPC wrapper
    const result = await contactService.checkForDuplicates(contactData);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error checking duplicates:', error);
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'CHECK_DUPLICATES_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

async function handleSendInvitation(
  contactService: ContactService,
  contactId: string,
  req: Request,
  tenantId: string,
  auditLogger: any
) {
  try {
    const result = await contactService.sendInvitation(contactId);

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        message: result.message || 'Invitation sent successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: corsHeaders }
    );
  } catch (error: any) {
    console.error('Error sending invitation:', error);
    
    return new Response(
      JSON.stringify({ 
        error: error.message,
        code: 'SEND_INVITATION_ERROR'
      }),
      { status: 500, headers: corsHeaders }
    );
  }
}

// ==========================================================
// Utility Functions
// ==========================================================

async function verifyInternalSignature(body: string, signature: string, secret: string): Promise<boolean> {
  try {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(body);
    
    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );
    
    const signatureBuffer = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const expectedSignature = Array.from(new Uint8Array(signatureBuffer))
      .map(b => b.toString(16).padStart(2, '0'))
      .join('');
    
    return signature === expectedSignature;
  } catch (error) {
    console.error('Signature verification error:', error);
    return false;
  }
}