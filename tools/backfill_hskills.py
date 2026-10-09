#!/usr/bin/env python3
"""Backfill the skill increase history from Mallard session logs.

The plugin only records `hskills` output it sees while loaded. This walks a
character's Mallard log archive and writes every `hskills` line it finds into
the plugin's per-world database, so /skill-history and /skill start with the
full history instead of from today.

Safe to re-run: rows go in with INSERT OR IGNORE against the same natural key
the plugin uses (char, skill, to_level, server_time), so a second pass — or
lines the live trigger already recorded — add nothing.

Single sources of truth, read out of the plugin source rather than copied:

  * HEADER_PATTERN / LINE_PATTERN / CAPTURE_WINDOW_SECONDS / TZ_OFFSETS
    from ../src/skill_history.lua
  * the DDL from ../src/history_store.lua

Same header gate as the live capture: a date-stamped skill line only counts
within CAPTURE_WINDOW_SECONDS of a "Recent skill changes during this
session:" header (each accepted line extends the window). That is what keeps
quoted hskills lines — e.g. in another player's room description — out.

Usage:
  python3 tools/backfill_hskills.py --list
  python3 tools/backfill_hskills.py --log-dir discworld-quack-1 --char quack --dry-run
  python3 tools/backfill_hskills.py --log-dir discworld-quack-1 --char quack --world 1
"""

import argparse
import gzip
import os
import re
import sqlite3
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

MALLARD_DATA = os.path.expanduser("~/Library/Application Support/net.mallard.app")
MALLARD_LOGS = os.path.join(MALLARD_DATA, "logs")
PLUGIN_ID = "net.mallard.discworld-vitals"

