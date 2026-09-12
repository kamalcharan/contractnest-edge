-- ═══════════════════════════════════════════════════════════════════
-- service-execution/011_ste_event_fk_swap.sql
-- APPLIED LIVE 2026-09-12 (service_execution_011). Source-of-record —
-- DO NOT RE-RUN.
--
-- t_service_ticket_events.event_id FK swap (cutover-era): fk_ste_event
-- referenced t_contract_events only, so a V2-native visit (n_jtd-only id)
-- could never be linked to a ticket — the B3.7 E2E harness caught it as
-- "event completed but ticket never completed" (the link row was never
-- written, see also 007c). One of the "junction FK swaps" already on the
-- cutover Phase 6 list, pulled forward for this junction only.
--
-- FK replaced by BEFORE INSERT/UPDATE trigger trg_zz_ste_event_check:
-- event id must exist in t_contract_events OR n_jtd, else
-- STE_EVENT_NOT_FOUND (fails closed). Twins are id-identical so migrated
-- events validate through either table.
-- NOTE: the old FK's ON DELETE CASCADE (events → links) is lost for
-- legacy events; event deletion is not a product operation (admin_reset_*
-- sweeps delete links explicitly) — accepted.
--
-- Rollback: DROP TRIGGER trg_zz_ste_event_check ON t_service_ticket_events;
--           DROP FUNCTION trg_fn_ste_event_check();
--           ALTER TABLE t_service_ticket_events ADD CONSTRAINT fk_ste_event
--             FOREIGN KEY (event_id) REFERENCES t_contract_events(id) ON DELETE CASCADE;
--           (re-adding the FK requires no jtd-only links to exist)
-- ═══════════════════════════════════════════════════════════════════

ALTER TABLE t_service_ticket_events DROP CONSTRAINT IF EXISTS fk_ste_event;

CREATE OR REPLACE FUNCTION trg_fn_ste_event_check() RETURNS trigger AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM t_contract_events WHERE id = NEW.event_id)
       AND NOT EXISTS (SELECT 1 FROM n_jtd WHERE id = NEW.event_id) THEN
        RAISE EXCEPTION 'STE_EVENT_NOT_FOUND: event % exists in neither t_contract_events nor n_jtd', NEW.event_id;
    END IF;
    RETURN NEW;
END
$fn$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_zz_ste_event_check ON t_service_ticket_events;
CREATE TRIGGER trg_zz_ste_event_check
BEFORE INSERT OR UPDATE OF event_id ON t_service_ticket_events
FOR EACH ROW EXECUTE FUNCTION trg_fn_ste_event_check();
