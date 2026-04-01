// knowledge-tree Edge Function
// Serves Knowledge Tree data for ContractNest Smart Forms
// Endpoints:
//   GET  /knowledge-tree/variants?resource_template_id=X
//   GET  /knowledge-tree/spare-parts?resource_template_id=X[&variant_id=Y]
//   GET  /knowledge-tree/checkpoints?resource_template_id=X[&variant_id=Y&service_activity=Z]
//   GET  /knowledge-tree/cycles?resource_template_id=X
//   GET  /knowledge-tree/overlays?resource_template_id=X
//   GET  /knowledge-tree/summary?resource_template_id=X
//   POST /knowledge-tree/save (admin only — transactional insert across all tables)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-tenant-id, x-is-admin",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function jsonResponse(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function errorResponse(message: string, status = 400) {
  return jsonResponse({ error: message }, status);
}

function getSupabaseAdmin() {
  const url = Deno.env.get("SUPABASE_URL")!;
  const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  return createClient(url, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

function groupBy(arr: any[], key: string): Record<string, any[]> {
  const result: Record<string, any[]> = {};
  for (const item of arr) {
    const k = item[key] || "Other";
    if (!result[k]) result[k] = [];
    result[k].push(item);
  }
  return result;
}

// ─── Route: GET /variants ──────────────────────────────────────────
async function getVariants(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const { data, error } = await sb
    .from("m_equipment_variants")
    .select("id, resource_template_id, name, description, capacity_range, attributes, sort_order, source")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("sort_order", { ascending: true });

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ count: data.length, variants: data });
}

// ─── Route: GET /spare-parts ───────────────────────────────────────
async function getSpareParts(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const variantId = params.get("variant_id");

  // Get spare parts
  const { data: parts, error: partsErr } = await sb
    .from("m_equipment_spare_parts")
    .select("id, resource_template_id, component_group, name, description, specifications, sort_order, source")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("component_group")
    .order("sort_order", { ascending: true });

  if (partsErr) return errorResponse(partsErr.message, 500);

  // Get variant map (optionally filtered by variant)
  const partIds = (parts || []).map((p: any) => p.id);
  if (partIds.length === 0) {
    return jsonResponse({ count: 0, component_groups: [], spare_parts_by_group: {} });
  }

  let mapQuery = sb
    .from("m_spare_part_variant_map")
    .select("id, spare_part_id, variant_id, is_recommended, notes")
    .in("spare_part_id", partIds);

  if (variantId) {
    mapQuery = mapQuery.eq("variant_id", variantId);
  }

  const { data: variantMap, error: mapErr } = await mapQuery;
  if (mapErr) return errorResponse(mapErr.message, 500);

  // Enrich parts with variant applicability, then group by component_group
  const enriched = (parts || []).map((part: any) => ({
    ...part,
    variant_applicability: (variantMap || []).filter(
      (m: any) => m.spare_part_id === part.id
    ),
  }));

  return jsonResponse({
    count: enriched.length,
    component_groups: [...new Set(enriched.map((p: any) => p.component_group))],
    spare_parts_by_group: groupBy(enriched, "component_group"),
  });
}

// ─── Route: GET /checkpoints ───────────────────────────────────────
async function getCheckpoints(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const variantId = params.get("variant_id");
  const serviceActivity = params.get("service_activity");

  let query = sb
    .from("m_equipment_checkpoints")
    .select("*")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("section_name")
    .order("sort_order", { ascending: true });

  if (serviceActivity) {
    query = query.eq("service_activity", serviceActivity);
  }

  const { data: checkpoints, error: cpErr } = await query;
  if (cpErr) return errorResponse(cpErr.message, 500);

  const cpIds = (checkpoints || []).map((c: any) => c.id);
  if (cpIds.length === 0) {
    return jsonResponse({ count: 0, sections: [], checkpoints_by_section: {} });
  }

  // Get checkpoint values (for condition-type checkpoints)
  const { data: values, error: valErr } = await sb
    .from("m_checkpoint_values")
    .select("id, checkpoint_id, label, severity, triggers_part_consumption, requires_photo, sort_order")
    .in("checkpoint_id", cpIds)
    .order("sort_order", { ascending: true });

  if (valErr) return errorResponse(valErr.message, 500);

  // Get variant map (optionally filtered)
  let vmQuery = sb
    .from("m_checkpoint_variant_map")
    .select("id, checkpoint_id, variant_id, override_min, override_max, override_amber, override_red")
    .in("checkpoint_id", cpIds);

  if (variantId) {
    vmQuery = vmQuery.eq("variant_id", variantId);
  }

  const { data: variantMap, error: vmErr } = await vmQuery;
  if (vmErr) return errorResponse(vmErr.message, 500);

  // Enrich checkpoints with values and variant applicability
  const enriched = (checkpoints || []).map((cp: any) => ({
    ...cp,
    values: (values || []).filter((v: any) => v.checkpoint_id === cp.id),
    variant_applicability: (variantMap || []).filter(
      (m: any) => m.checkpoint_id === cp.id
    ),
  }));

  return jsonResponse({
    count: enriched.length,
    sections: [...new Set(enriched.map((c: any) => c.section_name))],
    checkpoints_by_section: groupBy(enriched, "section_name"),
  });
}

