#!/usr/bin/env python3
"""Build a self-updating usage dashboard (metrics/DASHBOARD.md) from the traffic CSVs.

Reads metrics/traffic-views.csv and metrics/traffic-clones.csv (maintained by
merge_traffic.py) and renders a GitHub-native Markdown dashboard: headline
numbers plus Mermaid charts that GitHub renders inline. Run daily by the
Traffic snapshot workflow so the dashboard is always current.

Usage:
    build_dashboard.py <views.csv> <clones.csv> <dest.md>
"""
import csv
import datetime as dt
import sys


def load(path):
    rows = []
    try:
        with open(path, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                rows.append((r["date"], int(r["count"]), int(r["uniques"])))
    except FileNotFoundError:
        pass
    return sorted(rows)


def total(rows):
    return sum(c for _, c, _ in rows)


def last_n(rows, n):
    return rows[-n:] if len(rows) > n else rows


def busiest(rows):
    if not rows:
        return ("n/a", 0)
    d, c, _ = max(rows, key=lambda x: x[1])
    return (d, c)


def mermaid_line(title, ylabel, rows):
    rows = last_n(rows, 30)
    if not rows:
        return "_No data yet._"
    xs = ", ".join(d[5:] for d, _, _ in rows)          # MM-DD
    counts = ", ".join(str(c) for _, c, _ in rows)
    uniques = ", ".join(str(u) for _, _, u in rows)
    ymax = max(max(c for _, c, _ in rows), 1)
    return (
        "```mermaid\n"
        "xychart-beta\n"
        f'    title "{title}"\n'
        f"    x-axis [{xs}]\n"
        f'    y-axis "{ylabel}" 0 --> {ymax}\n'
        f"    bar [{counts}]\n"
        f"    line [{uniques}]\n"
        "```\n"
    )


def main():
    if len(sys.argv) != 4:
        print("usage: build_dashboard.py <views.csv> <clones.csv> <dest.md>", file=sys.stderr)
        return 2
    views = load(sys.argv[1])
    clones = load(sys.argv[2])

    today = dt.date.today().isoformat()
    v_total, c_total = total(views), total(clones)
    v7, c7 = total(last_n(views, 7)), total(last_n(clones, 7))
    v_days = len(views) or 1
    bv_d, bv_c = busiest(views)
    bc_d, bc_c = busiest(clones)
    first_day = views[0][0] if views else "n/a"
    last_day = views[-1][0] if views else "n/a"

    out = []
    out.append("# Toolkit Usage Dashboard\n")
    out.append(f"_Auto-generated {today} by the Traffic snapshot workflow. "
               f"History: {first_day} to {last_day}._\n")
    out.append("> **How to read this:** _Clones_ are downloads that run the toolkit (each is a git "
               "checkout). _Views_ are page visits. GitHub Traffic is anonymous, so these are counts "
               "only, never usernames. A few clones each day come from this repo's own automation, "
               "not people.\n")

    out.append("## At a glance\n")
    out.append("| Metric | Views | Clones |")
    out.append("|---|---:|---:|")
    out.append(f"| Total (all history) | {v_total} | {c_total} |")
    out.append(f"| Last 7 days | {v7} | {c7} |")
    out.append(f"| Daily average | {v_total / v_days:.1f} | {c_total / v_days:.1f} |")
    out.append(f"| Busiest day | {bv_d} ({bv_c}) | {bc_d} ({bc_c}) |")
    out.append("")

    out.append("## Daily views\n")
    out.append(mermaid_line("Daily views (bar) and unique visitors (line)", "Visitors", views))
    out.append("## Daily clones\n")
    out.append(mermaid_line("Daily clones (bar) and unique cloners (line)", "Clones", clones))

    out.append("## Recent activity (last 14 days)\n")
    out.append("| Date | Views | Unique visitors | Clones | Unique cloners |")
    out.append("|---|---:|---:|---:|---:|")
    cmap = {d: (c, u) for d, c, u in clones}
    for d, vc, vu in last_n(views, 14):
        cc, cu = cmap.get(d, (0, 0))
        out.append(f"| {d} | {vc} | {vu} | {cc} | {cu} |")
    out.append("")
    out.append("---")
    out.append("_Source: GitHub repository Traffic API. Raw history lives in "
               "`metrics/traffic-views.csv` and `metrics/traffic-clones.csv`._")

    with open(sys.argv[3], "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print(f"{sys.argv[3]}: wrote dashboard ({v_days} days)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
