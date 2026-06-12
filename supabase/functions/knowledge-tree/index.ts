// knowledge-tree Edge Function
// Serves Knowledge Tree data for ContractNest Smart Forms
// Endpoints:
//   GET  /knowledge-tree/variants?resource_template_id=X
//   GET  /knowledge-tree/spare-parts?resource_template_id=X[&variant_id=Y]
//   GET  /knowledge-tree/checkpoints?resource_template_id=X[&variant_id=Y&service_activity=Z]
//   GET  /knowledge-tree/cycles?resource_template_id=X
//   GET  /knowledge-tree/overlays?resource_template_id=X
//   GET  /knowledge-tree/summary?resource_template_id=X
//   GET  /knowledge-tree/equipment-meta?resource_template_id=X
//   POST /knowledge-tree/save-pricing (admin only — upsert pricing on spare_parts + service_cycles)
//   POST /knowledge-tree/patch-service-names (admin only — UPDATE service_name by section, no wipe)
//   POST /knowledge-tree/patch-variant-map (admin only — REPLACE checkpoint→variant applicability, no other data touched)
//   GET  /knowledge-tree/compliance-defaults?sub_category=X
//   POST /knowledge-tree/save (admin only — transactional insert across all tables)
//   POST /knowledge-tree/equipment-meta (admin only — upsert)
//   POST /knowledge-tree/tag-compliance (admin only — bulk update compliance tags on checkpoints)

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-tenant-id, x-is-admin",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
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

// ─── Route: GET /variants ───────────────────────────────────────────
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

