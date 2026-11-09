"""Fit CatBoost on historical facts and publish two scoring cohorts."""
import io
import json

import numpy as np
import pandas as pd
from catboost import CatBoostRegressor
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

from etl.db import ROOT, run
from ml.features import CATEGORIES, feature_frame, split_dates

MODEL = "catboost-rmse-v1"
KEYS = ("price_id", "loading_date", "loading_city_gcid", "unloading_city_gcid", "body_group")
MEASURES = ("actual_price_rub", "predicted_price_rub", "abs_error_rub", "ape_pct")


def evaluate(actual, predicted):
    return {
        "rows": len(actual),
        "r2": float(r2_score(actual, predicted)) if len(actual) >= 2 else None,
        "mape_pct": float(100 * np.mean(np.abs(predicted - actual) / actual)),
        "rmse_rub": float(np.sqrt(mean_squared_error(actual, predicted))),
        "mae_rub": float(mean_absolute_error(actual, predicted)),
    }


def score_snapshot(as_of):
    csv = run("--csv", "--file=ml/features.sql", variables={"as_of": as_of})
    rows = pd.read_csv(io.StringIO(csv), parse_dates=["loading_date"])
    if rows.empty or rows["price_id"].duplicated().any() or rows["revision"].nunique() != 1:
        raise ValueError("Empty input, duplicate price_id or inconsistent snapshot")
    train_start, test_start, anchor = split_dates(as_of)
    dates = rows["loading_date"]
    train = (dates >= train_start) & (dates < test_start)
    test = (dates >= test_start) & (dates <= anchor)
    future = dates > anchor
    target = rows["actual_price_rub"]
    if train.sum() < 2 or test.sum() < 2 or not (target[train | test] > 0).all():
        raise ValueError("Need positive historical labels and at least two rows in train and test")
    if not target[future].isna().all():
        raise ValueError("Future actuals must be null")

    features = feature_frame(rows)
    model = CatBoostRegressor(
        loss_function="RMSE", iterations=400, depth=6, learning_rate=0.08, random_seed=42,
        thread_count=4, verbose=False, allow_writing_files=False, cat_features=list(CATEGORIES),
    )
    model.fit(features.loc[train], target.loc[train])
    scored = rows.loc[test | future, list(KEYS) + ["actual_price_rub"]].copy()
    scored["predicted_price_rub"] = np.maximum(model.predict(features.loc[scored.index]), 0.01)
    scored["abs_error_rub"] = (scored["actual_price_rub"] - scored["predicted_price_rub"]).abs()
    scored["ape_pct"] = 100 * scored["abs_error_rub"] / scored["actual_price_rub"]

    actual = target.loc[test]
    prediction = scored.loc[actual.index, "predicted_price_rub"]
    carrier = rows.loc[test, "price_type"].isin([3, 9])
    metrics = {
        "test": evaluate(actual, prediction),
        "train_median_baseline": evaluate(actual, np.repeat(target.loc[train].median(), len(actual))),
        "carrier_test": evaluate(actual.loc[carrier], prediction.loc[carrier]) if carrier.any() else None,
        "train_rows": int(train.sum()),
        "future_rows": int(future.sum()),
    }
    load = (ROOT / "ml/publish.sql").read_text(encoding="utf-8")
    head, tail = load.split("-- CSV payload follows this marker\n", 1)
    # COPY FROM STDIN in one transaction, with no per-row database round trips.
    data = scored.loc[:, KEYS + MEASURES].to_csv(index=False)
    run("--file=-", variables={
        "as_of": as_of, "train_start": train_start.date(), "test_start": test_start.date(),
        "revision": int(rows["revision"].iat[0]), "model": MODEL,
        "metrics": json.dumps(metrics, allow_nan=False, separators=(",", ":")),
    }, script=head + data + "\\.\n" + tail)
    print(json.dumps({"event": "publish_predictions", "as_of": str(as_of), "model": MODEL,
                      **metrics}, ensure_ascii=False, allow_nan=False), flush=True)
