-- Skill increase history: parsing `hskills` output, inferring the increases
-- it missed from /skills-refresh diffs, and labelling both for display.
--
-- Pure Lua, no host APIs — main.lua owns the triggers and history_store.lua
-- owns the database. Everything here is unit-tested in
-- tests/skill_history_test.lua.
--
-- Two sources, two levels of certainty:
--
--   * EXACT rows come from the game's own `hskills` command, which lists
--     every skill change of the current login session:
--
--       Recent skill changes during this session:
--       Wed Oct  7 06:49:46 2026 [PDT] - magic.methods.mental.cursing increased by 1 level (and bonus 1) to level 168 (and bonus 286).
--       Sat Oct  3 16:28:50 2026 [PDT] - spoken Dwarfish increased by 1 level to level 19.
--
--     Language skills have no bonus, so both "(and bonus N)" clauses are
--     optional. Each run repeats the whole session so far, so the same line
--     is seen many times; the store dedupes on (char, skill, to_level,
--     server_time).
--
--   * INFERRED rows cover whatever `hskills` never showed — an increase
--     from a session that ended before anyone typed it. Every refresh
--     persists which skills' levels moved since the previous refresh
--     (`changes_from_diff`); `reconstruct` subtracts the exact rows that
--     explain part of that move and turns the remainder into rows whose
--     time is only known to lie in a window.
--
-- Inferred rows are derived on every read, never stored. That is what lets
-- an `hskills` typed AFTER a refresh retroactively shrink or erase an
-- inferred row without anything on disk being rewritten, and it means the
-- two sources can never double-count.

local M = {}

-- ---------------------------------------------------------------------
-- Trigger patterns (PCRE-ish, for mud.trigger / fancy_regex). The log
-- backfill (tools/backfill_hskills.py) reads these two strings straight out
-- of this file, so the live trigger and the backfill can't drift apart.
-- ---------------------------------------------------------------------

M.HEADER_PATTERN = [[^Recent skill changes during this session:\s*$]]