// ─── Route: GET /spare-parts ───────────────────────────────────────────
async function getSpareParts(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const variantId = params.get("variant_id");

  const { data: parts, error: partsErr } = await sb
    .from("m_equipment_spare_parts")
    .select("id, resource_template_id, component_group, name, description, specifications, sort_order, source, price_min, price_median, price_max, price_unit, price_currency, price_geo")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("component_group")
    .order("sort_order", { ascending: true });

  if (partsErr) return errorResponse(partsErr.message, 500);

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

// ─── Route: GET /checkpoints ───────────────────────────────────────────
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

  const { data: values, error: valErr } = await sb
    .from("m_checkpoint_values")
    .select("id, checkpoint_id, label, severity, triggers_part_consumption, requires_photo, sort_order")
    .in("checkpoint_id", cpIds)
    .order("sort_order", { ascending: true });

  if (valErr) return errorResponse(valErr.message, 500);

  let vmQuery = sb
    .from("m_checkpoint_variant_map")
    .select("id, checkpoint_id, variant_id, override_min, override_max, override_amber, override_red")
    .in("checkpoint_id", cpIds);

  if (variantId) {
    vmQuery = vmQuery.eq("variant_id", variantId);
  }

  const { data: variantMap, error: vmErr } = await vmQuery;
  if (vmErr) return errorResponse(vmErr.message, 500);

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

// ─── Route: GET /cycles ──────────────────────────────────────────────
async function getCycles(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

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
    .select("id, checkpoint_id, frequency_value, frequency_unit, varies_by, alert_overdue_days, source, catalog_name, price_min, price_median, price_max, price_currency, price_geo")
    .in("checkpoint_id", cpIds)
    .eq("is_active", true);

  if (cycErr) return errorResponse(cycErr.message, 500);

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

// ─── Route: GET /overlays ──────────────────────────────────────────────
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

// ─── Route: GET /summary ───────────────────────────────────────────────
async function getSummary(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  const { data: template, error: tplErr } = await sb
    .from("m_catalog_resource_templates")
    .select("id, name, description, sub_category, scope, resource_type_id")
    .eq("id", resourceTemplateId)
    .single();

  if (tplErr) return errorResponse(`Resource template not found: ${tplErr.message}`, 404);

  const [variantsRes, partsRes, checkpointsRes, cyclesRes, overlaysRes, metaRes] =
    await Promise.all([
      sb
        .from("m_equipment_variants")
        .select("id, name, description, capacity_range, attributes, sort_order, source")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("sort_order"),
      sb
        .from("m_equipment_spare_parts")
        .select("id, component_group, name, description, specifications, sort_order, source, price_min, price_median, price_max, price_unit, price_currency, price_geo")
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
        .select("id, checkpoint_id, frequency_value, frequency_unit, varies_by, alert_overdue_days, source, catalog_name, price_min, price_median, price_max, price_currency, price_geo")
        .eq("is_active", true),
      sb
        .from("m_context_overlays")
        .select("id, context_type, context_value, adjustments, priority")
        .eq("resource_template_id", resourceTemplateId)
        .eq("is_active", true)
        .order("priority"),
      sb
        .from("kt_equipment_meta")
        .select("id, equipment_criticality, calibration_interval_days, notes")
        .eq("resource_template_id", resourceTemplateId)
        .maybeSingle(),
    ]);

  const variants = variantsRes.data || [];
  const parts = partsRes.data || [];
  const checkpoints = checkpointsRes.data || [];
  const cpIds = checkpoints.map((c: any) => c.id);

  const cycles = (cyclesRes.data || []).filter((cy: any) =>
    cpIds.includes(cy.checkpoint_id)
  );
  const overlays = overlaysRes.data || [];
  const equipmentMeta = metaRes.data || null;

  const partIds = parts.map((p: any) => p.id);
  const [partMapRes, cpMapRes, cpValRes] = await Promise.all([
    partIds.length > 0
      ? sb
          .from("m_spare_part_variant_map")
          .select("id, spare_part_id, variant_id, is_recommended, notes")
          .in("spare_part_id", partIds)
      : Promise.resolve({ data: [], error: null }),
    cpIds.length > 0
      ? sb
          .from("m_checkpoint_variant_map")
          .select("id, checkpoint_id, variant_id, override_min, override_max, override_amber, override_red")
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

  const enrichedCheckpoints = checkpoints.map((cp: any) => ({
    ...cp,
    values: cpValues.filter((v: any) => v.checkpoint_id === cp.id),
    variant_applicability: cpVarMap.filter((m: any) => m.checkpoint_id === cp.id),
  }));

  const cpLookup: Record<string, any> = {};
  for (const cp of checkpoints) cpLookup[cp.id] = cp;

  const enrichedCycles = cycles.map((cy: any) => ({
    ...cy,
    checkpoint_name: cpLookup[cy.checkpoint_id]?.name,
    section_name: cpLookup[cy.checkpoint_id]?.section_name,
    service_activity: cpLookup[cy.checkpoint_id]?.service_activity,
  }));

  // Compliance aggregates
  const complianceStandards = [
    ...new Set(
      checkpoints
        .map((c: any) => c.compliance_standard)
        .filter((s: any) => s != null && s !== "")
    ),
  ];
  const mandatoryCount = checkpoints.filter((c: any) => c.is_mandatory === true).length;

  // Multi-pricing (m_kt_prices): which pricings are ACTIVE per node + coverage
  const allIds = [...cycles.map((c: any) => c.id), ...parts.map((p: any) => p.id)];
  let priceRows: any[] = [];
  if (allIds.length) {
    const { data: pr } = await sb
      .from("m_kt_prices")
      .select("entity_type, entity_id, geo, currency, price_min, price_median, price_max, price_unit, updated_at")
      .in("entity_id", allIds);
    priceRows = pr || [];
  }
  const pricesFor = (type: string, id: string) =>
    priceRows.filter((r: any) => r.entity_type === type && r.entity_id === id);
  const pricingCoverage = Object.values(
    priceRows.reduce((acc: any, r: any) => {
      const k = `${r.currency}/${r.geo}`;
      acc[k] = acc[k] || { currency: r.currency, geo: r.geo, cycles: 0, spare_parts: 0 };
      if (r.entity_type === "service_cycle") acc[k].cycles++;
      else acc[k].spare_parts++;
      return acc;
    }, {})
  );

  // Sellable service definitions (first-class service entity, with descriptions)
  const { data: serviceDefs } = await sb
    .from("m_kt_service_definitions")
    .select("service_name, description, source, updated_at")
    .eq("resource_template_id", resourceTemplateId);

  return jsonResponse({
    resource_template: template,
    equipment_meta: equipmentMeta,
    pricing_coverage: pricingCoverage,
    service_definitions: serviceDefs || [],
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
      compliance_standards: complianceStandards,
      mandatory_count: mandatoryCount,
    },
    variants,
    spare_parts_by_group: groupBy(
      parts.map((part: any) => ({
        ...part,
        variant_applicability: partMap.filter((m: any) => m.spare_part_id === part.id),
        prices: pricesFor("spare_part", part.id),
      })),
      "component_group"
    ),
    checkpoints_by_section: groupBy(enrichedCheckpoints, "section_name"),
    cycles: enrichedCycles.map((cy: any) => ({ ...cy, prices: pricesFor("service_cycle", cy.id) })),
    overlays_by_type: groupBy(overlays, "context_type"),
  });
}

// ─── Route: GET /equipment-meta ───────────────────────────────────────────
async function getEquipmentMeta(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const { data, error } = await sb
    .from("kt_equipment_meta")
    .select("id, resource_template_id, equipment_criticality, calibration_interval_days, notes, updated_at")
    .eq("resource_template_id", resourceTemplateId)
    .maybeSingle();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ equipment_meta: data });
}

// ─── Route: POST /equipment-meta ──────────────────────────────────────────
async function upsertEquipmentMeta(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, equipment_criticality, calibration_interval_days, notes } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");

  const validCriticalities = ["life_critical", "mission_critical", "standard"];
  if (equipment_criticality && !validCriticalities.includes(equipment_criticality)) {
    return errorResponse(`equipment_criticality must be one of: ${validCriticalities.join(", ")}`);
  }

  const sb = getSupabaseAdmin();
  const { data, error } = await sb
    .from("kt_equipment_meta")
    .upsert(
      {
        resource_template_id,
        equipment_criticality: equipment_criticality || "standard",
        calibration_interval_days: calibration_interval_days ?? null,
        notes: notes ?? null,
      },
      { onConflict: "resource_template_id" }
    )
    .select("id, resource_template_id, equipment_criticality, calibration_interval_days, notes, updated_at")
    .single();

  if (error) return errorResponse(error.message, 500);
  return jsonResponse({ status: "success", equipment_meta: data });
}

// ─── Route: GET /compliance-defaults ──────────────────────────────────────────
async function getComplianceDefaults(params: URLSearchParams) {
  const subCategory = params.get("sub_category");

  const sb = getSupabaseAdmin();
  let query = sb
    .from("kt_compliance_defaults")
    .select("id, sub_category, compliance_standard, description")
    .eq("is_active", true)
    .order("sub_category")
    .order("compliance_standard");

  if (subCategory) {
    query = query.eq("sub_category", subCategory);
  }

  const { data, error } = await query;
  if (error) return errorResponse(error.message, 500);

  return jsonResponse({
    count: (data || []).length,
    defaults: data || [],
    by_sub_category: groupBy(data || [], "sub_category"),
  });
}

