// supabase/functions/_shared/audit.ts
// Shared audit logging functionality for all Edge functions

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
  supabaseUrl: string;
  supabaseServiceKey: string;
  requestId: string;
  ipAddress: string;
  userAgent: string;
  userId?: string;
  sessionId?: string;
}

/**
 * Edge Audit Logger Class
 */
export class EdgeAuditLogger {
  private supabase: any;
  private context: EdgeAuditContext;
  
  constructor(context: EdgeAuditContext) {
    this.context = context;
    this.supabase = createClient(
      context.supabaseUrl,
      context.supabaseServiceKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false
        }
      }
    );
  }
  
  /**
   * Log an audit event
   */
  async log(entry: Omit<EdgeAuditEntry, 'ipAddress' | 'userAgent' | 'correlationId'>): Promise<void> {
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
          request_id: this.context.requestId
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
      } else {
        console.log(`[Audit] Logged: ${entry.action} on ${entry.resource}`);
      }
    } catch (error) {
      console.error('[Audit] Exception during logging:', error);
      // Never throw - audit failures shouldn't break the main flow
    }
  }
  
  /**
   * Log with automatic success/error detection
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
          duration_ms: Date.now() - startTime
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
          error_code: error.code,
          error_details: error.details
        }
      });
      
      throw error; // Re-throw the original error
    }
  }
  
  /**
   * Create a child logger with additional context
   */
  withContext(additionalContext: Partial<EdgeAuditContext>): EdgeAuditLogger {
    return new EdgeAuditLogger({
      ...this.context,
      ...additionalContext
    });
  }
}

/**
 * Extract audit context from request
 */
export function extractAuditContext(req: Request, env: any): EdgeAuditContext {
  return {
    supabaseUrl: env.SUPABASE_URL || '',
    supabaseServiceKey: env.SUPABASE_SERVICE_ROLE_KEY || '',
    requestId: req.headers.get('x-request-id') || crypto.randomUUID(),
    ipAddress: req.headers.get('x-forwarded-for') || 
               req.headers.get('x-real-ip') || 
               'unknown',
    userAgent: req.headers.get('user-agent') || 'unknown',
    userId: extractUserIdFromAuth(req),
    sessionId: req.headers.get('x-session-id') || undefined
  };
}

/**
 * Extract user ID from authorization header (JWT)
 */
function extractUserIdFromAuth(req: Request): string | undefined {
  try {
    const authHeader = req.headers.get('authorization');
    if (!authHeader || !authHeader.startsWith('Bearer ')) {
      return undefined;
    }
    
    // For Supabase, we can decode the JWT to get user ID
    // In production, you might want to verify the JWT
    const token = authHeader.substring(7);
    const payload = JSON.parse(atob(token.split('.')[1]));
    return payload.sub; // 'sub' contains the user ID in Supabase JWTs
  } catch (error) {
    console.error('[Audit] Failed to extract user ID:', error);
    return undefined;
  }
}