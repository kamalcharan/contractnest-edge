// supabase/functions/FKauth/utils/helpers.ts
import { corsHeaders } from './cors.ts';

// Generate a family space code from a name
export function generateWorkspaceCode(name: string): string {
  let base = name.replace(/[^a-zA-Z0-9]/g, '').toLowerCase();

  if (base.length < 3) {
    base = base.padEnd(3, 'x');
  }

  const random = Math.floor(Math.random() * 1000).toString().padStart(3, '0');
  return (base.substring(0, 3) + random).substring(0, 6);
}

// Generate a user code from first and last name
export function generateUserCode(firstName: string, lastName: string): string {
  const cleanFirst = (firstName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();
  const cleanLast = (lastName || '').replace(/[^a-zA-Z0-9]/g, '').toUpperCase();

  if (!cleanFirst && !cleanLast) {
    const timestamp = Date.now().toString(36).slice(-4).toUpperCase();
    const random = Math.random().toString(36).substring(2, 6).toUpperCase();
    return timestamp + random;
  }

  const firstPart = cleanFirst.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());
  const lastPart = cleanLast.substring(0, 4).padEnd(4, Math.random().toString(36).substring(2, 3).toUpperCase());

  return firstPart + lastPart;
}

// Create a standardized error response
export function errorResponse(error: string, status: number = 400) {
  return new Response(
    JSON.stringify({ error }),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}

// Create a standardized success response
export function successResponse(data: any, status: number = 200) {
  return new Response(
    JSON.stringify(data),
    {
      status,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' }
    }
  );
}
