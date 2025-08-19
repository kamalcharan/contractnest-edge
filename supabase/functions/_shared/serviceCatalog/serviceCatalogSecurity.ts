import { SecurityContext, RateLimitInfo } from './serviceCatalogTypes.ts';

export class ServiceCatalogSecurity {
  
  private static readonly HMAC_HEADER = 'x-signature-sha256';
  private static readonly TENANT_HEADER = 'x-tenant-id';
  private static readonly USER_HEADER = 'x-user-id';
  private static readonly REQUEST_ID_HEADER = 'x-request-id';
  
  private static readonly RATE_LIMITS = {
    CREATE_SERVICE: { requests: 100, windowMinutes: 60 },
    UPDATE_SERVICE: { requests: 200, windowMinutes: 60 },
    DELETE_SERVICE: { requests: 50, windowMinutes: 60 },
    QUERY_SERVICES: { requests: 1000, windowMinutes: 60 },
    BULK_OPERATIONS: { requests: 10, windowMinutes: 60 },
    MASTER_DATA: { requests: 500, windowMinutes: 60 },
    RESOURCES: { requests: 300, windowMinutes: 60 }
  };

  static async verifyHMACSignature(
    request: Request,
    body: string,
    signingSecret?: string
  ): Promise<{ isValid: boolean; error?: string }> {
    console.log('🔐 Security - verifying HMAC signature');

    try {
      const signature = request.headers.get(this.HMAC_HEADER);
      
      if (!signature) {
        console.warn('⚠️ Security - no HMAC signature provided');
        return { isValid: false, error: 'Missing HMAC signature' };
      }

      if (!signingSecret) {
        console.warn('⚠️ Security - no signing secret configured');
        return { isValid: false, error: 'HMAC verification not configured' };
      }

      const expectedSignature = await this.generateHMACSignature(body, signingSecret);
      const providedSignature = signature.replace('sha256=', '');

      const isValid = this.constantTimeCompare(expectedSignature, providedSignature);

      console.log('✅ Security - HMAC verification complete:', {
        isValid,
        signatureLength: providedSignature.length,
        expectedLength: expectedSignature.length
      });

      return {
        isValid,
        error: isValid ? undefined : 'Invalid HMAC signature'
      };
    } catch (error) {
      console.error('❌ Security - HMAC verification error:', error);
      return { isValid: false, error: 'HMAC verification failed' };
    }
  }

  private static async generateHMACSignature(message: string, secret: string): Promise<string> {
    const encoder = new TextEncoder();
    const keyData = encoder.encode(secret);
    const messageData = encoder.encode(message);

    const cryptoKey = await crypto.subtle.importKey(
      'raw',
      keyData,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign']
    );

    const signature = await crypto.subtle.sign('HMAC', cryptoKey, messageData);
    const hashArray = Array.from(new Uint8Array(signature));
    const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

    return hashHex;
  }

  private static constantTimeCompare(a: string, b: string): boolean {
    if (a.length !== b.length) {
      return false;
    }

    let result = 0;
    for (let i = 0; i < a.length; i++) {
      result |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }

    return result === 0;
  }

  static extractSecurityHeaders(request: Request): {
    tenantId?: string;
    userId?: string;
    requestId?: string;
    ipAddress?: string;
    userAgent?: string;
    signature?: string;
  } {
    console.log('🔐 Security - extracting security headers');

    const headers = {
      tenantId: request.headers.get(this.TENANT_HEADER) || undefined,
      userId: request.headers.get(this.USER_HEADER) || undefined,
      requestId: request.headers.get(this.REQUEST_ID_HEADER) || undefined,
      ipAddress: request.headers.get('x-forwarded-for') || 
                 request.headers.get('x-real-ip') || 
                 request.headers.get('cf-connecting-ip') || undefined,
      userAgent: request.headers.get('user-agent') || undefined,
      signature: request.headers.get(this.HMAC_HEADER) || undefined
    };

    console.log('✅ Security - security headers extracted:', {
      hasTenantId: !!headers.tenantId,
      hasUserId: !!headers.userId,
      hasRequestId: !!headers.requestId,
      hasIpAddress: !!headers.ipAddress,
      hasSignature: !!headers.signature
    });

    return headers;
  }

