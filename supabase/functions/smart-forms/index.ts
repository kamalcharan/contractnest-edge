// ============================================================================
// SmartForms — Edge Function (Thin Layer)
// ============================================================================
// Purpose: Protect → Route → Single DB Call → Return
// Tables: m_form_templates (global, no tenant_id)
// RPCs: rpc_m_form_clone_template, rpc_m_form_new_version
// Target: < 30ms CPU per request
// ============================================================================

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.38.4';
import { corsHeaders } from '../_shared/cors.ts';

// --- Helpers ---

const TABLE = 'm_form_templates';

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
    const templateId = UUID_RE.test(seg0) ? seg0 : null;

    // ==========================================================
    // GET /smart-forms — List templates (single query)
    // ==========================================================
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

    // ==========================================================
    // GET /smart-forms/:id — Get single template
    // ==========================================================
    if (req.method === 'GET' && templateId && !seg1) {
      const { data, error } = await db.from(TABLE).select('*').eq('id', templateId).single();
      if (error) return err('Template not found', 404);
      return json(data);
    }

    // ==========================================================
    // POST /smart-forms — Create template (admin, single insert)
    // ==========================================================
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

    // ==========================================================
    // POST /smart-forms/validate — Schema validation (no DB)
    // ==========================================================
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

    // ==========================================================
    // Routes that require a template ID
    // ==========================================================
    if (!templateId) return err('Not found', 404);

    // ----------------------------------------------------------
    // PUT /smart-forms/:id — Update draft (single query, DB enforces status)
    // ----------------------------------------------------------
    if (req.method === 'PUT' && !seg1) {
      if (!isAdmin) return err('Admin access required', 403);

      const updates: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (body.name !== undefined) updates.name = body.name;
      if (body.description !== undefined) updates.description = body.description;
      if (body.category !== undefined) updates.category = body.category;
      if (body.form_type !== undefined) updates.form_type = body.form_type;
      if (body.tags !== undefined) updates.tags = body.tags;
      if (body.schema !== undefined) updates.schema = body.schema;

      // Single call — .eq('status', 'draft') enforces draft-only editing
      const { data, error } = await db.from(TABLE)
        .update(updates)
        .eq('id', templateId)
        .eq('status', 'draft')
        .select()
        .single();

      if (error) return err('Template not found or not in draft status', 404);
      return json(data);
    }

    // ----------------------------------------------------------
    // DELETE /smart-forms/:id — Delete draft (single query, DB enforces status)
    // ----------------------------------------------------------
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

    // ----------------------------------------------------------
    // POST actions — all require admin
    // ----------------------------------------------------------
    if (req.method !== 'POST') return err('Method not allowed', 405);
    if (!isAdmin) return err('Admin access required', 403);

    // POST /smart-forms/:id/submit-review — draft → in_review (single query)
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

    // POST /smart-forms/:id/approve — in_review → approved (single query)
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

    // POST /smart-forms/:id/reject — in_review → draft (single query)
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

    // POST /smart-forms/:id/archive — approved → past (single query)
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

    // POST /smart-forms/:id/clone — Single RPC call
    if (seg1 === 'clone') {
      const { data, error } = await db.rpc('rpc_m_form_clone_template', {
        p_template_id: templateId,
        p_user_id: userId,
      });

      if (error) return err(error.message, error.message.includes('not found') ? 404 : 500);
      return json(Array.isArray(data) ? data[0] : data, 201);
    }

    // POST /smart-forms/:id/new-version — Single RPC call
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
