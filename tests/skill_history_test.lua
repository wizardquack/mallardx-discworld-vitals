-- Behaviour tests for src/skill_history.lua.
-- Run from project root: `lua tests/skill_history_test.lua`.

package.path = "./src/?.lua;" .. package.path
local sh = require("skill_history")

local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("PASS: " .. name)
  else
    print("FAIL: " .. name .. " — " .. tostring(err))
    os.exit(1)
  end
end

local function eq(got, want, ctx)
  assert(got == want,
    (ctx or "value") .. ": expected " .. tostring(want) .. ", got " .. tostring(got))
end

-- The captures LINE_PATTERN would produce for a typical line.
local function caps(over)
  local c = { dow = "Wed", mon = "Oct", day = 7, hms = "06:49:46", year = 2026,
              tz = "PDT", skill = "magic.methods.mental.cursing", levels = 1,
              bdelta = 1, to_level = 168, to_bonus = 286 }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

-- 2026-10-07 13:49:46 UTC.
local T_CURSING = 1791380986

-- ---------------------------------------------------------------------
-- Timestamps
-- ---------------------------------------------------------------------
test("days_from_civil matches known epochs", function()
  eq(sh._days_from_civil(1970, 1, 1), 0, "epoch")
  eq(sh._days_from_civil(2000, 3, 1), 11017, "2000-03-01")
  eq(sh._days_from_civil(2024, 2, 29), 19782, "leap day")
end)

test("server time honours the printed zone", function()
  local ts, exact = sh.parse_server_time("Oct", 7, "06:49:46", 2026, "PDT")
  eq(ts, T_CURSING, "PDT is UTC-7")
  eq(exact, true, "known zone")
  local pst = sh.parse_server_time("Jan", 5, "12:00:00", 2026, "PST")
  local utc = sh.parse_server_time("Jan", 5, "20:00:00", 2026, "UTC")
  eq(pst, utc, "PST is UTC-8")
end)

test("unknown zone falls back to local time, flagged", function()
  local ts, exact = sh.parse_server_time("Feb", 10, "00:21:07", 2024, "CA")
  eq(exact, false, "unknown zone")
  eq(ts, os.time({ year = 2024, month = 2, day = 10, hour = 0, min = 21, sec = 7 }), "local")
end)

-- ---------------------------------------------------------------------
-- Line parsing
-- ---------------------------------------------------------------------
test("increase_from_captures builds a full record", function()
  local r = sh.increase_from_captures(caps())
  eq(r.ts, T_CURSING, "ts")
  eq(r.server_time, "Wed Oct  7 06:49:46 2026 [PDT]", "server_time keeps the game's padding")
  eq(r.skill, "magic.methods.mental.cursing")
  eq(r.from_level, 167, "from_level"); eq(r.to_level, 168, "to_level")
  eq(r.from_bonus, 285, "from_bonus"); eq(r.to_bonus, 286, "to_bonus")
end)

test("language skills carry no bonus", function()
  local c = caps({ skill = "spoken Dwarfish", to_level = 19 })
  c.bdelta, c.to_bonus = nil, nil
  local r = sh.increase_from_captures(c)
  eq(r.skill, "spoken Dwarfish")
  eq(r.to_bonus, nil, "to_bonus"); eq(r.from_bonus, nil, "from_bonus")
  eq(r.from_level, 18, "from_level")
end)

test("capture only accepts lines inside the header window", function()
  local cap = sh.make_capture({ window = 5 })
  eq(cap.on_line(caps(), 100), nil, "no header yet")
  cap.on_header(200)
  assert(cap.on_line(caps(), 201), "inside window")
  assert(cap.on_line(caps(), 205), "each accepted line extends the window")
  eq(cap.on_line(caps(), 211), nil, "window closed")
end)