// ─── Route: POST /tag-compliance ───────────────────────────────────────────
// Bulk update compliance_standard and is_mandatory on checkpoints.
// Body: { resource_template_id, tags: [{ checkpoint_id, compliance_standard, is_mandatory }] }
async function tagCompliance(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, tags } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");
  if (!Array.isArray(tags) || tags.length === 0) return errorResponse("tags array required");

  const sb = getSupabaseAdmin();

  // Verify checkpoints belong to this resource_template
  const cpIds = [...new Set(tags.map((t: any) => t.checkpoint_id))];
  const { data: owned, error: ownErr } = await sb
    .from("m_equipment_checkpoints")
    .select("id")
    .eq("resource_template_id", resource_template_id)
    .in("id", cpIds);

  if (ownErr) return errorResponse(ownErr.message, 500);

  const ownedIds = new Set((owned || []).map((r: any) => r.id));
  const unauthorised = cpIds.filter((id) => !ownedIds.has(id));
  if (unauthorised.length > 0) {
    return errorResponse(`Checkpoints not in this resource template: ${unauthorised.join(", ")}`, 403);
  }

  // Apply updates one-by-one (Supabase doesn't support bulk upsert with different values per row in a single call)
  const errors: string[] = [];
  let updated = 0;

  for (const tag of tags) {
    const patch: Record<string, any> = {};
    if (tag.compliance_standard !== undefined) patch.compliance_standard = tag.compliance_standard || null;
    if (tag.is_mandatory !== undefined) patch.is_mandatory = !!tag.is_mandatory;

    if (Object.keys(patch).length === 0) continue;

    const { error } = await sb
      .from("m_equipment_checkpoints")
      .update(patch)
      .eq("id", tag.checkpoint_id)
      .eq("resource_template_id", resource_template_id);

    if (error) {
      errors.push(`${tag.checkpoint_id}: ${error.message}`);
    } else {
      updated++;
    }
  }

  if (errors.length > 0) {
    return jsonResponse({ status: "partial", updated, errors }, 207);
  }

  return jsonResponse({ status: "success", updated, resource_template_id });
}

// ─── Helper: wipe KT data for a resource_template_id ────────────────
// save_mode controls scope — prevents stepwise saves from wiping unrelated tables.
// 'variants'/'spare_parts'/'checkpoints'/'overlays': wipe only that scope.
// undefined (default): full wipe of all tables (used by manual Save and full AI regen).
async function wipeLiveData(
  sb: any,
  resource_template_id: string,
  service_activity?: string,
  save_mode?: 'variants' | 'spare_parts' | 'checkpoints' | 'service_cycles' | 'overlays',
): Promise<void> {
  // Activity-scoped wipe (+ Install / + Decomm): only checkpoints for that activity
  if (service_activity) {
    const cpRes = await sb
      .from("m_equipment_checkpoints")
      .select("id")
      .eq("resource_template_id", resource_template_id)
      .eq("service_activity", service_activity);
    const cpIds = (cpRes.data || []).map((r: any) => r.id);

    if (cpIds.length) {
      await Promise.all([
        sb.from("m_service_cycles").delete().in("checkpoint_id", cpIds),
        sb.from("m_checkpoint_variant_map").delete().in("checkpoint_id", cpIds),
        sb.from("m_checkpoint_values").delete().in("checkpoint_id", cpIds),
      ]);
      await sb.from("m_equipment_checkpoints").delete().in("id", cpIds);
    }
    return;
  }

  // Stepwise saves: only wipe the tables being replaced, leave everything else intact
  if (save_mode === 'variants') {
    await sb.from("m_equipment_variants").delete().eq("resource_template_id", resource_template_id);
    return;
  }

  if (save_mode === 'spare_parts') {
    const partRes = await sb.from("m_equipment_spare_parts").select("id").eq("resource_template_id", resource_template_id);
    const partIds = (partRes.data || []).map((r: any) => r.id);
    if (partIds.length) {
      await sb.from("m_spare_part_variant_map").delete().in("spare_part_id", partIds);
    }
    await sb.from("m_equipment_spare_parts").delete().eq("resource_template_id", resource_template_id);
    return;
  }

  if (save_mode === 'checkpoints') {
    // Wipes checkpoints + values + variant_map only.
    // service_cycles are managed independently via save_mode:'service_cycles'.
    const cpRes = await sb.from("m_equipment_checkpoints").select("id").eq("resource_template_id", resource_template_id);
    const cpIds = (cpRes.data || []).map((r: any) => r.id);
    if (cpIds.length) {
      await Promise.all([
        sb.from("m_checkpoint_variant_map").delete().in("checkpoint_id", cpIds),
        sb.from("m_checkpoint_values").delete().in("checkpoint_id", cpIds),
      ]);
    }
    await sb.from("m_equipment_checkpoints").delete().eq("resource_template_id", resource_template_id);
    return;
  }

  if (save_mode === 'service_cycles') {
    // Wipes only service_cycles for this resource template (via checkpoint_ids).
    const cpRes = await sb.from("m_equipment_checkpoints").select("id").eq("resource_template_id", resource_template_id);
    const cpIds = (cpRes.data || []).map((r: any) => r.id);
    if (cpIds.length) {
      await sb.from("m_service_cycles").delete().in("checkpoint_id", cpIds);
    }
    return;
  }

  if (save_mode === 'overlays') {
    await sb.from("m_context_overlays").delete().eq("resource_template_id", resource_template_id);
    return;
  }

  // Full wipe (default — manual Save Changes and full AI regeneration)
  const [partRes, cpRes] = await Promise.all([
    sb.from("m_equipment_spare_parts").select("id").eq("resource_template_id", resource_template_id),
    sb.from("m_equipment_checkpoints").select("id").eq("resource_template_id", resource_template_id),
  ]);

  const partIds = (partRes.data || []).map((r: any) => r.id);
  const cpIds = (cpRes.data || []).map((r: any) => r.id);

  if (cpIds.length) {
    await Promise.all([
      sb.from("m_service_cycles").delete().in("checkpoint_id", cpIds),
      sb.from("m_checkpoint_variant_map").delete().in("checkpoint_id", cpIds),
      sb.from("m_checkpoint_values").delete().in("checkpoint_id", cpIds),
    ]);
  }
  if (partIds.length) {
    await sb.from("m_spare_part_variant_map").delete().in("spare_part_id", partIds);
  }

  await Promise.all([
    sb.from("m_equipment_checkpoints").delete().eq("resource_template_id", resource_template_id),
    sb.from("m_equipment_spare_parts").delete().eq("resource_template_id", resource_template_id),
    sb.from("m_context_overlays").delete().eq("resource_template_id", resource_template_id),
  ]);
  await sb.from("m_equipment_variants").delete().eq("resource_template_id", resource_template_id);
}

