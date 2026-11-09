-- MVCC DELETE keeps the previous committed snapshot visible until this transaction commits.
DELETE FROM mart.route_card;

INSERT INTO mart.route_card (
    month, loading_city_gcid, unloading_city_gcid, body_group, weight_category,
    p25_trip, median_trip, p75_trip, avg_trip, p25_km, median_km, p75_km,
    trips_count, carriers_count, cv_rate, mom_pct, yoy_pct, latest_price_date, reliability_level, as_of
)
WITH deal_months AS (
    SELECT price_id, date_trunc('month', price_date)::date AS month,
           max(price_date) AS latest_price_date
    FROM raw.price_dates
    WHERE price_date <= :'as_of'::date
    GROUP BY price_id, date_trunc('month', price_date)::date
), cells AS MATERIALIZED (
    SELECT m.month, p.loading_city_gcid, p.unloading_city_gcid, b.body_group, p.weight_category,
           percentile_cont(ARRAY[0.25, 0.50, 0.75]) WITHIN GROUP (ORDER BY p.price_rub) AS trip,
           avg(p.price_rub ORDER BY p.price_id) AS avg_trip,
           percentile_cont(ARRAY[0.25, 0.50, 0.75])
               WITHIN GROUP (ORDER BY p.price_rub / nullif(p.distance, 0)) AS km,
           count(DISTINCT p.price_id) AS trips_count,
           count(DISTINCT p.organization_id) FILTER (WHERE p.price_type IN (3, 9)) AS carriers_count,
           stddev_samp(p.price_rub ORDER BY p.price_id) / nullif(avg(p.price_rub ORDER BY p.price_id), 0) AS cv_rate,
           max(m.latest_price_date) AS latest_price_date
    FROM core.deals p
    JOIN deal_months m ON m.price_id = p.price_id
    JOIN core.body_bridge b ON b.price_id = p.price_id
    WHERE p.is_fact AND p.price_type IN (1, 2, 3, 4, 5, 9)
      AND NOT p.complex AND NOT p.outlier_mark
      AND (p.created_at IS NULL OR p.created_at < :'as_of'::date + 1)
    GROUP BY m.month, p.loading_city_gcid, p.unloading_city_gcid, b.body_group, p.weight_category
)
SELECT c.month, c.loading_city_gcid, c.unloading_city_gcid, c.body_group, c.weight_category,
       c.trip[1], c.trip[2], c.trip[3], c.avg_trip, c.km[1], c.km[2], c.km[3],
       c.trips_count, c.carriers_count, c.cv_rate,
       100 * (c.trip[2] / nullif(pm.trip[2], 0) - 1),
       100 * (c.trip[2] / nullif(py.trip[2], 0) - 1),
       c.latest_price_date,
       CASE WHEN c.trips_count >= 30 AND c.carriers_count >= 5
                 AND :'as_of'::date - c.latest_price_date <= 30 THEN 'HIGH'
            WHEN c.trips_count >= 10 THEN 'MEDIUM'
            ELSE 'LOW_DATA' END,
       :'as_of'::date
FROM cells c
LEFT JOIN cells pm ON pm.month = (c.month - interval '1 month')::date
                  AND (pm.loading_city_gcid, pm.unloading_city_gcid, pm.body_group, pm.weight_category)
                    = (c.loading_city_gcid, c.unloading_city_gcid, c.body_group, c.weight_category)
LEFT JOIN cells py ON py.month = (c.month - interval '1 year')::date
                  AND (py.loading_city_gcid, py.unloading_city_gcid, py.body_group, py.weight_category)
                    = (c.loading_city_gcid, c.unloading_city_gcid, c.body_group, c.weight_category);

INSERT INTO core.refresh_state (singleton, revision, as_of)
VALUES (true, 1, :'as_of'::date)
ON CONFLICT (singleton) DO UPDATE
SET revision = core.refresh_state.revision + 1, as_of = excluded.as_of;

ANALYZE mart.route_card;
SELECT jsonb_build_object('event', 'refresh_mart', 'as_of', :'as_of',
                          'cells', count(*), 'high_reliability_cells',
                          count(*) FILTER (WHERE reliability_level = 'HIGH'))
FROM mart.route_card;
