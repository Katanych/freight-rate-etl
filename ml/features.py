"""Explicit allowlist of predictors available before a freight rate is known."""
import numpy as np
import pandas as pd

CATEGORIES = ("body_group", "weight_category", "volume_category", "origin_region", "destination_region")
NUMERICS = ("distance", "total_weight", "total_volume", "origin_lat", "origin_lon",
            "destination_lat", "destination_lon")


def split_dates(as_of):
    anchor = pd.Timestamp(as_of)
    return anchor - pd.DateOffset(months=3), anchor - pd.Timedelta(weeks=3), anchor


def feature_frame(rows):
    data = rows.loc[:, NUMERICS + CATEGORIES].copy()
    for col in CATEGORIES:
        data[col] = data[col].fillna("UNKNOWN").astype(str)

    dates = rows["loading_date"].dt
    data["year"] = dates.year
    for name, index, period in (
        ("month", dates.month - 1, 12),
        ("weekday", dates.dayofweek, 7),
        ("day_of_year", dates.dayofyear - 1, 365.25),
    ):
        angle = (2 * np.pi / period) * index
        data[f"{name}_sin"] = np.sin(angle)
        data[f"{name}_cos"] = np.cos(angle)
    return data