MONTHS = {m: i + 1 for i, m in enumerate(
    "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split())}


def lua_source(name):
    with open(os.path.join(ROOT, "src", name), encoding="utf-8") as f:
        return f.read()


def load_history_constants():
    src = lua_source("skill_history.lua")

    def lua_long_string(name):
        m = re.search(r"M\." + name + r"\s*=\s*\[\[(.+?)\]\]", src, re.S)
        if not m:
            sys.exit(f"could not find M.{name} in src/skill_history.lua")
        return m.group(1)

    window = re.search(r"M\.CAPTURE_WINDOW_SECONDS\s*=\s*(\d+)", src)
    tz_block = re.search(r"M\.TZ_OFFSETS\s*=\s*\{(.+?)\}", src, re.S)
    if not window or not tz_block:
        sys.exit("could not read CAPTURE_WINDOW_SECONDS / TZ_OFFSETS")
    tz = {k: float(v) for k, v in re.findall(r"(\w+)\s*=\s*(-?[\d.]+)", tz_block.group(1))}
    return (re.compile(lua_long_string("HEADER_PATTERN")),
            re.compile(lua_long_string("LINE_PATTERN")),
            int(window.group(1)), tz)


def load_schema():
    src = lua_source("history_store.lua")
    migrate = re.search(r"function M\.migrate\(\)(.+?)\nend", src, re.S)
    if not migrate:
        sys.exit("no migrate() in src/history_store.lua")
    stmts = re.findall(r"db\.exec\(\[\[(.+?)\]\]\)", migrate.group(1), re.S)
    if not stmts:
        sys.exit("no DDL found in src/history_store.lua")
    return [s.strip() for s in stmts]


# `2026-10-07T06:50:12-07:00 [1753880] text` — a second word in the bracket
# (`[123 echo]`, `[123 plugin]`, `[123 system]`) marks a non-server line.
MALLARD_LINE = re.compile(r"^(\S+) \[(\d+)(?: ([a-z_]+))?\] (.*)$")


def read_mallard(path):
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", errors="replace") as f:
        for raw in f:
            m = MALLARD_LINE.match(raw.rstrip("\n"))
            if not m:
                continue
            stamp, _id, source, text = m.groups()
            if source:
                continue
            try:
                ts = datetime.fromisoformat(stamp).timestamp()
            except ValueError:
                continue
            yield ts, text


def log_files(log_dir):
    names = [n for n in os.listdir(log_dir)
             if re.match(r"^\d{4}-\d\d-\d\d\.log(\.gz)?$", n)]
    # Chronological, so header windows never straddle files out of order.
    return [os.path.join(log_dir, n) for n in sorted(names)]


def server_ts(g, tz_offsets):
    """Mirror of skill_history.parse_server_time."""
    h, mi, s = (int(x) for x in g["hms"].split(":"))
    naive = datetime(int(g["year"]), MONTHS[g["mon"]], int(g["day"]), h, mi, s)
    off = tz_offsets.get(g["tz"].upper()) if g["tz"] is not None else None
    if off is None:
        return int(naive.timestamp()), False   # local-time fallback
    aware = naive.replace(tzinfo=timezone(timedelta(hours=off)))
    return int(aware.timestamp()), True


def extract(files, header_re, line_re, window, tz_offsets):
    found = {}
    stats = Counter()
    for path in files:
        open_until = None
        for ts, text in read_mallard(path):
            if header_re.match(text):
                stats["headers"] += 1
                open_until = ts + window
                continue
            m = line_re.match(text)
            if not m:
                continue
            if open_until is None or ts > open_until:
                stats["ungated"] += 1
                continue
            open_until = ts + window
            g = m.groupdict()
            sts, exact_zone = server_ts(g, tz_offsets)
            if not exact_zone:
                stats["unknown_tz"] += 1
            # Same shape increase_from_captures builds: day space-padded.
            server_time = "%s %s %2d %s %d" % (
                g["dow"], g["mon"], int(g["day"]), g["hms"], int(g["year"]))
            if g["tz"] is not None:
                server_time += " [%s]" % g["tz"]
            key = (g["skill"], int(g["to_level"]), server_time)
            stats["sightings"] += 1
            if key in found:
                continue
            found[key] = {
                "ts": sts,
                "server_time": server_time,
                "skill": g["skill"],
                "levels": int(g["levels"]),
                "bonus_delta": int(g["bdelta"]) if g["bdelta"] is not None else None,
                "to_level": int(g["to_level"]),
                "to_bonus": int(g["to_bonus"]) if g["to_bonus"] is not None else None,
            }
    return sorted(found.values(), key=lambda r: r["ts"]), stats


def db_path(world, override):
    if override:
        return override
    return os.path.join(MALLARD_DATA, "plugins-data", PLUGIN_ID, f"w{world}.db")


def write(path, char, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        for stmt in load_schema():
            conn.execute(stmt)
        added = 0
        for r in rows:
            cur = conn.execute(
                """INSERT OR IGNORE INTO skill_increases
                   (char, ts, server_time, skill, levels, bonus_delta,
                    to_level, to_bonus, source)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'log')""",
                (char, r["ts"], r["server_time"], r["skill"], r["levels"],
                 r["bonus_delta"], r["to_level"], r["to_bonus"]))
            added += max(cur.rowcount, 0)
        conn.commit()
        return added
    finally:
        conn.close()


def summarize(rows, stats):
    print(f"headers seen:            {stats['headers']}")
    print(f"skill line sightings:    {stats['sightings']} (gated in)")
    print(f"ungated skill lines:     {stats['ungated']} (no header nearby — skipped)")
    print(f"unknown-zone lines:      {stats['unknown_tz']}")
    print(f"distinct increases:      {len(rows)}")
    if not rows:
        return
    first = datetime.fromtimestamp(rows[0]["ts"]).strftime("%Y-%m-%d %H:%M")
    last = datetime.fromtimestamp(rows[-1]["ts"]).strftime("%Y-%m-%d %H:%M")
    print(f"span:                    {first} → {last}")
    levels = sum(r["levels"] for r in rows)
    skills = Counter(r["skill"] for r in rows)
    print(f"levels gained:           {levels} across {len(skills)} skills")
    print("top skills by increases:")
    for skill, n in skills.most_common(10):
        print(f"  {n:4d}  {skill}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="list log directories")
    ap.add_argument("--log-dir", help="log directory name under logs/ (or a path)")
    ap.add_argument("--char", help="character name the rows belong to (lowercase, as GMCP reports it)")
    ap.add_argument("--world", type=int, default=1,
                    help="Mallard world id; picks plugins-data/<plugin>/w<N>.db (default 1)")
    ap.add_argument("--db", help="explicit database path (overrides --world)")
    ap.add_argument("--dry-run", action="store_true", help="parse and report; write nothing")
    args = ap.parse_args()

    if args.list:
        for n in sorted(os.listdir(MALLARD_LOGS)):
            d = os.path.join(MALLARD_LOGS, n)
            if os.path.isdir(d):
                print(f"{n}  ({len(log_files(d))} text logs)")
        return
    if not args.log_dir or not args.char:
        ap.error("--log-dir and --char are required")

    log_dir = args.log_dir if os.path.isdir(args.log_dir) else os.path.join(MALLARD_LOGS, args.log_dir)
    header_re, line_re, window, tz = load_history_constants()
    files = log_files(log_dir)
    print(f"reading {len(files)} logs from {log_dir}")
    rows, stats = extract(files, header_re, line_re, window, tz)
    summarize(rows, stats)

    if args.dry_run:
        print("\n(dry run — nothing written)")
        return
    target = db_path(args.world, args.db)
    added = write(target, args.char, rows)
    print(f"\nwrote {added} new rows ({len(rows) - added} already present) to {target}")


if __name__ == "__main__":
    main()
