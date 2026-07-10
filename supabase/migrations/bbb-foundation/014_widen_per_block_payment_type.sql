-- Migration: bbb-foundation/014_widen_per_block_payment_type.sql
-- ============================================================================
-- Fix contract creation failing with 22001 "value too long for type
-- character varying(20)" when creating from a template with mixed / per-block
-- billing (e.g. the BBB membership: prepaid annual + monthly BAU).
--
-- t_contracts.per_block_payment_type stores a JSON MAP of block_id -> payment
-- type (e.g. {"<uuid>":"prepaid","<uuid>":"defined"}), serialized to a string
-- by the client. It was mistyped as varchar(20): fine while the map is empty
-- ("{}", 2 chars — how the wizard usually saves it) but it overflows the moment
-- the map is non-empty, which is exactly what the VaNi assemble-from-template
-- draft produces. Widen to text; existing values are unaffected. Fixes every
-- creation path (wizard, single Assign, bulk).
-- ============================================================================

ALTER TABLE t_contracts ALTER COLUMN per_block_payment_type TYPE text;