// ─── Route: GET /cycles ────────────────────────────────────────────
async function getCycles(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  // Service cycles are keyed by checkpoint_id — join through checkpoints
  const { data: checkpoints, error: cpErr } = await sb
    .from("m_equipment_checkpoints")
    .select("id, name, section_name, service_activity")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true);

  if (cpErr) return errorResponse(cpErr.message, 500);

  const cpIds = (checkpoints || []).map((c: any) => c.id);
  if (cpIds.length === 0) {
    return jsonResponse({ count: 0, cycles: [] });
  }

  const { data: cycles, error: cycErr } = await sb
    .from("m_service_cycles")
    .select("id, checkpoint_id, frequency_value, frequency_unit, varies_by, alert_overdue_days, source")
    .in("checkpoint_id", cpIds)
    .eq("is_active", true);

  if (cycErr) return errorResponse(cycErr.message, 500);

  // Enrich with checkpoint info
  const cpMap: Record<string, any> = {};
  for (const cp of checkpoints || []) cpMap[cp.id] = cp;

  const enriched = (cycles || []).map((cy: any) => ({
    ...cy,
    checkpoint_name: cpMap[cy.checkpoint_id]?.name,
    section_name: cpMap[cy.checkpoint_id]?.section_name,
    service_activity: cpMap[cy.checkpoint_id]?.service_activity,
  }));

  return jsonResponse({ count: enriched.length, cycles: enriched });
}

// ─── Route: GET /overlays ──────────────────────────────────────────
async function getOverlays(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const { data, error } = await sb
    .from("m_context_overlays")
    .select("id, resource_template_id, context_type, context_value, adjustments, priority")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("priority", { ascending: true });

  if (error) return errorResponse(error.message, 500);

  return jsonResponse({
    count: (data || []).length,
    overlays_by_type: groupBy(data || [], "context_type"),
  });
}

