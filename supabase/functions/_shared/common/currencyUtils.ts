// supabase/functions/_shared/common/currencyUtils.ts
// Centralized currency utilities for all edge functions

export interface CurrencyInfo {
  code: string;
  name: string;
  symbol: string;
  decimal_places: number;
  is_default?: boolean;
}

const CURRENCIES: CurrencyInfo[] = [
  { code: 'USD', name: 'US Dollar', symbol: '$', decimal_places: 2, is_default: false },
  { code: 'EUR', name: 'Euro', symbol: '€', decimal_places: 2, is_default: false },
  { code: 'GBP', name: 'British Pound', symbol: '£', decimal_places: 2, is_default: false },
  { code: 'INR', name: 'Indian Rupee', symbol: '₹', decimal_places: 2, is_default: true },
  { code: 'JPY', name: 'Japanese Yen', symbol: '¥', decimal_places: 0, is_default: false },
  { code: 'CAD', name: 'Canadian Dollar', symbol: 'C$', decimal_places: 2, is_default: false },
  { code: 'AUD', name: 'Australian Dollar', symbol: 'A$', decimal_places: 2, is_default: false },
  { code: 'CHF', name: 'Swiss Franc', symbol: 'CHF', decimal_places: 2, is_default: false },
  { code: 'CNY', name: 'Chinese Yuan', symbol: '¥', decimal_places: 2, is_default: false },
  { code: 'SEK', name: 'Swedish Krona', symbol: 'kr', decimal_places: 2, is_default: false }
];

export function getCurrencyByCode(code: string): CurrencyInfo | null {
  return CURRENCIES.find(currency => currency.code === code.toUpperCase()) || null;
}

export function getDefaultCurrency(): CurrencyInfo {
  return CURRENCIES.find(currency => currency.is_default) || CURRENCIES[0];
}

export function getAllCurrencies(): CurrencyInfo[] {
  return CURRENCIES;
}

export function formatCurrency(amount: number, currencyCode: string): string {
  const currency = getCurrencyByCode(currencyCode) || getDefaultCurrency();
     
  try {
    return new Intl.NumberFormat('en-US', {
      style: 'currency',
      currency: currency.code,
      minimumFractionDigits: currency.decimal_places,
      maximumFractionDigits: currency.decimal_places
    }).format(amount);
  } catch (error) {
    // Fallback formatting if Intl.NumberFormat fails
    return `${currency.symbol}${amount.toFixed(currency.decimal_places)}`;
  }
}

export function isValidCurrencyCode(code: string): boolean {
  return CURRENCIES.some(currency => currency.code === code.toUpperCase());
}