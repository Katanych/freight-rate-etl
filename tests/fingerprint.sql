-- Compare the outputs of two identical runs, excluding operational timestamps/revisions.
SELECT 'core', count(*), md5(string_agg(to_jsonb(p)::text, '|' ORDER BY price_id))
FROM core.deals p
UNION ALL
SELECT 'quarantine', count(*), md5(string_agg(to_jsonb(q)::text, '|' ORDER BY price_id))
FROM core.dq_quarantine_prices q
UNION ALL
SELECT 'mart', count(*), md5(string_agg(to_jsonb(r)::text, '|' ORDER BY
    month, loading_city_gcid, unloading_city_gcid, body_group, weight_category))
FROM mart.route_card r
UNION ALL
SELECT 'predictions', count(*), md5(string_agg((to_jsonb(m) - 'scored_at')::text, '|' ORDER BY as_of, price_id))
FROM mart.ml_price_predictions m
ORDER BY 1;
