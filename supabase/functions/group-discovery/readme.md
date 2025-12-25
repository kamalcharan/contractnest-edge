# GroupDiscovery Edge Function

## Overview

Single endpoint API for business directory operations:
- Session management
- Intent detection
- Segment listing
- Member listing
- Vector search (embedding from N8N)
- Contact details

## File Structure

```
supabase/functions/group-discovery/
├── index.ts              # Main entry, routing, session management
├── types.ts              # TypeScript interfaces
├── handlers/
│   ├── segments.ts       # List segments (get_segments_by_scope)
│   ├── members.ts        # List members (get_members_by_scope)
│   ├── search.ts         # Vector search (search_businesses_v2)
│   └── contact.ts        # Get contact (get_member_contact)
└── README.md             # This file
```

## Deployment

### 1. Copy files to your Supabase project

```bash
# From your project root
mkdir -p supabase/functions/group-discovery/handlers

# Copy all files to supabase/functions/group-discovery/
```

### 2. Deploy to Supabase

```bash
# Login if needed
supabase login

# Link to your project
supabase link --project-ref uwyqhzotluikawcboldr

# Deploy the function
supabase functions deploy group-discovery
```

### 3. Verify deployment

```bash
# Check function status
supabase functions list
```

## API Endpoint

```
POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery
```

## Request Format

```json
{
  "intent": "search",
  "message": "find AI companies",
  "phone": "9885164233",
  "user_id": null,
  "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567",
  "channel": "whatsapp",
  "params": {
    "query": "AI platform",
    "segment": "Technology",
    "membership_id": "uuid",
    "business_name": "apporchid",
    "limit": 10,
    "embedding": [0.123, -0.456, ...]
  }
}
```

### Required Fields

| Field | Required | Description |
|-------|----------|-------------|
| group_id | ✅ Yes | UUID of business group |
| phone OR user_id | ✅ One required | Identifier for session |
| message OR intent | ✅ One required | What user wants |

### Optional Fields

| Field | Default | Description |
|-------|---------|-------------|
| channel | 'chat' | 'chat' or 'whatsapp' |
| params | {} | Intent-specific parameters |
| params.embedding | - | Required for search (from N8N) |

## Response Format

```json
{
  "success": true,
  "intent": "search",
  "response_type": "search_results",
  "detail_level": "summary",
  "message": "Found 3 businesses matching \"AI companies\":",
  "results": [
    {
      "rank": 1,
      "membership_id": "uuid",
      "business_name": "Vikuna Technologies",
      "industry": "Technology",
      "city": "Hyderabad",
      "phone": "9885164233",
      "card_url": "https://...",
      "vcard_url": "https://...",
      "actions": [
        { "type": "call", "label": "Call", "value": "9885164233" }
      ]
    }
  ],
  "results_count": 3,
  "session_id": "uuid",
  "is_new_session": false,
  "group_id": "uuid",
  "group_name": "BBB",
  "channel": "chat",
  "from_cache": false,
  "duration_ms": 245
}
```

## Intents

| Intent | Description | Required Params |
|--------|-------------|-----------------|
| welcome | Greeting message | - |
| goodbye | End session | - |
| list_segments | List industries | - |
| list_members | List by industry | segment (optional) |
| search | Vector search | query, embedding |
| get_contact | Contact details | membership_id OR business_name |

## RPCs Used

| RPC | Handler |
|-----|---------|
| get_ai_session | Session lookup |
| create_ai_session | Session creation |
| update_ai_session | Session update |
| end_ai_session | Session end |
| get_segments_by_scope | segments.ts |
| get_members_by_scope | members.ts |
| search_businesses_v2 | search.ts |
| get_member_contact | contact.ts |
| store_search_cache | search.ts |

## Test Commands

### Welcome
```bash
curl -X POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "intent": "welcome",
    "phone": "9885164233",
    "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567"
  }'
```

### List Segments
```bash
curl -X POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "intent": "list_segments",
    "phone": "9885164233",
    "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567"
  }'
```

### List Members by Segment
```bash
curl -X POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "message": "who is into Technology",
    "phone": "9885164233",
    "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567"
  }'
```

### Get Contact
```bash
curl -X POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "message": "details for apporchid",
    "phone": "9885164233",
    "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567"
  }'
```

### Search (requires embedding from N8N)
```bash
curl -X POST https://uwyqhzotluikawcboldr.supabase.co/functions/v1/group-discovery \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_ANON_KEY" \
  -d '{
    "intent": "search",
    "phone": "9885164233",
    "group_id": "13ec19a3-59ee-41a2-8847-c914c496e567",
    "params": {
      "query": "AI platform",
      "embedding": [0.1, 0.2, ...]
    }
  }'
```

## N8N Integration

N8N workflow will:
1. Receive user request
2. Check if intent is "search"
3. If search → Call OpenAI for embedding
4. Call this Edge Function with embedding in params
5. Route response (WhatsApp vs Chat)

## Error Handling

All errors return structured response:
```json
{
  "success": false,
  "intent": "unknown",
  "response_type": "error",
  "message": "Error description",
  "error": "ERROR_CODE",
  "results": [],
  "results_count": 0
}
```
cd
## CORS

Enabled for all origins:
- Access-Control-Allow-Origin: *
- Access-Control-Allow-Methods: POST, OPTIONS