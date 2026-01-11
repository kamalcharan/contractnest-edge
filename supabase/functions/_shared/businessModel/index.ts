// supabase/functions/_shared/businessModel/index.ts
// Business Model utilities for Edge functions
// Provides helpers for credits, billing, and product config operations

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ============================================================
// TYPES
// ============================================================

export interface ProductConfig {
  id: string;
  product_code: string;
  product_name: string;
  description: string | null;
  billing_config: BillingConfig;
  is_active: boolean;
  created_at: string;
  updated_at: string;
}

export interface BillingConfig {
  billing_model: 'composite' | 'tiered_family' | 'subscription_plus_usage' | 'manual';
  billing_cycles: string[];
  base_fee?: BaseFee;
  storage?: StorageConfig;
  contracts?: ContractConfig;
  credits?: Record<string, CreditTypeConfig>;
  usage_metrics?: Record<string, UsageMetricConfig>;
  addons?: Record<string, AddonConfig>;
  trial?: TrialConfig;
  grace_period?: GracePeriodConfig;
  free_tier?: TierConfig;
  paid_tiers?: TierConfig[];
  base_subscription?: BaseSubscription;
  usage_charges?: Record<string, UsageChargeConfig>;
}

export interface BaseFee {
  description: string;
  included_users: number;
  tiers: UserTier[];
}

export interface UserTier {
  users_from: number;
  users_to: number | null;
  monthly_amount?: number;
  per_user_amount?: number;
}

export interface StorageConfig {
  included_mb: number;
  overage_per_mb: number;
}

export interface ContractConfig {
  description: string;
  base_price: number;
  standalone_price: number;
  with_rfp_price: number;
  tiers: PriceTier[];
}

export interface PriceTier {
  from: number;
  to: number | null;
  price: number;
}

export interface CreditTypeConfig {
  name: string;
  description: string;
  channels?: string[];
  included_per_contract?: number;
  configurable_expiry?: boolean;
  default_low_threshold: number;
}

export interface UsageMetricConfig {
  name: string;
  description: string;
  aggregation: 'sum' | 'max' | 'avg';
  billing_type: 'tiered' | 'overage' | 'credit_deduction' | 'per_unit' | 'free' | 'tier_selection' | 'limit_check';
}

export interface AddonConfig {
  name: string;
  description: string;
  monthly_price: number;
  trial_days?: number;
}

export interface TrialConfig {
  days: number;
  features_included: string;
  includes_reports?: number;
}

export interface GracePeriodConfig {
  days: number;
  access_level: 'full' | 'read_only' | 'none';
}

export interface TierConfig {
  tier_code?: string;
  name: string;
  users: number;
  assets_limit: number | null;
  price?: number;
  monthly_price?: number;
  quarterly_price?: number;
}

export interface BaseSubscription {
  name: string;
  monthly_price: number;
  includes: string[];
}

export interface UsageChargeConfig {
  name: string;
  description: string;
  price: number;
}

export interface CreditBalance {
  credit_type: string;
  channel: string | null;
  balance: number;
  reserved_balance: number;
  available_balance: number;
  expires_at: string | null;
  is_low: boolean;
  low_balance_threshold: number;
}

export interface DeductCreditsResult {
  success: boolean;
  balance_after: number;
  error_code: string | null;
  error_message: string | null;
}

export interface AddCreditsResult {
  success: boolean;
  balance_after: number;
  balance_id: string | null;
  error_message: string | null;
}

export interface BillingStatus {
  tenant_id: string;
  subscription: SubscriptionInfo | null;
  credits: CreditInfo[];
  usage: Record<string, UsageInfo>;
  invoices: InvoiceInfo;
  alerts: BillingAlert[];
  retrieved_at: string;
}

export interface SubscriptionInfo {
  id: string;
  status: string;
  product_code: string;
  plan_name: string | null;
  billing_cycle: string;
  start_date: string;
  renewal_date: string;
  next_billing_date: string | null;
  trial_ends: string | null;
  grace_end_date: string | null;
  days_until_renewal: number;
}

export interface CreditInfo {
  type: string;
  channel: string | null;
  balance: number;
  available: number;
  is_low: boolean;
}

export interface UsageInfo {
  total_quantity: number;
  record_count: number;
  first_recorded: string;
  last_recorded: string;
}

export interface InvoiceInfo {
  pending_count: number;
  last_payment: {
    date: string;
    amount: number;
  } | null;
}

export interface BillingAlert {
  type: string;
  severity: 'info' | 'warning' | 'critical';
  message: string;
  credit_type?: string;
  channel?: string;
}

export interface TopupPack {
  id: string;
  product_code: string;
  credit_type: string;
  name: string;
  description: string | null;
  quantity: number;
  price: number;
  currency_code: string;
  expiry_days: number | null;
  is_popular: boolean;
  is_active: boolean;
  original_price: number | null;
  discount_percentage: number | null;
  promotion_text: string | null;
}

// ============================================================
// PRODUCT CONFIG FUNCTIONS
// ============================================================

/**
 * Get product configuration by code
 */