-- Anchored on the full `<Day> <Mon> <dd> HH:MM:SS YYYY [TZ] - ` prefix:
-- guild chat and tells that quote a skill line ("Bosse: adventuring.movement
-- .sailing increased by 46 levels…") never start with a date, so they can't
-- match.
M.LINE_PATTERN = [[^(?P<dow>Mon|Tue|Wed|Thu|Fri|Sat|Sun) (?P<mon>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +(?P<day>\d{1,2}) (?P<hms>\d\d:\d\d:\d\d) (?P<year>\d{4}) \[(?P<tz>[A-Za-z0-9+-]+)\] - (?P<skill>.+?) increased by (?P<levels>\d+) levels? (?:\(and bonus (?P<bdelta>-?\d+)\) )?to level (?P<to_level>\d+)(?: \(and bonus (?P<to_bonus>-?\d+)\))?\.\s*$]]

-- A date-shaped skill line only counts if it arrives within this many
-- seconds of the "Recent skill changes" header (each accepted line extends
-- the window). Without the header gate, a room description that happens to
-- quote someone else's hskills line — seen in the logs: a teacher's room
-- showing "Sat Feb 10 00:21:07 2024 [CA] - fighting.special.unarmed …" —
-- would be recorded as ours.
M.CAPTURE_WINDOW_SECONDS = 5

-- ---------------------------------------------------------------------
-- Server timestamps
-- ---------------------------------------------------------------------

local MONTHS = {
  Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6,
  Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12,
}

-- UTC offsets (hours) for the zone abbreviations Discworld prints. The
-- game renders times in the player's chosen zone; anything not listed here
-- falls back to "assume it's the local zone" (see parse_server_time).
M.TZ_OFFSETS = {
  UTC = 0, GMT = 0, BST = 1, IST = 1, WET = 0, WEST = 1,
  CET = 1, CEST = 2, EET = 2, EEST = 3,
  PST = -8, PDT = -7, MST = -7, MDT = -6, CST = -6, CDT = -5,
  EST = -5, EDT = -4, AKST = -9, AKDT = -8, HST = -10,
  AEST = 10, AEDT = 11, ACST = 9.5, ACDT = 10.5, AWST = 8,
  NZST = 12, NZDT = 13,
}

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil). Done arithmetically rather than via os.time, because
-- os.time reads its table in the machine's local zone and we need the
-- zone the GAME printed.
local function days_from_civil(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = y // 400   -- Lua's // floors, so no negative-year correction
  local yoe = y - era * 400
  local mp  = (m + 9) % 12
  local doy = (153 * mp + 2) // 5 + d - 1
  local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
  return era * 146097 + doe - 719468
end
M._days_from_civil = days_from_civil

-- parse_server_time(mon, day, hms, year, tz) -> unix_ts, exact_zone
-- `exact_zone` is false when the zone abbreviation was unknown and the
-- wall-clock time was read as local time instead.
function M.parse_server_time(mon, day, hms, year, tz)
  local mo = MONTHS[mon]
  local h, mi, s = tostring(hms):match("^(%d+):(%d+):(%d+)$")
  day, year = tonumber(day), tonumber(year)
  if not (mo and h and day and year) then return nil end
  h, mi, s = tonumber(h), tonumber(mi), tonumber(s)
  local off = M.TZ_OFFSETS[tostring(tz):upper()]
  if off then
    local secs = days_from_civil(year, mo, day) * 86400 + h * 3600 + mi * 60 + s
    return math.floor(secs - off * 3600), true
  end
  return os.time({ year = year, month = mo, day = day,
                   hour = h, min = mi, sec = s }), false
end

-- ---------------------------------------------------------------------
-- Parsing one hskills line
-- ---------------------------------------------------------------------

-- Build an increase record from a trigger match (or any table carrying the
-- LINE_PATTERN's named groups). Returns nil for a malformed match.
--
--   { ts, server_time, skill, levels, bonus_delta, to_level, to_bonus,
--     from_level, from_bonus }
--
-- bonus_delta / to_bonus / from_bonus are nil for language skills.
function M.increase_from_captures(c)
  if type(c) ~= "table" then return nil end
  local skill    = c.skill and tostring(c.skill)
  local levels   = tonumber(c.levels)
  local to_level = tonumber(c.to_level)
  if not skill or skill == "" or not levels or not to_level then return nil end
  local ts = M.parse_server_time(c.mon, c.day, c.hms, c.year, c.tz)
  if not ts then return nil end
  local bdelta   = tonumber(c.bdelta)
  local to_bonus = tonumber(c.to_bonus)
  -- The game pads single-digit days with a space ("Oct  7"); rebuild that
  -- exact shape so the dedupe key matches whichever path saw the line.
  local server_time = string.format("%s %s %2d %s %d [%s]",
    tostring(c.dow), tostring(c.mon), tonumber(c.day), tostring(c.hms),
    tonumber(c.year), tostring(c.tz))
  return {
    ts          = ts,
    server_time = server_time,
    skill       = skill,
    levels      = levels,
    bonus_delta = bdelta,
    to_level    = to_level,
    to_bonus    = to_bonus,
    from_level  = to_level - levels,
    from_bonus  = (to_bonus and bdelta) and (to_bonus - bdelta) or nil,
  }
end

-- ---------------------------------------------------------------------
-- Header-gated capture state machine
-- ---------------------------------------------------------------------

-- make_capture() -> { on_header(now), on_line(captures, now) -> record|nil }
-- on_line only accepts lines inside the window opened by the header.
function M.make_capture(opts)
  opts = opts or {}
  local window = opts.window or M.CAPTURE_WINDOW_SECONDS
  local open_until = nil
  local self = {}
  function self.on_header(now)
    open_until = now + window
  end
  function self.on_line(captures, now)
    if not open_until or now > open_until then return nil end
    local rec = M.increase_from_captures(captures)
    if rec then open_until = now + window end
    return rec
  end
  function self.is_open(now) return open_until ~= nil and now <= open_until end
  return self
end

-- ---------------------------------------------------------------------
-- Refresh diffs
-- ---------------------------------------------------------------------

-- The per-refresh record we persist: one entry per skill whose LEVEL rose
-- between two snapshots. Bonus-only movement (stat changes, a neighbour's
-- TM shifting a shared bonus) is deliberately ignored — a single stat
-- point would otherwise spray dozens of rows. A skill missing from the
-- previous snapshot is treated as having been level 0 / bonus 0.
function M.changes_from_diff(prev, current)
  local out = {}
  if type(current) ~= "table" or type(current.level) ~= "table" then return out end
  local pl = (type(prev) == "table" and type(prev.level) == "table") and prev.level or {}
  local pb = (type(prev) == "table" and type(prev.bonus) == "table") and prev.bonus or {}
  local cb = type(current.bonus) == "table" and current.bonus or {}
  for path, lvl in pairs(current.level) do
    local old = pl[path] or 0
    if type(lvl) == "number" and lvl > old then
      out[#out + 1] = {
        skill     = path,
        old_level = old, new_level = lvl,
        old_bonus = pl[path] and pb[path] or 0,
        new_bonus = cb[path],
      }
    end
  end
  table.sort(out, function(a, b) return a.skill < b.skill end)
  return out
end

-- ---------------------------------------------------------------------
-- Reconstruction: exact rows + inferred gaps
-- ---------------------------------------------------------------------

-- reconstruct(increases, refreshes) -> rows, newest first.
--
-- `increases`: exact records (see increase_from_captures; from_* may be
--   absent and are recomputed).
-- `refreshes`: { skill, ts, prev_ts|nil, old_level, new_level, old_bonus,
--   new_bonus } — one per skill per refresh.
--
-- Each row: { skill, from_level, to_level, from_bonus, to_bonus,
--             inferred = bool,
--             ts (exact rows) | t_lo, t_hi (inferred; t_lo nil = unbounded),
--             server_time (exact rows) }
--
-- Matching is by LEVEL RANGE, not by time: levels only ever go up, so an
-- exact increase whose levels fall inside a refresh's old→new span must
-- belong to that span. That makes the merge immune to clock skew between
-- the game's timestamps and ours. Within a span, the gaps between exact
-- increases become inferred rows, and each gap's time window is tightened
-- by its neighbours: the 280→290 part of a 280→300 refresh, when 290→300
-- is known to have happened at T, must lie between the previous refresh
-- and T.
function M.reconstruct(increases, refreshes)
  local rows = {}
  local by_skill = {}
  for _, e in ipairs(increases or {}) do
    local r = {
      skill = e.skill, inferred = false, ts = e.ts, server_time = e.server_time,
      to_level = e.to_level, to_bonus = e.to_bonus,
      from_level = e.from_level or (e.to_level - e.levels),
      from_bonus = e.from_bonus
        or ((e.to_bonus and e.bonus_delta) and (e.to_bonus - e.bonus_delta) or nil),
    }
    rows[#rows + 1] = r
    local list = by_skill[r.skill]
    if not list then list = {}; by_skill[r.skill] = list end
    list[#list + 1] = r
  end
  for _, list in pairs(by_skill) do
    table.sort(list, function(a, b)
      if a.to_level ~= b.to_level then return a.to_level < b.to_level end
      return a.ts < b.ts
    end)
  end

  local function gap(skill, fl, tl, fb, tb, lo, hi)
    rows[#rows + 1] = {
      skill = skill, inferred = true,
      from_level = fl, to_level = tl, from_bonus = fb, to_bonus = tb,
      t_lo = lo, t_hi = hi,
    }
  end

  for _, rc in ipairs(refreshes or {}) do
    if rc.new_level and rc.old_level and rc.new_level > rc.old_level then
      local cur_l, cur_b, cur_t = rc.old_level, rc.old_bonus, rc.prev_ts
      for _, e in ipairs(by_skill[rc.skill] or {}) do
        if e.from_level >= rc.old_level and e.to_level <= rc.new_level then
          if e.from_level > cur_l then
            local hi = rc.ts
            if e.ts and e.ts < hi then hi = e.ts end
            gap(rc.skill, cur_l, e.from_level, cur_b, e.from_bonus, cur_t, hi)
          end
          if e.to_level > cur_l then
            cur_l, cur_b = e.to_level, e.to_bonus
            if e.ts and (not cur_t or e.ts > cur_t) then cur_t = e.ts end
          end
        end
      end
      if cur_l < rc.new_level then
        gap(rc.skill, cur_l, rc.new_level, cur_b, rc.new_bonus, cur_t, rc.ts)
      end
    end
  end

  table.sort(rows, function(a, b)
    local ka = a.ts or a.t_hi or 0
    local kb = b.ts or b.t_hi or 0
    if ka ~= kb then return ka > kb end
    if a.skill ~= b.skill then return a.skill < b.skill end
    return a.to_level > b.to_level
  end)
  return rows
end

-- Does `row` fall inside window `win` ({from|nil, to|nil}; nil = all time)?
-- An inferred row counts if its possible-time window overlaps at all.
function M.in_window(row, win)
  if not win then return true end
  local from, to = win.from, win.to
  if row.inferred then
    if from and row.t_hi and row.t_hi < from then return false end
    if to and row.t_lo and row.t_lo >= to then return false end
    return true
  end
  if from and row.ts < from then return false end
  if to and row.ts >= to then return false end
  return true
end

-- Does `skill` sit at or under the branch `path`? ("fighting.range" covers
-- itself and fighting.range.*, but not fighting.rangefinding.)
function M.under(skill, path)
  if not path then return true end
  return skill == path or skill:sub(1, #path + 1) == path .. "."
end

-- ---------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------

local MON_ABBR = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- Exact rows: local "YYYY-MM-DD HH:MM".
function M.exact_label(ts)
  return os.date("%Y-%m-%d %H:%M", ts)
end

-- Inferred rows: the coarsest label that is still true, so a vague time
-- never looks more precise than it is.
--
--   window inside one local day   2026-10-03
--   under two weeks               Oct 2–4 · Sep 29–Oct 3   (+ year if not now's)
--   longer                        Oct 2026 · Sep–Oct 2026 · Dec 2025–Jan 2026
--   no lower bound                before Oct 7             (+ year if not now's)
--
-- `now` decides whether the year is implied (defaults to os.time()).
function M.fuzzy_label(t_lo, t_hi, now)
  now = now or os.time()
  local this_year = os.date("*t", now).year
  local b = os.date("*t", t_hi)
  local function yr(d) return d.year == this_year and "" or (" " .. d.year) end
  if not t_lo then
    return string.format("before %s %d%s", MON_ABBR[b.month], b.day, yr(b))
  end
  local a = os.date("*t", t_lo)
  if a.year == b.year and a.yday == b.yday then
    return os.date("%Y-%m-%d", t_hi)
  end
  if t_hi - t_lo < 14 * 86400 then
    if a.year == b.year and a.month == b.month then
      return string.format("%s %d–%d%s", MON_ABBR[a.month], a.day, b.day, yr(b))
    end
    if a.year == b.year then
      return string.format("%s %d–%s %d%s", MON_ABBR[a.month], a.day,
        MON_ABBR[b.month], b.day, yr(b))
    end
    return string.format("%s %d %d–%s %d %d", MON_ABBR[a.month], a.day, a.year,
      MON_ABBR[b.month], b.day, b.year)
  end
  if a.year == b.year and a.month == b.month then
    return string.format("%s %d", MON_ABBR[a.month], a.year)
  end
  if a.year == b.year then
    return string.format("%s–%s %d", MON_ABBR[a.month], MON_ABBR[b.month], b.year)
  end
  return string.format("%s %d–%s %d", MON_ABBR[a.month], a.year,
    MON_ABBR[b.month], b.year)
end

function M.when_label(row, now)
  if row.inferred then return M.fuzzy_label(row.t_lo, row.t_hi, now) end
  return M.exact_label(row.ts)
end

-- "300→301 (+1)"; nil ends render as "?" (e.g. a language skill's bonus).
function M.span_label(from, to)
  if from == nil or to == nil then
    return string.format("%s→%s", from == nil and "?" or tostring(from),
      to == nil and "?" or tostring(to))
  end
  local d = to - from
  return string.format("%d→%d (%s%d)", from, to, d >= 0 and "+" or "-", math.abs(d))
end

return M