// ─── Route: GET /summary ───────────────────────────────────────────
async function getSummary(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  // Fetch resource template info
  const { data: template, error: tplErr } = await sb
    .from("m_catalog_resource_templates")
    .select("id, name, description, sub_category, scope")
    .eq("id", resourceTemplateId)
    .single();

  if (tplErr) return errorResponse(`Resource template not found: ${tplErr.message}`, 404);

  // Parallel fetch all knowledge tree data
  const [variantsRes, partsRes, checkpointsRes, cyclesRes, overlaysRes] =
    await Promise.all([
      sb
        .from("m_equipment_variants")
        .select("id, name, description, capacity_range, attributes, sort_order, source")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("sort_order"),
      sb
        .from("m_equipment_spare_parts")
        .select("id, component_group, name, description, specifications, sort_order, source")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("component_group")
        .order("sort_order"),
      sb
        .from("m_equipment_checkpoints")
        .select("*")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("section_name")
        .order("sort_order"),
      sb
        .from("m_service_cycles")
        .select("id, checkpoint_id, frequency_value, frequency_unit, varies_by, alert_overdue_days, source")
        .eq("is_active", true),
      sb
        .from("m_context_overlays")
        .select("id, context_type, context_value, adjustments, priority")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("priority"),
    ]);

  const variants = variantsRes.data || [];
  const parts = partsRes.data || [];
  const checkpoints = checkpointsRes.data || [];
  const cpIds = checkpoints.map((c: any) => c.id);

  // Filter cycles to only this resource's checkpoints
  const cycles = (cyclesRes.data || []).filter((cy: any) =>
    cpIds.includes(cy.checkpoint_id)
  );
  const overlays = overlaysRes.data || [];

  // Get junction tables
  const partIds = parts.map((p: any) => p.id);
  const [partMapRes, cpMapRes, cpValRes] = await Promise.all([
    partIds.length > 0
      ? sb
          .from("m_spare_part_variant_map")
          .select("spare_part_id, variant_id, is_recommended, notes")
          .in("spare_part_id", partIds)
      : Promise.resolve({ data: [], error: null }),
    cpIds.length > 0
      ? sb
          .from("m_checkpoint_variant_map")
          .select("checkpoint_id, variant_id, override_min, override_max, override_amber, override_red")
          .in("checkpoint_id", cpIds)
      : Promise.resolve({ data: [], error: null }),
    cpIds.length > 0
      ? sb
          .from("m_checkpoint_values")
          .select("id, checkpoint_id, label, severity, triggers_part_consumption, requires_photo, sort_order")
          .in("checkpoint_id", cpIds)
          .order("sort_order")
      : Promise.resolve({ data: [], error: null }),
  ]);

  const partMap = partMapRes.data || [];
  const cpVarMap = cpMapRes.data || [];
  const cpValues = cpValRes.data || [];

  // Enrich checkpoints
  const enrichedCheckpoints = checkpoints.map((cp: any) => ({
    ...cp,
    values: cpValues.filter((v: any) => v.checkpoint_id === cp.id),
    variant_applicability: cpVarMap.filter((m: any) => m.checkpoint_id === cp.id),
  }));

  // Enrich cycles
  const cpLookup: Record<string, any> = {};
  for (const cp of checkpoints) cpLookup[cp.id] = cp;

  const enrichedCycles = cycles.map((cy: any) => ({
    ...cy,
    checkpoint_name: cpLookup[cy.checkpoint_id]?.name,
    section_name: cpLookup[cy.checkpoint_id]?.section_name,
    service_activity: cpLookup[cy.checkpoint_id]?.service_activity,
  }));

  return jsonResponse({
    resource_template: template,
    summary: {
      variants_count: variants.length,
      spare_parts_count: parts.length,
      component_groups: [...new Set(parts.map((p: any) => p.component_group))],
      checkpoints_count: checkpoints.length,
      sections: [...new Set(checkpoints.map((c: any) => c.section_name))],
      service_activities: [...new Set(checkpoints.map((c: any) => c.service_activity))],
      cycles_count: cycles.length,
      overlays_count: overlays.length,
      variant_part_mappings: partMap.length,
      variant_checkpoint_mappings: cpVarMap.length,
    },
    variants,
    spare_parts_by_group: groupBy(
      parts.map((part: any) => ({
        ...part,
        variant_applicability: partMap.filter((m: any) => m.spare_part_id === part.id),
      })),
      "component_group"
    ),
    checkpoints_by_section: groupBy(enrichedCheckpoints, "section_name"),
    cycles: enrichedCycles,
    overlays_by_type: groupBy(overlays, "context_type"),
  });
}

// ─── Route: POST /save ─────────────────────────────────────────────
// Transactional insert across all knowledge tree tables
// Body: { resource_template_id, variants, spare_parts, spare_part_variant_map,
//         checkpoints, checkpoint_values, checkpoint_variant_map,
//         service_cycles, context_overlays }
async function saveKnowledgeTree(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const {
    resource_template_id,
    variants,
    spare_parts,
    spare_part_variant_map,
    checkpoints,
    checkpoint_values,
    checkpoint_variant_map,
    service_cycles,
    context_overlays,
  } = body;

  if (!resource_template_id) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const results: Record<string, number> = {};
  const errors: string[] = [];

  try {
    // Insert order matters for FK integrity:
    // 1. variants → 2. spare_parts → 3. spare_part_variant_map
    // 4. checkpoints → 5. checkpoint_values → 6. checkpoint_variant_map
    // 7. service_cycles → 8. context_overlays

    if (variants?.length) {
      const rows = variants.map((v: any) => ({
        ...v,
        resource_template_id,
        is_active: v.is_active ?? true,
      }));
      const { data, error } = await sb
        .from("m_equipment_variants")
        .upsert(rows, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`variants: ${error.message}`);
      else results.variants = data.length;
    }

    if (spare_parts?.length) {
      const rows = spare_parts.map((sp: any) => ({
        ...sp,
        resource_template_id,
        is_active: sp.is_active ?? true,
      }));
      const { data, error } = await sb
        .from("m_equipment_spare_parts")
        .upsert(rows, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`spare_parts: ${error.message}`);
      else results.spare_parts = data.length;
    }

    if (spare_part_variant_map?.length) {
      const { data, error } = await sb
        .from("m_spare_part_variant_map")
        .upsert(spare_part_variant_map, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`spare_part_variant_map: ${error.message}`);
      else results.spare_part_variant_map = data.length;
    }

    if (checkpoints?.length) {
      const rows = checkpoints.map((cp: any) => ({
        ...cp,
        resource_template_id,
        is_active: cp.is_active ?? true,
      }));
      const { data, error } = await sb
        .from("m_equipment_checkpoints")
        .upsert(rows, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`checkpoints: ${error.message}`);
      else results.checkpoints = data.length;
    }

    if (checkpoint_values?.length) {
      const { data, error } = await sb
        .from("m_checkpoint_values")
        .upsert(checkpoint_values, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`checkpoint_values: ${error.message}`);
      else results.checkpoint_values = data.length;
    }

    if (checkpoint_variant_map?.length) {
      const { data, error } = await sb
        .from("m_checkpoint_variant_map")
        .upsert(checkpoint_variant_map, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`checkpoint_variant_map: ${error.message}`);
      else results.checkpoint_variant_map = data.length;
    }

    if (service_cycles?.length) {
      const rows = service_cycles.map((sc: any) => ({
        ...sc,
        is_active: sc.is_active ?? true,
      }));
      const { data, error } = await sb
        .from("m_service_cycles")
        .upsert(rows, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`service_cycles: ${error.message}`);
      else results.service_cycles = data.length;
    }

    if (context_overlays?.length) {
      const rows = context_overlays.map((co: any) => ({
        ...co,
        resource_template_id,
        is_active: co.is_active ?? true,
      }));
      const { data, error } = await sb
        .from("m_context_overlays")
        .upsert(rows, { onConflict: "id" })
        .select("id");
      if (error) errors.push(`context_overlays: ${error.message}`);
      else results.context_overlays = data.length;
    }
  } catch (e: any) {
    return errorResponse(`Unexpected error: ${e.message}`, 500);
  }

  if (errors.length > 0) {
    return jsonResponse(
      { status: "partial", message: "Some inserts failed", inserted: results, errors },
      207
    );
  }

  return jsonResponse({ status: "success", resource_template_id, inserted: results });
}

