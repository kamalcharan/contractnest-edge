// supabase/functions/_shared/audit.ts
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
import { 
AuditActions, 
AuditResources, 
AuditSeverity,
getDefaultSeverity,
type AuditAction,
type AuditResource,
type AuditSeverityLevel
} from "./auditConstants.ts";

// Re-export constants for backward compatibility
export { AuditActions, AuditResources, AuditSeverity };

export interface EdgeAuditEntry {
tenantId: string;
userId?: string;
action: AuditAction | string;
resource: AuditResource | string;
resourceId?: string;
metadata?: Record<string, any>;
ipAddress?: string;
userAgent?: string;
success: boolean;
errorMessage?: string;
severity?: AuditSeverityLevel;
correlationId?: string;
sessionId?: string;
}

export interface EdgeAuditContext {
requestId: string;
ipAddress: string;
userAgent: string;
userId?: string;
sessionId?: string;
functionName?: string;
}

/**
* Environment configuration interface
*/
export interface EdgeEnvironmentConfig {
supabaseUrl: string;
supabaseServiceKey: string;
internalSecret?: string;
environment?: 'development' | 'staging' | 'production';
}

/**
* Validate and extract environment configuration
*/
export function validateEnvironmentConfig(env: any): EdgeEnvironmentConfig {
// Handle both Deno.env and direct object patterns
const getEnvVar = (key: string) => {
  if (env && typeof env.get === 'function') {
    return env.get(key);
  } else if (env && typeof env === 'object') {
    // Direct object mapping
    const envMap: Record<string, string> = {
      'SUPABASE_URL': env.supabaseUrl,
      'SUPABASE_SERVICE_ROLE_KEY': env.supabaseServiceKey,
      'INTERNAL_SIGNING_SECRET': env.internalSecret,
      'ENVIRONMENT': env.environment
    };
    return envMap[key];
  } else {
    // Fallback to Deno.env
    return Deno.env.get(key);
  }
};

const supabaseUrl = getEnvVar('SUPABASE_URL');
const supabaseServiceKey = getEnvVar('SUPABASE_SERVICE_ROLE_KEY');
const internalSecret = getEnvVar('INTERNAL_SIGNING_SECRET');
const environment = getEnvVar('ENVIRONMENT') || 'development';

// Validation
const errors: string[] = [];

if (!supabaseUrl) {
  errors.push('SUPABASE_URL environment variable is required');
}

if (!supabaseServiceKey) {
  errors.push('SUPABASE_SERVICE_ROLE_KEY environment variable is required');
}

if (!internalSecret) {
  console.warn('⚠️  INTERNAL_SIGNING_SECRET not set. Internal API signature verification will be disabled.');
}

if (errors.length > 0) {
  throw new Error(`Environment configuration errors: ${errors.join(', ')}`);
}

return {
  supabaseUrl,
  supabaseServiceKey,
  internalSecret,
  environment: environment as 'development' | 'staging' | 'production'
};
}

/**
* Edge Audit Logger Class - Enhanced for production use
*/
export class EdgeAuditLogger {
private supabase: any;
private context: EdgeAuditContext;
private config: EdgeEnvironmentConfig;
private isEnabled: boolean;

constructor(context: EdgeAuditContext, config: EdgeEnvironmentConfig) {
  this.context = context;
  this.config = config;
  
  try {
    this.supabase = createClient(
      config.supabaseUrl,
      config.supabaseServiceKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false
        }
      }
    );
    this.isEnabled = true;
    console.log(`✅ [Audit] Logger initialized for ${context.functionName || 'unknown-function'}`);
  } catch (error) {
    console.error(`❌ [Audit] Failed to initialize logger:`, error);
    this.isEnabled = false;
  }
}

/**
 * Log an audit event with enhanced error handling
 */
