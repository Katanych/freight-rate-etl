-- Run after the default full load and model scoring.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM raw.prices p
        LEFT JOIN core.deals c ON c.price_id = p.id
        LEFT JOIN core.dq_quarantine_prices q ON q.price_id = p.id
        WHERE (c.price_id IS NULL) = (q.price_id IS NULL)
    ) THEN
        RAISE EXCEPTION 'Each source ID must appear exactly once in Core or quarantine';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM core.dq_quarantine_prices)
       OR EXISTS (
           SELECT 1 FROM core.deals c JOIN raw.prices p ON p.id = c.price_id
           WHERE p.distance <= 0 OR p.price <= 0 OR (p.currency_code = '643' AND p.price <= 1000)
              OR p.total_weight < 0 OR p.total_volume < 0
              OR (p.currency_code = '643' AND c.price_rub <> p.price)
              OR (p.currency_code <> '643' AND NOT EXISTS (
                 SELECT 1 FROM raw.exchange_rates fx WHERE fx.num_code = p.currency_code
                    AND fx.setting_date = p.nearest_rate_date AND p.price * fx.value = c.price_rub
              ))
       ) THEN
        RAISE EXCEPTION 'DQ or exact currency conversion failed';
    END IF;

    IF (SELECT full_name_local FROM core.city_dim WHERE gc_id = 1003) <> 'Казань, Республика Татарстан'
       OR EXISTS (
         SELECT 1 FROM core.body_bridge GROUP BY price_id, body_group HAVING count(*) > 1
       ) OR (SELECT count(DISTINCT price_id) FROM core.body_bridge) <> (SELECT count(*) FROM core.deals)
    THEN
        RAISE EXCEPTION 'City or body dimension deduplication failed';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM mart.route_card) OR EXISTS (
        SELECT 1 FROM mart.route_card r
        LEFT JOIN mart.route_card pm
          ON pm.month = (r.month - interval '1 month')::date
         AND (pm.loading_city_gcid, pm.unloading_city_gcid, pm.body_group, pm.weight_category)
           = (r.loading_city_gcid, r.unloading_city_gcid, r.body_group, r.weight_category)
        LEFT JOIN mart.route_card py
          ON py.month = (r.month - interval '1 year')::date
         AND (py.loading_city_gcid, py.unloading_city_gcid, py.body_group, py.weight_category)
           = (r.loading_city_gcid, r.unloading_city_gcid, r.body_group, r.weight_category)
        WHERE r.p25_trip > r.median_trip OR r.median_trip > r.p75_trip
           OR r.p25_km > r.median_km OR r.median_km > r.p75_km
           OR r.latest_price_date > r.as_of OR r.carriers_count > r.trips_count
           OR (r.trips_count = 1 AND r.cv_rate IS NOT NULL)
           OR r.mom_pct IS DISTINCT FROM 100 * (r.median_trip / nullif(pm.median_trip, 0) - 1)
           OR r.yoy_pct IS DISTINCT FROM 100 * (r.median_trip / nullif(py.median_trip, 0) - 1)
           OR r.reliability_level <> CASE
                WHEN r.trips_count >= 30 AND r.carriers_count >= 5
                  AND r.as_of - r.latest_price_date <= 30 THEN 'HIGH'
                WHEN r.trips_count >= 10 THEN 'MEDIUM'
                ELSE 'LOW_DATA' END
    ) THEN
        RAISE EXCEPTION 'Market corridor invariants failed';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM mart.ml_price_predictions WHERE loading_date > as_of)
       OR NOT EXISTS (SELECT 1 FROM mart.ml_price_predictions WHERE loading_date = DATE '2026-10-05')
       OR EXISTS (
         SELECT 1 FROM mart.ml_price_predictions p JOIN mart.ml_model_runs m USING (as_of)
         WHERE p.loading_date < m.test_start OR
               (p.loading_date > p.as_of AND
                (p.actual_price_rub IS NOT NULL OR p.abs_error_rub IS NOT NULL OR p.ape_pct IS NOT NULL))
       ) THEN
        RAISE EXCEPTION 'Missing scoring cohort or incorrect split';
    END IF;
END
$$;

SELECT 'SQL smoke checks passed';
