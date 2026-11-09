-- Only called inside the refresh transaction. Window is [start, end).
CREATE TEMP TABLE classified ON COMMIT DROP AS
WITH fx AS (
    SELECT DISTINCT ON (num_code, setting_date) num_code, setting_date, value
    FROM raw.exchange_rates
    ORDER BY num_code, setting_date, id
)
SELECT p.*,
       p.price * CASE WHEN p.currency_code = '643' THEN 1.0 ELSE fx.value END AS price_rub,
       p.physical_reasons || array_remove(ARRAY[
           CASE WHEN NOT (p.price > 0 AND p.price < 'Infinity') THEN 'INVALID_PRICE'
                WHEN p.currency_code = '643' AND p.price <= 1000 THEN 'RUB_PRICE_LE_1000' END,
           CASE WHEN p.currency_code NOT IN ('643', '840', '978') THEN 'UNSUPPORTED_CURRENCY'
                WHEN p.currency_code IN ('840', '978')
                     AND (fx.value IS NULL OR NOT (fx.value > 0 AND fx.value < 'Infinity'))
                THEN 'MISSING_EXACT_FX' END
       ], NULL) AS reasons
FROM core.source_deals p
LEFT JOIN fx ON p.currency_code IN ('840', '978')
            AND fx.num_code = p.currency_code AND fx.setting_date = p.nearest_rate_date
WHERE p.loading_date >= :'start_date'::date AND p.loading_date < :'end_date'::date;

CREATE UNIQUE INDEX ON classified (id);
ANALYZE classified;

-- Also evict rows whose source date moved into the selected window since the last load.
DELETE FROM core.deals c
WHERE (c.loading_date >= :'start_date'::date AND c.loading_date < :'end_date'::date)
   OR EXISTS (SELECT 1 FROM classified p WHERE p.id = c.price_id);
DELETE FROM core.dq_quarantine_prices q
WHERE (q.loading_date >= :'start_date'::date AND q.loading_date < :'end_date'::date)
   OR EXISTS (SELECT 1 FROM classified p WHERE p.id = q.price_id);

INSERT INTO core.deals (
    price_id, loading_date, loading_city_gcid, unloading_city_gcid, distance, total_weight,
    total_volume, body_type, price_rub, organization_id, price_type, is_fact, complex,
    outlier_mark, weight_category, volume_category, created_at
)
SELECT id, loading_date, loading_city_gcid, unloading_city_gcid, distance, total_weight,
       total_volume, body_type, price_rub, organization_id, price_type, is_fact, complex,
       outlier_mark, resolved_weight_category, resolved_volume_category, created_at
FROM classified WHERE cardinality(reasons) = 0;

INSERT INTO core.dq_quarantine_prices (price_id, loading_date, reasons, source_row)
SELECT id, loading_date, reasons,
       to_jsonb(classified) - ARRAY['reasons', 'physical_reasons', 'price_rub',
                                    'resolved_weight_category', 'resolved_volume_category']
FROM classified WHERE cardinality(reasons) > 0;

SELECT jsonb_build_object(
    'event', 'load_window',
    'start_date', :'start_date', 'end_date_exclusive', :'end_date',
    'source_rows', count(*),
    'core_rows', count(*) FILTER (WHERE cardinality(reasons) = 0),
    'quarantine_rows', count(*) FILTER (WHERE cardinality(reasons) > 0),
    'reasons', coalesce(
        (SELECT jsonb_object_agg(reason, n)
         FROM (SELECT reason, count(*) AS n FROM classified CROSS JOIN unnest(reasons) AS r(reason)
               GROUP BY reason) counts),
        '{}'::jsonb)
)
FROM classified;

ANALYZE core.deals;
