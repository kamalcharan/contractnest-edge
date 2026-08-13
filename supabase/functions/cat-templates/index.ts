// supabase/functions/cat-templates/index.ts
// Catalog Studio - Templates Edge Function
// Version: 2.0 - With optimistic locking, pagination, idempotency, and replay protection

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import {
  corsHeaders,
  validateRequestSignature,
  parsePaginationParams,
  applyPagination,
  checkIdempotency,
  storeIdempotency,
  checkVersionConflict,
  createSuccessResponse,
  createErrorResponse,
  isValidUUID,
  generateOperationId,
  extractRequestContext,
  MAX_PAGE_SIZE,
  EdgeContext
} from "../_shared/edgeUtils.ts";

console.log('Cat-Templates Edge Function v2.0 - Starting up');

serve(async (req: Request) => {
  const startTime = Date.now();
  const operationId = generateOperationId('cat_templates');

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    // ========================================================================
    // STEP 1: Environment validation
    // ========================================================================
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    const internalSecret = Deno.env.get('INTERNAL_SIGNING_SECRET') || '';

    if (!supabaseUrl || !supabaseServiceKey) {
      return createErrorResponse('Missing required environment variables', 'CONFIGURATION_ERROR', 500, operationId);
    }

    // ========================================================================
    // STEP 2: Header validation
    // ========================================================================
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return createErrorResponse('Authorization header is required', 'MISSING_AUTH', 401, operationId);
    }

    const tenantIdHeader = req.headers.get('x-tenant-id');
    if (!tenantIdHeader) {
      return createErrorResponse('x-tenant-id header is required', 'MISSING_TENANT', 400, operationId);
    }

    if (!isValidUUID(tenantIdHeader)) {
      return createErrorResponse('Invalid tenant ID format', 'INVALID_TENANT_ID', 400, operationId);
    }

    // ========================================================================
    // STEP 3: Read body and validate signature
    // ========================================================================
    const requestBody = req.method !== 'GET' ? await req.text() : '';

    const signatureError = await validateRequestSignature(req, requestBody, internalSecret, operationId);
    if (signatureError) {
      return signatureError;
    }

    // ========================================================================
    // STEP 4: Extract context
    // ========================================================================
    const context = extractRequestContext(req, operationId, startTime);
    if (!context) {
      return createErrorResponse('Invalid request context', 'BAD_REQUEST', 400, operationId);
    }

    // ========================================================================
    // STEP 5: Create Supabase client
    // ========================================================================
    const supabase = createClient(supabaseUrl, supabaseServiceKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    });

    // ========================================================================
    // STEP 6: Parse URL and route
    // ========================================================================
    const url = new URL(req.url);
    const pathSegments = url.pathname.split('/').filter(Boolean);
    const lastSegment = pathSegments[pathSegments.length - 1];

    console.log(`[cat-templates] ${req.method} ${url.pathname}`, {
      operationId,
      tenantId: context.tenantId,
      isAdmin: context.isAdmin,
      isLive: context.isLive,
      hasIdempotencyKey: !!context.idempotencyKey,
      queryParams: Object.fromEntries(url.searchParams.entries())
    });

    // ========================================================================
    // STEP 7: Route to handlers
    // ========================================================================
    switch (req.method) {
      case 'GET':
        if (lastSegment === 'health') {
          return createSuccessResponse({
            status: 'ok',
            version: '2.0',
            message: 'Cat-Templates edge function is healthy',
            features: ['optimistic_locking', 'pagination', 'idempotency', 'replay_protection']
          }, operationId, startTime);
        }

        if (lastSegment === 'coverage') {
          return await handleGetCoverage(supabase, context);
        }

        if (lastSegment === 'plans') {
          return await handleGetPlanTemplates(supabase, url.searchParams, context);
        }

        if (lastSegment === 'packs') {
          return await handleGetPackTemplates(supabase, url.searchParams, context);
        }

        if (lastSegment === 'system') {
          return await handleGetSystemTemplates(supabase, url.searchParams, context);
        }

        if (lastSegment === 'public') {
          return await handleGetPublicTemplates(supabase, url.searchParams, context);
        }

        const templateId = url.searchParams.get('id');
        if (templateId) {
          return await handleGetTemplateById(supabase, templateId, context);
        }

        return await handleGetTemplates(supabase, url.searchParams, context);

      case 'POST':
        if (lastSegment === 'subscribe') {
          const subscribeIdempotency = await checkIdempotency(
            supabase, context.idempotencyKey, context.tenantId, operationId, startTime
          );
          if (subscribeIdempotency.found && subscribeIdempotency.response) {
            return subscribeIdempotency.response;
          }
          const subscribeBody = requestBody ? JSON.parse(requestBody) : {};
          return await handleSubscribeToPlan(supabase, subscribeBody, context);
        }

        // POST /templates/packs/purchase — checked on the segment pair, not
        // just the last one, so a future 'purchase' action under a different
        // parent never collides with this one.
        if (lastSegment === 'purchase' && pathSegments[pathSegments.length - 2] === 'packs') {
          const purchaseIdempotency = await checkIdempotency(
            supabase, context.idempotencyKey, context.tenantId, operationId, startTime
          );
          if (purchaseIdempotency.found && purchaseIdempotency.response) {
            return purchaseIdempotency.response;
          }
          const purchaseBody = requestBody ? JSON.parse(requestBody) : {};
          return await handlePurchasePack(supabase, purchaseBody, context);
        }

        if (lastSegment === 'copy') {
          const copyId = url.searchParams.get('id');
          if (!copyId) {
            return createErrorResponse('Template ID is required for copy', 'MISSING_ID', 400, operationId);
          }

          // Check idempotency for copy
          const copyIdempotency = await checkIdempotency(
            supabase, context.idempotencyKey, context.tenantId, operationId, startTime
          );
          if (copyIdempotency.found && copyIdempotency.response) {
            return copyIdempotency.response;
          }

          const copyBody = requestBody ? JSON.parse(requestBody) : {};
          return await handleCopyTemplate(supabase, copyId, copyBody, context);
        }

        // Check idempotency for create
        const createIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (createIdempotency.found && createIdempotency.response) {
          return createIdempotency.response;
        }

        const createBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleCreateTemplate(supabase, createBody, context);

      case 'PATCH':
        const updateId = url.searchParams.get('id');
        if (!updateId) {
          return createErrorResponse('Template ID is required for update', 'MISSING_ID', 400, operationId);
        }

        // Check idempotency
        const updateIdempotency = await checkIdempotency(
          supabase, context.idempotencyKey, context.tenantId, operationId, startTime
        );
        if (updateIdempotency.found && updateIdempotency.response) {
          return updateIdempotency.response;
        }

        const updateBody = requestBody ? JSON.parse(requestBody) : {};
        return await handleUpdateTemplate(supabase, updateId, updateBody, context);

      case 'DELETE':
        const deleteId = url.searchParams.get('id');
        if (!deleteId) {
          return createErrorResponse('Template ID is required for delete', 'MISSING_ID', 400, operationId);
        }
        return await handleDeleteTemplate(supabase, deleteId, context);

      default:
        return createErrorResponse(`Method ${req.method} not allowed`, 'METHOD_NOT_ALLOWED', 405, operationId);
    }

  } catch (error: any) {
    console.error('[cat-templates] Unhandled error:', error);
    return createErrorResponse(error.message, 'INTERNAL_ERROR', 500, operationId);
  }
});