  static validateTenantAccess(tenantId: string, requestTenantId?: string): { isValid: boolean; error?: string } {
    console.log('🔐 Security - validating tenant access:', {
      tenantId,
      requestTenantId,
      match: tenantId === requestTenantId
    });

    if (!requestTenantId) {
      return { isValid: false, error: 'Tenant ID not provided in request headers' };
    }

    if (tenantId !== requestTenantId) {
      return { isValid: false, error: 'Tenant ID mismatch' };
    }

    console.log('✅ Security - tenant access validated');
    return { isValid: true };
  }

  static validateUserAccess(userId: string, requestUserId?: string): { isValid: boolean; error?: string } {
    console.log('🔐 Security - validating user access:', {
      userId,
      requestUserId,
      match: userId === requestUserId
    });

    if (!requestUserId) {
      return { isValid: false, error: 'User ID not provided in request headers' };
    }

    if (userId !== requestUserId) {
      return { isValid: false, error: 'User ID mismatch' };
    }

    console.log('✅ Security - user access validated');
    return { isValid: true };
  }

  static getRateLimitForOperation(operation: string): { requests: number; windowMinutes: number } {
    const operationKey = operation.toUpperCase().replace('-', '_') as keyof typeof this.RATE_LIMITS;
    
    const limit = this.RATE_LIMITS[operationKey] || this.RATE_LIMITS.QUERY_SERVICES;
    
    console.log('🔐 Security - rate limit for operation:', {
      operation,
      operationKey,
      requests: limit.requests,
      windowMinutes: limit.windowMinutes
    });

    return limit;
  }

  static createSecurityContext(
    hmacVerified: boolean,
    tenantVerified: boolean,
    userVerified: boolean,
    rateLimitPassed: boolean,
    idempotencyChecked: boolean,
    requestSignature: string,
    securityHeaders: Record<string, string>
  ): SecurityContext {
    const context: SecurityContext = {
      hmac_verified: hmacVerified,
      tenant_verified: tenantVerified,
      user_verified: userVerified,
      rate_limit_passed: rateLimitPassed,
      idempotency_checked: idempotencyChecked,
      request_signature: requestSignature,
      security_headers: securityHeaders
    };

    console.log('🔐 Security - security context created:', {
      hmac_verified: context.hmac_verified,
      tenant_verified: context.tenant_verified,
      user_verified: context.user_verified,
      rate_limit_passed: context.rate_limit_passed,
      idempotency_checked: context.idempotency_checked
    });

    return context;
  }

  static sanitizeInput(input: string, maxLength = 1000, allowedPattern?: RegExp): string {
    console.log('🔐 Security - sanitizing input:', {
      inputLength: input.length,
      maxLength,
      hasPattern: !!allowedPattern
    });

    let sanitized = input.trim().substring(0, maxLength);

    sanitized = sanitized
      .replace(/[<>]/g, '')
      .replace(/javascript:/gi, '')
      .replace(/on\w+=/gi, '')
      .replace(/data:/gi, '')
      .replace(/vbscript:/gi, '');

    if (allowedPattern && !allowedPattern.test(sanitized)) {
      console.warn('⚠️ Security - input does not match allowed pattern');
      return '';
    }

    console.log('✅ Security - input sanitized:', {
      originalLength: input.length,
      sanitizedLength: sanitized.length
    });

    return sanitized;
  }

  static validateUUID(uuid: string): boolean {
    const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
    const isValid = uuidPattern.test(uuid);
    
    console.log('🔐 Security - UUID validation:', {
      uuid: uuid.substring(0, 8) + '...',
      isValid
    });

    return isValid;
  }

