BEGIN;
SELECT pg_advisory_xact_lock(825347);
-- Fail closed if ETL committed a newer revision while CatBoost was running.
CREATE TEMP TABLE revision_guard (valid boolean NOT NULL CHECK (valid)) ON COMMIT DROP;
INSERT INTO revision_guard
SELECT coalesce((SELECT revision = :'revision'::bigint AND as_of = :'as_of'::date
                 FROM core.refresh_state WHERE singleton), false);

CREATE TEMP TABLE predictions_input (
    price_id bigint PRIMARY KEY,
    loading_date date NOT NULL,
    loading_city_gcid integer NOT NULL,
    unloading_city_gcid integer NOT NULL,
    body_group text NOT NULL,
    actual_price_rub double precision,
    predicted_price_rub double precision NOT NULL,
    abs_error_rub double precision,
    ape_pct double precision
) ON COMMIT DROP;
COPY predictions_input FROM STDIN WITH (FORMAT csv, HEADER);
-- CSV payload follows this marker

DELETE FROM mart.ml_model_runs WHERE as_of = :'as_of'::date;
INSERT INTO mart.ml_model_runs (as_of, model_name, train_start, test_start, metrics)
VALUES (:'as_of', :'model', :'train_start', :'test_start', :'metrics'::jsonb);
INSERT INTO mart.ml_price_predictions (
    as_of, price_id, loading_date, loading_city_gcid, unloading_city_gcid, body_group,
    actual_price_rub, predicted_price_rub, abs_error_rub, ape_pct, model_name, scored_at
)
SELECT m.as_of, p.price_id, p.loading_date, p.loading_city_gcid, p.unloading_city_gcid, p.body_group,
       p.actual_price_rub, p.predicted_price_rub, p.abs_error_rub, p.ape_pct,
       m.model_name, m.scored_at
FROM predictions_input p CROSS JOIN mart.ml_model_runs m
WHERE m.as_of = :'as_of'::date;
COMMIT;
