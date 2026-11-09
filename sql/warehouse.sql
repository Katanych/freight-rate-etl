CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS mart;

CREATE TABLE IF NOT EXISTS core.deals (
    price_id bigint PRIMARY KEY,
    loading_date date NOT NULL,
    loading_city_gcid integer NOT NULL,
    unloading_city_gcid integer NOT NULL,
    distance double precision NOT NULL CHECK (distance > 0),
    total_weight double precision NOT NULL,
    total_volume double precision NOT NULL,
    body_type integer,
    price_rub double precision NOT NULL CHECK (price_rub > 0),
    organization_id integer,
    price_type smallint NOT NULL,
    is_fact boolean NOT NULL,
    complex boolean NOT NULL,
    outlier_mark boolean NOT NULL,
    weight_category varchar(4) NOT NULL,
    volume_category varchar(4) NOT NULL,
    created_at timestamp(0)
);
CREATE INDEX IF NOT EXISTS deals_loading_date ON core.deals (loading_date);

CREATE TABLE IF NOT EXISTS core.dq_quarantine_prices (
    price_id bigint PRIMARY KEY,
    loading_date date NOT NULL,
    reasons text[] NOT NULL CHECK (cardinality(reasons) > 0),
    source_row jsonb NOT NULL
);
CREATE INDEX IF NOT EXISTS quarantine_loading_date
    ON core.dq_quarantine_prices (loading_date);

CREATE TABLE IF NOT EXISTS core.refresh_state (
    singleton boolean PRIMARY KEY CHECK (singleton),
    revision bigint NOT NULL,
    as_of date NOT NULL
);

CREATE TABLE IF NOT EXISTS mart.route_card (
    month date NOT NULL,
    loading_city_gcid integer NOT NULL,
    unloading_city_gcid integer NOT NULL,
    body_group text NOT NULL,
    weight_category varchar(4) NOT NULL,
    p25_trip double precision NOT NULL,
    median_trip double precision NOT NULL,
    p75_trip double precision NOT NULL,
    avg_trip double precision NOT NULL,
    p25_km double precision NOT NULL,
    median_km double precision NOT NULL,
    p75_km double precision NOT NULL,
    trips_count bigint NOT NULL,
    carriers_count bigint NOT NULL,
    cv_rate double precision,
    mom_pct double precision,
    yoy_pct double precision,
    latest_price_date date NOT NULL,
    reliability_level text NOT NULL CHECK (reliability_level IN ('HIGH', 'MEDIUM', 'LOW_DATA')),
    as_of date NOT NULL,
    PRIMARY KEY (loading_city_gcid, unloading_city_gcid, body_group, weight_category, month)
);
CREATE INDEX IF NOT EXISTS route_card_month ON mart.route_card (month);

CREATE TABLE IF NOT EXISTS mart.ml_model_runs (
    as_of date PRIMARY KEY,
    model_name text NOT NULL,
    train_start date NOT NULL,
    test_start date NOT NULL,
    metrics jsonb NOT NULL,
    scored_at timestamptz NOT NULL DEFAULT statement_timestamp()
);
CREATE TABLE IF NOT EXISTS mart.ml_price_predictions (
    as_of date NOT NULL REFERENCES mart.ml_model_runs (as_of) ON DELETE CASCADE,
    price_id bigint NOT NULL,
    loading_date date NOT NULL,
    loading_city_gcid integer NOT NULL,
    unloading_city_gcid integer NOT NULL,
    body_group text NOT NULL,
    actual_price_rub double precision,
    predicted_price_rub double precision NOT NULL CHECK (predicted_price_rub > 0),
    abs_error_rub double precision,
    ape_pct double precision,
    model_name text NOT NULL,
    scored_at timestamptz NOT NULL DEFAULT statement_timestamp(),
    PRIMARY KEY (as_of, price_id),
    CHECK (
        (loading_date > as_of AND actual_price_rub IS NULL AND abs_error_rub IS NULL AND ape_pct IS NULL)
        OR
        (loading_date <= as_of AND actual_price_rub > 0 AND actual_price_rub IS NOT NULL
         AND abs_error_rub IS NOT NULL AND ape_pct IS NOT NULL)
    )
);
CREATE INDEX IF NOT EXISTS predictions_dates ON mart.ml_price_predictions (as_of, loading_date);

