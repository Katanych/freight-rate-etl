-- Fixtures supplement the supplied generator. Everything in this file is rolled back.
BEGIN;
SELECT pg_advisory_xact_lock(825347);
INSERT INTO raw.prices
    (id, loading_date, loading_city_gcid, unloading_city_gcid, distance, total_weight,
     total_volume, price, currency_code, nearest_rate_date)
VALUES
    (-1, '2035-01-03', 1001, 1001, 20, 29.96, 120, 1001, '643', NULL),
    (-2, '2035-01-03', 1001, 1003, 20, 9.96, 0, 1000, '643', NULL),
    (-3, '2035-01-03', 1001, 9999, 0, -1, -1, 5000, '643', NULL),
    (-4, '2035-01-03', 1001, 1003, 20, 9.96, 0, 1000, '840', NULL),
    (-5, '2035-01-03', 1001, 1003, 20, 9.96, 0, 1000, '840', '2026-10-24');

\set start_date 2035-01-03
\set end_date 2035-01-04
\ir ../sql/load_window.sql

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.deals
        WHERE price_id = -1 AND loading_city_gcid = unloading_city_gcid
          AND weight_category = 'G20T' AND volume_category = 'FTL'
    ) OR NOT EXISTS (
        SELECT 1 FROM core.deals
        WHERE price_id = -5 AND weight_category = 'FTL' AND volume_category = 'OTH'
          AND price_rub = (SELECT 1000 * value FROM raw.exchange_rates
                           WHERE num_code = '840' AND setting_date = '2026-10-24'
                           ORDER BY id LIMIT 1)
    ) THEN
        RAISE EXCEPTION 'Same-city route, category boundary or stored FX date failed';
    END IF;
    IF (SELECT reasons FROM core.dq_quarantine_prices WHERE price_id = -2)
           IS DISTINCT FROM ARRAY['RUB_PRICE_LE_1000']
       OR (SELECT reasons FROM core.dq_quarantine_prices WHERE price_id = -3)
           IS DISTINCT FROM ARRAY['INVALID_DISTANCE','INVALID_WEIGHT','INVALID_VOLUME','UNKNOWN_UNLOADING_CITY']
       OR (SELECT reasons FROM core.dq_quarantine_prices WHERE price_id = -4)
           IS DISTINCT FROM ARRAY['MISSING_EXACT_FX']
    THEN
        RAISE EXCEPTION 'Quarantine edge-case rules failed';
    END IF;
END
$$;
ROLLBACK;
SELECT 'DQ edge cases passed';
