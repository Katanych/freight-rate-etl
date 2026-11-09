"""Load a date window, refresh market data, then score a frozen snapshot."""
import argparse
import json
import os
from datetime import date

from etl.db import run
from ml.score import score_snapshot


def refresh(start_date, end_date, as_of):
    result = run(
        "--no-align", "--tuples-only", "--file=sql/refresh.sql",
        variables={"start_date": start_date, "end_date": end_date, "as_of": as_of},
    )
    for line in result.splitlines():
        if line.startswith("{"):
            print(json.dumps(json.loads(line), ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start-date", type=date.fromisoformat,
                        default=os.getenv("START_DATE", "2023-01-01"))
    parser.add_argument("--end-date", type=date.fromisoformat,
                        default=os.getenv("END_DATE", "2027-04-01"))
    parser.add_argument("--as-of", type=date.fromisoformat,
                        default=os.getenv("AS_OF", "2026-10-26"))
    parser.add_argument("--skip-ml", action="store_true",
                        help="Refresh Core and Mart without fitting or publishing predictions")
    args = parser.parse_args()
    if args.start_date >= args.end_date:
        parser.error("start-date must be before end-date (exclusive)")
    refresh(args.start_date, args.end_date, args.as_of)
    if not args.skip_ml:
        score_snapshot(args.as_of)


if __name__ == "__main__":
    main()