// ============================================================================
// HANDLER: POST /cat-templates/subscribe
//
// Tenant self-service subscription. The SUBSCRIBER is always the calling
// tenant — taken from the request context, never from the body — so one
// tenant cannot subscribe another by posting someone else's id.
//
// Everything else happens inside subscribe_tenant_to_plan: the contact is
// created in the platform tenant's book with source_tenant_id set, the plan
// contract is raised under the platform tenant, and the plan's metering is
// applied to this tenant's t_tenant_context. One transaction, so a failure
// part-way cannot leave a contact without a contract or a contract without
// entitlements.
// ============================================================================
async function handleSubscribeToPlan(
  supabase: any,
  body: any,
  ctx: EdgeContext
) {
  const templateId = body?.template_id;

  if (!templateId || !isValidUUID(templateId)) {
    return createErrorResponse('template_id is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }

  // No is_live argument by design. ContractNest's own commercial model is
  // ALWAYS live: a tenant playing in its test environment still has exactly
  // one real subscription, billed for real. Scoping it by ctx.isLive gave a
  // tenant a separate phantom plan per environment.
  const { data, error } = await supabase.rpc('subscribe_tenant_to_plan', {
    p_template_id: templateId,
    p_subscriber_tenant_id: ctx.tenantId,
    p_user_id: ctx.userId || null,
  });

  if (error) {
    console.error('[cat-templates] subscribe RPC error:', error);
    return createErrorResponse(error.message, 'RPC_ERROR', 500, ctx.operationId);
  }

  if (!data?.success) {
    // 409 for "you already have a plan" — it is a state conflict, not a bad
    // request, and the UI shows it differently.
    const status = data?.error_code === 'ALREADY_SUBSCRIBED' ? 409 : 400;
    return createErrorResponse(
      data?.error || 'Subscription failed',
      data?.error_code || 'SUBSCRIBE_FAILED',
      status,
      ctx.operationId
    );
  }

  return createSuccessResponse(data, ctx.operationId, ctx.startTime);
}


// ============================================================================
// HANDLER: GET /cat-templates/plans
//
// The plan catalogue every OTHER tenant buys from. ContractNest's own
// commercial model is authored as ordinary contract templates owned by the
// platform tenant; this is the single endpoint that serves them across the
// tenant boundary, and it is deliberately read-only.
//
// The platform tenant is resolved by its is_admin FLAG, never a hardcoded
// uuid — that differs per environment and would rot.
//
// Why not reuse /system: system templates are `tenant_id IS NULL`, and
// handleGetTemplates already matches those, so publishing the plans that way
// would drop "Free", "Quarterly" and the rest into every tenant's own
// Templates hub alongside their contract templates — the same cross-tenant
// bleed as the is_admin bypass fixed above. The plans therefore stay owned by
// the platform tenant and are served only here.
// ============================================================================
async function handleGetPlanTemplates(
  supabase: any,
  _params: URLSearchParams,
  ctx: EdgeContext
) {
  const { data: platform, error: platformErr } = await supabase
    .from('t_tenants')
    .select('id')
    .eq('is_admin', true)
    .limit(1)
    .maybeSingle();

  if (platformErr) {
    console.error('[cat-templates] plans: platform tenant lookup failed:', platformErr);
    return createErrorResponse(platformErr.message, platformErr.code || 'QUERY_ERROR', 500, ctx.operationId);
  }
  if (!platform) {
    // No platform tenant configured — an empty catalogue, not an error.
    return createSuccessResponse({ plans: [], count: 0 }, ctx.operationId, ctx.startTime);
  }

  const buildQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('id, name, display_name, description, category, tags, blocks, currency, subtotal, total, settings, is_live, sequence_no, created_at, updated_at')
      .eq('tenant_id', platform.id)
      .eq('is_active', true)
      // Exclude packs AND wallet top-ups. Nothing about a plan's own
      // category is enforced here (plans predate this constant and are not
      // tagged consistently), but neither of these must ever render as a
      // plan card — a pack has no limits and its one_time grant would be
      // mislabeled as a per-creation rate; a wallet top-up has no metering
      // at all and would render as a plan with nothing in it. 'per_contract'
      // IS meant to render here — it is a billing mode, displayed alongside
      // the capped plans, just with no price/term/cap of its own.
      .not('category', 'in', '("topup_pack","wallet_topup")')
      // ALWAYS live, never ctx.isLive. The plan catalogue is ContractNest's
      // own commercial model, which exists once — a tenant switching to its
      // test environment is still on the same real plan and must see the same
      // prices, not a parallel test catalogue.
      .eq('is_live', true)
      // Published only. Lifecycle lives in settings.lifecycle ('draft' until
      // signed_off); without this a half-built plan would be purchasable.
      .eq('settings->>lifecycle', 'signed_off')
      // AND listed for sale. Two separate gates on purpose: a plan can be
      // published (usable to create contracts) while not yet offered on the
      // price list — drafting Quarterly's pricing while Free stays the only
      // thing a tenant can buy. subscribe_tenant_to_plan enforces the same
      // pair, so an unlisted plan cannot be bought by guessing its id.
      .eq('is_public', true);

    if (withLatest) q = q.eq('is_latest', true);
    // sequence_no, not total — Per Contract's total is 0 (nothing is paid
    // upfront), which would tie it with Free under a price sort and put it
    // second instead of last. sequence_no is the author's explicit display
    // order, and happens to already match ascending price for the three
    // capped plans, so this changes nothing for them.
    return q.order('sequence_no', { ascending: true });
  };

  let { data, error } = await buildQuery(true);
  if (error) {
    console.warn('[cat-templates] plans: retrying without is_latest:', error.message);
    ({ data, error } = await buildQuery(false));
  }

  if (error) {
    console.error('[cat-templates] plans query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Everything a plan card needs is derived HERE, from the template's own
  // self-contained blocks snapshot, so the buying tenant never has to read the
  // platform tenant's block rows — which it has no right to.
  // Which plan is this tenant already on? The subscription is found through
  // the contact's source_tenant_id — the same link subscribe_tenant_to_plan
  // uses for its ALREADY_SUBSCRIBED guard, so the page and the server can
  // never disagree about who is subscribed to what.
  //
  // Without this the page rendered "Subscribe" on every card and the tenant
  // only discovered they were already subscribed by clicking and getting a
  // 409 — a refusal doing the job a badge should have done.
  let currentPlanTemplateId: string | null = null;
  let currentContractNumber: string | null = null;

  // Two lookups rather than an embedded join: there is NO foreign key between
  // t_contracts.buyer_id and t_contacts.id, so PostgREST cannot infer the
  // relationship and a `t_contacts!inner(...)` embed fails at runtime — which
  // would take this whole page down, not just the badge.
  const { data: planContact } = await supabase
    .from('t_contacts')
    .select('id')
    .eq('tenant_id', platform.id)
    .eq('is_live', true)
    .eq('source_tenant_id', ctx.tenantId)
    .limit(1)
    .maybeSingle();

  if (planContact?.id) {
    const { data: activeSub } = await supabase
      .from('t_contracts')
      .select('contract_number, metadata')
      .eq('tenant_id', platform.id)
      .eq('is_live', true)
      .eq('record_type', 'contract')
      .eq('buyer_id', planContact.id)
      .in('status', ['active', 'pending_acceptance'])
      .limit(1)
      .maybeSingle();

    if (activeSub) {
      currentContractNumber = activeSub.contract_number ?? null;
      currentPlanTemplateId = activeSub.metadata?.plan_template_id ?? null;
    }
  }

  const plans = (data || []).map((t: any) => {
    const defaults = t.settings?.defaults || {};
    const blocks: any[] = Array.isArray(t.blocks) ? t.blocks : [];

    const limits: Record<string, number> = {};
    const grants: Record<string, number> = {};
    // Paise per creation, keyed the same as limits ('contracts'/'rfqs') — only
    // ever populated for the 'per_contract' category template. trg_fn_wallet_
    // charge reads the SAME block, live, from the database — this is not a
    // parallel copy of the rate, it is the one place both the charge and the
    // display read from.
    const rates: Record<string, number> = {};
    const flags: string[] = [];

    for (const b of blocks) {
      const m = b?.config_overrides?.config?.metering;
      if (!m) continue;
      if (m.mode === 'limit' && m.limits) Object.assign(limits, m.limits);
      if ((m.mode === 'per_creation' || m.mode === 'one_time') && m.grants) Object.assign(grants, m.grants);
      if (m.mode === 'per_creation_charge' && m.rates) Object.assign(rates, m.rates);
      if (m.mode === 'flag' && m.flag) flags.push(m.flag);
    }

    // How the price is actually collected — from the priced billing block's
    // own cadence, so "₹23,996 / 12 months" can render as what it really is:
    // 4 payments of ₹5,999, billed quarterly. A cadenced block (billing_cycle
    // other than 'prepaid') wins over a prepaid one; a plan with only prepaid
    // pricing is a single upfront payment of the template total.
    let billing: { cycle: string; installment_amount: number; installments: number } | null = null;
    for (const b of blocks) {
      const co = b?.config_overrides || {};
      const price = Number(co.unit_price ?? 0);
      if (price <= 0) continue;
      const cycle = co.billing_cycle || 'prepaid';
      if (cycle !== 'prepaid') {
        billing = { cycle, installment_amount: price, installments: Number(co.quantity ?? 1) || 1 };
        break;
      }
      if (!billing) {
        billing = { cycle: 'prepaid', installment_amount: Number(t.total ?? 0), installments: 1 };
      }
    }

    return {
      id: t.id,
      name: t.display_name || t.name,
      description: t.description,
      // Only 'per_contract' is acted on by the UI today (a distinct, no-cap
      // card) — returned generically rather than a one-off boolean so a
      // future distinct category doesn't need another field bolted on.
      category: t.category,
      currency: t.currency || 'INR',
      price: Number(t.total ?? 0),
      term: { value: defaults.duration_value ?? null, unit: defaults.duration_unit ?? null },
      billing,
      limits,
      grants,
      rates,
      flags,
      updated_at: t.updated_at,
    };
  });

  // B6 — can the platform actually TAKE money for these plans?
  //
  // Returned with the catalogue rather than fetched separately, for two
  // reasons: it is the same platform tenant this handler already resolved
  // (no second round trip), and a capability that arrives with the plan list
  // cannot drift out of step with the plans it applies to.
  //
  // Without this the only way to discover an unconfigured seller was to
  // subscribe, raise a real contract and invoice, and THEN fail at checkout
  // — leaving the buyer holding an invoice nobody could collect on. The page
  // now checks first and offers "you have been notified" instead.
  const seller = await sellerCapability(supabase, platform.id);

  return createSuccessResponse({
    plans,
    count: plans.length,
    current_plan_id: currentPlanTemplateId,
    current_contract_number: currentContractNumber,
    seller,
  }, ctx.operationId, ctx.startTime);
}


// Shared by /plans and /packs — both sell on the platform tenant's behalf,
// so both need the same answer. A failure here must NOT fail the catalogue:
// an unknown capability degrades to "cannot collect", which shows the
// notified-you path rather than a broken page or, worse, a checkout that
// dies at the last step.
async function sellerCapability(supabase: any, platformTenantId: string) {
  const { data, error } = await supabase.rpc('can_collect_payment', {
    p_tenant_id: platformTenantId,
  });

  if (error || !data?.success) {
    console.error('[cat-templates] can_collect_payment failed:', error?.message || data?.error);
    return { name: null, can_collect: false, online: false, offline_upi: false };
  }

  return {
    name: data.tenant_name ?? null,
    can_collect: !!data.can_collect,
    online: !!data.online,
    offline_upi: !!data.offline_upi,
  };
}


// ============================================================================
// HANDLER: GET /cat-templates/packs
//
// The pack catalogue every tenant can buy from — same platform-tenant
// template shape as /plans, filtered to category IN ('topup_pack',
// 'wallet_topup') so neither ever gets listed as a plan or vice versa.
// purchase_topup_template itself re-derives what a template actually is —
// a one_time grant for a credit pack, the template's own price for a wallet
// top-up — independently of this category tag; the tag is what makes
// LISTING cheap, not what makes a purchase safe.
//
// Two different things ride this one endpoint on purpose, reusing the same
// route/RPC/UI section rather than building a parallel pipe for each:
//   'topup_pack'    -> grants notification credits once (one_time block)
//   'wallet_topup'  -> the template's OWN PRICE is credited to the wallet
//                      on payment; no metering block at all
// ============================================================================
async function handleGetPackTemplates(
  supabase: any,
  _params: URLSearchParams,
  ctx: EdgeContext
) {
  const { data: platform, error: platformErr } = await supabase
    .from('t_tenants')
    .select('id')
    .eq('is_admin', true)
    .limit(1)
    .maybeSingle();

  if (platformErr) {
    console.error('[cat-templates] packs: platform tenant lookup failed:', platformErr);
    return createErrorResponse(platformErr.message, platformErr.code || 'QUERY_ERROR', 500, ctx.operationId);
  }
  if (!platform) {
    return createSuccessResponse({ packs: [], count: 0 }, ctx.operationId, ctx.startTime);
  }

  const buildQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('id, name, display_name, description, category, blocks, currency, total, settings, is_live, updated_at')
      .eq('tenant_id', platform.id)
      .in('category', ['topup_pack', 'wallet_topup'])
      .eq('is_active', true)
      .eq('is_live', true)
      .eq('settings->>lifecycle', 'signed_off')
      .eq('is_public', true);

    if (withLatest) q = q.eq('is_latest', true);
    return q.order('total', { ascending: true });
  };

  let { data, error } = await buildQuery(true);
  if (error) {
    console.warn('[cat-templates] packs: retrying without is_latest:', error.message);
    ({ data, error } = await buildQuery(false));
  }

  if (error) {
    console.error('[cat-templates] packs query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Everything a pack card needs, derived from the template's own blocks
  // snapshot — same reasoning as /plans: the buying tenant never reads the
  // platform tenant's block rows directly.
  const packs = (data || [])
    .map((t: any) => {
      const isWalletTopup = t.category === 'wallet_topup';
      const blocks: any[] = Array.isArray(t.blocks) ? t.blocks : [];
      const grants: Record<string, number> = {};
      const flags: string[] = [];
      for (const b of blocks) {
        const m = b?.config_overrides?.config?.metering;
        if (m?.mode === 'one_time' && m.grants) Object.assign(grants, m.grants);
        if (m?.mode === 'flag' && m.flag) flags.push(m.flag);
      }
      return {
        id: t.id,
        name: t.display_name || t.name,
        description: t.description,
        currency: t.currency || 'INR',
        price: Number(t.total ?? 0),
        grants,
        // Addon flags this pack unlocks (e.g. addon_extend_website) — the
        // Extend touchpoint packs grant one of these instead of a credit
        // count, so they carry no `grants` entry at all.
        flags,
        // Only set for wallet_topup templates — the amount credited to the
        // wallet on payment. Paise, matching t_tenant_context.wallet_balance_paise.
        wallet_paise: isWalletTopup ? Math.round(Number(t.total ?? 0) * 100) : 0,
        updated_at: t.updated_at,
      };
    })
    // A pack with no one_time grant, no flag, and no wallet credit is
    // mis-authored (missing its metering block) — dropped rather than shown
    // as an empty pack. A wallet top-up has no grants/flags by design, so it
    // survives on wallet_paise alone.
    .filter((p: any) => Object.keys(p.grants).length > 0 || p.flags.length > 0 || p.wallet_paise > 0);

  return createSuccessResponse({
    packs,
    count: packs.length,
    // Same capability as /plans — a wallet top-up is a purchase too, and the
    // Pay-as-you-go card now buys one directly (B7), so it needs to know
    // whether that purchase can complete before offering the button.
    seller: await sellerCapability(supabase, platform.id),
  }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: POST /cat-templates/packs/purchase
//
// Buys the calling tenant a credit pack. Mirrors handleSubscribeToPlan: the
// buyer is always the calling tenant from the request context, never the
// body, so a tenant cannot buy a pack for someone else. All of the actual
// work — raising the contract, snapshotting the grants, waiting for payment
// — lives in purchase_topup_template.
// ============================================================================
async function handlePurchasePack(
  supabase: any,
  body: any,
  ctx: EdgeContext
) {
  const templateId = body?.template_id;

  if (!templateId || !isValidUUID(templateId)) {
    return createErrorResponse('template_id is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }

  const { data, error } = await supabase.rpc('purchase_topup_template', {
    p_template_id: templateId,
    p_buyer_tenant_id: ctx.tenantId,
    p_user_id: ctx.userId || null,
  });

  if (error) {
    console.error('[cat-templates] purchase pack RPC error:', error);
    return createErrorResponse(error.message, 'RPC_ERROR', 500, ctx.operationId);
  }

  if (!data?.success) {
    return createErrorResponse(
      data?.error || 'Purchase failed',
      data?.error_code || 'PURCHASE_FAILED',
      400,
      ctx.operationId
    );
  }

  return createSuccessResponse(data, ctx.operationId, ctx.startTime);
}


// ============================================================================
// HANDLER: GET /cat-templates - List templates with pagination
// ============================================================================
async function handleGetTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  // Filter params — declared at HANDLER scope (not inside the query builder)
  // because the response payload below references them too. Declaring them
  // inside the closure caused a ReferenceError -> 500 on every list call.
  const category = params.get('category');
  const isSystem = params.get('is_system');
  const search = params.get('search');
  const isActiveParam = params.get('is_active');

  // Build base query — try with is_latest first; fallback without if column missing
  const buildListQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' });

    // is_active: 'true' (default) | 'false' | 'all'
    if (isActiveParam === 'false') {
      q = q.eq('is_active', false);
    } else if (isActiveParam === 'all') {
      // No filter — return active and inactive (client filters/restores)
    } else {
      q = q.eq('is_active', true);
    }

    if (withLatest) q = q.eq('is_latest', true);

    // Visibility filter.
    //
    // The platform tenant is a TENANT like any other — it authors and owns its
    // own templates. Being is_admin must not silently widen this list to every
    // tenant's templates: that is a cross-tenant leak, and it made the platform
    // tenant's own Templates hub show BBB's and hubb's records as if they were
    // its own. Admin now has to ASK for the cross-tenant view via
    // ?all_tenants=true, rather than getting it by default.
    // (Same fix as cat-blocks, which had this bug identically.)
    const allTenantsView = ctx.isAdmin && params.get('all_tenants') === 'true';
    if (!allTenantsView) {
      q = q.or(`tenant_id.eq.${ctx.tenantId},and(tenant_id.is.null,is_system.eq.true)`);
      q = q.or(`is_live.eq.${ctx.isLive},tenant_id.is.null`);
    }

    // Filters
    if (category) q = q.eq('category', category);
    if (isSystem !== null) q = q.eq('is_system', isSystem === 'true');
    if (search) q = q.ilike('name', `%${search}%`);

    // Order
    q = q.order('sequence_no', { ascending: true }).order('name', { ascending: true });

    return applyPagination(q, pagination, MAX_PAGE_SIZE);
  };

  let result = await buildListQuery(true);
  if (result.error) {
    console.warn('[cat-templates] List query failed, retrying without is_latest:', result.error.message);
    result = await buildListQuery(false);
  }

  const { data, error, count } = result;

  if (error) {
    console.error('[cat-templates] Query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Separate templates
  const ownTemplates = (data || []).filter((t: any) => t.tenant_id === ctx.tenantId);
  const systemTemplates = (data || []).filter((t: any) => t.tenant_id === null && t.is_system);

  const responseData: any = {
    templates: data || [],
    own_templates: ownTemplates,
    system_templates: systemTemplates,
    count: data?.length || 0,
    filters: { category, is_system: isSystem, search, is_live: ctx.isLive }
  };

  if (pagination) {
    responseData.pagination = {
      page: pagination.page,
      limit: pagination.limit,
      total: count || 0,
      has_more: pagination.offset + pagination.limit < (count || 0)
    };
  }

  return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: GET /cat-templates/system - System templates with pagination
// Industry filtering is done in JS to avoid PostgREST jsonb containment issues.
// ============================================================================
async function handleGetSystemTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const industryTag = params.get('industry');
  const pagination = parsePaginationParams(params);

  const buildSystemQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' })
      .is('tenant_id', null)
      .eq('is_system', true);

    const isActiveParam = params.get('is_active');
    if (isActiveParam === 'false') {
      q = q.eq('is_active', false);
    } else if (isActiveParam === 'all') {
      // No filter — return both active and inactive
    } else {
      q = q.eq('is_active', true);
    }

    if (withLatest) q = q.eq('is_latest', true);

    const category = params.get('category');
    if (category) q = q.eq('category', category);

    const search = params.get('search');
    if (search) q = q.ilike('name', `%${search}%`);

    q = q.order('sequence_no', { ascending: true }).order('name', { ascending: true });

    if (!industryTag) {
      return applyPagination(q, pagination, MAX_PAGE_SIZE);
    }
    return q;
  };

  let result = await buildSystemQuery(true);
  if (result.error) {
    console.warn('[cat-templates] First query failed, retrying without is_latest:', result.error.message);
    result = await buildSystemQuery(false);
  }

  let { data, error, count } = result;

  if (error) {
    console.error('[cat-templates] System query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  let templates = data || [];

  if (industryTag) {
    templates = templates.filter((t: any) =>
      Array.isArray(t.industry_tags) && t.industry_tags.includes(industryTag)
    );
  }

  const total = templates.length;

  if (industryTag && pagination) {
    templates = templates.slice(pagination.offset, pagination.offset + pagination.limit);
  }

  const responseData: any = {
    templates,
    count: templates.length,
    type: 'system'
  };

  if (pagination) {
    responseData.pagination = {
      page: pagination.page,
      limit: pagination.limit,
      total: industryTag ? total : (count || 0),
      has_more: industryTag
        ? (pagination.offset + pagination.limit < total)
        : (pagination.offset + pagination.limit < (count || 0))
    };
  }

  return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: GET /cat-templates/coverage - Template coverage statistics
// Joins t_cat_templates (system) with m_catalog_industries to produce
// per-industry counts, overall stats, and uncovered industries list.
// ============================================================================
async function handleGetCoverage(
  supabase: any,
  ctx: EdgeContext
) {
  try {
    // 1. Fetch all active system templates
    let tplResult = await supabase
      .from('t_cat_templates')
      .select('id, name, display_name, category, industry_tags, tags, is_public, status_id, blocks, created_at, updated_at')
      .is('tenant_id', null)
      .eq('is_system', true)
      .eq('is_active', true)
      .eq('is_latest', true);

    if (tplResult.error) {
      console.warn('[cat-templates] Coverage: retrying without is_latest:', tplResult.error.message);
      tplResult = await supabase
        .from('t_cat_templates')
        .select('id, name, display_name, category, industry_tags, tags, is_public, status_id, blocks, created_at, updated_at')
        .is('tenant_id', null)
        .eq('is_system', true)
        .eq('is_active', true);
    }

    const { data: templates, error: tplErr } = tplResult;

    if (tplErr) {
      console.error('[cat-templates] Coverage templates query error:', tplErr);
      return createErrorResponse(tplErr.message, tplErr.code || 'QUERY_ERROR', 500, ctx.operationId);
    }

    // 2. Fetch all level-0 industries (parent segments)
    const { data: industries, error: indErr } = await supabase
      .from('m_catalog_industries')
      .select('id, name, icon, description, sort_order, is_active')
      .eq('level', 0)
      .eq('is_active', true)
      .order('sort_order', { ascending: true });

    if (indErr) {
      console.error('[cat-templates] Coverage industries query error:', indErr);
      return createErrorResponse(indErr.message, indErr.code || 'QUERY_ERROR', 500, ctx.operationId);
    }

    const allTemplates = templates || [];
    const allIndustries = industries || [];

    // 3. Build per-industry coverage map
    const industryMap: Record<string, number> = {};
    for (const tpl of allTemplates) {
      const tags: string[] = tpl.industry_tags || [];
      for (const tag of tags) {
        industryMap[tag] = (industryMap[tag] || 0) + 1;
      }
    }

    // 4. Build industry coverage array
    const industryCoverage = allIndustries.map((ind: any) => ({
      id: ind.id,
      name: ind.name,
      icon: ind.icon || null,
      description: ind.description || null,
      templateCount: industryMap[ind.id] || 0,
      hasCoverage: (industryMap[ind.id] || 0) > 0,
    }));

    // 5. Compute summary stats
    const coveredIndustries = industryCoverage.filter((i: any) => i.hasCoverage);
    const uncoveredIndustries = industryCoverage.filter((i: any) => !i.hasCoverage);

    // 6. Count unique categories
    const categories = new Set(allTemplates.map((t: any) => t.category).filter(Boolean));

    const responseData = {
      summary: {
        totalTemplates: allTemplates.length,
        totalIndustries: allIndustries.length,
        coveredIndustries: coveredIndustries.length,
        uncoveredIndustries: uncoveredIndustries.length,
        coveragePercent: allIndustries.length > 0
          ? Math.round((coveredIndustries.length / allIndustries.length) * 100)
          : 0,
        totalCategories: categories.size,
        publicTemplates: allTemplates.filter((t: any) => t.is_public).length,
      },
      industries: industryCoverage,
      uncovered: uncoveredIndustries.map((i: any) => ({ id: i.id, name: i.name, icon: i.icon })),
    };

    return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
  } catch (error: any) {
    console.error('[cat-templates] Coverage handler error:', error);
    return createErrorResponse(error.message, 'COVERAGE_ERROR', 500, ctx.operationId);
  }
}

// ============================================================================
// HANDLER: GET /cat-templates/public - Public templates with pagination
// ============================================================================
async function handleGetPublicTemplates(
  supabase: any,
  params: URLSearchParams,
  ctx: EdgeContext
) {
  const pagination = parsePaginationParams(params);

  const buildPublicQuery = (withLatest: boolean) => {
    let q = supabase
      .from('t_cat_templates')
      .select('*', { count: 'exact' })
      .eq('is_public', true)
      .eq('is_active', true);

    if (withLatest) q = q.eq('is_latest', true);

    const category = params.get('category');
    if (category) q = q.eq('category', category);

    const search = params.get('search');
    if (search) q = q.ilike('name', `%${search}%`);

    q = q.order('sequence_no', { ascending: true });
    return applyPagination(q, pagination, MAX_PAGE_SIZE);
  };

  let result = await buildPublicQuery(true);
  if (result.error) {
    console.warn('[cat-templates] Public query failed, retrying without is_latest:', result.error.message);
    result = await buildPublicQuery(false);
  }

  const { data, error, count } = result;

  if (error) {
    console.error('[cat-templates] Public query error:', error);
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  const responseData: any = {
    templates: data || [],
    count: data?.length || 0,
    type: 'public'
  };

  if (pagination) {
    responseData.pagination = {
      page: pagination.page,
      limit: pagination.limit,
      total: count || 0,
      has_more: pagination.offset + pagination.limit < (count || 0)
    };
  }

  return createSuccessResponse(responseData, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: GET /cat-templates?id={id}
// ============================================================================
async function handleGetTemplateById(
  supabase: any,
  templateId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  const { data, error } = await supabase
    .from('t_cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (error) {
    if (error.code === 'PGRST116') {
      return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
    }
    return createErrorResponse(error.message, error.code || 'QUERY_ERROR', 500, ctx.operationId);
  }

  // Access check
  if (!ctx.isAdmin) {
    const isOwner = data.tenant_id === ctx.tenantId;
    const isSystemTemplate = data.tenant_id === null && data.is_system;
    const isPublic = data.is_public;

    if (!isOwner && !isSystemTemplate && !isPublic) {
      return createErrorResponse('Access denied to this template', 'FORBIDDEN', 403, ctx.operationId);
    }
  }

  return createSuccessResponse({ template: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: POST /cat-templates - Create with idempotency
// ============================================================================
async function handleCreateTemplate(
  supabase: any,
  body: any,
  ctx: EdgeContext
) {
  if (!body.name) {
    return createErrorResponse('Template name is required', 'VALIDATION_ERROR', 400, ctx.operationId);
  }

  // Determine tenant_id
  let templateTenantId: string | null = ctx.tenantId;
  if (ctx.isAdmin && body.is_system === true) {
    templateTenantId = null;
  }

  const insertData = {
    tenant_id: templateTenantId,
    is_live: templateTenantId === null ? true : ctx.isLive,
    name: body.name,
    display_name: body.display_name || body.name,
    description: body.description || null,
    category: body.category || null,
    tags: body.tags || [],
    cover_image: body.cover_image || null,
    blocks: body.blocks || [],
    currency: body.currency || 'INR',
    tax_rate: body.tax_rate ?? null,
    discount_config: body.discount_config || { allowed: true, max_percent: 20 },
    subtotal: body.subtotal || null,
    total: body.total || null,
    settings: body.settings || {},
    is_system: ctx.isAdmin && body.is_system === true,
    copied_from_id: null,
    industry_tags: body.industry_tags || [],
    is_public: body.is_public ?? false,
    is_active: body.is_active ?? true,
    status_id: body.status_id || null,
    sequence_no: body.sequence_no || 0,
    is_deletable: body.is_deletable ?? true,
    created_by: body.created_by || null,
    updated_by: body.created_by || null,
    is_latest: true,
    parent_template_id: null  // Will be set to own id after insert
  };

  const { data, error } = await supabase
    .from('t_cat_templates')
    .insert(insertData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Create error:', error);
    return createErrorResponse(error.message, error.code || 'CREATE_ERROR', 500, ctx.operationId);
  }

  // Set parent_template_id to own id (first version points to itself)
  if (data && !data.parent_template_id) {
    await supabase
      .from('t_cat_templates')
      .update({ parent_template_id: data.id })
      .eq('id', data.id);
    data.parent_template_id = data.id;
  }

  console.log(`[cat-templates] Created template: ${data.id} (tenant: ${templateTenantId || 'SYSTEM'})`);

  const responseBody = {
    success: true,
    data: { template: data },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return new Response(JSON.stringify(responseBody), {
    status: 201,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// ============================================================================
// HANDLER: POST /cat-templates/copy - Copy with idempotency
// ============================================================================
async function handleCopyTemplate(
  supabase: any,
  templateId: string,
  body: any,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Get source template
  const { data: source, error: sourceError } = await supabase
    .from('t_cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (sourceError || !source) {
    return createErrorResponse('Source template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!source.is_system && source.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Can only copy system templates or your own templates', 'FORBIDDEN', 403, ctx.operationId);
  }

  // Create copy
  const copyData = {
    tenant_id: ctx.tenantId,
    is_live: ctx.isLive,
    name: body.name || `${source.name} (Copy)`,
    display_name: body.display_name || source.display_name,
    description: source.description,
    category: source.category,
    tags: source.tags,
    cover_image: source.cover_image,
    blocks: source.blocks,
    currency: source.currency,
    tax_rate: source.tax_rate,
    discount_config: source.discount_config,
    subtotal: source.subtotal,
    total: source.total,
    // Copies start their own life as drafts (sign-off is per template)
    settings: { ...(source.settings || {}), lifecycle: 'draft' },
    is_system: false,
    copied_from_id: templateId,
    industry_tags: source.industry_tags,
    is_public: false,
    is_active: true,
    status_id: source.status_id,
    sequence_no: 0,
    is_deletable: true,
    created_by: body.created_by || null,
    is_latest: true,
    parent_template_id: null  // Will be set to own id after insert
  };

  const { data, error } = await supabase
    .from('t_cat_templates')
    .insert(copyData)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] Copy error:', error);
    return createErrorResponse(error.message, error.code || 'COPY_ERROR', 500, ctx.operationId);
  }

  // Set parent_template_id to own id (new copy is first version of a new chain)
  if (data && !data.parent_template_id) {
    await supabase
      .from('t_cat_templates')
      .update({ parent_template_id: data.id })
      .eq('id', data.id);
    data.parent_template_id = data.id;
  }

  console.log(`[cat-templates] Copied template ${templateId} to ${data.id}`);

  const responseBody = {
    success: true,
    data: { template: data, copied_from: templateId },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return new Response(JSON.stringify(responseBody), {
    status: 201,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  });
}

// ============================================================================
// Metadata-only fields that should NOT trigger copy-on-write versioning.
// These are status/admin toggles that update the row in place.
// ============================================================================
const METADATA_ONLY_FIELDS = new Set([
  'is_active', 'is_public', 'is_deletable', 'sequence_no', 'status_id',
]);

/**
 * Returns true when the request body touches ONLY metadata fields
 * (no content changes that warrant a new version).
 */
function isMetadataOnlyUpdate(body: any): boolean {
  const bodyKeys = Object.keys(body).filter(
    (k) => !['expected_version', 'updated_by', 'skip_versioning'].includes(k)
  );
  return bodyKeys.length > 0 && bodyKeys.every((k) => METADATA_ONLY_FIELDS.has(k));
}

// ============================================================================
// HANDLER: PATCH /cat-templates?id={id} - Smart update
// Metadata-only changes (is_active toggle, etc.) → in-place update.
// Content changes (name, blocks, tags, etc.) → copy-on-write versioning.
// ============================================================================
async function handleUpdateTemplate(
  supabase: any,
  templateId: string,
  body: any,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Get the full existing template
  const { data: existing, error: checkError } = await supabase
    .from('t_cat_templates')
    .select('*')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin && existing.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Cannot update templates you do not own', 'FORBIDDEN', 403, ctx.operationId);
  }

  // ── Route: metadata-only OR explicit skip_versioning → in-place update ──
  if (isMetadataOnlyUpdate(body) || body.skip_versioning === true) {
    return handleInPlaceUpdate(supabase, templateId, existing, body, ctx);
  }

  // ── Route: content change → copy-on-write versioning ──
  return handleVersionedUpdate(supabase, templateId, existing, body, ctx);
}

// ============================================================================
// In-place update (no versioning) for metadata fields like is_active, etc.
// ============================================================================
async function handleInPlaceUpdate(
  supabase: any,
  templateId: string,
  existing: any,
  body: any,
  ctx: EdgeContext
) {
  const allowedMeta = [
    'is_active', 'is_public', 'is_deletable', 'sequence_no', 'status_id', 'updated_by',
  ];
  if (ctx.isAdmin) allowedMeta.push('is_system');

  const updateData: any = { updated_at: new Date().toISOString() };
  for (const field of allowedMeta) {
    if (body[field] !== undefined) {
      updateData[field] = body[field];
    }
  }
  if (!updateData.updated_by) {
    updateData.updated_by = existing.updated_by;
  }

  const { data, error } = await supabase
    .from('t_cat_templates')
    .update(updateData)
    .eq('id', templateId)
    .select()
    .single();

  if (error) {
    console.error('[cat-templates] In-place update error:', error);
    return createErrorResponse(error.message, error.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] In-place updated template: ${templateId} (fields: ${Object.keys(updateData).join(', ')})`);

  return createSuccessResponse({ template: data }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// Versioned update (copy-on-write) for content changes
// ============================================================================
async function handleVersionedUpdate(
  supabase: any,
  templateId: string,
  existing: any,
  body: any,
  ctx: EdgeContext
) {
  // Optimistic locking check
  if (body.expected_version !== undefined && body.expected_version !== existing.version) {
    return createErrorResponse(
      `Template was modified by another user. Expected version ${body.expected_version}, current version ${existing.version}. Please refresh and try again.`,
      'VERSION_CONFLICT',
      409,
      ctx.operationId
    );
  }

  // Determine parent_template_id (version chain root)
  const parentId = existing.parent_template_id || existing.id;

  // ── STEP 1: Mark old row as legacy (is_latest = false) ──
  const { error: legacyError } = await supabase
    .from('t_cat_templates')
    .update({
      is_latest: false,
      updated_at: new Date().toISOString(),
    })
    .eq('id', templateId)
    .eq('version', existing.version);  // Optimistic lock on old row

  if (legacyError) {
    console.error('[cat-templates] Legacy mark error:', legacyError);
    return createErrorResponse(legacyError.message, legacyError.code || 'UPDATE_ERROR', 500, ctx.operationId);
  }

  // ── STEP 2: Build new version row (copy all fields + apply changes) ──
  const allowedFields = [
    'name', 'display_name', 'description', 'category', 'tags', 'cover_image',
    'blocks', 'currency', 'tax_rate', 'discount_config', 'subtotal', 'total',
    'settings', 'industry_tags', 'is_public', 'is_active', 'status_id',
    'sequence_no', 'is_deletable', 'updated_by'
  ];

  if (ctx.isAdmin) {
    allowedFields.push('is_system', 'tenant_id');
  }

  // Start from existing data (copy all fields)
  const newRow: any = {
    // Carry over all existing fields
    tenant_id: existing.tenant_id,
    is_live: existing.is_live,
    name: existing.name,
    display_name: existing.display_name,
    description: existing.description,
    category: existing.category,
    tags: existing.tags,
    cover_image: existing.cover_image,
    blocks: existing.blocks,
    currency: existing.currency,
    tax_rate: existing.tax_rate,
    discount_config: existing.discount_config,
    subtotal: existing.subtotal,
    total: existing.total,
    settings: existing.settings,
    is_system: existing.is_system,
    copied_from_id: existing.copied_from_id,
    industry_tags: existing.industry_tags,
    is_public: existing.is_public,
    is_active: existing.is_active,
    status_id: existing.status_id,
    sequence_no: existing.sequence_no,
    is_deletable: existing.is_deletable,
    created_by: existing.created_by,
    updated_by: body.updated_by || existing.updated_by,
    // Versioning fields
    version: (existing.version || 1) + 1,
    is_latest: true,
    parent_template_id: parentId,
    // Timestamps
    created_at: existing.created_at,  // Preserve original creation time
    updated_at: new Date().toISOString(),
  };

  // Apply changes from request body
  for (const field of allowedFields) {
    if (body[field] !== undefined) {
      newRow[field] = body[field];
    }
  }

  // ── STEP 3: Insert new version ──
  const { data: newVersion, error: insertError } = await supabase
    .from('t_cat_templates')
    .insert(newRow)
    .select()
    .single();

  if (insertError) {
    console.error('[cat-templates] Version insert error:', insertError);
    // Rollback: mark old row back as latest
    await supabase
      .from('t_cat_templates')
      .update({ is_latest: true })
      .eq('id', templateId);
    return createErrorResponse(insertError.message, insertError.code || 'VERSION_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Versioned template: ${templateId} → ${newVersion.id} (v${existing.version} → v${newVersion.version})`);

  const responseBody = {
    success: true,
    data: { template: newVersion, previous_version_id: templateId },
    metadata: {
      request_id: ctx.operationId,
      duration_ms: Date.now() - ctx.startTime,
      timestamp: new Date().toISOString()
    }
  };

  // Store idempotency
  await storeIdempotency(supabase, ctx.idempotencyKey, ctx.tenantId, responseBody);

  return createSuccessResponse({ template: newVersion, previous_version_id: templateId }, ctx.operationId, ctx.startTime);
}

// ============================================================================
// HANDLER: DELETE /cat-templates?id={id} - Soft delete
// ============================================================================
async function handleDeleteTemplate(
  supabase: any,
  templateId: string,
  ctx: EdgeContext
) {
  if (!isValidUUID(templateId)) {
    return createErrorResponse('Invalid template ID format', 'INVALID_ID', 400, ctx.operationId);
  }

  // Check existence
  const { data: existing, error: checkError } = await supabase
    .from('t_cat_templates')
    .select('id, tenant_id, is_deletable, name')
    .eq('id', templateId)
    .single();

  if (checkError || !existing) {
    return createErrorResponse('Template not found', 'NOT_FOUND', 404, ctx.operationId);
  }

  // Permission check
  if (!ctx.isAdmin && existing.tenant_id !== ctx.tenantId) {
    return createErrorResponse('Cannot delete templates you do not own', 'FORBIDDEN', 403, ctx.operationId);
  }

  if (!existing.is_deletable) {
    return createErrorResponse(`Template "${existing.name}" cannot be deleted`, 'NOT_DELETABLE', 400, ctx.operationId);
  }

  // Soft delete
  const { error } = await supabase
    .from('t_cat_templates')
    .update({
      is_active: false,
      updated_at: new Date().toISOString()
    })
    .eq('id', templateId);

  if (error) {
    console.error('[cat-templates] Delete error:', error);
    return createErrorResponse(error.message, error.code || 'DELETE_ERROR', 500, ctx.operationId);
  }

  console.log(`[cat-templates] Soft deleted template: ${templateId}`);

  return createSuccessResponse({
    message: 'Template deleted successfully',
    template_id: templateId
  }, ctx.operationId, ctx.startTime);
}
