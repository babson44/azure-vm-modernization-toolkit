#!/usr/bin/env python3
"""Merge a GitHub Traffic API response into a running CSV history.

The Traffic API only returns the last 14 days. Running this daily and upserting
each day's row (keyed by date) builds a permanent history without duplicates.

Usage:
    merge_traffic.py <kind> <source.json> <dest.csv>
    <kind> is "views" or "clones" (the array key in the API response).
"""
import csv
import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: merge_traffic.py <views|clones> <src.json> <dest.csv>", file=sys.stderr)
        return 2

    kind, src, dst = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(src, encoding="utf-8") as f:
        data = json.load(f)

    # date -> (count, uniques). Existing history is loaded first, then the fresh
    # 14-day window overwrites those same dates with the latest numbers.
    rows: dict[str, tuple[int, int]] = {}

    if os.path.exists(dst):
        with open(dst, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                rows[r["date"]] = (int(r["count"]), int(r["uniques"]))

    for item in data.get(kind, []):
        day = item["timestamp"][:10]  # YYYY-MM-DD
        rows[day] = (int(item["count"]), int(item["uniques"]))

    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["date", "count", "uniques"])
        for day in sorted(rows):
            count, uniques = rows[day]
            w.writerow([day, count, uniques])

    print(f"{dst}: {len(rows)} day(s) of history")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
