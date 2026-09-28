// ============================================================================
// SmartForms — Edge Function (Thin Layer) — Cycle 3 Update
// ============================================================================
// Purpose: Protect → Route → Single DB Call → Return
// Tables: m_form_templates, m_form_tenant_selections, m_form_submissions
// RPCs: rpc_m_form_clone_template, rpc_m_form_new_version
// Target: < 30ms CPU per request
// v7 (B2.5, 2026-09-12): + GET /mappings (resolved per-contract form
// requirements) and submission → event-asset gating (friendly pre-checks;
// the DB trigger trg_zz_submission_asset_gate is the authoritative backstop).
// NOTE: this file is rebuilt from the DEPLOYED v6 source — the repo copy had
// drifted (was missing the resource_template_id filter + equipment-tags route).
// ============================================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';
import { corsHeaders } from '../_shared/cors.ts';

// --- Helpers ---

const TABLE = 'm_form_templates';
const SELECTIONS_TABLE = 'm_form_tenant_selections';
const SUBMISSIONS_TABLE = 'm_form_submissions';

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function err(message: string, status = 400) {
  return new Response(
    JSON.stringify({ error: message }),
    { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
  );
}

function supabase() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

function parsePath(url: string) {
  const parsed = new URL(url);
  const parts = parsed.pathname.split('/').filter(Boolean);
  const idx = parts.indexOf('smart-forms');
  return { segments: idx !== -1 ? parts.slice(idx + 1) : [], params: parsed.searchParams };
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// ============================================================================
// Main Handler
// ============================================================================

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    const db = supabase();
    const { segments, params } = parsePath(req.url);
    let isAdmin = false;
    const tenantId = req.headers.get('x-tenant-id') || '';

    // Extract user ID from auth token (single call, cached by Supabase)
    let userId = 'system';
    const authHeader = req.headers.get('Authorization');
    if (authHeader) {
      const { data: { user } } = await db.auth.getUser(authHeader.replace('Bearer ', ''));
      if (user) userId = user.id;
    }

    if (userId === 'system') return err('Sign in to access Smart Forms', 401);
    const {data: profile} = await db.from('t_user_profiles').select('is_admin').eq('user_id',userId).eq('is_active',true).maybeSingle();
    isAdmin = profile?.is_admin === true;
    if (tenantId) {
      if (!UUID_RE.test(tenantId)) return err('Invalid workspace',400);
      const {data: membership,error: membershipError} = await db.from('t_user_tenants').select('id').eq('user_id',userId).eq('tenant_id',tenantId).eq('status','active').maybeSingle();
      if (membershipError || !membership) return err('You do not have access to this workspace',403);
    }

    // Parse body for write requests
    let body: Record<string, unknown> = {};
    if (req.method !== 'GET' && req.body) {
      const text = await req.text();
      if (text) body = JSON.parse(text);
    }

    const seg0 = segments[0] || '';
    const seg1 = segments[1] || '';
    const seg2 = segments[2] || '';
    const templateId = UUID_RE.test(seg0) ? seg0 : null;

    // ============================================================
    // TENANT SELECTIONS — /smart-forms/selections/*
    // ============================================================

    if (seg0 === 'selections') {

      // GET /smart-forms/selections — List tenant's selected templates
      if (req.method === 'GET' && !seg1) {
        if (!tenantId) return err('x-tenant-id header required', 400);

        const { data, error } = await db
          .from(SELECTIONS_TABLE)
          .select(`
            id,
            tenant_id,
            form_template_id,
            is_active,
            selected_by,
            selected_at,
            deactivated_at,
            created_at,
            updated_at,
            m_form_templates (
              id, name, description, category, form_type, tags, version, status
            )
          `)
          .eq('tenant_id', tenantId)
          .order('selected_at', { ascending: false });

        if (error) return err(error.message, 500);
        return json({ data: data || [] });
      }

      // POST /smart-forms/selections — Toggle a template selection
      if (req.method === 'POST' && !seg1) {
        if (!tenantId) return err('x-tenant-id header required', 400);
        if (!body.form_template_id) return err('form_template_id is required');

        const templateIdVal = body.form_template_id as string;

        // Check if selection already exists
        const { data: existing } = await db
          .from(SELECTIONS_TABLE)
          .select('id, is_active')
          .eq('tenant_id', tenantId)
          .eq('form_template_id', templateIdVal)
          .maybeSingle();

        if (existing) {
          // Toggle is_active
          const newState = !existing.is_active;
          const { data, error } = await db
            .from(SELECTIONS_TABLE)
            .update({
              is_active: newState,
              deactivated_at: newState ? null : new Date().toISOString(),
              updated_at: new Date().toISOString(),
            })
            .eq('id', existing.id)
            .select()
            .single();

          if (error) return err(error.message, 500);
          return json(data);
        } else {
          // Create new selection
          const { data, error } = await db
            .from(SELECTIONS_TABLE)
            .insert({
              id: crypto.randomUUID(),
              tenant_id: tenantId,
              form_template_id: templateIdVal,
              is_active: true,
              selected_by: userId,
              selected_at: new Date().toISOString(),
            })
            .select()
            .single();

          if (error) return err(error.message, 500);
          return json(data, 201);
        }
      }

      return err('Not found', 404);
    }

    // ============================================================
    // MAPPINGS — /smart-forms/mappings?contract_id=... (B2.5)
    // Resolved form requirements for a contract, written at activation
    // by resolve_contract_form_mappings (D9 ladder). Block-level rows
    // sort first; contract-level rows (contract_block_id NULL) last.
    // ============================================================

    if (seg0 === 'mappings') {
      if (!tenantId) return err('x-tenant-id header required', 400);
      if (req.method !== 'GET') return err('Method not allowed', 405);
      const contractIdParam = params.get('contract_id');
      if (!contractIdParam) return err('contract_id is required', 400);

      const { data, error } = await db
        .from('m_form_template_mappings')
        .select(`
          id, contract_id, contract_block_id, form_template_id,
          resource_template_id, require_upload, resolved_via, timing,
          is_mandatory, status, effective_from, effective_to,
          m_form_templates ( id, name, version, category, form_type )
        `)
        .eq('tenant_id', tenantId)
        .eq('contract_id', contractIdParam)
        .eq('status', 'active')
        .order('contract_block_id', { ascending: true, nullsFirst: false });

      if (error) return err(error.message, 500);
      const { data: blocks, error: blockError } = await db.from('t_contract_blocks')
        .select('id, custom_fields').eq('contract_id', contractIdParam);
      if (blockError) return err(blockError.message, 500);
      return json({ data: (data || []).map(m => ({ ...m,
        original_block_id: blocks?.find(b => b.id === m.contract_block_id)?.custom_fields?.originalId ?? null
      })) });
    }

    // ============================================================
    // SUBMISSIONS — /smart-forms/submissions/*
    // ============================================================

    if (seg0 === 'submissions') {
      if (!tenantId) return err('x-tenant-id header required', 400);

      const submissionId = UUID_RE.test(seg1) ? seg1 : null;

      if (req.method === 'GET' && seg1 === 'start-check') {
        const eventId = params.get('event_id') || '';
        if (!UUID_RE.test(eventId)) return err('Invalid service', 400);
        const { data: serviceEvent } = await db.from('t_contract_events')
          .select('id').eq('id', eventId).eq('tenant_id', tenantId).eq('event_type', 'service').maybeSingle();
        if (!serviceEvent) return err('Service not found in this workspace', 404);
        const { data, error } = await db.rpc('service_start_metadata_problem', { p_tenant: tenantId, p_event: eventId });
        if (error) return err(error.message, 500);
        return json({ problem: data || null });
      }

      // Server-owned values for read-only registry/service fields.
      if (req.method === 'GET' && seg1 === 'context') {
        const eventId = params.get('event_id') || '';
        const eventAssetId = params.get('event_asset_id');
        const formTemplateId = params.get('template_id') || '';
        if (!UUID_RE.test(eventId) || !UUID_RE.test(formTemplateId) ||
            (eventAssetId && !UUID_RE.test(eventAssetId))) return err('Invalid form context', 400);
        const { data, error } = await db.rpc('service_form_execution_context', {
          p_tenant: tenantId, p_event: eventId, p_event_asset: eventAssetId || null,
          p_template: formTemplateId,
        });
        if (error) return err(error.message, error.code === '23514' ? 422 : 500);
        return json(data);
      }

      // GET /smart-forms/submissions?event_id=xxx — List submissions for an event
      if (req.method === 'GET' && !seg1) {
        const eventId = params.get('event_id');
        const contractId = params.get('contract_id');
        const templateId = params.get('template_id');

        let query = db.from(SUBMISSIONS_TABLE).select('*').eq('tenant_id', tenantId);

        if (eventId) query = query.eq('service_event_id', eventId);
        if (contractId) query = query.eq('contract_id', contractId);
        if (templateId) query = query.eq('form_template_id', templateId);

        const { data, error } = await query.order('created_at', { ascending: false });

        if (error) return err(error.message, 500);
        return json({ data: data || [] });
      }

      // GET /smart-forms/submissions/:id — Get single submission
      if (req.method === 'GET' && submissionId) {
        const { data, error } = await db
          .from(SUBMISSIONS_TABLE)
          .select('*')
          .eq('id', submissionId)
          .eq('tenant_id', tenantId)
          .single();

        if (error) return err('Submission not found', 404);
        return json(data);
      }

      // POST /smart-forms/submissions — Create submission
      if (req.method === 'POST' && !seg1) {
        if (!body.form_template_id || !body.service_event_id || !body.contract_id) {
          return err('form_template_id, service_event_id, and contract_id are required');
        }

        const {data: serviceEvent} = await db.from('t_contract_events').select('id,contract_id,status').eq('id',body.service_event_id).eq('tenant_id',tenantId).eq('contract_id',body.contract_id).eq('event_type','service').maybeSingle();
        if (!serviceEvent) return err('Service not found in this workspace',404);
        if (['completed','cancelled'].includes(serviceEvent.status)) return err('This service is closed. Its evidence is read-only.',409);

        // Get template to snapshot version
        const { data: template, error: tplErr } = await db
          .from(TABLE)
          .select('version, schema')
          .eq('id', body.form_template_id as string)
          .single();

        if (tplErr) return err('Template not found', 404);
        if (body.status !== undefined && !['draft','submitted'].includes(String(body.status))) return err('Invalid submission status',422);
        if (body.status === 'draft' && template.schema?.settings?.allow_draft !== true) return err('This form does not allow drafts. Record the complete outcome.',422);

        // B2.5 gate (friendly pre-check; the DB trigger
        // trg_zz_submission_asset_gate is the authoritative backstop):
        // a visit with per-asset rows requires event_asset_id, the row must
        // belong to this visit, and it must not be a placeholder slot.
        const eventAssetId = (body.event_asset_id as string) || null;
        const { data: assetRows } = await db
          .from('t_contract_event_assets')
          .select('id, status')
          .eq('event_id', body.service_event_id as string)
          .eq('tenant_id', tenantId)
          .eq('is_active', true);
        if (assetRows && assetRows.length > 0) {
          if (!eventAssetId) {
            return err('This visit tracks proof per asset — event_asset_id is required', 422);
          }
          const assetRow = assetRows.find((r) => r.id === eventAssetId);
          if (!assetRow) {
            return err('event_asset_id does not belong to this visit', 422);
          }
          if (assetRow.status === 'blocked_placeholder') {
            return err('This slot is a placeholder — attach the real asset before submitting evidence', 422);
          }
        }

        const { data, error } = await db
          .from(SUBMISSIONS_TABLE)
          .insert({
            id: crypto.randomUUID(),
            tenant_id: tenantId,
            form_template_id: body.form_template_id,
            form_template_version: template.version,
            service_event_id: body.service_event_id,
            contract_id: body.contract_id,
            mapping_id: (body.mapping_id as string) || null,
            event_asset_id: eventAssetId,
            responses: body.responses || {},
            computed_values: body.computed_values || {},
            status: body.status || 'draft',
            submitted_at: body.status === 'submitted' ? new Date().toISOString() : null,
            submitted_by: userId,
            device_info: body.device_info || {},
          })
          .select()
          .single();

        if (error) return err(error.message, error.code === '23514' ? 422 : 500);
        return json(data, 201);
      }

      // PUT /smart-forms/submissions/:id — Update submission (draft/submitted only)
      if (req.method === 'PUT' && submissionId) {
        if (body.status !== undefined && !['draft', 'submitted'].includes(String(body.status))) return err('Invalid submission status', 422);
        const { data: prior } = await db.from(SUBMISSIONS_TABLE).select('form_template_id, form_template_version, service_event_id, status, form_schema_snapshot').eq('id', submissionId).eq('tenant_id', tenantId).single();
        if (!prior) return err('Submission not found', 404);
        if (['submitted','approved'].includes(prior.status) && prior.form_schema_snapshot) return err('This report is submitted and read-only. Open a new report to correct it.', 409);
        const {data: priorEvent} = await db.from('t_contract_events').select('status').eq('id',prior.service_event_id).eq('tenant_id',tenantId).maybeSingle();
        if (!priorEvent || ['completed','cancelled'].includes(priorEvent.status)) return err('The service is missing or closed. Its evidence cannot be changed.',409);
        const { data: currentTemplate } = await db.from(TABLE).select('version, schema').eq('id', prior.form_template_id).single();
        if (!currentTemplate || currentTemplate.version !== prior.form_template_version) return err('This form has changed. Open a new form to record the current requirements; your earlier answers are preserved.', 409);
        if (body.status === 'draft' && currentTemplate.schema?.settings?.allow_draft !== true) return err('This form does not allow drafts. Record the complete outcome.', 422);
        const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };

        if (body.responses !== undefined) updates.responses = body.responses;
        if (body.computed_values !== undefined) updates.computed_values = body.computed_values;
        if (body.status !== undefined) {
          updates.status = body.status;
          if (body.status === 'submitted') {
            updates.submitted_at = new Date().toISOString();
            updates.submitted_by = userId;
          }
        }

        const { data, error } = await db
          .from(SUBMISSIONS_TABLE)
          .update(updates)
          .eq('id', submissionId)
          .eq('tenant_id', tenantId)
          .in('status', ['draft', 'submitted'])
          .select()
          .single();

        if (error) return err(error.message, error.code === '23514' ? 422 : 500);
        return json(data);
      }

      return err('Not found', 404);
    }

    // ============================================================
    // TEMPLATES — /smart-forms/* (existing Cycle 1 routes)
    // ============================================================

    // GET /smart-forms — List templates (single query)
    if (req.method === 'GET' && segments.length === 0) {
      const page = Math.max(1, parseInt(params.get('page') || '1'));
      const limit = Math.min(100, Math.max(1, parseInt(params.get('limit') || '20')));
      const offset = (page - 1) * limit;

      let query = db.from(TABLE).select('*', { count: 'exact' });

      const status = params.get('status');
      const category = params.get('category');
      const formType = params.get('form_type');
      const search = params.get('search');
      const resourceTemplateId = params.get('resource_template_id');

      if (status) query = query.eq('status', status);
      if (category) query = query.eq('category', category);
      if (formType) query = query.eq('form_type', formType);
      if (resourceTemplateId) query = query.eq('resource_template_id', resourceTemplateId);
      if (search) query = query.or(`name.ilike.%${search}%,description.ilike.%${search}%`);

      const { data, count, error } = await query
        .order('updated_at', { ascending: false })
        .range(offset, offset + limit - 1);

      if (error) return err(error.message, 500);

      return json({
        data: data || [],
        pagination: { page, limit, total: count || 0, has_more: (count || 0) > offset + limit },
      });
    }

    // GET /smart-forms/equipment-tags — Distinct equipment/facility facets
    // for the Admin list filter dropdown. Dynamic (grows with each new
    // Knowledge Tree), unlike the fixed category/form_type enums, so it
    // has to be read from the DB rather than a hardcoded list.
    if (req.method === 'GET' && seg0 === 'equipment-tags') {
      const { data, error } = await db.rpc('get_form_equipment_tags');
      if (error) return err(error.message, 500);
      return json({ data: data || [] });
    }

    // GET /smart-forms/:id — Get single template
    if (req.method === 'GET' && templateId && !seg1) {
      const { data, error } = await db.from(TABLE).select('*').eq('id', templateId).single();
      if (error) return err('Template not found', 404);
      return json(data);
    }

    // POST /smart-forms — Create template (admin, single insert)
    if (req.method === 'POST' && segments.length === 0) {
      if (!isAdmin) return err('Admin access required', 403);
      if (!body.name || !body.category || !body.form_type || !body.schema) {
        return err('name, category, form_type, and schema are required');
      }

      const { data, error } = await db.from(TABLE)
        .insert({
          name: body.name,
          description: body.description || null,
          category: body.category,
          form_type: body.form_type,
          tags: body.tags || [],
          schema: body.schema,
          version: 1,
          status: 'draft',
          created_by: userId,
          // Previously never read from the request body, so every template
          // silently fell back to the column default ('manual') regardless
          // of actual origin -- Knowledge Tree exports were indistinguishable
          // from hand-built forms except via the tags array.
          source: body.source || 'manual',
          resource_template_id: body.resource_template_id || null,
        })
        .select()
        .single();

      if (error) return err(error.message, 500);
      return json(data, 201);
    }

    // POST /smart-forms/validate — Schema validation (no DB)
    if (req.method === 'POST' && seg0 === 'validate') {
      const s = body.schema as Record<string, unknown> | undefined;
      if (!s) return err('schema is required');

      const errors: string[] = [];
      if (!s.id || typeof s.id !== 'string') errors.push('schema.id is required (string)');
      if (!s.title || typeof s.title !== 'string') errors.push('schema.title is required (string)');

      if (!Array.isArray(s.sections)) {
        errors.push('schema.sections must be an array');
      } else {
        const fieldIds = new Set<string>();
        const sectionIds = new Set<string>();
        for (let si = 0; si < s.sections.length; si++) {
          const sec = s.sections[si] as Record<string, unknown>;
          if (!sec.id) errors.push(`sections[${si}].id is required`);
          if (!sec.title) errors.push(`sections[${si}].title is required`);
          if (sectionIds.has(sec.id as string)) errors.push(`Duplicate section id: ${sec.id}`);
          sectionIds.add(sec.id as string);
          if (!Array.isArray(sec.fields)) { errors.push(`sections[${si}].fields must be an array`); continue; }
          for (let fi = 0; fi < sec.fields.length; fi++) {
            const f = sec.fields[fi] as Record<string, unknown>;
            if (!f.id) errors.push(`sections[${si}].fields[${fi}].id is required`);
            if (!f.type) errors.push(`sections[${si}].fields[${fi}].type is required`);
            if (!f.label) errors.push(`sections[${si}].fields[${fi}].label is required`);
            if (fieldIds.has(f.id as string)) errors.push(`Duplicate field id: ${f.id}`);
            fieldIds.add(f.id as string);
          }
        }
      }

      return json({ valid: errors.length === 0, errors });
    }

    // Routes that require a template ID
    if (!templateId) return err('Not found', 404);

    // PUT /smart-forms/:id — Update draft (single query, DB enforces status)
    if (req.method === 'PUT' && !seg1) {
      if (!isAdmin) return err('Admin access required', 403);

      const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (body.name !== undefined) updates.name = body.name;
      if (body.description !== undefined) updates.description = body.description;
      if (body.category !== undefined) updates.category = body.category;
      if (body.form_type !== undefined) updates.form_type = body.form_type;
      if (body.tags !== undefined) updates.tags = body.tags;
      if (body.schema !== undefined) updates.schema = body.schema;

      const { data, error } = await db.from(TABLE)
        .update(updates)
        .eq('id', templateId)
        .eq('status', 'draft')
        .select()
        .single();

      if (error) return err('Template not found or not in draft status', 404);
      return json(data);
    }

    // DELETE /smart-forms/:id — Delete draft (single query, DB enforces status)
    if (req.method === 'DELETE' && !seg1) {
      if (!isAdmin) return err('Admin access required', 403);

      const { data, error } = await db.from(TABLE)
        .delete()
        .eq('id', templateId)
        .eq('status', 'draft')
        .select()
        .single();

      if (error) return err('Template not found or not in draft status', 404);
      return json({ success: true, deleted: data.id });
    }

    // POST actions — all require admin
    if (req.method !== 'POST') return err('Method not allowed', 405);
    if (!isAdmin) return err('Admin access required', 403);

    // POST /smart-forms/:id/submit-review
    if (seg1 === 'submit-review') {
      const { data, error } = await db.from(TABLE)
        .update({ status: 'in_review', updated_at: new Date().toISOString() })
        .eq('id', templateId)
        .eq('status', 'draft')
        .select()
        .single();

      if (error) return err('Template not found or not in draft status', 404);
      return json(data);
    }

    // POST /smart-forms/:id/approve
    if (seg1 === 'approve') {
      const { data, error } = await db.from(TABLE)
        .update({
          status: 'approved',
          approved_by: userId,
          approved_at: new Date().toISOString(),
          review_notes: (body.notes as string) || null,
          updated_at: new Date().toISOString(),
        })
        .eq('id', templateId)
        .eq('status', 'in_review')
        .select()
        .single();

      if (error) return err('Template not found or not in review status', 404);
      return json(data);
    }

    // POST /smart-forms/:id/reject
    if (seg1 === 'reject') {
      if (!body.notes) return err('Rejection notes are required');

      const { data, error } = await db.from(TABLE)
        .update({
          status: 'draft',
          review_notes: body.notes as string,
          updated_at: new Date().toISOString(),
        })
        .eq('id', templateId)
        .eq('status', 'in_review')
        .select()
        .single();

      if (error) return err('Template not found or not in review status', 404);
      return json(data);
    }

    // POST /smart-forms/:id/archive
    if (seg1 === 'archive') {
      const { data, error } = await db.from(TABLE)
        .update({ status: 'past', updated_at: new Date().toISOString() })
        .eq('id', templateId)
        .eq('status', 'approved')
        .select()
        .single();

      if (error) return err('Template not found or not in approved status', 404);
      return json(data);
    }

    // POST /smart-forms/:id/clone
    if (seg1 === 'clone') {
      const { data, error } = await db.rpc('rpc_m_form_clone_template', {
        p_template_id: templateId,
        p_user_id: userId,
      });

      if (error) return err(error.message, error.message.includes('not found') ? 404 : 500);
      return json(Array.isArray(data) ? data[0] : data, 201);
    }

    // POST /smart-forms/:id/new-version
    if (seg1 === 'new-version') {
      const { data, error } = await db.rpc('rpc_m_form_new_version', {
        p_template_id: templateId,
        p_user_id: userId,
      });

      if (error) return err(error.message, error.message.includes('not found') ? 404 : 500);
      return json(Array.isArray(data) ? data[0] : data, 201);
    }

    return err('Not found', 404);

  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : 'Internal server error';
    console.error('[smart-forms]', msg);
    return err(msg, 500);
  }
});
