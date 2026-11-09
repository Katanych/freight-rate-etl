"""Boundary and leakage regression tests for the model inputs."""
import unittest
from datetime import date

import numpy as np
import pandas as pd

from ml.features import CATEGORIES, NUMERICS, feature_frame, split_dates


class FeatureTest(unittest.TestCase):
    def test_input_projection_and_cycles(self):
        rows = pd.DataFrame({**{col: [1.0, 2.0] for col in NUMERICS},
                             **{col: [None, "group"] for col in CATEGORIES}})
        rows["loading_date"] = pd.to_datetime(["2026-01-01", "2026-12-31"])
        rows["actual_price_rub"] = [50000, 30000]
        rows["price_km"] = [50, 30]
        rows["outlier_mark"] = [False, True]
        rows["avg_price"] = [51000, 33000]
        features = feature_frame(rows)
        expected = set(NUMERICS + CATEGORIES) | {"year"} | {
            f"{cycle}_{trig}" for cycle in ("month", "weekday", "day_of_year")
            for trig in ("sin", "cos")
        }
        self.assertEqual(set(features.columns), expected)
        self.assertEqual(features.iloc[0]["body_group"], "UNKNOWN")
        self.assertEqual(features.iloc[0]["month_sin"], 0)
        self.assertTrue(np.allclose(features["weekday_sin"]**2 + features["weekday_cos"]**2, 1))

    def test_snapshot_split(self):
        train_start, test_start, as_of = split_dates(date(2026, 10, 26))
        self.assertEqual(train_start.date(), date(2026, 7, 26))
        self.assertEqual(test_start.date(), date(2026, 10, 5))
        self.assertEqual(as_of.date(), date(2026, 10, 26))


if __name__ == "__main__":
    unittest.main()
