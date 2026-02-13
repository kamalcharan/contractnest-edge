-- ============================================================================
-- ROLLBACK: 035_seed_resource_templates.sql
-- Removes industry-specific templates added by P1a.
-- Does NOT remove the 20 generic templates from the scripts/ seed.
-- ============================================================================

-- All templates added by 035 use gen_random_uuid() so we can't match on id.
-- Instead, delete templates that match the names inserted in the UP migration.
-- Only deletes rows NOT in the original 20 scripts/ rows (those have fixed UUIDs).

DELETE FROM m_catalog_resource_templates
WHERE id NOT IN (
    '17f1f072-728f-44bf-835c-0ce009ecaefe',
    '1b412d45-4bdb-4857-b21a-5e79c0308193',
    '2ea4dc7d-6c2e-4b95-807a-754840c8e59b',
    '3c0bd339-1f66-4554-80ee-1b622f044785',
    '3db24f83-999c-4adf-8e97-8aa20f36b8d5',
    '4e4d7099-c942-41ff-a714-be54c7127e22',
    '5d9cf59c-6057-401a-8757-e755f4e7cbe7',
    '6aa0d6e2-18d1-4ca8-88cd-7c90ed26ca3b',
    '6b31ed1f-8827-4d49-ae18-219c5e3dcc32',
    '709b99a3-e043-4fb4-aad2-8ef1e26118fd',
    '7e602c7b-0b34-4c95-9d34-d6ebeba5c4f6',
    '841f42d0-6804-4ae6-a2fd-4041c7577ddb',
    '87c28e42-b0c9-475a-9562-69af1957d8d0',
    '88da12cd-f4b5-4bc0-9542-d8b7ba5876d4',
    'b6f97a7c-f6c8-432d-9956-a58c8e5eca45',
    'b7a0ac3d-c81d-455a-b6e8-31383fe7f47d',
    'c1c136f3-343f-4d4b-91ae-876311c82a9a',
    'ec49ec59-08dc-4b85-ba79-868356701b6c',
    'f265584b-f724-473f-807f-244ff9e4dacd',
    'f91dbfc2-64ac-48c1-91f3-442085be6b47',
    'fd732067-4b55-4ef8-96ba-6f2b70aa832c'
);