// ─── Route: POST /save ───────────────────────────────────────────────────
async function saveKnowledgeTree(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const {
    resource_template_id,
    save_mode,
    service_activity,
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
  const isActivitySave = !!service_activity && !variants?.length;

  await wipeLiveData(sb, resource_template_id, isActivitySave ? service_activity : undefined, save_mode);

  const results: Record<string, number> = {};
  const errors: string[] = [];

  try {
    if (!isActivitySave) {
      if (variants?.length) {
        const rows = variants.map((v: any) => ({ ...v, resource_template_id, is_active: v.is_active ?? true }));
        const { data, error } = await sb.from("m_equipment_variants").insert(rows).select("id");
        if (error) errors.push(`variants: ${error.message}`);
        else results.variants = data.length;
      }
      if (spare_parts?.length) {
        const rows = spare_parts.map((sp: any) => ({ ...sp, resource_template_id, is_active: sp.is_active ?? true }));
        const { data, error } = await sb.from("m_equipment_spare_parts").insert(rows).select("id");
        if (error) errors.push(`spare_parts: ${error.message}`);
        else results.spare_parts = data.length;
      }
      if (spare_part_variant_map?.length) {
        const { data, error } = await sb.from("m_spare_part_variant_map").insert(spare_part_variant_map).select("id");
        if (error) errors.push(`spare_part_variant_map: ${error.message}`);
        else results.spare_part_variant_map = data.length;
      }
      if (context_overlays?.length) {
        const rows = context_overlays.map((co: any) => ({ ...co, resource_template_id, is_active: co.is_active ?? true }));
        const { data, error } = await sb.from("m_context_overlays").insert(rows).select("id");
        if (error) errors.push(`context_overlays: ${error.message}`);
        else results.context_overlays = data.length;
      }
    }

    if (checkpoints?.length) {
      const rows = checkpoints.map((cp: any) => ({
        ...cp,
        resource_template_id,
        is_active: cp.is_active ?? true,
        compliance_standard: cp.compliance_standard ?? null,
        is_mandatory: cp.is_mandatory ?? false,
        service_name: cp.service_name ?? null,
      }));
      const { data, error } = await sb.from("m_equipment_checkpoints").insert(rows).select("id");
      if (error) errors.push(`checkpoints: ${error.message}`);
      else results.checkpoints = data.length;
    }
    if (checkpoint_values?.length) {
      const { data, error } = await sb.from("m_checkpoint_values").insert(checkpoint_values).select("id");
      if (error) errors.push(`checkpoint_values: ${error.message}`);
      else results.checkpoint_values = data.length;
    }
    if (checkpoint_variant_map?.length) {
      const { data, error } = await sb.from("m_checkpoint_variant_map").insert(checkpoint_variant_map).select("id");
      if (error) errors.push(`checkpoint_variant_map: ${error.message}`);
      else results.checkpoint_variant_map = data.length;
    }
    if (service_cycles?.length) {
      const rows = service_cycles.map((sc: any) => ({
        ...sc,
        is_active: sc.is_active ?? true,
        catalog_name: sc.catalog_name ?? null,
      }));
      const { data, error } = await sb.from("m_service_cycles").insert(rows).select("id");
      if (error) errors.push(`service_cycles: ${error.message}`);
      else results.service_cycles = data.length;
    }
  } catch (e: any) {
    return errorResponse(`Unexpected error during insert: ${e.message}`, 500);
  }

  if (errors.length > 0) {
    return jsonResponse({ status: "partial", message: "Some inserts failed", inserted: results, errors }, 207);
  }

  try {
    await createSnapshot(
      {
        resource_template_id,
        snapshot_type: isActivitySave ? "activity_added" : "ai_generated",
        notes: isActivitySave
          ? `Auto: ${service_activity} activity generated by VaNi`
          : "Auto: Knowledge tree generated by VaNi",
      },
      true,
    );
  } catch (snapErr: any) {
    console.warn("Auto-snapshot failed (non-critical):", snapErr?.message);
  }

  return jsonResponse({ status: "success", resource_template_id, inserted: results });
}

// ─── Route: POST /delete ────────────────────────────────────────────────
async function deleteKnowledgeTree(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  try {
    await wipeLiveData(sb, resource_template_id);
    await sb.from("m_knowledge_tree_snapshots").delete().eq("resource_template_id", resource_template_id);
    await sb.from("kt_equipment_meta").delete().eq("resource_template_id", resource_template_id);
  } catch (e: any) {
    return errorResponse(`Delete failed: ${e.message}`, 500);
  }

  return jsonResponse({ status: "success", resource_template_id });
}

// ─── Route: GET /coverage ───────────────────────────────────────────────
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

// ─── Route: POST /snapshot ──────────────────────────────────────────────
async function createSnapshot(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, snapshot_type, notes, created_by } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  const [varRes, partsRes, cpRes, valRes, cycRes, ovRes] = await Promise.all([
    sb.from("m_equipment_variants").select("*").eq("resource_template_id", resource_template_id).eq("is_active", true),
    sb.from("m_equipment_spare_parts").select("*").eq("resource_template_id", resource_template_id).eq("is_active", true),
    sb.from("m_equipment_checkpoints").select("*").eq("resource_template_id", resource_template_id).eq("is_active", true),
    sb.from("m_checkpoint_values").select("*"),
    sb.from("m_service_cycles").select("*").eq("is_active", true),
    sb.from("m_context_overlays").select("*").eq("resource_template_id", resource_template_id).eq("is_active", true),
  ]);

  const variants = varRes.data || [];
  const spareParts = partsRes.data || [];
  const checkpoints = cpRes.data || [];
  const cpIds = checkpoints.map((c: any) => c.id);
  const partIds = spareParts.map((p: any) => p.id);

  const checkpointValues = (valRes.data || []).filter((v: any) => cpIds.includes(v.checkpoint_id));
  const serviceCycles = (cycRes.data || []).filter((c: any) => cpIds.includes(c.checkpoint_id));

  const [spvmRes, cvmRes] = await Promise.all([
    partIds.length > 0
      ? sb.from("m_spare_part_variant_map").select("*").in("spare_part_id", partIds)
      : Promise.resolve({ data: [], error: null }),
    cpIds.length > 0
      ? sb.from("m_checkpoint_variant_map").select("*").in("checkpoint_id", cpIds)
      : Promise.resolve({ data: [], error: null }),
  ]);

  const snapshotData = {
    variants,
    spare_parts: spareParts,
    spare_part_variant_map: spvmRes.data || [],
    checkpoints,
    checkpoint_values: checkpointValues,
    checkpoint_variant_map: cvmRes.data || [],
    service_cycles: serviceCycles,
    context_overlays: ovRes.data || [],
    _meta: {
      captured_at: new Date().toISOString(),
      counts: {
        variants: variants.length,
        spare_parts: spareParts.length,
        spare_part_variant_map: (spvmRes.data || []).length,
        checkpoints: checkpoints.length,
        checkpoint_values: checkpointValues.length,
        checkpoint_variant_map: (cvmRes.data || []).length,
        service_cycles: serviceCycles.length,
        context_overlays: (ovRes.data || []).length,
      },
    },
  };

  const { data, error } = await sb
    .from("m_knowledge_tree_snapshots")
    .insert({
      resource_template_id,
      snapshot_type: snapshot_type || "auto_backup",
      snapshot_data: snapshotData,
      notes: notes || null,
      created_by: created_by || null,
    })
    .select("id, version, snapshot_type, created_at")
    .single();

  if (error) return errorResponse(error.message, 500);

  return jsonResponse({
    status: "success",
    snapshot: data,
    counts: snapshotData._meta.counts,
  });
}