-- ---------------------------------------------------------------------
-- Refresh diffs
-- ---------------------------------------------------------------------
test("changes_from_diff keeps level rises only", function()
  local prev = { level = { a = 10, b = 20, c = 30 }, bonus = { a = 5, b = 6, c = 7 } }
  local cur  = { level = { a = 12, b = 20, c = 30, d = 3 }, bonus = { a = 9, b = 99, c = 7, d = 2 } }
  local ch = sh.changes_from_diff(prev, cur)
  eq(#ch, 2, "a rose, d is new; b's bonus-only change is ignored")
  eq(ch[1].skill, "a"); eq(ch[1].old_level, 10); eq(ch[1].new_level, 12)
  eq(ch[1].old_bonus, 5); eq(ch[1].new_bonus, 9)
  eq(ch[2].skill, "d"); eq(ch[2].old_level, 0, "new skill starts at 0")
end)

-- ---------------------------------------------------------------------
-- Reconstruction
-- ---------------------------------------------------------------------
local function inc(skill, to_level, levels, to_bonus, bdelta, ts)
  return { skill = skill, to_level = to_level, levels = levels, to_bonus = to_bonus,
           bonus_delta = bdelta, ts = ts, server_time = tostring(ts) }
end
local function refresh(skill, old_l, new_l, old_b, new_b, prev_ts, ts)
  return { skill = skill, old_level = old_l, new_level = new_l, old_bonus = old_b,
           new_bonus = new_b, prev_ts = prev_ts, ts = ts }
end

test("exact increases fully explaining a refresh leave no inferred row", function()
  local rows = sh.reconstruct(
    { inc("s", 301, 1, 278, 0, 500) },
    { refresh("s", 300, 301, 278, 278, 100, 1000) })
  eq(#rows, 1, "rows"); eq(rows[1].inferred, false)
end)

test("refresh with no exact data becomes one inferred row", function()
  local rows = sh.reconstruct({}, { refresh("s", 280, 290, 268, 273, 100, 1000) })
  eq(#rows, 1)
  local r = rows[1]
  eq(r.inferred, true); eq(r.from_level, 280); eq(r.to_level, 290)
  eq(r.from_bonus, 268); eq(r.to_bonus, 273)
  eq(r.t_lo, 100); eq(r.t_hi, 1000)
end)

test("partial exact coverage leaves the residual, with a tightened window", function()
  -- Refresh saw 280→300; hskills only caught 290→300 at t=600.
  local rows = sh.reconstruct(
    { inc("s", 300, 10, 278, 5, 600) },
    { refresh("s", 280, 300, 268, 278, 100, 1000) })
  eq(#rows, 2)
  eq(rows[1].inferred, false, "exact row is newest")
  local g = rows[2]
  eq(g.inferred, true); eq(g.from_level, 280); eq(g.to_level, 290)
  eq(g.from_bonus, 268); eq(g.to_bonus, 273, "bonus up to the exact row's start")
  eq(g.t_lo, 100); eq(g.t_hi, 600, "must precede the exact increase")
end)

test("gap after the last exact increase starts at that increase", function()
  local rows = sh.reconstruct(
    { inc("s", 281, 1, 269, 1, 300) },
    { refresh("s", 280, 285, 268, 271, 100, 1000) })
  eq(#rows, 2)
  local g = rows[1].inferred and rows[1] or rows[2]
  eq(g.from_level, 281); eq(g.to_level, 285)
  eq(g.t_lo, 300); eq(g.t_hi, 1000)
end)

test("increases outside a refresh's level span don't count against it", function()
  local rows = sh.reconstruct(
    { inc("s", 291, 1, 274, 1, 2000), inc("other", 285, 5, 1, 1, 500) },
    { refresh("s", 280, 290, 268, 273, nil, 1000) })
  eq(#rows, 3)
  local g
  for _, r in ipairs(rows) do if r.inferred then g = r end end
  eq(g.from_level, 280); eq(g.to_level, 290)
  eq(g.t_lo, nil, "unknown previous refresh time")
end)

test("rows sort newest first by ts / t_hi", function()
  local rows = sh.reconstruct(
    { inc("a", 2, 1, 1, 1, 50), inc("b", 2, 1, 1, 1, 900) },
    { refresh("c", 0, 5, 0, 3, 100, 500) })
  eq(rows[1].skill, "b"); eq(rows[2].skill, "c"); eq(rows[3].skill, "a")
end)

-- ---------------------------------------------------------------------
-- Windows, subtrees, labels
-- ---------------------------------------------------------------------
test("in_window: exact by ts, inferred by overlap", function()
  local win = { from = 1000 }
  assert(sh.in_window({ ts = 1500 }, win)); assert(not sh.in_window({ ts = 999 }, win))
  assert(sh.in_window({ inferred = true, t_lo = 500, t_hi = 1200 }, win), "overlaps")
  assert(not sh.in_window({ inferred = true, t_lo = 500, t_hi = 900 }, win), "ends before")
  assert(sh.in_window({ ts = 1 }, nil), "nil window is all time")
end)

test("under() matches a branch and its descendants only", function()
  assert(sh.under("fighting.range.fired", "fighting.range"))
  assert(sh.under("fighting.range", "fighting.range"))
  assert(not sh.under("fighting.rangefinding", "fighting.range"))
  assert(sh.under("anything", nil))
end)

test("fuzzy_label picks the coarsest true label", function()
  local function t(y, m, d, h) return os.time({ year = y, month = m, day = d, hour = h or 12 }) end
  local now = t(2026, 10, 7)
  eq(sh.fuzzy_label(t(2026, 10, 3, 8), t(2026, 10, 3, 20), now), "2026-10-03", "same day")
  eq(sh.fuzzy_label(t(2026, 10, 2), t(2026, 10, 4), now), "Oct 2–4", "short span")
  eq(sh.fuzzy_label(t(2026, 9, 29), t(2026, 10, 3), now), "Sep 29–Oct 3", "across months")
  eq(sh.fuzzy_label(t(2025, 12, 30), t(2026, 1, 2), now), "Dec 30 2025–Jan 2 2026", "across years")
  eq(sh.fuzzy_label(t(2026, 10, 1), t(2026, 10, 28), now), "Oct 2026", "month")
  eq(sh.fuzzy_label(t(2026, 8, 20), t(2026, 10, 3), now), "Aug–Oct 2026", "months")
  eq(sh.fuzzy_label(nil, t(2026, 10, 7), now), "before Oct 7", "unbounded")
  eq(sh.fuzzy_label(nil, t(2025, 3, 1), now), "before Mar 1 2025", "unbounded, other year")
end)

test("span_label formats deltas and missing ends", function()
  eq(sh.span_label(300, 301), "300→301 (+1)")
  eq(sh.span_label(278, 278), "278→278 (+0)")
  eq(sh.span_label(nil, 19), "?→19")
end)

-- ---------------------------------------------------------------------
-- Log backfill
-- ---------------------------------------------------------------------
local HDR = "Recent skill changes during this session:"
local L_CURSING = "Wed Oct  7 06:49:46 2026 [PDT] - magic.methods.mental.cursing "
  .. "increased by 1 level (and bonus 1) to level 168 (and bonus 286)."
local L_DWARFISH = "Sat Oct  3 16:28:50 2026 [PDT] - spoken Dwarfish "
  .. "increased by 1 level to level 19."
local L_SAILING = "Mon Sep 28 21:02:11 2026 [PDT] - adventuring.movement.sailing "
  .. "increased by 46 levels (and bonus 52) to level 120 (and bonus 160)."

test("parse_line yields the trigger's captures", function()
  local c = sh.parse_line(L_CURSING)
  eq(c.dow, "Wed"); eq(c.mon, "Oct"); eq(c.day, 7); eq(c.hms, "06:49:46")
  eq(c.year, 2026); eq(c.tz, "PDT"); eq(c.skill, "magic.methods.mental.cursing")
  eq(c.levels, 1); eq(c.bdelta, 1); eq(c.to_level, 168); eq(c.to_bonus, 286)
  local r = sh.increase_from_captures(c)
  eq(r.ts, T_CURSING, "ts"); eq(r.server_time, "Wed Oct  7 06:49:46 2026 [PDT]")
end)

test("parse_line handles language skills and plural levels", function()
  local d = sh.parse_line(L_DWARFISH)
  eq(d.skill, "spoken Dwarfish"); eq(d.to_level, 19)
  eq(d.bdelta, nil, "bdelta"); eq(d.to_bonus, nil, "to_bonus")
  local s = sh.parse_line(L_SAILING)
  eq(s.levels, 46); eq(s.bdelta, 52); eq(s.to_bonus, 160)
end)

test("parse_line rejects what LINE_PATTERN rejects", function()
  eq(sh.parse_line("Bosse: " .. L_SAILING), nil, "quoted in chat")
  eq(sh.parse_line(L_CURSING:gsub("^Wed", "Wen")), nil, "bad weekday")
  eq(sh.parse_line(L_CURSING:gsub("%.$", "")), nil, "no full stop")
  eq(sh.parse_line(L_CURSING .. " extra"), nil, "trailing text")
  eq(sh.parse_line(HDR), nil, "header")
end)

test("is_header", function()
  assert(sh.is_header(HDR))
  assert(sh.is_header(HDR .. "  "))
  assert(not sh.is_header("> " .. HDR))
end)

-- Feed (text, seconds) pairs newest first, as logs.search delivers them.
local function feed_all(gate, hits)
  local got = {}
  for _, h in ipairs(hits) do
    for _, r in ipairs(gate.feed(h[1], h[2] * 1000)) do got[#got + 1] = r end
  end
  return got
end

test("log gate accepts a burst once its header arrives", function()
  local g = sh.make_log_gate()
  local got = feed_all(g, {
    { L_DWARFISH, 102 }, { L_CURSING, 101 }, { HDR, 100 },
  })
  eq(#got, 2, "accepted")
  eq(got[1].skill, "magic.methods.mental.cursing", "oldest first")
  eq(g.headers, 1); eq(g.accepted, 2); eq(g.ungated, 0)
end)

test("log gate chains each line off the one before it", function()
  local g = sh.make_log_gate()
  -- 100 → 104 → 108 → 112: every step inside 5s, though 112 is 12s past
  -- the header.
  local got = feed_all(g, {
    { L_SAILING, 112 }, { L_DWARFISH, 108 }, { L_CURSING, 104 }, { HDR, 100 },
  })
  eq(#got, 3)
end)

test("log gate drops lines with no header in reach", function()
  local g = sh.make_log_gate()
  local got = feed_all(g, {
    { L_SAILING, 500 },               -- quoted in a room, long after
    { L_DWARFISH, 102 }, { HDR, 100 },
    { L_CURSING, 50 },                -- before any header
  })
  eq(#got, 1, "accepted"); eq(got[1].skill, "spoken Dwarfish")
  eq(g.finish(), 1, "left pending")
  eq(g.ungated, 2, "ungated")
end)

test("log gate: header too far before the burst accepts nothing", function()
  local g = sh.make_log_gate()
  local got = feed_all(g, { { L_DWARFISH, 108 }, { L_CURSING, 107 }, { HDR, 100 } })
  eq(#got, 0); eq(g.ungated, 2)
end)

test("log gate: each header claims only the lines after it", function()
  local g = sh.make_log_gate()
  local got = feed_all(g, {
    { L_CURSING, 3601 }, { HDR, 3600 },   -- a later hskills run
    { L_CURSING, 1 }, { HDR, 0 },         -- the same line, an hour earlier
  })
  eq(#got, 2, "both sightings accepted (the store dedupes)")
end)

test("log gate tags each record with its own line's character", function()
  local g = sh.make_log_gate()
  local got = {}
  for _, h in ipairs({
    { L_CURSING, 3601, "quack" }, { HDR, 3600, "quack" },
    { L_DWARFISH, 1, "flibber" }, { HDR, 0, "flibber" },
    { L_SAILING, -99, nil }, { HDR, -100, nil },
  }) do
    for _, r in ipairs(g.feed(h[1], h[2] * 1000, h[3])) do got[#got + 1] = r end
  end
  eq(#got, 3)
  eq(got[1].who, "quack"); eq(got[2].who, "flibber"); eq(got[3].who, nil, "unknown")
end)

print(string.format("\n%d tests passed", passed))
