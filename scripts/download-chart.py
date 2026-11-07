#!/usr/bin/env python3
"""Records today's download totals and draws the README's download chart.

    python3 scripts/download-chart.py <folder>

Reads every release's asset counts from GitHub's public API (GITHUB_TOKEN is used if
set, for a higher rate limit). It writes into <folder>:

  downloads.csv  one row per day: running totals of downloads, updates and checks.
                 GitHub keeps only running totals, so history starts with the first run.
                 Running again on the same day replaces that day's row.
  downloads.svg  running totals over time, and new downloads and updates per release.

Counted like scripts/download-stats.sh:
  downloads  Tinycap-<version>.dmg (website, README, Homebrew)
  updates    Tinycap-<version>-update.dmg (in-app updates through Sparkle)
  checks     appcast.xml (update checks; recorded in the CSV, not drawn)
"""
import csv
import datetime as dt
import json
import os
import sys
import urllib.request
from html import escape

REPO = os.environ.get("REPO", "soleo/tinycap")
FIELDS = ["date", "downloads", "updates", "checks"]


def fetch_releases():
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/releases?per_page=100",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "tinycap-download-chart"},
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def per_release(releases):
    """Oldest first: (tag, downloads, updates, checks)."""
    rows = []
    for release in releases:
        if release.get("draft"):
            continue
        downloads = updates = checks = 0
        for asset in release.get("assets", []):
            name, count = asset["name"], asset["download_count"]
            if name.endswith(("-update.dmg", "-update.zip")):
                updates += count
            elif name.endswith((".dmg", ".zip")):
                downloads += count
            elif name == "appcast.xml":
                checks += count
        rows.append((release.get("published_at") or "", release["tag_name"], downloads, updates, checks))
    rows.sort()
    return [row[1:] for row in rows]


def record(csv_path, today, totals):
    rows = []
    if os.path.exists(csv_path):
        with open(csv_path, newline="") as f:
            rows = [r for r in csv.DictReader(f) if r["date"] != today]
    rows.append({"date": today, **{k: str(v) for k, v in totals.items()}})
    rows.sort(key=lambda r: r["date"])
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    return rows


# ---------- Drawing ----------

W, H = 760, 520
LEFT, RIGHT = 56, 36
STYLE = """
  .surface { fill: #fcfcfb; }
  .title { fill: #0b0b0b; font: 600 15px -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; }
  .sub, .tick { fill: #52514e; font: 12px -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; }
  .value { fill: #0b0b0b; font: 600 12px -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; }
  .grid { stroke: #e4e3df; stroke-width: 1; }
  .axis { stroke: #b9b8b2; stroke-width: 1; }
  .s1 { fill: #2a78d6; } .s1l { stroke: #2a78d6; }
  .s2 { fill: #eb6834; } .s2l { stroke: #eb6834; }
  .ring { stroke: #fcfcfb; }
  @media (prefers-color-scheme: dark) {
    .surface { fill: #1a1a19; }
    .title, .value { fill: #f0efec; }
    .sub, .tick { fill: #c3c2b7; }
    .grid { stroke: #2e2e2c; }
    .axis { stroke: #55544f; }
    .s1 { fill: #3987e5; } .s1l { stroke: #3987e5; }
    .s2 { fill: #d95926; } .s2l { stroke: #d95926; }
    .ring { stroke: #1a1a19; }
  }
"""


def nice_max(value):
    """A round axis top at or above value, with 4 even steps."""
    value = max(value, 4)
    step = value / 4
    magnitude = 10 ** (len(str(int(step))) - 1)
    for m in (1, 2, 2.5, 5, 10):
        if step <= m * magnitude:
            return int(m * magnitude * 4)
    return int(10 * magnitude * 4)


def y_axis(out, top, height, maximum):
    for i in range(5):
        v = maximum * i // 4
        y = top + height - height * i / 4
        out.append(f'<line class="{"axis" if i == 0 else "grid"}" x1="{LEFT}" x2="{W - RIGHT}" y1="{y:.1f}" y2="{y:.1f}"/>')
        out.append(f'<text class="tick" x="{LEFT - 8}" y="{y + 4:.1f}" text-anchor="end">{v}</text>')


def legend(out, x, y):
    for cls, label in (("s1", "Downloads"), ("s2", "In-app updates")):
        out.append(f'<rect class="{cls}" x="{x}" y="{y - 9}" width="10" height="10" rx="2"/>')
        out.append(f'<text class="sub" x="{x + 15}" y="{y}">{label}</text>')
        x += 15 + 8 * len(label) + 18


def short_date(iso):
    d = dt.date.fromisoformat(iso)
    return f"{d.strftime('%b')} {d.day}"


