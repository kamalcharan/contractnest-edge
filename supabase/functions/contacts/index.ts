// supabase/functions/contacts/index.ts - V2 RPC OPTIMIZED VERSION
// PERFORMANCE FIX: Non-blocking audit logging + removed from LIST operations
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
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  let auditLogger: any = null;
  let contactService: ContactService | null = null;
  let validationService: ContactValidationService | null = null;
  let tenantId: string | null = null;
  let isLive: boolean = true;

  try {
    // ==========================================================
    // STEP 1: Extract and Validate Headers
    // ==========================================================
    tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'live';
    const idempotencyKey = req.headers.get('x-idempotency-key');

    isLive = environment.toLowerCase() !== 'test';

    // ==========================================================
    // STEP 2: Validate Environment Variables
    // ==========================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    // ==========================================================
    // STEP 3: Validate Tenant ID
    // ==========================================================
    if (!tenantId) {
      return new Response(
        JSON.stringify({
          error: 'x-tenant-id header is required',
          code: 'MISSING_TENANT_ID'
        }),
        {
          status: 400,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    // ==========================================================
    // STEP 4: Validate HMAC Signature (if configured)
    // ==========================================================
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return new Response(
        JSON.stringify({
          error: 'Missing internal signature',
          code: 'MISSING_SIGNATURE'
        }),
        {
          status: 401,
          headers: { ...corsHeaders, 'Content-Type': 'application/json' }
        }
      );
    }

    let requestBody = '';
    if (internalSigningSecret && signature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValidSignature = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValidSignature) {
        return new Response(
          JSON.stringify({
            error: 'Invalid internal signature',
            code: 'INVALID_SIGNATURE'
          }),
          {
            status: 403,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' }
          }
        );
      }
    }

    // ==========================================================
    // STEP 5: Initialize Services
    // ==========================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // Initialize audit logger (used for WRITE operations only)
    auditLogger = createContactAuditLogger(req, Deno.env, 'contacts');

    contactService = new ContactService(
      supabase,
      auditLogger,
      ContactAuditActions,
      ContactAuditResources,
      isLive,
      tenantId
    );

    validationService = new ContactValidationService(supabase);

    // ==========================================================
    // STEP 6: Parse Request and Route
    // ==========================================================
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(segment => segment);

    const isStatsRequest = pathSegments.includes('stats');
    const isConstantsRequest = pathSegments.includes('constants');
    const isSearchRequest = pathSegments.includes('search');
    const isDuplicatesRequest = pathSegments.includes('duplicates');
    const isInviteRequest = pathSegments.includes('invite');

    const lastSegment = pathSegments[pathSegments.length - 1];
    const isUUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(lastSegment);
    const contactId = isUUID && !isStatsRequest && !isConstantsRequest && !isSearchRequest && !isDuplicatesRequest ? lastSegment : null;

    // ==========================================================
    // STEP 7: Route to Appropriate Handler
    // ==========================================================
    let response: Response;

    switch (method) {
      case 'GET':
        // READ operations - NO AUDIT LOGGING (performance critical)
        if (isStatsRequest) {
          response = await handleGetStats(contactService, url.searchParams);
        } else if (isConstantsRequest) {
          response = await handleGetConstants();
        } else if (contactId) {
          response = await handleGetContact(contactService, contactId);
        } else {
          response = await handleListContacts(contactService, url.searchParams);
        }
        break;

      case 'POST':
        if (isSearchRequest) {
          // Search is a read operation - NO AUDIT
          const searchData = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleSearchContacts(contactService, searchData);
        } else if (isDuplicatesRequest) {
          const duplicateData = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleCheckDuplicates(contactService, duplicateData);
        } else if (isInviteRequest && contactId) {
          response = await handleSendInvitation(contactService, contactId, tenantId, isLive, auditLogger);
        } else {
          const createData = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleCreateContact(contactService, validationService, createData, tenantId, isLive, auditLogger, idempotencyKey);
        }
        break;

      case 'PUT':
        if (contactId) {
          const updateData = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleUpdateContact(contactService, validationService, contactId, updateData, tenantId, isLive, auditLogger, idempotencyKey);
        } else {
          response = new Response(
            JSON.stringify({ error: 'Contact ID required for update' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        break;

      case 'PATCH':
        if (contactId) {
          const statusData = requestBody ? JSON.parse(requestBody) : await req.json();
          response = await handleUpdateContactStatus(contactService, contactId, statusData, tenantId, isLive, auditLogger);
        } else {
          response = new Response(
            JSON.stringify({ error: 'Contact ID required for status update' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        break;

      case 'DELETE':
        if (contactId) {
          const deleteData = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
          response = await handleDeleteContact(contactService, contactId, deleteData, tenantId, isLive, auditLogger);
        } else {
          response = new Response(
            JSON.stringify({ error: 'Contact ID required for deletion' }),
            { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }
        break;

      default:
        response = new Response(
          JSON.stringify({ error: 'Method not allowed' }),
          { status: 405, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
    }

    return response;

  } catch (error: any) {
    console.error('Error in contacts function:', error);

    // Fire-and-forget error logging - don't await
    if (auditLogger && tenantId) {
      auditLogger.log({
        tenantId,
        action: ContactAuditActions.SYSTEM_ERROR || 'system.error',
        resource: ContactAuditResources.CONTACT || 'contact',
        success: false,
        errorMessage: error.message,
        metadata: { method: req.method, url: req.url }
      }).catch(() => {}); // Ignore audit errors
    }

    return new Response(
      JSON.stringify({
        error: error.message || 'Internal server error',
        code: 'INTERNAL_ERROR'
      }),
      {
        status: 500,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  }
});

// ==========================================================
// READ HANDLERS - NO AUDIT LOGGING (Performance Critical)
// ==========================================================

async function handleListContacts(
  contactService: ContactService,
  searchParams: URLSearchParams
): Promise<Response> {
  try {
    const filters = {
      page: parseInt(searchParams.get('page') || '1'),
      limit: parseInt(searchParams.get('limit') || '20'),
      search: searchParams.get('search') || undefined,
      status: searchParams.get('status') || undefined,
      type: searchParams.get('type') || undefined,
      sort_by: searchParams.get('sort_by') || 'created_at',
      sort_order: (searchParams.get('sort_order') || 'desc') as 'asc' | 'desc',
      classifications: searchParams.get('classifications')
        ? searchParams.get('classifications')!.split(',').filter(Boolean)
        : undefined,
      user_status: searchParams.get('user_status') || undefined,
      show_duplicates: searchParams.get('show_duplicates') === 'true',
      includeInactive: searchParams.get('includeInactive') === 'true',
      includeArchived: searchParams.get('includeArchived') === 'true'
    };

    const result = await contactService.listContacts(filters);

    return new Response(
      JSON.stringify({
        success: true,
        data: result.contacts,
        pagination: result.pagination,
        timestamp: new Date().toISOString()
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: any) {
    console.error('Error listing contacts:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'LIST_CONTACTS_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetContact(
  contactService: ContactService,
  contactId: string
): Promise<Response> {
  try {
    const contact = await contactService.getContactById(contactId);

    if (!contact) {
      return new Response(
        JSON.stringify({ error: 'Contact not found', code: 'CONTACT_NOT_FOUND' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        timestamp: new Date().toISOString()
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: any) {
    console.error('Error getting contact:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'GET_CONTACT_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetStats(
  contactService: ContactService,
  searchParams: URLSearchParams
): Promise<Response> {
  try {
    const filters = {
      search: searchParams.get('search') || undefined,
      type: searchParams.get('type') || undefined,
      classifications: searchParams.get('classifications')
        ? searchParams.get('classifications')!.split(',').filter(Boolean)
        : undefined
    };

    const stats = await contactService.getContactStats(filters);

    return new Response(
      JSON.stringify({
        success: true,
        data: stats,
        timestamp: new Date().toISOString()
      }),
      {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' }
      }
    );
  } catch (error: any) {
    console.error('Error getting stats:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'GET_STATS_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleGetConstants(): Promise<Response> {
  const constants = {
    types: ['individual', 'corporate'],
    statuses: ['active', 'inactive', 'archived'],
    classifications: ['buyer', 'seller', 'vendor', 'partner', 'team_member'],
    channel_types: ['mobile', 'email', 'whatsapp', 'linkedin', 'website', 'telegram', 'skype'],
    address_types: ['home', 'office', 'billing', 'shipping', 'factory', 'warehouse', 'other']
  };

  return new Response(
    JSON.stringify({ success: true, data: constants, timestamp: new Date().toISOString() }),
    { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}

async function handleSearchContacts(
  contactService: ContactService,
  requestData: any
): Promise<Response> {
  try {
    const { query, filters } = requestData;

    if (!query || query.trim().length === 0) {
      return new Response(
        JSON.stringify({ error: 'Search query is required', code: 'SEARCH_QUERY_REQUIRED' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
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
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error searching contacts:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'SEARCH_CONTACTS_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleCheckDuplicates(
  contactService: ContactService,
  requestData: any
): Promise<Response> {
  try {
    const result = await contactService.checkForDuplicates(requestData);
    return new Response(
      JSON.stringify({ success: true, data: result, timestamp: new Date().toISOString() }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error checking duplicates:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'CHECK_DUPLICATES_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ==========================================================
// WRITE HANDLERS - WITH AUDIT LOGGING (Fire-and-Forget)
// ==========================================================

async function handleCreateContact(
  contactService: ContactService,
  validationService: ContactValidationService,
  requestData: any,
  tenantId: string,
  isLive: boolean,
  auditLogger: any,
  idempotencyKey: string | null
): Promise<Response> {
  try {
    requestData.tenant_id = tenantId;
    requestData.is_live = isLive;

    const validationResult = await validationService.validateCreateRequest(requestData);
    if (!validationResult.isValid) {
      return new Response(
        JSON.stringify({
          error: 'Validation failed',
          code: 'VALIDATION_ERROR',
          validation_errors: validationResult.errors
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    if (!requestData.force_create) {
      const duplicateCheck = await contactService.checkForDuplicates(requestData);
      if (duplicateCheck.hasDuplicates) {
        return new Response(
          JSON.stringify({
            error: 'Potential duplicate contacts found',
            code: 'DUPLICATE_CONTACTS_FOUND',
            duplicates: duplicateCheck.duplicates,
            warning: true
          }),
          { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    const contact = await contactService.createContact(requestData, idempotencyKey || undefined);

    if (contact && contact.code === 'DUPLICATE_CONTACTS_FOUND') {
      return new Response(
        JSON.stringify({
          success: false,
          error: contact.error,
          code: contact.code,
          duplicates: contact.duplicates,
          warning: true
        }),
        { status: 409, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Fire-and-forget audit logging - DON'T AWAIT
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.CREATE || 'contact.create',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contact?.id,
      success: true,
      metadata: { environment: isLive ? 'live' : 'test' }
    }).catch(() => {});

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: 'Contact created successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 201, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error creating contact:', error);

    // Fire-and-forget error audit
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.CREATE || 'contact.create',
      resource: ContactAuditResources.CONTACT || 'contact',
      success: false,
      errorMessage: error.message
    }).catch(() => {});

    let errorCode = 'CREATE_CONTACT_ERROR';
    let statusCode = 500;
    if (error.message.includes('DUPLICATE')) { errorCode = 'DUPLICATE_CONTACTS_FOUND'; statusCode = 409; }
    if (error.message.includes('VALIDATION')) { errorCode = 'VALIDATION_ERROR'; statusCode = 400; }

    return new Response(
      JSON.stringify({ error: error.message, code: errorCode }),
      { status: statusCode, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleUpdateContact(
  contactService: ContactService,
  validationService: ContactValidationService,
  contactId: string,
  requestData: any,
  tenantId: string,
  isLive: boolean,
  auditLogger: any,
  idempotencyKey: string | null
): Promise<Response> {
  try {
    const validationResult = await validationService.validateUpdateRequest(contactId, requestData);
    if (!validationResult.isValid) {
      return new Response(
        JSON.stringify({
          error: 'Validation failed',
          code: 'VALIDATION_ERROR',
          validation_errors: validationResult.errors
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const contact = await contactService.updateContact(contactId, requestData, idempotencyKey || undefined);

    if (!contact) {
      return new Response(
        JSON.stringify({ error: 'Contact not found', code: 'CONTACT_NOT_FOUND' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Fire-and-forget audit logging
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.UPDATE || 'contact.update',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: true,
      metadata: { environment: isLive ? 'live' : 'test' }
    }).catch(() => {});

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: 'Contact updated successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error updating contact:', error);

    auditLogger.log({
      tenantId,
      action: ContactAuditActions.UPDATE || 'contact.update',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: false,
      errorMessage: error.message
    }).catch(() => {});

    let errorCode = 'UPDATE_CONTACT_ERROR';
    let statusCode = 500;
    if (error.message.includes('not found')) { errorCode = 'CONTACT_NOT_FOUND'; statusCode = 404; }
    if (error.message.includes('archived')) { errorCode = 'CONTACT_ARCHIVED'; statusCode = 400; }

    return new Response(
      JSON.stringify({ error: error.message, code: errorCode }),
      { status: statusCode, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleUpdateContactStatus(
  contactService: ContactService,
  contactId: string,
  requestData: any,
  tenantId: string,
  isLive: boolean,
  auditLogger: any
): Promise<Response> {
  try {
    const { status } = requestData;
    const validStatuses = ['active', 'inactive', 'archived'];

    if (!validStatuses.includes(status)) {
      return new Response(
        JSON.stringify({
          error: 'Invalid status',
          code: 'INVALID_STATUS',
          valid_statuses: validStatuses
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const contact = await contactService.updateContactStatus(contactId, status);

    if (!contact) {
      return new Response(
        JSON.stringify({ error: 'Contact not found', code: 'CONTACT_NOT_FOUND' }),
        { status: 404, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Fire-and-forget audit
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.UPDATE || 'contact.update',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: true,
      metadata: { newStatus: status, environment: isLive ? 'live' : 'test' }
    }).catch(() => {});

    return new Response(
      JSON.stringify({
        success: true,
        data: contact,
        message: `Contact ${status} successfully`,
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error updating contact status:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'UPDATE_STATUS_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleDeleteContact(
  contactService: ContactService,
  contactId: string,
  requestData: any,
  tenantId: string,
  isLive: boolean,
  auditLogger: any
): Promise<Response> {
  try {
    const { force = false } = requestData;
    const result = await contactService.deleteContact(contactId, force);

    if (!result.success) {
      return new Response(
        JSON.stringify({ error: result.error, code: result.code || 'DELETE_CONTACT_ERROR' }),
        { status: result.error?.includes('not found') ? 404 : 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // Fire-and-forget audit
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.DELETE || 'contact.delete',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: true,
      metadata: { force, environment: isLive ? 'live' : 'test' }
    }).catch(() => {});

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Contact deleted successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error deleting contact:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'DELETE_CONTACT_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

async function handleSendInvitation(
  contactService: ContactService,
  contactId: string,
  tenantId: string,
  isLive: boolean,
  auditLogger: any
): Promise<Response> {
  try {
    const result = await contactService.sendInvitation(contactId);

    // Fire-and-forget audit
    auditLogger.log({
      tenantId,
      action: ContactAuditActions.INVITATION_SEND || 'contact.invitation.send',
      resource: ContactAuditResources.CONTACT || 'contact',
      resourceId: contactId,
      success: true
    }).catch(() => {});

    return new Response(
      JSON.stringify({
        success: true,
        data: result,
        message: result.message || 'Invitation sent successfully',
        timestamp: new Date().toISOString()
      }),
      { status: 200, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  } catch (error: any) {
    console.error('Error sending invitation:', error);
    return new Response(
      JSON.stringify({ error: error.message, code: 'SEND_INVITATION_ERROR' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
}

// ==========================================================
// UTILITY FUNCTIONS
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