async log(entry: Omit<EdgeAuditEntry, 'ipAddress' | 'userAgent' | 'correlationId'>): Promise<void> {
  if (!this.isEnabled) {
    console.debug('[Audit] Skipping log - logger not enabled');
    return;
  }
  
  try {
    // Determine severity if not provided
    const severity = entry.severity || (
      entry.action in AuditActions 
        ? getDefaultSeverity(entry.action as AuditAction)
        : AuditSeverity.INFO
    );
    
    const auditRecord = {
      tenant_id: entry.tenantId,
      user_id: entry.userId || this.context.userId,
      action: entry.action,
      resource: entry.resource,
      resource_id: entry.resourceId,
      metadata: {
        ...entry.metadata,
        edge_function: true,
        function_name: this.context.functionName,
        request_id: this.context.requestId,
        environment: this.config.environment
      },
      ip_address: this.context.ipAddress,
      user_agent: this.context.userAgent,
      success: entry.success,
      error_message: entry.errorMessage,
      severity,
      correlation_id: this.context.requestId,
      session_id: entry.sessionId || this.context.sessionId,
      created_at: new Date().toISOString()
    };
    
    const { error } = await this.supabase
      .from('t_audit_logs')
      .insert(auditRecord);
    
    if (error) {
      console.error('[Audit] Failed to insert log:', error);
      // In production, you might want to queue this for retry
      this.handleAuditFailure(auditRecord, error);
    } else {
      console.log(`[Audit] ✅ ${entry.action} on ${entry.resource} (${severity})`);
    }
  } catch (error) {
    console.error('[Audit] Exception during logging:', error);
    // Never throw - audit failures shouldn't break the main flow
  }
}

/**
 * ✅ NEW: Log data change events (for backward compatibility with catalog service)
 * This method is specifically required by the catalog service
 */
async logDataChange(
  tenantId: string,
  userId: string,
  resource: string,
  resourceId: string,
  action: string,
  oldData: any,
  newData: any
): Promise<void> {
  if (!this.isEnabled) {
    console.debug('[Audit] Skipping logDataChange - logger not enabled');
    return;
  }

  try {
    // Prepare metadata with old and new data
    const metadata: Record<string, any> = {
      operation_type: 'data_change'
    };

    // Include old data if provided (for updates/deletes)
    if (oldData !== null && oldData !== undefined) {
      metadata.old_data = oldData;
    }

    // Include new data if provided (for creates/updates)
    if (newData !== null && newData !== undefined) {
      metadata.new_data = newData;
    }

    // Determine if this is a successful operation (no error data)
    const success = !metadata.old_data?.error && !metadata.new_data?.error;

    // Call the existing log method with mapped parameters
    await this.log({
      tenantId,
      userId,
      action,
      resource,
      resourceId,
      success,
      metadata,
      // Set appropriate severity based on action
      severity: action.includes('delete') ? AuditSeverity.WARNING : 
               action.includes('error') ? AuditSeverity.ERROR : AuditSeverity.INFO
    });

    console.log(`[Audit] ✅ Data change logged: ${action} on ${resource}/${resourceId}`);
  } catch (error) {
    console.error('[Audit] Exception during logDataChange:', error);
    // Never throw - audit failures shouldn't break the main flow
  }
}

/**
 * Log with automatic success/error detection and enhanced metadata
 */
async logOperation<T>(
  entry: Omit<EdgeAuditEntry, 'success' | 'errorMessage' | 'ipAddress' | 'userAgent' | 'correlationId'>,
  operation: () => Promise<T>
): Promise<T> {
  const startTime = Date.now();
  
  try {
    const result = await operation();
    
    // Log success
    await this.log({
      ...entry,
      success: true,
      metadata: {
        ...entry.metadata,
        duration_ms: Date.now() - startTime,
        operation_type: 'success'
      }
    });
    
    return result;
  } catch (error: any) {
    // Log failure
    await this.log({
      ...entry,
      success: false,
      errorMessage: error.message || 'Operation failed',
      severity: AuditSeverity.ERROR,
      metadata: {
        ...entry.metadata,
        duration_ms: Date.now() - startTime,
        operation_type: 'failure',
        error_code: error.code,
        error_details: error.details,
        error_stack: this.config.environment === 'development' ? error.stack : undefined
      }
    });
    
    throw error; // Re-throw the original error
  }
}