def over_time(out, rows, top):
    """Running totals per day: one line per series, labeled at its end."""
    out.append(f'<text class="title" x="{LEFT - 40}" y="{top}">Running totals</text>')
    out.append(f'<text class="sub" x="{LEFT - 40}" y="{top + 18}">Since {short_date(rows[0]["date"])}, when tracking started; updated daily</text>')
    plot_top, plot_h = top + 44, 150
    series = [("s1", [int(r["downloads"]) for r in rows]), ("s2", [int(r["updates"]) for r in rows])]
    maximum = nice_max(max(max(v) for _, v in series))
    y_axis(out, plot_top, plot_h, maximum)
    right = W - RIGHT - 70  # room for end labels
    n = len(rows)

    def x(i):
        return (LEFT + right) / 2 if n == 1 else LEFT + (right - LEFT) * i / (n - 1)

    def y(v):
        return plot_top + plot_h - plot_h * v / maximum

    ends = []
    for cls, values in series:
        if n > 1:
            points = " ".join(f"{x(i):.1f},{y(v):.1f}" for i, v in enumerate(values))
            out.append(f'<polyline class="{cls}l" fill="none" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" points="{points}"/>')
        out.append(f'<circle class="{cls} ring" stroke-width="2" cx="{x(n - 1):.1f}" cy="{y(values[-1]):.1f}" r="4.5"/>')
        ends.append([y(values[-1]), values[-1]])
    # Keep the two end labels from overlapping.
    if abs(ends[0][0] - ends[1][0]) < 14:
        upper, lower = sorted(range(2), key=lambda i: ends[i][0])
        mid = (ends[0][0] + ends[1][0]) / 2
        ends[upper][0], ends[lower][0] = mid - 7, mid + 7
    for (label_y, value) in ends:
        out.append(f'<text class="value" x="{x(n - 1) + 10:.1f}" y="{label_y + 4:.1f}">{value}</text>')
    labels = {0: rows[0]["date"], n - 1: rows[-1]["date"]}
    for i, iso in labels.items():
        anchor = "middle" if n == 1 else ("start" if i == 0 else "end")
        out.append(f'<text class="tick" x="{x(i):.1f}" y="{plot_top + plot_h + 18}" text-anchor="{anchor}">{short_date(iso)}</text>')


def by_release(out, releases, top):
    """New downloads and updates per release, as paired bars."""
    out.append(f'<text class="title" x="{LEFT - 40}" y="{top}">By release</text>')
    out.append(f'<text class="sub" x="{LEFT - 40}" y="{top + 18}">All-time downloads of each version\'s files. Before 0.4.0, updates counted as downloads</text>')
    plot_top, plot_h = top + 44, 150
    maximum = nice_max(max([d for _, d, _, _ in releases] + [u for _, _, u, _ in releases] + [1]))
    y_axis(out, plot_top, plot_h, maximum)
    slot = (W - RIGHT - LEFT) / max(len(releases), 1)
    bar = min(18, slot / 3)
    base = plot_top + plot_h
    for i, (tag, downloads, updates, _) in enumerate(releases):
        center = LEFT + slot * (i + 0.5)
        for cls, value, bx in (("s1", downloads, center - bar - 1), ("s2", updates, center + 1)):
            h = plot_h * value / maximum
            if h > 0:
                r = min(4, h, bar / 2)
                # Rounded top, square foot on the baseline.
                out.append(f'<path class="{cls}" d="M{bx:.1f},{base} V{base - h + r:.1f} Q{bx:.1f},{base - h:.1f} {bx + r:.1f},{base - h:.1f} '
                           f'H{bx + bar - r:.1f} Q{bx + bar:.1f},{base - h:.1f} {bx + bar:.1f},{base - h + r:.1f} V{base} Z">'
                           f'<title>{escape(tag)}: {value} {"downloads" if cls == "s1" else "in-app updates"}</title></path>')
        out.append(f'<text class="tick" x="{center:.1f}" y="{base + 18}" text-anchor="middle">{escape(tag.lstrip("v"))}</text>')


def draw(rows, releases):
    last = rows[-1]
    desc = (f"Tinycap downloads: {last['downloads']} downloads and {last['updates']} in-app updates in total "
            f"as of {last['date']}. Per release: "
            + "; ".join(f"{t} {d} downloads, {u} updates" for t, d, u, _ in releases) + ".")
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="t d">',
           '<title id="t">Tinycap downloads</title>', f'<desc id="d">{escape(desc)}</desc>',
           f"<style>{STYLE}</style>",
           f'<rect class="surface" width="{W}" height="{H}" rx="12"/>']
    legend(out, W - RIGHT - 240, 30)
    over_time(out, rows, 30)
    by_release(out, releases, 286)
    out.append("</svg>")
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    releases = per_release(fetch_releases())
    totals = {
        "downloads": sum(r[1] for r in releases),
        "updates": sum(r[2] for r in releases),
        "checks": sum(r[3] for r in releases),
    }
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    rows = record(os.path.join(folder, "downloads.csv"), today, totals)
    with open(os.path.join(folder, "downloads.svg"), "w") as f:
        f.write(draw(rows, releases))
    print(f"{today}: {totals['downloads']} downloads, {totals['updates']} updates, {totals['checks']} checks "
          f"({len(rows)} days recorded)")


if __name__ == "__main__":
    main()
