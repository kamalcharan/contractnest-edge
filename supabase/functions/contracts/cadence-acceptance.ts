// supabase/functions/contracts/cadence-acceptance.ts
// Buyer-selected cadence at acceptance (cadence pricing step 2c).
//
// Locked owner decisions:
//   - The seller PROPOSES a cadence; at sign-off the buyer may pick any other
//     enabled cadence from the block's rate card that fits the contract term.
//   - The seller's hand-set final payment applies ONLY to the cadence it was
//     set for — a switched cadence uses the standard remainder suggestion.
//   - Applies to sign-off-link acceptance only (auto/payment acceptance keep
//     the seller's proposal — handled upstream by never offering the picker).
//
// SECURITY MODEL: this endpoint is public (CNAK + secret is the auth), so the
// client may only send {block_id, cycle}. EVERY amount is recomputed here from
// the STORED rate card (t_contract_blocks.custom_fields.config.cadencePricing)
// — client-supplied amounts are never trusted, never even read.
//
// ⚠ PARITY CONTRACT: the math below is a 1:1 port of the UI/API sources:
//   - cadenceTermMath        → contractnest-ui src/utils/catalog-studio/cadencePricing.ts
//   - regenerateBillingEvents→ the cadence billing branch of
//                              contractnest-ui src/utils/service-contracts/contractEvents.ts
//                              (== contractnest-api contractEventsDerivationService.ts)
// If any of those change, change this file the same way. This module is pure
// (no Deno / supabase imports) so it can be diff-tested against the UI math.

// ── Shared constants (mirror CADENCE_CYCLES / cycleToPeriodDays / cycleLabel) ──

export const CADENCE_MONTHS: Record<string, number> = {
  monthly: 1,
  quarterly: 3,
  halfyearly: 6,
  annual: 12,
};

export const CADENCE_PERIOD_DAYS: Record<string, number> = {
  monthly: 30,
  quarterly: 90,
  halfyearly: 182,
  annual: 365,
};

export const CADENCE_LABEL: Record<string, string> = {
  monthly: 'Monthly',
  quarterly: 'Quarterly',
  halfyearly: '6-Monthly',
  annual: 'Annual',
};

// ── Types (subset of the stored JSONB shapes) ──

export interface StoredCadenceRate {
  cycle: string;
  amount: number;
  enabled: boolean;
}

export interface StoredCadencePricing {
  baseAmount: number;
  baseMonths: number;
  rates: StoredCadenceRate[];
  defaultCadence?: string;
}

export interface StoredBlockRow {
  id: string;
  source_block_id: string | null;
  block_name: string;
  category_id: string | null;
  unit_price: number;
  quantity: number;
  billing_cycle: string;
  total_price: number;
  custom_fields: {
    currency?: string;
    originalId?: string;
    config?: {
      customPrice?: number;
      cadencePricing?: StoredCadencePricing;
      cadenceFinalPayment?: number;
      cadenceOverrides?: Record<string, number>;
      [k: string]: unknown;
    };
    [k: string]: unknown;
  } | null;
}

export interface ComputedEventEntry {
  block_id?: string;
  block_name?: string;
  category_id?: string;
  event_type: string;
  billing_sub_type?: string;
  billing_cycle_label?: string;
  sequence_number?: number;
  total_occurrences?: number;
  scheduled_date: string;
  amount?: number;
  currency?: string;
  [k: string]: unknown;
}

export interface CadenceSelection {
  block_id: string; // t_contract_blocks row id
  cycle: string;    // monthly | quarterly | halfyearly | annual
}

export interface RepriceResult {
  blockRowId: string;
  newCycle: string;
  newUnitPrice: number;
  newTotalPrice: number;
  newCustomFields: Record<string, unknown>;
  /** Deltas against the stored row (rounded to 2dp) */
  deltaPreTax: number;
  deltaTax: number;
  deltaTotal: number;
  /** Regenerated billing events for this block (mapper JSONB schema) */
  billingEvents: ComputedEventEntry[];
  /** computed_events block_id key these events replace */
  eventsBlockId: string;
}

const round2 = (n: number): number => Math.round(n * 100) / 100;

// ── cadenceTermMath — verbatim port (cadencePricing.ts) ──

