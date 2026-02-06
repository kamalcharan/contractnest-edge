// supabase/functions/contracts/index.ts
// Edge function for contract & RFQ CRUD operations
// Pattern: CORS → HMAC validation → single RPC per handler → response
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.7.1';
import { corsHeaders } from '../_shared/cors.ts';
import { sendContractSignoffNotification } from './jtd-integration.ts';

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // ==========================================================
    // PUBLIC ROUTES (no auth / HMAC required)
    // Must be checked BEFORE tenant/signature validation
    // ==========================================================
    const publicUrl = new URL(req.url);
    const publicSegments = publicUrl.pathname.split('/').filter(s => s);
    const isPublicRoute = publicSegments.includes('public');

    if (isPublicRoute && req.method === 'POST') {
      const supabaseUrlPublic = Deno.env.get('SUPABASE_URL');
      const supabaseKeyPublic = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

      if (!supabaseUrlPublic || !supabaseKeyPublic) {
        throw new Error('Missing required environment variables');
      }

      const supabasePublic = createClient(supabaseUrlPublic, supabaseKeyPublic);
      const publicBody = await req.json();
      const publicLastSegment = publicSegments[publicSegments.length - 1];

      // POST /contracts/public/validate
      if (publicLastSegment === 'validate') {
        return await handlePublicValidate(supabasePublic, publicBody);
      }

      // POST /contracts/public/respond
      if (publicLastSegment === 'respond') {
        return await handlePublicRespond(supabasePublic, publicBody);
      }

      return jsonResponse({ success: false, error: 'Unknown public endpoint', code: 'NOT_FOUND' }, 404);
    }

    // ==========================================================
    // STEP 1: Extract and validate headers
    // ==========================================================
    const tenantId = req.headers.get('x-tenant-id');
    const environment = req.headers.get('x-environment') || 'live';
    const idempotencyKey = req.headers.get('x-idempotency-key');
    const userId = req.headers.get('x-user-id');

    const isLive = environment.toLowerCase() !== 'test';

    // ==========================================================
    // STEP 2: Validate environment variables
    // ==========================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSigningSecret = Deno.env.get('INTERNAL_SIGNING_SECRET');

    if (!supabaseUrl || !supabaseServiceKey) {
      throw new Error('Missing required environment variables');
    }

    // ==========================================================
    // STEP 3: Validate tenant ID
    // ==========================================================
    if (!tenantId) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'x-tenant-id header is required',
          code: 'MISSING_TENANT_ID'
        }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    // ==========================================================
    // STEP 4: Validate HMAC signature (internal_handshake)
    // ==========================================================
    const signature = req.headers.get('x-internal-signature');
    if (internalSigningSecret && !signature) {
      return new Response(
        JSON.stringify({
          success: false,
          error: 'Missing internal signature',
          code: 'MISSING_SIGNATURE'
        }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    let requestBody = '';
    if (internalSigningSecret && signature) {
      requestBody = req.method !== 'GET' ? await req.text() : '';
      const isValid = await verifyInternalSignature(requestBody, signature, internalSigningSecret);

      if (!isValid) {
        return new Response(
          JSON.stringify({
            success: false,
            error: 'Invalid internal signature',
            code: 'INVALID_SIGNATURE'
          }),
          { status: 403, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
    }

    // ==========================================================
    // STEP 5: Initialize Supabase client
    // ==========================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    // ==========================================================
    // STEP 6: Parse URL and route
    // ==========================================================
    const url = new URL(req.url);
    const method = req.method;
    const pathSegments = url.pathname.split('/').filter(s => s);

    const isStatsRequest = pathSegments.includes('stats');
    const isStatusRequest = pathSegments.includes('status');
    const isInvoicesRequest = pathSegments.includes('invoices');
    const isRecordPaymentRequest = pathSegments.includes('record-payment');
    const isNotifyRequest = pathSegments.includes('notify');
    const isClaimRequest = pathSegments.includes('claim');

    const lastSegment = pathSegments[pathSegments.length - 1];
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

    // For sub-resource routes: /contracts/{id}/status, /contracts/{id}/invoices, etc.
    let contractId: string | null = null;
    if (isStatusRequest || isInvoicesRequest || isNotifyRequest) {
      // ID is before the sub-resource segment
      for (let i = 0; i < pathSegments.length - 1; i++) {
        if (uuidRegex.test(pathSegments[i])) {
          contractId = pathSegments[i];
          break;
        }
      }
    } else {
      contractId = uuidRegex.test(lastSegment) && !isStatsRequest ? lastSegment : null;
    }

    // ==========================================================
    // STEP 7: Route to handler
    // ==========================================================
    let response: Response;

    switch (method) {
      case 'GET':
        if (isStatsRequest) {
          response = await handleGetStats(supabase, tenantId, isLive);
        } else if (isInvoicesRequest && contractId) {
          response = await handleGetInvoices(supabase, contractId, tenantId);
        } else if (contractId) {
          response = await handleGetById(supabase, contractId, tenantId);
        } else {
          response = await handleList(supabase, tenantId, isLive, url.searchParams);
        }
        break;

      case 'POST': {
        const createData = requestBody ? JSON.parse(requestBody) : await req.json();
        if (isNotifyRequest && contractId) {
          response = await handleSendNotification(supabase, contractId, createData, tenantId, isLive);
        } else if (isRecordPaymentRequest && isInvoicesRequest && contractId) {
          response = await handleRecordPayment(supabase, createData, contractId, tenantId, isLive, userId);
        } else if (isClaimRequest) {
          response = await handleClaimContract(supabase, createData, tenantId, userId);
        } else {
          response = await handleCreate(supabase, createData, tenantId, isLive, userId, idempotencyKey);
        }
        break;
      }

      case 'PUT': {
        if (!contractId) {
          response = jsonResponse({ success: false, error: 'Contract ID required for update', code: 'MISSING_ID' }, 400);
          break;
        }
        const updateData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleUpdate(supabase, contractId, updateData, tenantId, userId, idempotencyKey);
        break;
      }

      case 'PATCH': {
        if (!contractId || !isStatusRequest) {
          response = jsonResponse({ success: false, error: 'Contract ID required for status update', code: 'MISSING_ID' }, 400);
          break;
        }
        const statusData = requestBody ? JSON.parse(requestBody) : await req.json();
        response = await handleStatusUpdate(supabase, contractId, statusData, tenantId, userId);
        break;
      }

      case 'DELETE': {
        if (!contractId) {
          response = jsonResponse({ success: false, error: 'Contract ID required for deletion', code: 'MISSING_ID' }, 400);
          break;
        }
        const deleteData = requestBody ? JSON.parse(requestBody) : await req.json().catch(() => ({}));
        response = await handleDelete(supabase, contractId, deleteData, tenantId, userId);
        break;
      }

      default:
        response = jsonResponse({ success: false, error: 'Method not allowed', code: 'METHOD_NOT_ALLOWED' }, 405);
    }

    return response;

  } catch (error: any) {
    console.error('Error in contracts edge function:', error);
    return new Response(
      JSON.stringify({
        success: false,
        error: error.message || 'Internal server error',
        code: 'INTERNAL_ERROR'
      }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});


// ==========================================================
// HANDLER: GET list (paginated)
// Single RPC: get_contracts_list
// ==========================================================
async function handleList(
  supabase: any,
  tenantId: string,
  isLive: boolean,
  searchParams: URLSearchParams
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contracts_list', {
    p_tenant_id: tenantId,
    p_is_live: isLive,
    p_record_type: searchParams.get('record_type') || null,
    p_contract_type: searchParams.get('contract_type') || null,
    p_status: searchParams.get('status') || null,
    p_search: searchParams.get('search')?.trim() || null,
    p_page: parseInt(searchParams.get('page') || '1', 10),
    p_per_page: Math.min(parseInt(searchParams.get('per_page') || '20', 10), 100),
    p_sort_by: searchParams.get('sort_by') || 'created_at',
    p_sort_order: searchParams.get('sort_order') || 'desc'
  });

  if (error) {
    console.error('RPC get_contracts_list error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  // RPC returns { success, data, pagination, ... } — pass through
  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: GET by ID
// Single RPC: get_contract_by_id
// ==========================================================
async function handleGetById(
  supabase: any,
  contractId: string,
  tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_by_id', {
    p_contract_id: contractId,
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC get_contract_by_id error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 : (data?.error?.includes('not found') ? 404 : 400);
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: GET stats
// Single RPC: get_contract_stats
// ==========================================================
async function handleGetStats(
  supabase: any,
  tenantId: string,
  isLive: boolean
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_stats', {
    p_tenant_id: tenantId,
    p_is_live: isLive
  });

  if (error) {
    console.error('RPC get_contract_stats error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST create
// Single RPC: create_contract_transaction
// ==========================================================
async function handleCreate(
  supabase: any,
  body: any,
  tenantId: string,
  isLive: boolean,
  userId: string | null,
  idempotencyKey: string | null
): Promise<Response> {
  const payload = {
    ...body,
    tenant_id: tenantId,
    is_live: isLive,
    created_by: userId || body.created_by,
    performed_by_type: 'user',
    performed_by_name: body.performed_by_name || null
  };

  const { data, error } = await supabase.rpc('create_contract_transaction', {
    p_payload: payload,
    p_idempotency_key: idempotencyKey || null
  });

  if (error) {
    console.error('RPC create_contract_transaction error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: PUT update
// Single RPC: update_contract_transaction
// ==========================================================
async function handleUpdate(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null,
  idempotencyKey: string | null
): Promise<Response> {
  const payload = {
    ...body,
    tenant_id: tenantId,
    updated_by: userId || body.updated_by,
    performed_by_type: 'user',
    performed_by_name: body.performed_by_name || null
  };

  const { data, error } = await supabase.rpc('update_contract_transaction', {
    p_contract_id: contractId,
    p_payload: payload,
    p_idempotency_key: idempotencyKey || null
  });

  if (error) {
    console.error('RPC update_contract_transaction error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: PATCH status
// Single RPC: update_contract_status
// ==========================================================
async function handleStatusUpdate(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('update_contract_status', {
    p_contract_id: contractId,
    p_tenant_id: tenantId,
    p_new_status: body.status,
    p_performed_by_id: userId || body.performed_by_id || null,
    p_performed_by_name: body.performed_by_name || null,
    p_performed_by_type: body.performed_by_type || 'user',
    p_note: body.note || null,
    p_version: body.version || null
  });

  if (error) {
    console.error('RPC update_contract_status error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 :
    data?.error_code === 'INVALID_TRANSITION' ? 422 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: DELETE soft delete
// Single RPC: soft_delete_contract
// ==========================================================
async function handleDelete(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { data, error } = await supabase.rpc('soft_delete_contract', {
    p_contract_id: contractId,
    p_tenant_id: tenantId,
    p_performed_by_id: userId || body.performed_by_id || null,
    p_performed_by_name: body.performed_by_name || null,
    p_version: body.version || null,
    p_note: body.note || null
  });

  if (error) {
    console.error('RPC soft_delete_contract error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  const status = data?.success ? 200 :
    data?.error_code === 'DELETE_NOT_ALLOWED' ? 422 :
    data?.error_code === 'VERSION_CONFLICT' ? 409 : 400;
  return jsonResponse(data, status);
}


// ==========================================================
// HANDLER: GET invoices for a contract
// Single RPC: get_contract_invoices
// ==========================================================
async function handleGetInvoices(
  supabase: any,
  contractId: string,
  tenantId: string
): Promise<Response> {
  const { data, error } = await supabase.rpc('get_contract_invoices', {
    p_contract_id: contractId,
    p_tenant_id: tenantId
  });

  if (error) {
    console.error('RPC get_contract_invoices error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST record payment against invoice
// Single RPC: record_invoice_payment
// ==========================================================
async function handleRecordPayment(
  supabase: any,
  body: any,
  contractId: string,
  tenantId: string,
  isLive: boolean,
  userId: string | null
): Promise<Response> {
  const payload = {
    ...body,
    contract_id: contractId,
    tenant_id: tenantId,
    is_live: isLive,
    recorded_by: userId || body.recorded_by
  };

  const { data, error } = await supabase.rpc('record_invoice_payment', {
    p_payload: payload
  });

  if (error) {
    console.error('RPC record_invoice_payment error:', error);
    return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
  }

  return jsonResponse(data, data?.success ? 201 : 400);
}


// ==========================================================
// HANDLER: POST /contracts/{id}/notify
// Sends sign-off notification to buyer via email/WhatsApp
// Uses JTD framework for async delivery
// ==========================================================
async function handleSendNotification(
  supabase: any,
  contractId: string,
  body: any,
  tenantId: string,
  isLive: boolean
): Promise<Response> {
  try {
    // Step 1: Fetch full contract data to get buyer info + CNAK
    const { data: contractData, error: contractError } = await supabase.rpc('get_contract_by_id', {
      p_contract_id: contractId,
      p_tenant_id: tenantId
    });

    if (contractError || !contractData?.success || !contractData?.data) {
      return jsonResponse({ success: false, error: 'Contract not found', code: 'NOT_FOUND' }, 404);
    }

    const contract = contractData.data;
    const cnak = contract.global_access_id;

    if (!cnak) {
      return jsonResponse({ success: false, error: 'Contract has no CNAK — cannot send notification', code: 'VALIDATION_ERROR' }, 400);
    }

    // Step 2: Get secret_code from t_contract_access
    const { data: accessData } = await supabase
      .from('t_contract_access')
      .select('secret_code, accessor_email, accessor_name')
      .eq('global_access_id', cnak)
      .eq('is_active', true)
      .limit(1)
      .single();

    const secretCode = accessData?.secret_code || '';

    // Step 3: Get tenant profile for sender name
    const { data: tenantProfile } = await supabase
      .from('t_tenant_profiles')
      .select('business_name')
      .eq('tenant_id', tenantId)
      .limit(1)
      .single();

    const { data: tenant } = await supabase
      .from('t_tenants')
      .select('name')
      .eq('id', tenantId)
      .single();

    const senderName = tenantProfile?.business_name || tenant?.name || 'Your provider';

    // Step 4: Build review link
    const frontendUrl = Deno.env.get('FRONTEND_URL') || 'http://localhost:3000';
    const reviewLink = `${frontendUrl}/contracts/review?cnak=${encodeURIComponent(cnak)}&code=${encodeURIComponent(secretCode)}`;

    // Step 5: Determine recipient info
    // Priority: body overrides > contract buyer fields > access record > contact lookup
    let recipientName = body.recipient_name || contract.buyer_name || accessData?.accessor_name || 'there';
    let recipientEmail = body.recipient_email || contract.buyer_email || accessData?.accessor_email;
    let recipientMobile = body.recipient_mobile || contract.buyer_phone;

    console.log('[notify] buyer fields from contract:', JSON.stringify({
      buyer_id: contract.buyer_id,
      buyer_email: contract.buyer_email,
      buyer_phone: contract.buyer_phone,
      buyer_contact_person_id: contract.buyer_contact_person_id,
      contact_id: contract.contact_id,
      accessor_email: accessData?.accessor_email,
    }));
    console.log('[notify] after direct fields — email:', recipientEmail, 'mobile:', recipientMobile);

    // Fallback: look up email/phone from t_contact_channels
    // (t_contacts does NOT have email/phone columns — they're in t_contact_channels)
    if (!recipientEmail && !recipientMobile) {
      // Determine which contact ID to look up channels for
      // Contact persons are also t_contacts records (type='contact_person')
      const lookupId = contract.buyer_contact_person_id || contract.contact_id || contract.buyer_id;
      console.log('[notify] fallback lookupId:', lookupId);

      if (lookupId) {
        // Fetch email channel (use array + [0] instead of single() to handle 0 or multiple rows)
        const { data: emailChannels, error: emailErr } = await supabase
          .from('t_contact_channels')
          .select('value')
          .eq('contact_id', lookupId)
          .eq('channel_type', 'email')
          .order('is_primary', { ascending: false })
          .limit(1);

        const emailChannel = emailChannels?.[0];
        console.log('[notify] email channel query:', JSON.stringify({ data: emailChannel || null, error: emailErr?.message }));

        if (emailChannel?.value) {
          recipientEmail = emailChannel.value;
        }

        // Fetch mobile/whatsapp/phone channel (contacts may store numbers under different types)
        const { data: mobileChannels, error: mobileErr } = await supabase
          .from('t_contact_channels')
          .select('value, country_code, channel_type')
          .eq('contact_id', lookupId)
          .in('channel_type', ['mobile', 'whatsapp', 'phone'])
          .order('is_primary', { ascending: false })
          .limit(1);

        const mobileChannel = mobileChannels?.[0];
        console.log('[notify] mobile channel query:', JSON.stringify({ data: mobileChannel || null, error: mobileErr?.message }));

        if (mobileChannel?.value) {
          recipientMobile = mobileChannel.value;
        }

        // Get name from the contact record if we don't have one
        if (recipientName === 'there') {
          const { data: contactRecord } = await supabase
            .from('t_contacts')
            .select('name, company_name')
            .eq('id', lookupId)
            .single();

          if (contactRecord) {
            recipientName = contactRecord.name || contactRecord.company_name || 'there';
          }
        }
      }
    }

    console.log('[notify] final — email:', recipientEmail, 'mobile:', recipientMobile, 'name:', recipientName);

    if (!recipientEmail && !recipientMobile) {
      return jsonResponse({
        success: false,
        error: 'No buyer email or phone available — cannot send notification',
        code: 'VALIDATION_ERROR'
      }, 400);
    }

    // Step 6: Format contract value
    const currencySymbols: Record<string, string> = { USD: '$', EUR: '€', GBP: '£', INR: '₹', AED: 'AED ' };
    const symbol = currencySymbols[contract.currency || 'USD'] || (contract.currency + ' ');
    const grandTotal = contract.grand_total || contract.total_value || 0;
    const contractValue = `${symbol}${grandTotal.toLocaleString('en', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

    // Step 7: Create JTD entries via multi-channel integration
    const result = await sendContractSignoffNotification(supabase, {
      tenantId,
      contractId,
      recipientName,
      recipientEmail,
      recipientMobile,
      recipientCountryCode: body.recipient_country_code,
      senderName,
      contractTitle: contract.name || contract.title || 'Untitled Contract',
      contractNumber: contract.contract_number || '',
      contractValue,
      cnak,
      secretCode,
      reviewLink,
      isLive
    });

    const notifyResponse: any = {
      success: result.anySuccess,
      notification: {
        channels: result.channels,
        review_link: reviewLink,
        cnak
      }
    };
    if (!result.anySuccess) {
      notifyResponse.code = 'NOTIFICATION_FAILED';
    }
    return jsonResponse(notifyResponse, result.anySuccess ? 200 : 500);

  } catch (error) {
    console.error('handleSendNotification error:', error);
    return jsonResponse({
      success: false,
      error: error instanceof Error ? error.message : 'Failed to send notification',
      code: 'INTERNAL_ERROR'
    }, 500);
  }
}


// ==========================================================
// HANDLER: PUBLIC validate contract access
// Single RPC: validate_contract_access
// ==========================================================
async function handlePublicValidate(
  supabase: any,
  body: any
): Promise<Response> {
  const { cnak, secret_code } = body;

  if (!cnak || !secret_code) {
    return jsonResponse({ valid: false, error: 'CNAK and secret code are required' }, 400);
  }

  // Step 1: Validate access
  const { data, error } = await supabase.rpc('validate_contract_access', {
    p_cnak: cnak,
    p_secret_code: secret_code
  });

  if (error) {
    console.error('RPC validate_contract_access error:', error);
    return jsonResponse({ valid: false, error: error.message }, 500);
  }

  if (!data?.valid) {
    return jsonResponse(data, 200);
  }

  // Step 2: Fetch full contract data via existing get_contract_by_id RPC
  const contractId = data.contract?.id;
  const tenantId = data.tenant?.id;

  if (contractId && tenantId) {
    const { data: fullContract, error: fullError } = await supabase.rpc('get_contract_by_id', {
      p_contract_id: contractId,
      p_tenant_id: tenantId
    });

    if (!fullError && fullContract?.success && fullContract?.data) {
      // Replace the minimal contract with the full contract data
      data.contract = fullContract.data;
    }
  }

  return jsonResponse(data, 200);
}


// ==========================================================
// HANDLER: PUBLIC respond to contract
// Single RPC: respond_to_contract
// ==========================================================
async function handlePublicRespond(
  supabase: any,
  body: any
): Promise<Response> {
  const { cnak, secret_code, action, responded_by, responder_name, responder_email, rejection_reason } = body;

  if (!cnak || !secret_code || !action) {
    return jsonResponse({ success: false, error: 'CNAK, secret code, and action are required' }, 400);
  }

  if (!['accept', 'reject'].includes(action)) {
    return jsonResponse({ success: false, error: 'Action must be accept or reject' }, 400);
  }

  const { data, error } = await supabase.rpc('respond_to_contract', {
    p_cnak: cnak,
    p_secret_code: secret_code,
    p_action: action,
    p_responded_by: responded_by || null,
    p_responder_name: responder_name || null,
    p_responder_email: responder_email || null,
    p_rejection_reason: rejection_reason || null
  });

  if (error) {
    console.error('RPC respond_to_contract error:', error);
    return jsonResponse({ success: false, error: error.message }, 500);
  }

  return jsonResponse(data, data?.success ? 200 : 400);
}


// ==========================================================
// HANDLER: POST /contracts/claim
// Claim a contract using CNAK (authenticated)
// Single RPC: claim_contract_by_cnak
// ==========================================================
async function handleClaimContract(
  supabase: any,
  body: any,
  tenantId: string,
  userId: string | null
): Promise<Response> {
  const { cnak } = body;

  if (!cnak) {
    return jsonResponse({ success: false, error: 'CNAK is required', code: 'VALIDATION_ERROR' }, 400);
  }

  if (!tenantId) {
    return jsonResponse({ success: false, error: 'tenant_id is required', code: 'MISSING_TENANT_ID' }, 400);
  }

  try {
    const { data, error } = await supabase.rpc('claim_contract_by_cnak', {
      p_cnak: cnak,
      p_tenant_id: tenantId,
      p_user_id: userId || null
    });

    if (error) {
      console.error('RPC claim_contract_by_cnak error:', error);
      return jsonResponse({ success: false, error: error.message, code: 'RPC_ERROR' }, 500);
    }

    // RPC returns { success: true/false, ... }
    return jsonResponse(data, data?.success ? 200 : 400);
  } catch (err) {
    console.error('handleClaimContract error:', err);
    return jsonResponse({ success: false, error: 'Failed to claim contract', code: 'INTERNAL_ERROR' }, 500);
  }
}


// ==========================================================
// UTILITY: JSON Response helper
// ==========================================================
function jsonResponse(data: any, status: number = 200): Response {
  return new Response(
    JSON.stringify(data),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
  );
}


// ==========================================================
// UTILITY: HMAC signature verification (Deno Web Crypto)
// ==========================================================
async function verifyInternalSignature(
  body: string,
  signature: string,
  secret: string
): Promise<boolean> {
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