export async function getProductConfig(
  supabase: SupabaseClient,
  productCode: string
): Promise<ProductConfig | null> {
  const { data, error } = await supabase
    .from('t_bm_product_config')
    .select('*')
    .eq('product_code', productCode)
    .eq('is_active', true)
    .single();

  if (error || !data) {
    console.error('Error fetching product config:', error);
    return null;
  }

  return data as ProductConfig;
}

/**
 * Get all active product configurations
 */
export async function getAllProductConfigs(
  supabase: SupabaseClient
): Promise<ProductConfig[]> {
  const { data, error } = await supabase
    .from('t_bm_product_config')
    .select('*')
    .eq('is_active', true)
    .order('product_code');

  if (error) {
    console.error('Error fetching product configs:', error);
    return [];
  }

  return data as ProductConfig[];
}

// ============================================================
// CREDIT FUNCTIONS
// ============================================================

/**
 * Deduct credits atomically with race condition protection
 */
export async function deductCredits(
  supabase: SupabaseClient,
  tenantId: string,
  creditType: string,
  quantity: number = 1,
  options: {
    channel?: string;
    referenceType?: string;
    referenceId?: string;
    description?: string;
    createdBy?: string;
  } = {}
): Promise<DeductCreditsResult> {
  const { data, error } = await supabase.rpc('deduct_credits', {
    p_tenant_id: tenantId,
    p_credit_type: creditType,
    p_channel: options.channel || null,
    p_quantity: quantity,
    p_reference_type: options.referenceType || null,
    p_reference_id: options.referenceId || null,
    p_description: options.description || null,
    p_created_by: options.createdBy || null,
  });

  if (error) {
    console.error('Error deducting credits:', error);
    return {
      success: false,
      balance_after: 0,
      error_code: 'RPC_ERROR',
      error_message: error.message,
    };
  }

  // RPC returns array, get first row
  const result = Array.isArray(data) ? data[0] : data;
  return result as DeductCreditsResult;
}

/**
 * Add credits atomically
 */
export async function addCredits(
  supabase: SupabaseClient,
  tenantId: string,
  creditType: string,
  quantity: number,
  options: {
    channel?: string;
    transactionType?: 'topup' | 'refund' | 'adjustment' | 'initial' | 'transfer';
    referenceType?: string;
    referenceId?: string;
    description?: string;
    expiresAt?: string;
    createdBy?: string;
  } = {}
): Promise<AddCreditsResult> {
  const { data, error } = await supabase.rpc('add_credits', {
    p_tenant_id: tenantId,
    p_credit_type: creditType,
    p_channel: options.channel || null,
    p_quantity: quantity,
    p_transaction_type: options.transactionType || 'topup',
    p_reference_type: options.referenceType || null,
    p_reference_id: options.referenceId || null,
    p_description: options.description || null,
    p_expires_at: options.expiresAt || null,
    p_created_by: options.createdBy || null,
  });

  if (error) {
    console.error('Error adding credits:', error);
    return {
      success: false,
      balance_after: 0,
      balance_id: null,
      error_message: error.message,
    };
  }

  const result = Array.isArray(data) ? data[0] : data;
  return result as AddCreditsResult;
}

/**
 * Get credit balance for a tenant
 */
export async function getCreditBalance(
  supabase: SupabaseClient,
  tenantId: string,
  creditType?: string
): Promise<CreditBalance[]> {
  const { data, error } = await supabase.rpc('get_credit_balance', {
    p_tenant_id: tenantId,
    p_credit_type: creditType || null,
  });

  if (error) {
    console.error('Error getting credit balance:', error);
    return [];
  }

  return data as CreditBalance[];
}

/**
 * Check if tenant has sufficient credits (without deducting)
 */
export async function checkCreditAvailability(
  supabase: SupabaseClient,
  tenantId: string,
  creditType: string,
  quantity: number = 1,
  channel?: string
): Promise<{ isAvailable: boolean; availableBalance: number; shortfall: number }> {
  const { data, error } = await supabase.rpc('check_credit_availability', {
    p_tenant_id: tenantId,
    p_credit_type: creditType,
    p_channel: channel || null,
    p_quantity: quantity,
  });

  if (error) {
    console.error('Error checking credit availability:', error);
    return { isAvailable: false, availableBalance: 0, shortfall: quantity };
  }

  const result = Array.isArray(data) ? data[0] : data;
  return {
    isAvailable: result.is_available,
    availableBalance: result.available_balance,
    shortfall: result.shortfall,
  };
}

// ============================================================
// BILLING STATUS FUNCTIONS
// ============================================================

/**
 * Get comprehensive billing status for a tenant
 */
export async function getBillingStatus(
  supabase: SupabaseClient,
  tenantId: string
): Promise<BillingStatus | null> {
  const { data, error } = await supabase.rpc('get_billing_status', {
    p_tenant_id: tenantId,
  });

  if (error) {
    console.error('Error getting billing status:', error);
    return null;
  }

  return data as BillingStatus;
}

/**
 * Get billing alerts for a tenant
 */
