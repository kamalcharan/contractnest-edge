// supabase/functions/FKauth/utils/validation.ts
export function validateEmail(email: string): boolean {
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  return emailRegex.test(email);
}

export function validatePassword(password: string): { valid: boolean; error?: string } {
  if (!password || password.length < 6) {
    return { valid: false, error: 'Password must be at least 6 characters' };
  }
  return { valid: true };
}

export function validateRequired(fields: Record<string, any>, requiredFields: string[]): string | null {
  for (const field of requiredFields) {
    if (!fields[field]) {
      return `${field} is required`;
    }
  }
  return null;
}