  static sanitizeFilters(filters: any): any {
    console.log('🔐 Security - sanitizing filters');

    const sanitized: any = {};

    if (filters.search_term) {
      sanitized.search_term = this.sanitizeInput(filters.search_term, 255, /^[a-zA-Z0-9\s\-_.]+$/);
    }

    if (filters.category_id) {
      if (this.validateUUID(filters.category_id)) {
        sanitized.category_id = filters.category_id;
      }
    }

    if (filters.industry_id) {
      sanitized.industry_id = this.sanitizeInput(filters.industry_id, 100, /^[a-zA-Z0-9_]+$/);
    }

    if (typeof filters.is_active === 'boolean') {
      sanitized.is_active = filters.is_active;
    }

    if (typeof filters.price_min === 'number' && filters.price_min >= 0) {
      sanitized.price_min = Math.max(0, Math.min(999999999, filters.price_min));
    }

    if (typeof filters.price_max === 'number' && filters.price_max >= 0) {
      sanitized.price_max = Math.max(0, Math.min(999999999, filters.price_max));
    }

    if (filters.currency) {
      sanitized.currency = this.sanitizeInput(filters.currency, 3, /^[A-Z]{3}$/);
    }

    if (typeof filters.has_resources === 'boolean') {
      sanitized.has_resources = filters.has_resources;
    }

    if (typeof filters.duration_min === 'number' && filters.duration_min > 0) {
      sanitized.duration_min = Math.max(1, Math.min(525600, filters.duration_min));
    }

    if (typeof filters.duration_max === 'number' && filters.duration_max > 0) {
      sanitized.duration_max = Math.max(1, Math.min(525600, filters.duration_max));
    }

    if (Array.isArray(filters.tags)) {
      sanitized.tags = filters.tags
        .filter(tag => typeof tag === 'string')
        .map(tag => this.sanitizeInput(tag, 50, /^[a-zA-Z0-9\-_]+$/))
        .filter(tag => tag.length > 0)
        .slice(0, 10);
    }

    if (filters.sort_by) {
      const allowedSorts = ['name', 'price', 'created_at', 'sort_order', 'usage_count', 'avg_rating'];
      if (allowedSorts.includes(filters.sort_by)) {
        sanitized.sort_by = filters.sort_by;
      }
    }

    if (filters.sort_direction) {
      const allowedDirections = ['asc', 'desc'];
      if (allowedDirections.includes(filters.sort_direction)) {
        sanitized.sort_direction = filters.sort_direction;
      }
    }

    sanitized.limit = Math.min(1000, Math.max(1, parseInt(filters.limit) || 50));
    sanitized.offset = Math.max(0, parseInt(filters.offset) || 0);

    console.log('✅ Security - filters sanitized:', {
      originalKeys: Object.keys(filters).length,
      sanitizedKeys: Object.keys(sanitized).length
    });

    return sanitized;
  }

  static validateJSONPayload(payload: any, maxDepth = 10, maxKeys = 100): { isValid: boolean; error?: string } {
    console.log('🔐 Security - validating JSON payload:', {
      hasPayload: !!payload,
      payloadType: typeof payload,
      maxDepth,
      maxKeys
    });

    try {
      if (!payload || typeof payload !== 'object') {
        return { isValid: false, error: 'Invalid payload type' };
      }

      const validation = this.validateObjectStructure(payload, 0, maxDepth, maxKeys);
      
      console.log('✅ Security - JSON payload validation complete:', {
        isValid: validation.isValid,
        error: validation.error
      });

      return validation;
    } catch (error) {
      console.error('❌ Security - JSON payload validation error:', error);
      return { isValid: false, error: 'Payload validation failed' };
    }
  }

  private static validateObjectStructure(
    obj: any, 
    currentDepth: number, 
    maxDepth: number, 
    maxKeys: number
  ): { isValid: boolean; error?: string } {
    if (currentDepth > maxDepth) {
      return { isValid: false, error: 'Object nesting too deep' };
    }

    if (typeof obj === 'object' && obj !== null) {
      const keys = Object.keys(obj);
      
      if (keys.length > maxKeys) {
        return { isValid: false, error: 'Too many object keys' };
      }

      for (const key of keys) {
        if (key.length > 100) {
          return { isValid: false, error: 'Object key too long' };
        }

        const value = obj[key];
        
        if (typeof value === 'string' && value.length > 10000) {
          return { isValid: false, error: 'String value too long' };
        }

        if (Array.isArray(value) && value.length > 1000) {
          return { isValid: false, error: 'Array too large' };
        }

        if (typeof value === 'object' && value !== null) {
          const nestedValidation = this.validateObjectStructure(value, currentDepth + 1, maxDepth, maxKeys);
          if (!nestedValidation.isValid) {
            return nestedValidation;
          }
        }
      }
    }

    return { isValid: true };
  }