export async function getBillingAlerts(
  supabase: SupabaseClient,
  tenantId: string
): Promise<BillingAlert[]> {
  const { data, error } = await supabase.rpc('get_billing_alerts', {
    p_tenant_id: tenantId,
  });

  if (error) {
    console.error('Error getting billing alerts:', error);
    return [];
  }

  return data as BillingAlert[];
}

// ============================================================
// USAGE FUNCTIONS
// ============================================================

/**
 * Record a usage event
 */
export async function recordUsage(
  supabase: SupabaseClient,
  tenantId: string,
  subscriptionId: string,
  metricType: string,
  quantity: number = 1,
  options: {
    referenceType?: string;
    referenceId?: string;
    billingPeriod?: string;
  } = {}
): Promise<{ success: boolean; usageId: string | null; periodTotal: number; errorMessage: string | null }> {
  const { data, error } = await supabase.rpc('record_usage', {
    p_tenant_id: tenantId,
    p_subscription_id: subscriptionId,
    p_metric_type: metricType,
    p_quantity: quantity,
    p_reference_type: options.referenceType || null,
    p_reference_id: options.referenceId || null,
    p_billing_period: options.billingPeriod || null,
  });

  if (error) {
    console.error('Error recording usage:', error);
    return { success: false, usageId: null, periodTotal: 0, errorMessage: error.message };
  }

  const result = Array.isArray(data) ? data[0] : data;
  return {
    success: result.success,
    usageId: result.usage_id,
    periodTotal: result.period_total,
    errorMessage: result.error_message,
  };
}

// ============================================================
// TOPUP PACK FUNCTIONS
// ============================================================

/**
 * Get available topup packs for a product
 */
export async function getTopupPacks(
  supabase: SupabaseClient,
  productCode: string,
  creditType?: string
): Promise<TopupPack[]> {
  let query = supabase
    .from('t_bm_topup_pack')
    .select('*')
    .eq('product_code', productCode)
    .eq('is_active', true)
    .order('sort_order')
    .order('quantity');

  if (creditType) {
    query = query.eq('credit_type', creditType);
  }

  const { data, error } = await query;

  if (error) {
    console.error('Error fetching topup packs:', error);
    return [];
  }

  return data as TopupPack[];
}

// ============================================================
// PRICING HELPERS
// ============================================================

/**
 * Calculate tiered price using database function
 */
export async function calculateTieredPrice(
  supabase: SupabaseClient,
  tiers: PriceTier[],
  quantity: number
): Promise<number> {
  const { data, error } = await supabase.rpc('calculate_tiered_price', {
    p_tiers: tiers,
    p_quantity: quantity,
  });

  if (error) {
    console.error('Error calculating tiered price:', error);
    return 0;
  }

  return data as number;
}

/**
 * Calculate user-based fee from billing config
 */
export function calculateUserBasedFee(
  baseFee: BaseFee,
  userCount: number,
  billingCycle: 'monthly' | 'quarterly' | 'annual'
): number {
  const tier = baseFee.tiers.find(t =>
    userCount >= t.users_from &&
    (t.users_to === null || userCount <= t.users_to)
  );

  if (!tier) return 0;

  let monthlyAmount: number;
  if (tier.monthly_amount !== undefined) {
    monthlyAmount = tier.monthly_amount;
  } else if (tier.per_user_amount !== undefined) {
    monthlyAmount = tier.per_user_amount * userCount;
  } else {
    return 0;
  }

  // Apply billing cycle multiplier
  const multipliers = { monthly: 1, quarterly: 3, annual: 12 };
  return monthlyAmount * multipliers[billingCycle];
}

/**
 * Calculate storage overage fee
 */
export function calculateStorageOverage(
  storageConfig: StorageConfig,
  usedMb: number
): number {
  if (usedMb <= storageConfig.included_mb) return 0;
  const overageMb = usedMb - storageConfig.included_mb;
  return overageMb * storageConfig.overage_per_mb;
}

// ============================================================
// VALIDATION HELPERS
// ============================================================

/**
 * Check if tenant is in trial period
 */
export function isInTrial(subscription: SubscriptionInfo | null): boolean {
  if (!subscription) return false;
  return subscription.status === 'trial';
}

/**
 * Check if tenant is in grace period
 */
export function isInGracePeriod(subscription: SubscriptionInfo | null): boolean {
  if (!subscription) return false;
  return subscription.status === 'grace_period';
}

/**
 * Check if tenant subscription is active
 */
export function isSubscriptionActive(subscription: SubscriptionInfo | null): boolean {
  if (!subscription) return false;
  return ['active', 'trial'].includes(subscription.status);
}

/**
 * Check if tenant can access features (active, trial, or grace period)
 */
export function canAccessFeatures(subscription: SubscriptionInfo | null, gracePeriodAccess: 'full' | 'read_only' | 'none' = 'full'): boolean {
  if (!subscription) return false;

  if (['active', 'trial'].includes(subscription.status)) return true;

  if (subscription.status === 'grace_period') {
    return gracePeriodAccess !== 'none';
  }

  return false;
}
