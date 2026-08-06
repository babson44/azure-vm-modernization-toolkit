# Reach metrics (owner-facing)

This folder holds a **long-term history of this repo's GitHub Traffic** so you can show
adoption over time, not just the last 14 days.

## How it works

- `.github/workflows/traffic-snapshot.yml` runs once a day (and on demand).
- It reads **GitHub's own** Traffic numbers for this repo (the same data in
  **Insights -> Traffic**) via the Traffic API.
- It upserts each day's row into the CSVs below, keyed by date, so history accumulates
  without duplicates even though the API only exposes a 14-day window.

There is **no telemetry**. Nothing runs on customer machines and no data leaves GitHub.
These are the counts GitHub already collects for every repository owner.

## The files

| File | What each row means |
|---|---|
| `traffic-views.csv`  | `date, count, uniques` - page views that day, and unique visitors |
| `traffic-clones.csv` | `date, count, uniques` - clones that day, and unique cloners |

`uniques` is the number you usually want for an impact story ("N unique visitors,
M unique cloners this month").

## Turning this into a management story

- **Reach:** sum / trend `uniques` in `traffic-views.csv` over a month.
- **Hands-on adoption:** `uniques` in `traffic-clones.csv` - each unique cloner pulled
  the toolkit down to run it (the recommended enterprise / security-reviewed path in the
  README uses `git clone`, so serious users show up here).
- Open either CSV in Excel and drop in a line chart for a ready-to-share visual.

## First run

The CSVs are created by the first successful workflow run. To populate them immediately,
open the repo's **Actions** tab, select **Traffic snapshot**, and click **Run workflow**.

> Note: the Traffic API needs repo push/admin access. The built-in `GITHUB_TOKEN` covers
> this automatically. If you ever see a permissions error, create a fine-grained PAT with
> **Administration: read** and save it as a repo secret named `TRAFFIC_TOKEN`.
