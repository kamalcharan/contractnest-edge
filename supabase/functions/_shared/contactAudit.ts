// supabase/functions/_shared/contactAudit.ts
import { createAuditLogger } from './audit.ts';

export const ContactAuditActions = {
  CREATE: 'contact.create',
  UPDATE: 'contact.update',
  DELETE: 'contact.delete',
  ARCHIVE: 'contact.archive',
  ACTIVATE: 'contact.activate',
  DEACTIVATE: 'contact.deactivate',
  
  // Channel operations
  CHANNEL_ADD: 'contact.channel.add',
  CHANNEL_UPDATE: 'contact.channel.update',
  CHANNEL_DELETE: 'contact.channel.delete',
  
  // Address operations
  ADDRESS_ADD: 'contact.address.add',
  ADDRESS_UPDATE: 'contact.address.update',
  ADDRESS_DELETE: 'contact.address.delete',
  
  // Tag operations
  TAG_ADD: 'contact.tag.add',
  TAG_REMOVE: 'contact.tag.remove',
  
  // Classification operations
  CLASSIFICATION_ADD: 'contact.classification.add',
  CLASSIFICATION_REMOVE: 'contact.classification.remove',
  
  // Business operations
  INVITATION_SEND: 'contact.invitation.send',
  DUPLICATE_FLAG: 'contact.duplicate.flag',
  DUPLICATE_RESOLVE: 'contact.duplicate.resolve'
} as const;

export const ContactAuditResources = {
  CONTACT: 'contact',
  CONTACT_CHANNEL: 'contact_channel',
  CONTACT_ADDRESS: 'contact_address',
  CONTACT_TAG: 'contact_tag',
  CONTACT_CLASSIFICATION: 'contact_classification'
} as const;

export function createContactAuditLogger(req: Request, env: any, functionName: string) {
  return createAuditLogger(req, env, functionName);
}