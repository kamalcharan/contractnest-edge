// ============================================================================
// SmartForms — Edge Function (Thin Layer) — Cycle 3 Update
// ============================================================================
// Purpose: Protect → Route → Single DB Call → Return
// Tables: m_form_templates, m_form_tenant_selections, m_form_submissions
// RPCs: rpc_m_form_clone_template, rpc_m_form_new_version
// Target: < 30ms CPU per request
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
    const isAdmin = req.headers.get('x-is-admin') === 'true';
    const tenantId = req.headers.get('x-tenant-id') || '';

    // Extract user ID from auth token (single call, cached by Supabase)
    let userId = 'system';
    const authHeader = req.headers.get('Authorization');
    if (authHeader) {
      const { data: { user } } = await db.auth.getUser(authHeader.replace('Bearer ', ''));
      if (user) userId = user.id;
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
    // SUBMISSIONS — /smart-forms/submissions/*
    // ============================================================

    if (seg0 === 'submissions') {
      if (!tenantId) return err('x-tenant-id header required', 400);

      const submissionId = UUID_RE.test(seg1) ? seg1 : null;

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

        // Get template to snapshot version
        const { data: template, error: tplErr } = await db
          .from(TABLE)
          .select('version')
          .eq('id', body.form_template_id as string)
          .single();

        if (tplErr) return err('Template not found', 404);

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
            responses: body.responses || {},
            computed_values: body.computed_values || {},
            status: 'draft',
            submitted_by: userId,
            device_info: body.device_info || {},
          })
          .select()
          .single();

        if (error) return err(error.message, 500);
        return json(data, 201);
      }

      // PUT /smart-forms/submissions/:id — Update submission (draft/submitted only)
      if (req.method === 'PUT' && submissionId) {
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

        if (error) return err('Submission not found or not editable', 404);
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

      if (status) query = query.eq('status', status);
      if (category) query = query.eq('category', category);
      if (formType) query = query.eq('form_type', formType);
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