// ─── Route: GET /snapshots ──────────────────────────────────────────────
async function getSnapshots(params: URLSearchParams) {
  const resourceTemplateId = params.get("resource_template_id");
  if (!resourceTemplateId) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();
  const { data, error } = await sb
    .from("m_knowledge_tree_snapshots")
    .select("id, version, snapshot_type, notes, created_by, created_at, snapshot_data->_meta->counts")
    .eq("resource_template_id", resourceTemplateId)
    .eq("is_active", true)
    .order("version", { ascending: false });

  if (error) return errorResponse(error.message, 500);

  const snapshots = (data || []).map((row: any) => ({
    id: row.id,
    version: row.version,
    snapshot_type: row.snapshot_type,
    notes: row.notes,
    created_by: row.created_by,
    created_at: row.created_at,
    counts: row.counts || {},
  }));

  return jsonResponse({ count: snapshots.length, snapshots });
}

// ─── Route: POST /restore ──────────────────────────────────────────────
async function restoreSnapshot(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { snapshot_id, resource_template_id } = body;
  if (!snapshot_id) return errorResponse("snapshot_id required");
  if (!resource_template_id) return errorResponse("resource_template_id required");

  const sb = getSupabaseAdmin();

  const { data: snapshot, error: snapErr } = await sb
    .from("m_knowledge_tree_snapshots")
    .select("id, version, snapshot_type, snapshot_data")
    .eq("id", snapshot_id)
    .eq("resource_template_id", resource_template_id)
    .eq("is_active", true)
    .single();

  if (snapErr || !snapshot) return errorResponse(`Snapshot not found: ${snapErr?.message || "no data"}`, 404);

  const sd = snapshot.snapshot_data;

  await createSnapshot(
    { resource_template_id, snapshot_type: "pre_restore", notes: `Auto-backup before restoring to v${snapshot.version}` },
    true,
  );

  await sb.from("m_context_overlays").delete().eq("resource_template_id", resource_template_id);
  const existingCps = await sb.from("m_equipment_checkpoints").select("id").eq("resource_template_id", resource_template_id);
  const existingCpIds = (existingCps.data || []).map((c: any) => c.id);
  if (existingCpIds.length > 0) {
    await sb.from("m_service_cycles").delete().in("checkpoint_id", existingCpIds);
    await sb.from("m_checkpoint_variant_map").delete().in("checkpoint_id", existingCpIds);
    await sb.from("m_checkpoint_values").delete().in("checkpoint_id", existingCpIds);
  }
  await sb.from("m_equipment_checkpoints").delete().eq("resource_template_id", resource_template_id);
  const existingParts = await sb.from("m_equipment_spare_parts").select("id").eq("resource_template_id", resource_template_id);
  const existingPartIds = (existingParts.data || []).map((p: any) => p.id);
  if (existingPartIds.length > 0) {
    await sb.from("m_spare_part_variant_map").delete().in("spare_part_id", existingPartIds);
  }
  await sb.from("m_equipment_spare_parts").delete().eq("resource_template_id", resource_template_id);
  await sb.from("m_equipment_variants").delete().eq("resource_template_id", resource_template_id);

  const errors: string[] = [];
  const inserted: Record<string, number> = {};

  if (sd.variants?.length) {
    const { data: d, error: e } = await sb.from("m_equipment_variants").insert(sd.variants).select("id");
    if (e) errors.push(`variants: ${e.message}`); else inserted.variants = d.length;
  }
  if (sd.spare_parts?.length) {
    const { data: d, error: e } = await sb.from("m_equipment_spare_parts").insert(sd.spare_parts).select("id");
    if (e) errors.push(`spare_parts: ${e.message}`); else inserted.spare_parts = d.length;
  }
  if (sd.spare_part_variant_map?.length) {
    const { data: d, error: e } = await sb.from("m_spare_part_variant_map").insert(sd.spare_part_variant_map).select("id");
    if (e) errors.push(`spare_part_variant_map: ${e.message}`); else inserted.spare_part_variant_map = d.length;
  }
  if (sd.checkpoints?.length) {
    const { data: d, error: e } = await sb.from("m_equipment_checkpoints").insert(sd.checkpoints).select("id");
    if (e) errors.push(`checkpoints: ${e.message}`); else inserted.checkpoints = d.length;
  }
  if (sd.checkpoint_values?.length) {
    const { data: d, error: e } = await sb.from("m_checkpoint_values").insert(sd.checkpoint_values).select("id");
    if (e) errors.push(`checkpoint_values: ${e.message}`); else inserted.checkpoint_values = d.length;
  }
  if (sd.checkpoint_variant_map?.length) {
    const { data: d, error: e } = await sb.from("m_checkpoint_variant_map").insert(sd.checkpoint_variant_map).select("id");
    if (e) errors.push(`checkpoint_variant_map: ${e.message}`); else inserted.checkpoint_variant_map = d.length;
  }
  if (sd.service_cycles?.length) {
    const { data: d, error: e } = await sb.from("m_service_cycles").insert(sd.service_cycles).select("id");
    if (e) errors.push(`service_cycles: ${e.message}`); else inserted.service_cycles = d.length;
  }
  if (sd.context_overlays?.length) {
    const { data: d, error: e } = await sb.from("m_context_overlays").insert(sd.context_overlays).select("id");
    if (e) errors.push(`context_overlays: ${e.message}`); else inserted.context_overlays = d.length;
  }

  if (errors.length > 0) {
    return jsonResponse({ status: "partial", message: "Restore had errors", restored_from: `v${snapshot.version}`, inserted, errors }, 207);
  }

  return jsonResponse({ status: "success", restored_from: `v${snapshot.version}`, inserted });
}

