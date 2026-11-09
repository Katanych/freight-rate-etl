#!/bin/sh
set -eu
psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -v n_prices="${N_PRICES:-300000}" --single-transaction \
    -c "SET TIME ZONE 'UTC'; CREATE SCHEMA raw; SET search_path TO raw" \
    -f /source/schema.sql -f /source/synthetic.sql