/**
 * Create a child logger with additional context
 */
withContext(additionalContext: Partial<EdgeAuditContext>): EdgeAuditLogger {
  return new EdgeAuditLogger(
    { ...this.context, ...additionalContext },
    this.config
  );
}

/**
 * Get logger status for debugging
 */
getStatus(): { enabled: boolean; config: Partial<EdgeEnvironmentConfig>; context: EdgeAuditContext } {
  return {
    enabled: this.isEnabled,
    config: {
      environment: this.config.environment,
      hasUrl: !!this.config.supabaseUrl,
      hasKey: !!this.config.supabaseServiceKey,
      hasSecret: !!this.config.internalSecret
    },
    context: this.context
  };
}

/**
 * Handle audit logging failures (for future enhancement)
 */
private handleAuditFailure(record: any, error: any): void {
  // In production, you might want to:
  // 1. Queue for retry
  // 2. Send to fallback logging system
  // 3. Alert operations team
  console.warn('[Audit] Failed record:', {
    action: record.action,
    resource: record.resource,
    error: error.message
  });
}
}

/**
* Extract audit context from request with enhanced error handling
*/
export function extractAuditContext(req: Request, functionName?: string): EdgeAuditContext {
try {
  return {
    requestId: req.headers.get('x-request-id') || 
              req.headers.get('cf-ray') || // Cloudflare
              crypto.randomUUID(),
    ipAddress: req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() || 
              req.headers.get('x-real-ip') || 
              req.headers.get('cf-connecting-ip') || // Cloudflare
              'unknown',
    userAgent: req.headers.get('user-agent') || 'unknown',
    userId: extractUserIdFromAuth(req),
    sessionId: req.headers.get('x-session-id') || undefined,
    functionName: functionName || extractFunctionName(req)
  };
} catch (error) {
  console.error('[Audit] Failed to extract context:', error);
  
  // Return safe fallback context
  return {
    requestId: crypto.randomUUID(),
    ipAddress: 'unknown',
    userAgent: 'unknown',
    functionName: functionName || 'unknown'
  };
}
}

/**
* Extract user ID from authorization header (JWT) with enhanced error handling
*/
function extractUserIdFromAuth(req: Request): string | undefined {
try {
  const authHeader = req.headers.get('authorization');
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return undefined;
  }
  
  const token = authHeader.substring(7);
  const parts = token.split('.');
  
  if (parts.length !== 3) {
    console.warn('[Audit] Invalid JWT format');
    return undefined;
  }
  
  const payload = JSON.parse(atob(parts[1]));
  return payload.sub; // 'sub' contains the user ID in Supabase JWTs
} catch (error) {
  console.warn('[Audit] Failed to extract user ID:', error.message);
  return undefined;
}
}

/**
* Extract function name from request URL
*/
function extractFunctionName(req: Request): string {
try {
  const url = new URL(req.url);
  const pathParts = url.pathname.split('/').filter(Boolean);
  
  // Supabase Edge Functions typically have: /functions/v1/{function-name}
  if (pathParts.length >= 3 && pathParts[0] === 'functions' && pathParts[1] === 'v1') {
    return pathParts[2];
  }
  
  // Fallback to first path segment
  return pathParts[0] || 'unknown';
} catch (error) {
  return 'unknown';
}
}

/**
* Factory function to create audit logger with validation
*/
export function createAuditLogger(req: Request, env: any, functionName?: string): EdgeAuditLogger {
try {
  const config = validateEnvironmentConfig(env);
  const context = extractAuditContext(req, functionName);
  
  return new EdgeAuditLogger(context, config);
} catch (error) {
  console.error('[Audit] Failed to create logger:', error);
  
  // Return a disabled logger that won't break the application
  return new EdgeAuditLogger(
    {
      requestId: crypto.randomUUID(),
      ipAddress: 'unknown',
      userAgent: 'unknown',
      functionName: functionName || 'unknown'
    },
    {
      supabaseUrl: '',
      supabaseServiceKey: ''
    }
  );
}
}