// supabase/functions/FKauth/types/index.ts
export interface AuthUser {
  id: string;
  email: string;
  user_metadata?: Record<string, any>;
  app_metadata?: Record<string, any>;
}

export interface UserProfile {
  id?: string;
  user_id: string;
  first_name: string;
  last_name: string;
  email: string;
  user_code: string;
  is_active: boolean;
  is_admin?: boolean;
  country_code?: string;
  mobile_number?: string;
  date_of_birth?: string;
  gender?: string;
  preferred_theme?: string;
  is_dark_mode?: boolean;
  preferred_language?: string;
  registration_status?: string;
}

export interface FamilySpace {
  id: string;
  name: string;
  workspace_code: string;
  domain?: string;
  status: string;
  created_by: string;
  is_admin: boolean;
}

export interface RegisterData {
  email: string;
  password: string;
  firstName?: string;
  lastName?: string;
  workspaceName?: string;
  countryCode?: string;
  mobileNumber?: string;
}