// ─── Route: POST /patch-service-names ────────────────────────────────────────
// Option A: Patch service_name on existing checkpoints by section_name — no data wipe.
// Body: { resource_template_id, service_names: [{ section_name, service_name }] }
async function patchServiceNames(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, service_names } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");
  if (!Array.isArray(service_names) || service_names.length === 0) return errorResponse("service_names array required");

  const sb = getSupabaseAdmin();
  const errors: string[] = [];
  let updated = 0;

  for (const entry of service_names) {
    if (!entry.section_name || !entry.service_name) {
      errors.push(`Missing section_name or service_name in entry: ${JSON.stringify(entry)}`);
      continue;
    }
    const { error, count } = await sb
      .from("m_equipment_checkpoints")
      .update({ service_name: entry.service_name })
      .eq("resource_template_id", resource_template_id)
      .eq("section_name", entry.section_name)
      .eq("is_active", true);

    if (error) {
      errors.push(`section "${entry.section_name}": ${error.message}`);
    } else {
      updated += count ?? 0;
    }

    // Service definition: one row per sellable service; description stored ONCE
    // (founder decision — m_kt_service_definitions, not repeated on checkpoints)
    const { error: defError } = await sb
      .from("m_kt_service_definitions")
      .upsert({
        resource_template_id,
        service_name: entry.service_name,
        ...(entry.description ? { description: entry.description } : {}),
        source: "generated",
        updated_at: new Date().toISOString(),
      }, { onConflict: "resource_template_id,service_name" });
    if (defError) errors.push(`service_definition "${entry.service_name}": ${defError.message}`);
  }

  if (errors.length > 0) {
    return jsonResponse({ status: "partial", updated, errors }, 207);
  }

  return jsonResponse({ status: "success", resource_template_id, sections_patched: service_names.length, checkpoints_updated: updated });
}

