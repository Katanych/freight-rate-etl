BEGIN;
-- Serialize pipeline writers. Raw is a frozen input snapshot for a run.
SELECT pg_advisory_xact_lock(825347);
\ir warehouse.sql
\ir load_window.sql
\ir refresh_mart.sql
COMMIT;