CREATE OR REPLACE VIEW core.city_dim AS
SELECT DISTINCT ON (gc_id)
       gc_id, name, full_name_local,
       nullif(btrim(substring(full_name_local FROM ',(.*)$')), '') AS region,
       latitude, longitude
FROM raw.cities
ORDER BY gc_id, id;

CREATE OR REPLACE FUNCTION core.body_group(standard_id integer)
RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN standard_id IS NULL THEN 'Не указан'
        WHEN standard_id IN (56, 57, 58, 59, 60, 61) THEN 'Тент'
        WHEN standard_id IN (4, 46, 47, 48) THEN 'Рефрижератор'
        WHEN standard_id = 2 THEN 'Изотерм'
        WHEN standard_id IN (1, 15) THEN 'Борт'
        ELSE 'Прочие'
    END
$$;

CREATE OR REPLACE VIEW core.body_dim AS
SELECT id, core.body_group(coalesce(std_id, id::integer)) AS body_group
FROM raw.body_types;

CREATE OR REPLACE VIEW core.source_deals AS
SELECT p.*,
       coalesce(nullif(p.weight_category, ''),
           CASE
               WHEN round(p.total_weight::numeric, 1) >= 30 THEN 'G20T'
               WHEN round(p.total_weight::numeric, 1) >= 10 THEN 'FTL'
               WHEN round(p.total_weight::numeric, 1) >= 5 THEN '10T'
               WHEN round(p.total_weight::numeric, 1) >= 2.5 THEN '5T'
               WHEN round(p.total_weight::numeric, 1) >= 0.5 THEN 'L5T'
               ELSE 'OTH'
           END) AS resolved_weight_category,
       coalesce(nullif(p.volume_category, ''),
           CASE WHEN p.total_volume > 0 AND p.total_volume <= 120 THEN 'FTL'
                ELSE 'OTH' END) AS resolved_volume_category,
       array_remove(ARRAY[
           CASE WHEN NOT (p.distance > 0 AND p.distance < 'Infinity') THEN 'INVALID_DISTANCE' END,
           CASE WHEN NOT (p.total_weight >= 0 AND p.total_weight < 'Infinity') THEN 'INVALID_WEIGHT' END,
           CASE WHEN NOT (p.total_volume >= 0 AND p.total_volume < 'Infinity') THEN 'INVALID_VOLUME' END,
           CASE WHEN origin.gc_id IS NULL THEN 'UNKNOWN_LOADING_CITY' END,
           CASE WHEN destination.gc_id IS NULL THEN 'UNKNOWN_UNLOADING_CITY' END
       ], NULL) AS physical_reasons
FROM raw.prices p
LEFT JOIN core.city_dim origin ON origin.gc_id = p.loading_city_gcid
LEFT JOIN core.city_dim destination ON destination.gc_id = p.unloading_city_gcid;

CREATE OR REPLACE VIEW core.body_bridge AS
SELECT DISTINCT p.price_id, coalesce(bt.body_group, core.body_group(b.body_type_id)) AS body_group
FROM core.deals p
JOIN raw.price_body_types b ON b.price_id = p.price_id
LEFT JOIN core.body_dim bt ON bt.id = b.body_type_id
UNION ALL
SELECT p.price_id, coalesce(bt.body_group, core.body_group(p.body_type))
FROM core.deals p
LEFT JOIN core.body_dim bt ON bt.id = p.body_type
WHERE NOT EXISTS (SELECT 1 FROM raw.price_body_types b WHERE b.price_id = p.price_id);