  static checkSQLInjection(input: string): { isSafe: boolean; threats: string[] } {
    console.log('🔐 Security - checking for SQL injection patterns');

    const sqlPatterns = [
      /(\b(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|EXEC|EXECUTE)\b)/i,
      /(\bUNION\b.*\bSELECT\b)/i,
      /(\b(OR|AND)\b.*['"].*['"].*=.*['"].*['"])/i,
      /(;.*--)|(\/\*.*\*\/)/,
      /(\bxp_|\bsp_)/i,
      /(\b(INFORMATION_SCHEMA|SYSOBJECTS|SYSCOLUMNS)\b)/i
    ];

    const threats: string[] = [];
    
    for (let i = 0; i < sqlPatterns.length; i++) {
      if (sqlPatterns[i].test(input)) {
        threats.push(`SQL_PATTERN_${i + 1}`);
      }
    }

    const isSafe = threats.length === 0;

    console.log('✅ Security - SQL injection check complete:', {
      isSafe,
      threatsFound: threats.length,
      threats
    });

    return { isSafe, threats };
  }

  static checkXSSThreats(input: string): { isSafe: boolean; threats: string[] } {
    console.log('🔐 Security - checking for XSS threats');

    const xssPatterns = [
      /<script[\s\S]*?>[\s\S]*?<\/script>/gi,
      /<iframe[\s\S]*?>[\s\S]*?<\/iframe>/gi,
      /javascript:/gi,
      /on\w+\s*=/gi,
      /<img[\s\S]*?onerror[\s\S]*?>/gi,
      /eval\s*\(/gi,
      /document\.cookie/gi,
      /window\.location/gi
    ];

    const threats: string[] = [];
    
    for (let i = 0; i < xssPatterns.length; i++) {
      if (xssPatterns[i].test(input)) {
        threats.push(`XSS_PATTERN_${i + 1}`);
      }
    }

    const isSafe = threats.length === 0;

    console.log('✅ Security - XSS threat check complete:', {
      isSafe,
      threatsFound: threats.length,
      threats
    });

    return { isSafe, threats };
  }

  static generateSecureToken(length = 32): string {
    const charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    const array = new Uint8Array(length);
    crypto.getRandomValues(array);
    
    const token = Array.from(array, byte => charset[byte % charset.length]).join('');
    
    console.log('🔐 Security - secure token generated:', {
      length: token.length,
      tokenPrefix: token.substring(0, 8) + '...'
    });

    return token;
  }

  static hashSensitiveData(data: string): string {
    const encoder = new TextEncoder();
    const dataBuffer = encoder.encode(data);
    
    return crypto.subtle.digest('SHA-256', dataBuffer).then(hashBuffer => {
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
      
      console.log('🔐 Security - sensitive data hashed:', {
        originalLength: data.length,
        hashLength: hashHex.length
      });

      return hashHex;
    });
  }

  static maskSensitiveFields(obj: any, sensitiveFields: string[] = ['password', 'secret', 'token', 'key']): any {
    console.log('🔐 Security - masking sensitive fields');

    const masked = JSON.parse(JSON.stringify(obj));

    const maskValue = (value: any, key: string): any => {
      if (sensitiveFields.some(field => key.toLowerCase().includes(field.toLowerCase()))) {
        if (typeof value === 'string') {
          return value.length > 4 ? value.substring(0, 4) + '*'.repeat(value.length - 4) : '****';
        }
        return '****';
      }

      if (typeof value === 'object' && value !== null) {
        const maskedObj: any = Array.isArray(value) ? [] : {};
        for (const [nestedKey, nestedValue] of Object.entries(value)) {
          maskedObj[nestedKey] = maskValue(nestedValue, nestedKey);
        }
        return maskedObj;
      }

      return value;
    };

    for (const [key, value] of Object.entries(masked)) {
      masked[key] = maskValue(value, key);
    }

    console.log('✅ Security - sensitive fields masked');
    return masked;
  }
}