// ─── Route: POST /patch-variant-map ──────────────────────────────────────────
// Patch: Replace checkpoint→variant applicability for an existing KT — no other data touched.
// Empty map after replace = every checkpoint applies to all variants (mapper fallback).
// Body: { resource_template_id, checkpoint_variant_map: [{ id?, checkpoint_id, variant_id, override_min, override_max }] }
async function patchVariantMap(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, checkpoint_variant_map } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");
  if (!Array.isArray(checkpoint_variant_map)) return errorResponse("checkpoint_variant_map array required (empty array = all checkpoints universal)");

  const sb = getSupabaseAdmin();

  // Scope safety: only accept IDs that belong to this template
  const [cpRes, varRes] = await Promise.all([
    sb.from("m_equipment_checkpoints").select("id").eq("resource_template_id", resource_template_id),
    sb.from("m_equipment_variants").select("id").eq("resource_template_id", resource_template_id),
  ]);
  if (cpRes.error) return errorResponse(`checkpoints lookup: ${cpRes.error.message}`, 500);
  if (varRes.error) return errorResponse(`variants lookup: ${varRes.error.message}`, 500);

  const cpIds = new Set((cpRes.data || []).map((r: any) => r.id));
  const varIds = new Set((varRes.data || []).map((r: any) => r.id));
  if (cpIds.size === 0) return errorResponse("No checkpoints found for this resource_template_id");

  const rows = checkpoint_variant_map
    .filter((m: any) => cpIds.has(m.checkpoint_id) && varIds.has(m.variant_id))
    .map((m: any) => ({
      ...(m.id ? { id: m.id } : {}),
      checkpoint_id: m.checkpoint_id,
      variant_id: m.variant_id,
      override_min: m.override_min ?? null,
      override_max: m.override_max ?? null,
    }));
  const skipped = checkpoint_variant_map.length - rows.length;

  // Replace semantics: wipe existing map for this template's checkpoints, insert fresh
  const { error: delError } = await sb
    .from("m_checkpoint_variant_map")
    .delete()
    .in("checkpoint_id", Array.from(cpIds));
  if (delError) return errorResponse(`wipe failed: ${delError.message}`, 500);

  let inserted = 0;
  if (rows.length) {
    const { data, error: insError } = await sb.from("m_checkpoint_variant_map").insert(rows).select("id");
    if (insError) return errorResponse(`insert failed after wipe: ${insError.message}`, 500);
    inserted = data?.length ?? 0;
  }

  return jsonResponse({
    status: "success",
    resource_template_id,
    mappings_inserted: inserted,
    skipped_foreign_ids: skipped,
    variant_specific_checkpoints: new Set(rows.map((r: any) => r.checkpoint_id)).size,
  });
}

