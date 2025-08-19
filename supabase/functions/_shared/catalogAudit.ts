// supabase/functions/_shared/catalogAudit.ts
import { createAuditLogger } from './audit.ts';

export const CatalogAuditActions = {
  CREATE: 'catalog.create',
  UPDATE: 'catalog.update',
  DELETE: 'catalog.delete',
  RESTORE: 'catalog.restore',
  PRICING_UPDATE: 'catalog.pricing.update',
  PRICING_DELETE: 'catalog.pricing.delete',
  VERSION_CREATE: 'catalog.version.create'
} as const;

export const CatalogAuditResources = {
  CATALOG_ITEM: 'catalog_item',
  CATALOG_PRICING: 'catalog_pricing',
  CATALOG_VERSION: 'catalog_version'
} as const;

export function createCatalogAuditLogger(req: Request, env: any, functionName: string) {
  return createAuditLogger(req, env, functionName);
}