export function cadenceTermMath(
  rate: number,
  durationMonths: number,
  monthsPerPeriod: number,
  sellerFinal?: number
): { fullPayments: number; remMonths: number; suggestedFinal: number; finalPayment: number; termTotal: number } {
  const fullPayments = Math.max(0, Math.floor(durationMonths / monthsPerPeriod));
  const remMonths = Math.max(0, durationMonths - fullPayments * monthsPerPeriod);
  const suggestedFinal = remMonths > 0 ? Math.round((rate * remMonths) / monthsPerPeriod) : 0;
  const finalPayment = remMonths > 0 ? (sellerFinal ?? suggestedFinal) : 0;
  return { fullPayments, remMonths, suggestedFinal, finalPayment, termTotal: rate * fullPayments + finalPayment };
}

// ── durationToDays — verbatim port (contractEvents.ts) ──

export function durationToDays(value: number, unit: string): number {
  switch (unit) {
    case 'days': return value;
    case 'months': return value * 30;
    case 'years': return value * 365;
    default: return value * 30;
  }
}

function addDays(date: Date, days: number): Date {
  const result = new Date(date);
  result.setDate(result.getDate() + days);
  return result;
}

// ── Repricing + billing-event regeneration for one buyer selection ──

export function repriceBlockForCadence(input: {
  row: StoredBlockRow;
  cycle: string;                 // buyer-chosen cadence
  durationValue: number;
  durationUnit: string;
  contractStart: Date;           // anchor for regenerated billing events
  contractCurrency: string;
}): { ok: true; result: RepriceResult } | { ok: false; error: string } {
  const { row, cycle, durationValue, durationUnit, contractStart, contractCurrency } = input;

  const cfg = row.custom_fields?.config || {};
  const card = cfg.cadencePricing;
  if (!card || !Array.isArray(card.rates)) {
    return { ok: false, error: `Block "${row.block_name}" is not cadence-priced` };
  }

  const monthsPerPeriod = CADENCE_MONTHS[cycle];
  if (!monthsPerPeriod) {
    return { ok: false, error: `Unknown cadence "${cycle}"` };
  }

  const rateEntry = card.rates.find((r) => r.cycle === cycle && r.enabled !== false && r.amount > 0);
  if (!rateEntry) {
    return { ok: false, error: `Cadence "${cycle}" is not offered for "${row.block_name}"` };
  }

  const totalDays = durationToDays(durationValue, durationUnit);
  const durationMonths = Math.max(1, Math.round(totalDays / 30));
  if (monthsPerPeriod > durationMonths) {
    return { ok: false, error: `Cadence "${cycle}" does not fit the ${durationMonths}-month term` };
  }

  // ── Effective tax factor, backed out of the STORED totals ──
  // total_price is the tax-inclusive term total the seller sent; the pre-tax
  // term total is reproducible from the stored rate + seller final. Their
  // ratio is the block's effective tax factor — no tax columns needed.
  const oldMonths = CADENCE_MONTHS[row.billing_cycle] || monthsPerPeriod;
  const oldEffRate = typeof cfg.customPrice === 'number' ? cfg.customPrice : row.unit_price;
  const oldMath = cadenceTermMath(
    oldEffRate,
    durationMonths,
    oldMonths,
    typeof cfg.cadenceFinalPayment === 'number' ? cfg.cadenceFinalPayment : undefined
  );
  const taxFactor = oldMath.termTotal > 0 ? row.total_price / oldMath.termTotal : 1;

  // ── New cadence: seller's per-cadence override rate wins over the card rate;
  //     the seller's final payment does NOT carry to a cadence they didn't set it for ──
  const overrideRate = cfg.cadenceOverrides?.[cycle];
  const newEffRate = typeof overrideRate === 'number' && overrideRate > 0 ? overrideRate : rateEntry.amount;
  const newMath = cadenceTermMath(newEffRate, durationMonths, monthsPerPeriod);
  const newTotal = round2(newMath.termTotal * taxFactor);

  // ── Regenerate this block's billing events (verbatim branch port) ──
  const eventsBlockId = row.source_block_id || (row.custom_fields?.originalId as string) || row.id;
  const currency = row.custom_fields?.currency || contractCurrency;
  const periodDays = CADENCE_PERIOD_DAYS[cycle];
  const endDate = addDays(contractStart, totalDays);

  const blockTotal = newTotal;
  const preTaxFinal = newMath.remMonths > 0 ? newMath.suggestedFinal : 0;
  const finalWithTax = round2(preTaxFinal * taxFactor);
  const count = newMath.fullPayments + (finalWithTax > 0 ? 1 : 0);
  const perPeriodAmount = newMath.fullPayments > 0
    ? round2((blockTotal - finalWithTax) / newMath.fullPayments)
    : 0;

  const billingEvents: ComputedEventEntry[] = [];
  for (let i = 0; i < newMath.fullPayments; i++) {
    const date = addDays(contractStart, i * periodDays);
    if (date > endDate) break;
    billingEvents.push({
      block_id: eventsBlockId,
      block_name: row.block_name,
      category_id: row.category_id || undefined,
      event_type: 'billing',
      billing_sub_type: 'recurring',
      billing_cycle_label: `${CADENCE_LABEL[cycle] || cycle} ${i + 1}/${count}`,
      sequence_number: i + 1,
      total_occurrences: count,
      scheduled_date: date.toISOString(),
      amount: perPeriodAmount,
      currency,
    });
  }
  // Last full payment absorbs rounding against the regular share
  if (billingEvents.length === newMath.fullPayments && billingEvents.length > 0) {
    billingEvents[billingEvents.length - 1].amount =
      round2((blockTotal - finalWithTax) - perPeriodAmount * (newMath.fullPayments - 1));
  }
  // Final payment for the leftover months (standard remainder — buyer switched)
  if (finalWithTax > 0) {
    const date = addDays(contractStart, newMath.fullPayments * periodDays);
    billingEvents.push({
      block_id: eventsBlockId,
      block_name: row.block_name,
      category_id: row.category_id || undefined,
      event_type: 'billing',
      billing_sub_type: 'recurring',
      billing_cycle_label: `${CADENCE_LABEL[cycle] || cycle} final (${newMath.remMonths} mo)`,
      sequence_number: newMath.fullPayments + 1,
      total_occurrences: count,
      scheduled_date: date.toISOString(),
      amount: finalWithTax,
      currency,
    });
  }

  // ── Contract-total deltas (pre-tax / tax / grand) ──
  const oldPreTax = oldMath.termTotal;
  const newPreTax = newMath.termTotal;
  const deltaPreTax = round2(newPreTax - oldPreTax);
  const deltaTotal = round2(newTotal - row.total_price);
  const deltaTax = round2(deltaTotal - deltaPreTax);

  // ── Updated block row fields ──
  const newConfig: Record<string, unknown> = {
    ...cfg,
    // per-cadence seller override becomes the effective custom price (or clears)
    customPrice: typeof overrideRate === 'number' && overrideRate > 0 ? overrideRate : undefined,
    // seller's final belonged to the proposed cadence only
    cadenceFinalPayment: undefined,
    // audit trail of the buyer's decision
    cadenceSelectedByBuyer: cycle,
    cadenceProposedBySeller: row.billing_cycle,
  };
  const newCustomFields = { ...(row.custom_fields || {}), config: newConfig };

  return {
    ok: true,
    result: {
      blockRowId: row.id,
      newCycle: cycle,
      newUnitPrice: newEffRate,
      newTotalPrice: newTotal,
      newCustomFields,
      deltaPreTax,
      deltaTax,
      deltaTotal,
      billingEvents,
      eventsBlockId,
    },
  };
}

/**
 * Merge regenerated billing events into a contract's computed_events:
 * drop the block's OLD billing events, keep everything else (its service
 * events and all other blocks' events), append the new ones, sort by date.
 */
export function mergeComputedEvents(
  computedEvents: ComputedEventEntry[] | null | undefined,
  results: RepriceResult[]
): ComputedEventEntry[] {
  const replacedIds = new Set(results.map((r) => r.eventsBlockId));
  const kept = (computedEvents || []).filter(
    (e) => !(e.event_type === 'billing' && e.block_id && replacedIds.has(e.block_id))
  );
  const merged = [...kept, ...results.flatMap((r) => r.billingEvents)];
  merged.sort((a, b) => new Date(a.scheduled_date).getTime() - new Date(b.scheduled_date).getTime());
  return merged;
}
