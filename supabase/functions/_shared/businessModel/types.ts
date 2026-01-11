// supabase/functions/_shared/businessModel/types.ts
// Type definitions for Business Model

// ============================================================
// PRODUCT CONFIG TYPES
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
  billing_model: BillingModel;
  billing_cycles: BillingCycle[];
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

export type BillingModel = 'composite' | 'tiered_family' | 'subscription_plus_usage' | 'manual';
export type BillingCycle = 'monthly' | 'quarterly' | 'annual';

// ============================================================
// FEE & PRICING TYPES
// ============================================================

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

// ============================================================
// CREDIT TYPES
// ============================================================

export interface CreditTypeConfig {
  name: string;
  description: string;
  channels?: string[];
  included_per_contract?: number;
  configurable_expiry?: boolean;
  default_low_threshold: number;
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

export interface DeductCreditsParams {
  channel?: string;
  referenceType?: string;
  referenceId?: string;
  description?: string;
  createdBy?: string;
}

export interface DeductCreditsResult {
  success: boolean;
  balance_after: number;
  error_code: string | null;
  error_message: string | null;
}

export interface AddCreditsParams {
  channel?: string;
  transactionType?: CreditTransactionType;
  referenceType?: string;
  referenceId?: string;
  description?: string;
  expiresAt?: string;
  createdBy?: string;
}

export interface AddCreditsResult {
  success: boolean;
  balance_after: number;
  balance_id: string | null;
  error_message: string | null;
}

export type CreditTransactionType = 'topup' | 'refund' | 'adjustment' | 'initial' | 'transfer' | 'deduction' | 'expiry';

// ============================================================
// USAGE TYPES
// ============================================================

export interface UsageMetricConfig {
  name: string;
  description: string;
  aggregation: UsageAggregation;
  billing_type: UsageBillingType;
}

export type UsageAggregation = 'sum' | 'max' | 'avg';
export type UsageBillingType = 'tiered' | 'overage' | 'credit_deduction' | 'per_unit' | 'free' | 'tier_selection' | 'limit_check';

export interface RecordUsageParams {
  referenceType?: string;
  referenceId?: string;
  billingPeriod?: string;
}

export interface RecordUsageResult {
  success: boolean;
  usageId: string | null;
  periodTotal: number;
  errorMessage: string | null;
}

// ============================================================
// ADDON TYPES
// ============================================================

export interface AddonConfig {
  name: string;
  description: string;
  monthly_price: number;
  trial_days?: number;
}

// ============================================================
// TRIAL & GRACE PERIOD TYPES
// ============================================================

export interface TrialConfig {
  days: number;
  features_included: string;
  includes_reports?: number;
}

export interface GracePeriodConfig {
  days: number;
  access_level: AccessLevel;
}

export type AccessLevel = 'full' | 'read_only' | 'none';

// ============================================================
// TIER TYPES
// ============================================================

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

// ============================================================
// BILLING STATUS TYPES
// ============================================================

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
  status: SubscriptionStatus;
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

export type SubscriptionStatus = 'active' | 'trial' | 'grace_period' | 'suspended' | 'canceled' | 'expired';

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
  last_payment: LastPayment | null;
}

export interface LastPayment {
  date: string;
  amount: number;
}

export interface BillingAlert {
  type: BillingAlertType;
  severity: AlertSeverity;
  message: string;
  credit_type?: string;
  channel?: string;
}

export type BillingAlertType = 'trial_expiring' | 'grace_period' | 'suspended' | 'low_credits' | 'overdue_invoices';
export type AlertSeverity = 'info' | 'warning' | 'critical';

// ============================================================
// TOPUP PACK TYPES
// ============================================================

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
  sort_order: number;
  original_price: number | null;
  discount_percentage: number | null;
  promotion_text: string | null;
  promotion_ends_at: string | null;
}

// ============================================================
// INVOICE TYPES (Contract Billing)
// ============================================================

export interface ContractInvoice {
  id: string;
  tenant_id: string;
  contract_id: string | null;
  customer_name: string;
  customer_email: string | null;
  customer_phone: string | null;
  invoice_number: string;
  invoice_date: string;
  due_date: string;
  currency_code: string;
  subtotal: number;
  tax_amount: number;
  discount_amount: number;
  total_amount: number;
  amount_paid: number;
  balance_due: number;
  line_items: InvoiceLineItem[];
  payment_status: PaymentStatus;
}

export interface InvoiceLineItem {
  description: string;
  quantity: number;
  unit_price: number;
  amount: number;
  tax_rate?: number;
}

export type PaymentStatus = 'draft' | 'sent' | 'pending' | 'partial' | 'paid' | 'overdue' | 'cancelled' | 'refunded';
