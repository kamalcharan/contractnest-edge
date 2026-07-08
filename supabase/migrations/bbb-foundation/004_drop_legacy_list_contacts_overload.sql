-- ============================================================
-- BBB FOUNDATION 004 — Drop legacy list_contacts_with_channels_v2 overload
-- Migration 003 added a 15-param overload (with p_tags) but a legacy
-- 12-param overload still existed, leaving TWO functions of the same name.
-- PostgREST could not reliably disambiguate the RPC → the contacts LIST
-- call (e.g. the contract wizard's buyer step) failed with an ambiguity
-- error ("function is not unique").
-- The edge calls only the 15-param signature; the 12-param is orphaned.
-- ============================================================

DROP FUNCTION IF EXISTS public.list_contacts_with_channels_v2(
  uuid, boolean, text, text, text, text[], integer, integer, text, text, boolean, boolean
);