// ─── Route: GET /coverage ─────────────────────────────────────────
// Lightweight: returns counts per resource_template_id (no specific ID required)
async function getCoverage() {
  const sb = getSupabaseAdmin();

  const [variantsRes, partsRes, checkpointsRes] = await Promise.all([
    sb.from("m_equipment_variants").select("resource_template_id").eq("is_active", true),
    sb.from("m_equipment_spare_parts").select("resource_template_id").eq("is_active", true),
    sb.from("m_equipment_checkpoints").select("resource_template_id").eq("is_active", true),
  ]);

  if (variantsRes.error) return errorResponse(variantsRes.error.message, 500);
  if (partsRes.error) return errorResponse(partsRes.error.message, 500);
  if (checkpointsRes.error) return errorResponse(checkpointsRes.error.message, 500);

  const coverage: Record<string, { resource_template_id: string; variants_count: number; spare_parts_count: number; checkpoints_count: number }> = {};

  const ensure = (id: string) => {
    if (!coverage[id]) coverage[id] = { resource_template_id: id, variants_count: 0, spare_parts_count: 0, checkpoints_count: 0 };
  };

  for (const r of variantsRes.data || []) { ensure(r.resource_template_id); coverage[r.resource_template_id].variants_count++; }
  for (const r of partsRes.data || []) { ensure(r.resource_template_id); coverage[r.resource_template_id].spare_parts_count++; }
  for (const r of checkpointsRes.data || []) { ensure(r.resource_template_id); coverage[r.resource_template_id].checkpoints_count++; }

  return jsonResponse({ count: Object.keys(coverage).length, coverage });
}

// ─── Main Router ───────────────────────────────────────────────────
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  // Handle both /knowledge-tree/X and just /X (depends on Supabase routing)
  const fullPath = url.pathname;
  const path = fullPath
    .replace(/^\/knowledge-tree\/?/, "")
    .replace(/^\//, "")
    .replace(/\/$/, "");
  const params = url.searchParams;

  // Auth
  const isAdmin = req.headers.get("x-is-admin") === "true";
  const authHeader = req.headers.get("authorization");

  if (!authHeader && !isAdmin) {
    return errorResponse("Authorization required", 401);
  }

  try {
    if (req.method === "GET") {
      switch (path) {
        case "variants":
          return await getVariants(params);
        case "spare-parts":
          return await getSpareParts(params);
        case "checkpoints":
          return await getCheckpoints(params);
        case "cycles":
          return await getCycles(params);
        case "overlays":
          return await getOverlays(params);
        case "summary":
          return await getSummary(params);
        case "coverage":
          return await getCoverage();
        default:
          return errorResponse(
            `Unknown path: /${path}. Valid GET: variants, spare-parts, checkpoints, cycles, overlays, summary, coverage`,
            404
          );
      }
    }

    if (req.method === "POST") {
      const body = await req.json();
      switch (path) {
        case "save":
          return await saveKnowledgeTree(body, isAdmin);
        default:
          return errorResponse(`Unknown path: /${path}. Valid POST: save`, 404);
      }
    }

    return errorResponse("Method not allowed", 405);
  } catch (e: any) {
    return errorResponse(`Internal error: ${e.message}`, 500);
  }
});