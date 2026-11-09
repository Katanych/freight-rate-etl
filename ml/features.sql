WITH bounds AS (
    SELECT :'as_of'::date AS as_of,
           (:'as_of'::date - interval '3 months')::date AS train_start
), candidates AS (
    -- All accepted historical facts. The benchmark also reports the carrier-only slice.
    SELECT d.price_id, d.loading_date, d.loading_city_gcid, d.unloading_city_gcid,
           d.distance, d.total_weight, d.total_volume, d.body_type,
           d.weight_category, d.volume_category, d.price_type, d.price_rub AS actual_price_rub
    FROM core.deals d CROSS JOIN bounds b
    WHERE d.loading_date BETWEEN b.train_start AND b.as_of
      AND (d.created_at IS NULL OR d.created_at < b.as_of + 1)
      AND d.is_fact AND d.price_type IN (1, 2, 3, 4, 5, 9)
      AND NOT d.complex AND NOT d.outlier_mark
    UNION ALL
    -- Planning inputs require a valid route and cargo, but no known price or exchange rate.
    SELECT p.id, p.loading_date, p.loading_city_gcid, p.unloading_city_gcid,
           p.distance, p.total_weight, p.total_volume, p.body_type,
           p.resolved_weight_category, p.resolved_volume_category, p.price_type, NULL::float8
    FROM core.source_deals p CROSS JOIN bounds b
    WHERE p.loading_date > b.as_of
      AND p.created_at < b.as_of + 1
      AND NOT p.complex AND cardinality(p.physical_reasons) = 0
)
SELECT c.price_id, c.loading_date, c.loading_city_gcid, c.unloading_city_gcid,
       c.distance, c.total_weight, c.total_volume, c.weight_category, c.volume_category,
       coalesce(primary_body.body_group, linked.body_group, core.body_group(c.body_type)) AS body_group,
       origin.region AS origin_region, destination.region AS destination_region,
       origin.latitude AS origin_lat, origin.longitude AS origin_lon,
       destination.latitude AS destination_lat, destination.longitude AS destination_lon,
       c.price_type, c.actual_price_rub, r.revision
FROM candidates c
JOIN core.city_dim origin ON origin.gc_id = c.loading_city_gcid
JOIN core.city_dim destination ON destination.gc_id = c.unloading_city_gcid
LEFT JOIN core.body_dim primary_body ON primary_body.id = c.body_type
LEFT JOIN LATERAL (
    SELECT coalesce(d.body_group, core.body_group(b.body_type_id)) AS body_group
    FROM raw.price_body_types b LEFT JOIN core.body_dim d ON d.id = b.body_type_id
    WHERE b.price_id = c.price_id
    ORDER BY b.body_type_id LIMIT 1
) linked ON c.body_type IS NULL
JOIN core.refresh_state r ON r.as_of = :'as_of'::date
ORDER BY c.loading_date, c.price_id;