// ─── Route: POST /save-pricing ────────────────────────────────────────────────
// Step 5: Upsert pricing fields only — does NOT wipe/replace any KT data.
// Body: {
//   resource_template_id,
//   currency,  // e.g. "INR", "USD"
//   geo,       // e.g. "IN", "US"
//   spare_parts: [{ id, price_min, price_median, price_max, price_unit }],
//   service_cycles: [{ id, price_min, price_median, price_max }]
// }
async function savePricing(body: any, isAdmin: boolean) {
  if (!isAdmin) return errorResponse("Admin access required", 403);

  const { resource_template_id, currency = "INR", geo = "IN", spare_parts = [], service_cycles = [] } = body;
  if (!resource_template_id) return errorResponse("resource_template_id required");
  if (!spare_parts.length && !service_cycles.length) return errorResponse("spare_parts or service_cycles required");

  const sb = getSupabaseAdmin();
  const errors: string[] = [];
  const updated: Record<string, number> = {};

  // KT MULTI-PRICING FIX (founder bug): pricing is now upserted per
  // (entity, geo) into m_kt_prices — generating USD no longer destroys INR.
  // The legacy single-slot columns are updated ONLY when the incoming geo
  // matches the slot's current geo, or the slot is empty.
  const upsertPrice = async (entityType: string, row: any, priceUnit?: string | null) => {
    const { error } = await sb
      .from("m_kt_prices")
      .upsert({
        entity_type: entityType,
        entity_id: row.id,
        geo,
        currency,
        price_min: row.price_min ?? null,
        price_median: row.price_median ?? null,
        price_max: row.price_max ?? null,
        price_unit: priceUnit ?? null,
        source: "generated",
        updated_at: new Date().toISOString(),
      }, { onConflict: "entity_type,entity_id,geo" });
    return error;
  };

  // Update spare parts pricing
  for (const sp of spare_parts) {
    if (!sp.id) { errors.push("spare_part missing id"); continue; }
    const upErr = await upsertPrice("spare_part", sp, sp.price_unit);
    if (upErr) { errors.push(`spare_part ${sp.id}: ${upErr.message}`); continue; }

    // Legacy slot policy (founder: INR is default): home geo 'IN' ALWAYS owns
    // the slot; other geos may only fill an empty slot.
    let slotQuery = sb
      .from("m_equipment_spare_parts")
      .update({
        price_min: sp.price_min ?? null,
        price_median: sp.price_median ?? null,
        price_max: sp.price_max ?? null,
        price_unit: sp.price_unit ?? null,
        price_currency: currency,
        price_geo: geo,
      })
      .eq("id", sp.id)
      .eq("resource_template_id", resource_template_id);
    if (geo !== "IN") slotQuery = slotQuery.or(`price_geo.is.null,price_geo.eq.${geo}`);
    const { error } = await slotQuery;
    if (error) errors.push(`spare_part ${sp.id}: ${error.message}`);
    else updated.spare_parts = (updated.spare_parts || 0) + 1;
  }

  // Update service cycles pricing
  for (const sc of service_cycles) {
    if (!sc.id) { errors.push("service_cycle missing id"); continue; }
    const upErr = await upsertPrice("service_cycle", sc);
    if (upErr) { errors.push(`service_cycle ${sc.id}: ${upErr.message}`); continue; }

    let cycleSlotQuery = sb
      .from("m_service_cycles")
      .update({
        price_min: sc.price_min ?? null,
        price_median: sc.price_median ?? null,
        price_max: sc.price_max ?? null,
        price_currency: currency,
        price_geo: geo,
      })
      .eq("id", sc.id);
    if (geo !== "IN") cycleSlotQuery = cycleSlotQuery.or(`price_geo.is.null,price_geo.eq.${geo}`);
    const { error } = await cycleSlotQuery;
    if (error) errors.push(`service_cycle ${sc.id}: ${error.message}`);
    else updated.service_cycles = (updated.service_cycles || 0) + 1;

    // Layer 2: currency-neutral per-variant multipliers (relative to the cycle
    // median) — upserted per (cycle, variant), so re-runs in ANY currency refresh
    // the same rows instead of duplicating.
    if (Array.isArray(sc.variant_multipliers) && sc.variant_multipliers.length) {
      for (const vm of sc.variant_multipliers) {
        const mult = Number(vm?.multiplier);
        if (!vm?.variant_id || !Number.isFinite(mult) || mult <= 0 || mult > 20) {
          errors.push(`cycle ${sc.id}: invalid multiplier entry ${JSON.stringify(vm)}`);
          continue;
        }
        const { error: vmErr } = await sb
          .from("m_kt_variant_price_multipliers")
          .upsert({
            service_cycle_id: sc.id,
            variant_id: vm.variant_id,
            multiplier: mult,
            source: "generated",
            updated_at: new Date().toISOString(),
          }, { onConflict: "service_cycle_id,variant_id" });
        if (vmErr) errors.push(`cycle ${sc.id} variant ${vm.variant_id}: ${vmErr.message}`);
        else updated.variant_multipliers = (updated.variant_multipliers || 0) + 1;
      }
    }
  }

  if (errors.length > 0) {
    return jsonResponse({ status: "partial", updated, errors }, 207);
  }

  return jsonResponse({ status: "success", resource_template_id, currency, geo, updated });
}

// ─── Main Router ──────────────────────────────────────────────────────────────
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const url = new URL(req.url);
  const fullPath = url.pathname;
  const path = fullPath
    .replace(/^\/knowledge-tree\/?/, "")
    .replace(/^\//, "")
    .replace(/\/$/, "");
  const params = url.searchParams;

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
        case "snapshots":
          return await getSnapshots(params);
        case "equipment-meta":
          return await getEquipmentMeta(params);
        case "compliance-defaults":
          return await getComplianceDefaults(params);
        default:
          return errorResponse(
            `Unknown path: /${path}. Valid GET: variants, spare-parts, checkpoints, cycles, overlays, summary, coverage, snapshots, equipment-meta, compliance-defaults`,
            404
          );
      }
    }

    if (req.method === "POST") {
      const body = await req.json();
      switch (path) {
        case "save":
          return await saveKnowledgeTree(body, isAdmin);
        case "delete":
          return await deleteKnowledgeTree(body, isAdmin);
        case "snapshot":
          return await createSnapshot(body, isAdmin);
        case "restore":
          return await restoreSnapshot(body, isAdmin);
        case "equipment-meta":
          return await upsertEquipmentMeta(body, isAdmin);
        case "tag-compliance":
          return await tagCompliance(body, isAdmin);
        case "save-pricing":
          return await savePricing(body, isAdmin);
        case "patch-service-names":
          return await patchServiceNames(body, isAdmin);
        case "patch-variant-map":
          return await patchVariantMap(body, isAdmin);
        default:
          return errorResponse(`Unknown path: /${path}. Valid POST: save, delete, snapshot, restore, equipment-meta, tag-compliance, save-pricing, patch-service-names, patch-variant-map`, 404);
      }
    }

    return errorResponse("Method not allowed", 405);
  } catch (e: any) {
    return errorResponse(`Internal error: ${e.message}`, 500);
  }
});
