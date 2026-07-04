-- Discworld Vitals — custom HTML panel (ui/vitals.{html,css,js}).
--
-- Maintains a single state table and pushes the full snapshot to the iframe
-- via `panel:post("state", ...)` after every mutation. The iframe replaces
-- the DOM wholesale, same pattern as discworld-sailing / discworld-grouping.
--
-- XP/hour math lives in src/xp_tracker.lua and GP optimistic-regen in
-- src/gp_tracker.lua — both are unit-tested at the Lua level under
-- src-tauri/tests/discworld_vitals_plugin.rs.

local xp_tracker    = require("xp_tracker")
local gp_tracker    = require("gp_tracker")
local skills_parser = require("skills_parser")
local stats_parser  = require("stats_parser")
local planner       = require("planner")
local skill_data    = require("skill_data")
local skill_query   = require("skill_query")
local panel_push    = require("panel_push")

local panel = mud.panel("vitals")

-- ---------------------------------------------------------------------
-- State snapshot. Mutations route through push_state() so every change
-- triggers a fresh panel post. CCC / BUG / MS sit at "unknown" until
-- detection lands in a later session — the slots are reserved here so
-- adding them later is just a shield_set() call.
-- ---------------------------------------------------------------------

local state = {
  charname = nil,         -- current character name | nil   (for the panel menu header)
  hp       = nil,         -- { value, max } | nil
  gp       = nil,         -- { value, max } | nil
  burden   = nil,         -- 0..100 | nil
  xp       = nil,         -- formatted string | nil
  xp_rate  = nil,         -- formatted string | nil   (trailing-window xp count)
  xp_chart = {            -- point-in-time xp/hour samples
    enabled = settings.get("show_xp_chart") ~= false,
    series  = {},         -- array of xp/hour numbers, oldest first, max 60
  },
  shields = {
    eff = { state = "unknown", detail = "" },
    ccc = { state = "unknown", detail = "" },
    bug = { state = "unknown", detail = "" },
    ms  = { state = "unknown", detail = "" },
    tpa = { state = "unknown", detail = "" },
  },
}

-- Change-gated: re-posting the full snapshot on every mutation is correct but
-- wasteful — most mutations (periodic char.vitals refresh, GP regen tick, XP
-- bucket with an unchanged rate) leave the rendered state identical. panel_push
-- suppresses those no-op posts, cutting load on the shared plugin runtime.
local _pusher = panel_push.new(function(s) panel:post("state", s) end)
local function push_state() _pusher.push(state) end

-- Keep the panel told who we're logged in as, so its right-click menu can
-- show a "Vitals: <charname>" header. Only re-push on an actual change.
local function set_charname(name)
  if type(name) ~= "string" or name == "" or name == state.charname then return end
  state.charname = name
  push_state()
end

-- A (re)opened iframe holds no state, so force a full repaint past the gate.
panel:on_message("ready", function() _pusher.force(state) end)

-- ---------------------------------------------------------------------
-- Formatting helpers
-- ---------------------------------------------------------------------

local function format_thousands(n)
  if type(n) ~= "number" then return tostring(n) end
  local s = tostring(math.floor(n))
  local rev = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (rev:gsub("^,", ""))
end

-- Comma-tolerant numeric coercion. Wire sources are inconsistent about
-- thousands separators: GMCP usually delivers raw numbers, MXP entities and
-- score-brief captures are strings, and user-entered settings may include
-- commas. Strip commas before delegating to tonumber so every numeric input
-- to the plugin parses the same way.
local function to_num(v)
  if type(v) == "number" then return v end
  if type(v) ~= "string" then return nil end
  return tonumber((v:gsub(",", "")))
end

-- Title-case every whitespace-separated word ("dull red" → "Dull Red").
local function title_case(s)
  if type(s) ~= "string" or s == "" then return s end
  return (s:gsub("(%a)(%w*)", function(first, rest)
    return first:upper() .. rest:lower()
  end))
end

-- Compact human-readable duration: "12s", "2m 30s", "1h 5m".
local function format_duration(s)
  if type(s) ~= "number" or s < 0 then return "?" end
  s = math.floor(s)
  if s < 60 then return s .. "s" end
  local m = math.floor(s / 60)
  local rs = s % 60
  if m < 60 then return string.format("%dm %ds", m, rs) end
  local h = math.floor(m / 60)
  local rm = m % 60
  return string.format("%dh %dm", h, rm)
end

local function now_seconds() return os.time() end

-- ---------------------------------------------------------------------
-- Trackers
-- ---------------------------------------------------------------------

local gp_regen       = settings.get("gp_regen")
local XP_CHART_MAX_POINTS = 60
local XP_BUCKET_SECONDS   = 60
local tracker        = xp_tracker.make(XP_BUCKET_SECONDS, XP_CHART_MAX_POINTS)
local gp             = gp_tracker.make(gp_regen)

-- Last raw XP value seen, used to compute the per-update delta for the
-- optional gain-announcement feature. Nil until the first sample arrives —
-- we don't announce on the initial reading.
local last_xp = nil

local function announce_xp_gain(raw_xp)
  local n = to_num(raw_xp)
  if not n then return end
  if last_xp ~= nil and settings.get("show_xp_gains") then
    local gain      = n - last_xp
    local threshold = to_num(settings.get("xp_gain_threshold")) or 0
    if gain >= threshold and gain > 0 then
      mud.note("{xp: " .. format_thousands(gain) .. "}")
    end
  end
  last_xp = n
end

local function set_hp(v, m)
  if v and m then state.hp = { value = v, max = m }; push_state() end
end

-- GP-full chime is arm-then-fire: a dip below 75% arms it, the next refill to
-- full fires it. Without the arming step, a single small cast that nicks GP
-- by a few points would re-trigger the chime every combat round. Threshold
-- ported from Quow's UpdateVitals (QuowMinimap.xml:17371).
local gp_full_armed = false
local gp_was_full   = false
local GP_FULL_ARM_THRESHOLD = 0.75

local function set_gp(v, m)
  if not (v and m) then return end
  state.gp = { value = v, max = m }

  -- Broadcast the GP-full moment so peer plugins (e.g. discworld-magic, to
  -- resume casting) can react. Edge-triggered on the not-full → full
  -- transition: any refill to max fires it exactly once (no 75%-dip gate),
  -- and it won't re-fire on the authoritative refreshes that keep landing
  -- while GP sits pinned at max. Emitted independently of the user's local
  -- gp_full_sound preference. Complements the inbound
  -- `net.mallard.discworld.gp.zero` we already subscribe to.
  local is_full = m > 0 and v >= m
  if is_full and not gp_was_full then
    events.emit("net.mallard.discworld.gp.full", { subject = "self", gp = v, maxgp = m })
  end
  gp_was_full = is_full

  -- The chime keeps its own arm-then-fire gate: a dip below 75% arms it, the
  -- next refill fires it. Without the arm step a single GP-nicking cast would
  -- re-chime every combat round.
  if m > 0 and v < m * GP_FULL_ARM_THRESHOLD then
    gp_full_armed = true
  elseif v >= m and gp_full_armed then
    gp_full_armed = false
    if settings.get("gp_full_sound") then
      mud.play_sound("mallard:ding-ding-ding")
    end
  end
  push_state()
end

local function push_gp_optimistic()
  local v, m = gp.current()
  if v and m then set_gp(v, m) end
end

local function set_burden(b)
  if b then state.burden = b; push_state() end
end

local function set_xp(x)
  if x then state.xp = format_thousands(x); push_state() end
end

-- Forward-declared so the `char.info` handler below can reference it
-- before the persistence section defines it further down.
local hydrate_xp_state

-- ---------------------------------------------------------------------
-- Live settings updates. Three of our five settings (show_xp_gains,
-- xp_gain_threshold, gp_full_sound) are read inline at point-of-use, so
-- they auto-apply without any wiring here. The remaining two are cached
-- at startup and need a handler to re-apply on change. With every setting
-- handled in-place, `mud.request_restart()` is never called — settings
-- changes never restart the VM, preserving the XP tracker buffer + the
-- gp optimistic-regen state across edits.
-- ---------------------------------------------------------------------

settings.on("change", function(key, new, _old)
  if key == "gp_regen" then
    gp.set_regen(to_num(new) or 3)
  elseif key == "show_xp_chart" then
    state.xp_chart.enabled = new ~= false
    push_state()
  end
end)

-- ---------------------------------------------------------------------
-- GMCP — `char.vitals` carries authoritative HP/GP/burden/XP on login
-- and (on some Discworld configs) periodic refreshes. MXP entity pushes
-- below are the primary real-time update mechanism.
-- ---------------------------------------------------------------------

gmcp.on("char.vitals", function(_pkg, data)
  if type(data) ~= "table" then return end
  local hp, maxhp   = to_num(data.hp),     to_num(data.maxhp)
  local gpv, maxgp  = to_num(data.gp),     to_num(data.maxgp)
  local burden      = to_num(data.burden)
  local xp          = to_num(data.xp)
  if hp and maxhp then state.hp = { value = hp, max = maxhp } end
  if gpv and maxgp then
    gp.set(gpv, maxgp)
    local v, m = gp.current()
    if v and m then set_gp(v, m) end
  end
  if burden then state.burden = burden end
  if xp then
    state.xp = format_thousands(xp)
    announce_xp_gain(xp)
  end
  push_state()
end)

-- ---------------------------------------------------------------------
-- char.info mirror — scalars into world vars under `char.info.<key>` and
-- re-broadcast as a Mallard event so discworld-grouping can read player
-- identity without holding its own gmcp grant. (Behaviour unchanged from
-- v0.3.x; the rewrite only touches the panel UI.)
-- ---------------------------------------------------------------------
gmcp.on("char.info", function(_pkg, data)
  if type(data) ~= "table" then return end
  -- char.info is the first wire-side hint of who we're logged in as.
  -- Hydrate is idempotent per (charname) — repeated info updates with the
  -- same name don't re-hydrate. A name change (alt switch) triggers a
  -- fresh hydrate and from then on saves the new alt's slot.
  if type(data.name) == "string" then
    hydrate_xp_state(data.name)
    set_charname(data.name)
  end
end)

-- ---------------------------------------------------------------------
-- MXP entity pushes — primary real-time path (Plan #9c).
-- ---------------------------------------------------------------------

local function refresh_hp()
  local v = to_num(mxp.get_entity("hp"))
  local m = to_num(mxp.get_entity("maxhp"))
  set_hp(v, m)
end

local function refresh_gp_from_mxp()
  local v = to_num(mxp.get_entity("gp"))
  local m = to_num(mxp.get_entity("maxgp"))
  if v and m then
    gp.set(v, m)
    push_gp_optimistic()
  end
end

mxp.on_entity("hp",    refresh_hp)
mxp.on_entity("maxhp", refresh_hp)
mxp.on_entity("gp",    refresh_gp_from_mxp)
mxp.on_entity("maxgp", refresh_gp_from_mxp)

mxp.on_entity("burden", function(_, v)
  local b = to_num(v)
  if b then set_burden(b) end
end)

mxp.on_entity("xp", function(_, v)
  local x = to_num(v)
  if x then
    set_xp(x)
    announce_xp_gain(x)
  end
end)

-- ---------------------------------------------------------------------
-- XP state persistence — keyed by `char.info.name` so the chart and the
-- "last shown" xp/hour figure survive plugin restart / relog.
--
-- Strategy is restore-verbatim with no gap-filling: the persisted delta
-- buffer + baseline are dropped back in exactly as written, so the chart
-- at moment-of-reconnect is byte-identical to moment-of-disconnect. The
-- next tick (≤10s after relog) appends a fresh bucket against the restored
-- baseline; if no XP was earned offline the delta is 0 and the rolling
-- window starts draining naturally from there. See quow's UpdateXPGraph
-- (QuowMinimap.xml:17105) for the reference implementation we ported.
--
-- We gate saves on a successful hydration (or a confirmed nothing-to-
-- hydrate) so the first post-login save can't blank out the persisted
-- record before char.info has arrived to tell us who we are.
-- ---------------------------------------------------------------------

local hydrated_for = nil

hydrate_xp_state = function(charname)
  if not charname or charname == "" then return end
  if hydrated_for == charname then return end
  hydrated_for = charname
  local saved = storage.get("xp_state/" .. charname)
  if type(saved) ~= "table" then return end

  -- Restore chart series in-place — preserves the table identity referenced
  -- from state.xp_chart.series, so we don't have to reassign + push twice.
  -- Drop the oldest entries if the saved buffer is larger than the current
  -- XP_CHART_MAX_POINTS (e.g., persisted under a finer-grained bucket schema
  -- on a previous plugin version) so the renderer's fixed-width x-axis
  -- denominator stays in sync with the actual entry count.
  local series = state.xp_chart.series
  for i = #series, 1, -1 do series[i] = nil end
  if type(saved.chart_series) == "table" then
    local saved_series = saved.chart_series
    local n = #saved_series
    local start = (n > XP_CHART_MAX_POINTS) and (n - XP_CHART_MAX_POINTS + 1) or 1
    for i = start, n do
      local v = saved_series[i]
      if type(v) == "number" then series[#series + 1] = v end
    end
  end

  tracker.restore(saved.xp_deltas, saved.baseline_xp)

  if type(saved.last_rate) == "string" and saved.last_rate ~= "" then
    state.xp_rate = saved.last_rate
  end

  push_state()
end

local function save_xp_state()
  if not hydrated_for then return end
  storage.set("xp_state/" .. hydrated_for, {
    chart_series = state.xp_chart.series,
    xp_deltas    = tracker.deltas(),
    baseline_xp  = tracker.baseline(),
    last_rate    = state.xp_rate,
    saved_at     = now_seconds(),
  })
end

-- Single 10s tick drives both the chart series and the headline rate.
-- `tracker.tick(last_xp)` records one bucket-delta (0 if no XP arrived since
-- the previous tick) and returns the new per-bucket-avg * 360 hourly rate.
-- Idle stretches contribute 0-deltas, so the rate drains as old non-zero
-- buckets slide off — no stickiness, no stale plateau. The chart renderer
-- treats each slot as a fixed time step, so we keep advancing it whether or
-- not anything changed numerically.
mud.every(XP_BUCKET_SECONDS * 1000, function()
  local r = tracker.tick(last_xp)
  -- Only touch the chart + headline when tick() produced a real rate. A nil
  -- means the tracker is still seeding its baseline (first tick of a fresh
  -- session, or first tick after hydrate from a pre-bucket-schema save).
  -- Treating that nil as 0 would cliff the chart edge and blank the sticky
  -- last_rate restored by hydrate_xp_state — skip the append/format instead.
  if r ~= nil then
    local series = state.xp_chart.series
    series[#series + 1] = r
    while #series > XP_CHART_MAX_POINTS do table.remove(series, 1) end
    state.xp_rate = format_thousands(r)
  end
  save_xp_state()
  push_state()
end)

-- ---------------------------------------------------------------------
-- GP optimistic regen — one combat round (~2s). Authoritative sources
-- overwrite the optimistic value when they arrive.
-- ---------------------------------------------------------------------

mud.every(2000, function()
  if gp.tick() then push_gp_optimistic() end
end)

-- ---------------------------------------------------------------------
-- Shields — unified bus from discworld-magic.
--
-- Event payload shapes (subject="self" only — others go to grouping):
--   eff up:   { item }
--   eff down: {}                                       (binary)
--   ccc up:   { substance, strength (1..5|nil) }
--   ccc down: { duration_seconds, previous_substance, previous_strength }
--   bug up:   { size, bugs }
--   bug down: { duration_seconds, cause, previous_size, previous_bugs }
--   ms  up:   { deity, form, via, strength (string) }
--   ms  down: { duration_seconds, previous_deity, previous_strength }
--   tpa up:   { glow, percent }                        (rich, has age ticker)
--   tpa down: { hits, duration_seconds }               (rich broken summary)
-- ---------------------------------------------------------------------

local function shield_set(key, status, detail)
  local sh = state.shields[key]
  if not sh then return end
  sh.state  = status
  sh.detail = detail or ""
  push_state()
end

-- TPA-specific tracking (declared up here so shield.cleared below can
-- reset them; the TPA handlers further down read & write them).
local tpa_glow         = ""
local tpa_percent      = nil
local tpa_down_summary = nil

-- Per-type "up" detail formatters. The returned string is appended after
-- the shield's full name in the chip tooltip:  "Bugshield — Large cloud
-- of butterflies".
local UP_DETAIL = {
  eff = function(d)
    return (d.item and d.item ~= "") and d.item or ""
  end,
  ccc = function(d)
    local sub = (d.substance and d.substance ~= "") and title_case(d.substance) or nil
    local str = d.strength and (tostring(d.strength) .. "/5") or nil
    if sub and str then return sub .. " · " .. str end
    return sub or str or ""
  end,
  bug = function(d)
    local size = (d.size and d.size ~= "") and title_case(d.size) or nil
    local bugs = (d.bugs and d.bugs ~= "") and d.bugs or nil
    if size and bugs then return size .. " cloud of " .. bugs end
    if size then return size .. " cloud" end
    if bugs then return "Cloud of " .. bugs end
    return ""
  end,
  ms = function(d)
    local deity = (d.deity and d.deity ~= "") and d.deity or nil
    local str   = (d.strength and d.strength ~= "") and d.strength or nil
    if deity and str then return deity .. " · " .. str end
    return deity or str or ""
  end,
}

-- TPA is rich enough to warrant its own dedicated handlers + age ticker
-- (see below). The generic dispatcher below skips it.
events.on("net.mallard.discworld.shield.up", function(d)
  if type(d) ~= "table" or d.subject ~= "self" then return end
  local t = d.type
  if not t or t == "tpa" then return end
  local fmt = UP_DETAIL[t]
  if not fmt or not state.shields[t] then return end
  shield_set(t, "up", fmt(d))
end)

events.on("net.mallard.discworld.shield.down", function(d)
  if type(d) ~= "table" or d.subject ~= "self" then return end
  local t = d.type
  if not t or t == "tpa" then return end
  if not state.shields[t] then return end
  shield_set(t, "down", "")
end)

-- GP zeroed by discworld-magic (trance emerge). Discworld doesn't push
-- a fresh Char.Vitals when contemplation ends, so the magic plugin
-- emits this event and we force gp.value to 0 in the mirror — mirrors
-- Quow's HandleContemplateEnd (QuowMinimap.xml:22990). maxgp is left
-- untouched; if we never saw an authoritative gp/maxgp yet, no-op.
events.on("net.mallard.discworld.gp.zero", function(d)
  if type(d) ~= "table" or d.subject ~= "self" then return end
  local _, m = gp.current()
  if not m then return end
  gp.set(0, m)
  push_gp_optimistic()
end)

-- `shield.cleared` for self fires when the wire confirms "no arcane
-- protection" (or on a future-proofing path: the start of a protections
-- dump for self). Reset every chip to "down" — subsequent shield.up
-- events repopulate whatever's actually active.
events.on("net.mallard.discworld.shield.cleared", function(d)
  if type(d) ~= "table" or d.subject ~= "self" then return end
  for k, _ in pairs(state.shields) do
    state.shields[k].state  = "down"
    state.shields[k].detail = ""
  end
  tpa_glow         = ""
  tpa_percent      = nil
  tpa_down_summary = nil
  push_state()
end)

-- TPA: rich detail. While up we show "<percent>% · <Glow>". On break we freeze
-- a "Broken · N hits · duration" summary. (Live age tracking was dropped: a
-- per-second age counter meant a 1 Hz timer reposting the whole snapshot for
-- the lifetime of the shield — pure churn on the shared plugin runtime for a
-- cosmetic readout. The break summary still reports total duration.)

local function tpa_format_up()
  local pct  = (tpa_percent ~= nil) and (tpa_percent .. "%") or "?%"
  local glow = (tpa_glow   ~= "")   and title_case(tpa_glow)  or "?"
  return pct .. " · " .. glow
end

events.on("net.mallard.discworld.shield.up", function(data)
  if type(data) ~= "table" or data.subject ~= "self" or data.type ~= "tpa" then return end
  tpa_glow    = data.glow    or ""
  tpa_percent = data.percent or nil
  shield_set("tpa", "up", tpa_format_up())
end)

events.on("net.mallard.discworld.shield.down", function(data)
  if type(data) ~= "table" or data.subject ~= "self" or data.type ~= "tpa" then return end
  local hits     = data.hits             or 0
  local duration = data.duration_seconds or nil
  if hits > 0 and duration then
    tpa_down_summary = string.format("Broken · %d %s · %s",
      hits, (hits == 1) and "hit" or "hits", format_duration(duration))
  elseif duration then
    tpa_down_summary = "Broken · " .. format_duration(duration)
  else
    tpa_down_summary = "Broken"
  end
  shield_set("tpa", "down", tpa_down_summary)
end)

-- ---------------------------------------------------------------------
-- Score-brief text trigger — FALLBACK PATH for users with MXP disabled.
-- Pattern ported verbatim from Quow's QuowMinimap.xml line 26682 with
-- the leading `(?:> )?` prompt prefix removed (Mallard convention).
-- ---------------------------------------------------------------------

mud.trigger(
  [==[^Hp: (?P<hp>[\d,]+) ?\((?P<maxhp>[\d,]+)\) +(?:Gp\: (?P<gp>[\d,]+) ?\((?P<maxgp>[\d,]+)\)) +(?:Xp\: (?P<xp>[\d,]+))(?:  Burden: (?P<burden>[\d,]+)\%)?$]==],
  function(m)
    -- Defensive: some host paths invoke the callback without a match table
    -- (observed as spammy `attempt to index a nil value (local 'm')` warnings).
    -- Bail rather than fault — there's nothing to apply without captures.
    if not m then return end
    local hp, maxhp = to_num(m.hp), to_num(m.maxhp)
    local gpv, maxgp = to_num(m.gp), to_num(m.maxgp)
    local burden, xp = to_num(m.burden), to_num(m.xp)
    if hp and maxhp then
      state.hp = { value = hp, max = maxhp }
    end
    if gpv and maxgp then
      gp.set(gpv, maxgp)
      local v, mx = gp.current()
      if v and mx then set_gp(v, mx) end
    end
    -- Quow's logic (QuowMinimap.xml:13783-13791): only update xp+burden
    -- when the burden capture is non-empty. Lines without a burden field
    -- are combat-monitor lines, not regular vitals — updating xp from
    -- them would poison the rolling-window tracker.
    if burden and xp then
      state.burden = burden
      state.xp     = format_thousands(xp)
      announce_xp_gain(xp)
    end
    push_state()
  end
)

-- ---------------------------------------------------------------------
-- Skills — parse `skills raw` into a flat path → (level, bonus) snapshot,
-- store per character, and broadcast `net.mallard.discworld.skills.updated`
-- so peer plugins (autocols, future build planners, etc.) can read skill
-- state without re-parsing the wire format. Late-binding consumers can fire
-- `net.mallard.discworld.skills.request` to get a replay of the cached
-- snapshot — the same convention discworld-magic uses for shield state.
--
-- Entry point: `/skills-refresh` slash alias. We intentionally don't parse
-- bare `skills raw` typed by the user — gating on the alias keeps the absorb
-- triggers cold until we know an authoritative output is en route.
--
-- Format details and the column-major walk live in src/skills_parser.lua.
-- ---------------------------------------------------------------------

-- How long to wait for the SKILLS header after arming before giving up. The
-- MUD can be laggy — especially when /goals refresh fires `skills raw` and
-- `score stats` back to back — so this is generous; it only matters when *no*
-- output arrives at all (a real line stops the watchdog).
local SKILLS_ARM_TIMEOUT_SECONDS = 20

-- Diff two skill snapshots into a sorted list of changes. Each entry is
-- { path, old_lvl, old_bonus, new_lvl, new_bonus }; nil values mean the
-- path was added (no old_*) or removed (no new_*).
local function diff_skills(prev, current)
  local changes = {}
  local seen = {}
  for path, lvl in pairs(current.level) do
    seen[path] = true
    local old_lvl = prev.level and prev.level[path]
    local old_bonus = prev.bonus and prev.bonus[path]
    if lvl ~= old_lvl or current.bonus[path] ~= old_bonus then
      changes[#changes + 1] = {
        path = path,
        old_lvl = old_lvl, old_bonus = old_bonus,
        new_lvl = lvl,     new_bonus = current.bonus[path],
      }
    end
  end
  if prev.level then
    for path, lvl in pairs(prev.level) do
      if not seen[path] then
        changes[#changes + 1] = {
          path = path,
          old_lvl = lvl, old_bonus = prev.bonus and prev.bonus[path],
          new_lvl = nil, new_bonus = nil,
        }
      end
    end
  end
  table.sort(changes, function(a, b) return a.path < b.path end)
  return changes
end

local function print_skills_diff(charname, changes)
  local function fmt(lvl, bonus)
    return string.format("%s/%s",
      lvl ~= nil and tostring(lvl) or "—",
      bonus ~= nil and tostring(bonus) or "—")
  end
  mud.note(string.format("skills-refresh: %d skill%s changed for %s:",
    #changes, #changes == 1 and "" or "s", charname))
  -- Two-pass: precompute formatted cells and per-column max widths so the
  -- path column left-pads and the level/bonus columns right-justify, e.g.
  --   crafts.smithing.gold              : 1113/815 → 1114/815
  --   adventuring.points                :   89/143 →   99/147
  -- Width is measured in bytes; UTF-8 chars in the values (only `—` for
  -- added/removed paths) under-pad by 2 bytes each, which is acceptable
  -- for a rare edge case and keeps the alignment math trivial.
  local rows = {}
  local w_path, w_old, w_new = 0, 0, 0
  for _, c in ipairs(changes) do
    local old = fmt(c.old_lvl, c.old_bonus)
    local new = fmt(c.new_lvl, c.new_bonus)
    rows[#rows + 1] = { path = c.path, old = old, new = new }
    if #c.path > w_path then w_path = #c.path end
    if #old    > w_old  then w_old  = #old    end
    if #new    > w_new  then w_new  = #new    end
  end
  local line_fmt = "  %-" .. w_path .. "s : %" .. w_old .. "s → %" .. w_new .. "s"
  for _, r in ipairs(rows) do
    mud.note(string.format(line_fmt, r.path, r.old, r.new))
  end
end

-- Forward-declared so on_state_change (below) can reach the on-demand
-- idle/arm watchdog; the watchdog itself is defined just after this make().
local ensure_skills_poll, stop_skills_poll
local skills_sm = skills_parser.make({
  -- The full Discworld tree is ~190 leaves. Set the floor well below that
  -- so we still accept legitimate parses if the tree shrinks slightly, but
  -- comfortably above any plausible interrupted or garbage capture.
  min_skills    = 100,
  on_log        = function(_level, msg) mud.note(msg) end,
  on_flush      = function(snapshot)
    -- char.info.name is guaranteed by login ordering — see plugin.toml
    -- header. If it's somehow missing we'd rather drop than write under a
    -- placeholder key that could collide across alts.
    local charname = gmcp.get("char.info.name")
    if not charname or charname == "" then
      mud.note("skills_parser: no char.info.name yet; dropping snapshot.")
      return
    end
    local prev = storage.get("skills/" .. charname)
    -- Stamp the fetch time so /goals can show how stale the data is. Extra
    -- field is inert to diff_skills (it walks .level/.bonus) and to consumers
    -- of the emitted event.
    snapshot.saved_at = now_seconds()
    storage.set("skills/" .. charname, snapshot)
    storage.set("skills/_last_active", charname)
    events.emit("net.mallard.discworld.skills.updated", {
      charname = charname,
      snapshot = snapshot,
    })
    local prefix = string.format("skills-refresh: finished refreshing %d skills for %s",
      snapshot.skill_count, charname)
    if not prev then
      mud.note(prefix .. " (first refresh)")
      return
    end
    local changes = diff_skills(prev, snapshot)
    if #changes == 0 then
      mud.note(prefix .. " (no skills changed since last refresh)")
      return
    end
    local count_label = string.format("%d skill%s",
      #changes, #changes == 1 and "" or "s")
    mud.note(
      prefix .. " (",
      mud.span(count_label, {
        underline = true,
        on_click  = function() print_skills_diff(charname, changes) end,
      }),
      " changed since last refresh)"
    )
  end,
  -- Start/stop the idle/arm watchdog so it only runs during an actual
  -- refresh (armed/collecting), not for the whole idle session.
  on_state_change = function(mode)
    if mode == "idle" then stop_skills_poll() else ensure_skills_poll() end
  end,
})

-- On-demand idle/arm watchdog. Runs ONLY while the SM is armed or
-- collecting: on_state_change (above) starts it on the idle→active
-- transition and stops it on the return to idle, so we don't burn a fixed
-- 4×/sec poll on the shared Lua VM through the long idle stretches. We
-- previously used `mud.delay` reschedule-on-each-absorb, which churned one
-- handle per absorbed line and was racy; this churns one handle per refresh
-- cycle and only ever removes a handle from arm context (see below).
local last_absorb_at = nil
-- Quiet gap after the last absorbed line that means "output finished, flush
-- now". Must comfortably exceed any mid-stream pause the MUD/network injects
-- into a long `skills raw` dump — a premature flush parses an incomplete
-- column grid (orphans) and then resets, losing the rest of the stream.
local SKILLS_IDLE_FLUSH_SECONDS = 3
local skills_poll = nil          -- last mud.every handle (may be disabled)
local skills_poll_active = false -- is it currently scheduled?
local function mark_absorbed() last_absorb_at = now_seconds() end

local function skills_tick()
  local now = now_seconds()
  skills_sm.try_arm_timeout(now, SKILLS_ARM_TIMEOUT_SECONDS)
  if last_absorb_at and (now - last_absorb_at) >= SKILLS_IDLE_FLUSH_SECONDS then
    last_absorb_at = nil
    skills_sm.try_flush(now)   -- may drive the SM → idle → stop_skills_poll
  end
end

-- `mud.every` handles can't be re-enabled once disabled (host API), so each
-- active window gets a fresh handle. We reclaim the prior (disabled)
-- handle's callback id here — only ever from arm/header context, never from
-- inside skills_tick — to avoid the self-remove "unknown callback id" race.
ensure_skills_poll = function()
  if skills_poll_active then return end
  if skills_poll then skills_poll:remove() end
  skills_poll = mud.every(500, skills_tick)
  skills_poll_active = true
end

-- Called (via on_state_change) from inside skills_tick on the flush/timeout
-- that returns the SM to idle. disable() stops the scheduler entry without
-- dropping the callback id — the part that is unsafe to do mid-fire.
stop_skills_poll = function()
  if not skills_poll_active then return end
  if skills_poll then skills_poll:disable() end
  skills_poll_active = false
end

-- Header trigger flips armed → collecting. The pattern is the documented
-- start-of-output marker that Discworld emits at the top of `skills raw`.
-- We gag the header only when /skills-refresh armed us — a user who types
-- `skills raw` directly still sees their output scroll normally.
mud.trigger(skills_parser.HEADER_PATTERN, function(m)
  if skills_sm.state() == "armed" then m:gag() end
  skills_sm.on_header(now_seconds())
  mark_absorbed()
end)

-- Absorber: any line containing at least one skill-shaped cell. Coarse on
-- purpose — the canonical parse happens in build_snapshot at flush time.
-- `on_line` returns true only when we're actively collecting (= we're the
-- ones who requested this output), so gating the gag on its return matches
-- the header-trigger policy: hide ours, leave manual `skills raw` alone.
-- `mud.trigger` fires once per regex match, so for a packed 27-cell line we
-- gag 27 times; the effect is idempotent.
mud.trigger(skills_parser.LINE_HAS_SKILL_CELL_PATTERN, function(m)
  if skills_sm.on_line(m.text) then
    m:gag()
    mark_absorbed()
  end
end)

-- Client command — the only sanctioned entry point.
mud.command("skills-refresh", function()
  skills_sm.arm(now_seconds())
  mud.note("skills-refresh: working...")
  mud.send("skills raw", { silent = true })
end, {
  description = "Re-fetch your skills from the MUD.",
  usage = "skills-refresh",
})

-- Late-binding read surface. A consumer plugin that loaded after the parse
-- can fire this event with an optional `charname`; we reply by re-emitting
-- `skills.updated` with the cached snapshot, marked `replay = true` so
-- consumers can distinguish on-demand replies from live updates.
events.on("net.mallard.discworld.skills.request", function(d)
  d = (type(d) == "table") and d or {}
  local charname = d.charname
                or gmcp.get("char.info.name")
                or storage.get("skills/_last_active")
  if not charname or charname == "" then return end
  local snapshot = storage.get("skills/" .. charname)
  if not snapshot then return end
  events.emit("net.mallard.discworld.skills.updated", {
    charname = charname,
    snapshot = snapshot,
    replay   = true,
  })
end)

-- ---------------------------------------------------------------------
-- Stats — parse `score stats` into the five core stats (constitution,
-- dexterity, intelligence, strength, wisdom), store per character, and
-- broadcast `net.mallard.discworld.stats.updated` so peer plugins can
-- read stat state without re-parsing the wire format. Same late-binding
-- replay convention as skills: fire `net.mallard.discworld.stats.request`
-- to get a replay of the cached snapshot.
--
-- Entry point: `/stats-refresh` slash alias. As with skills, we don't
-- parse bare `score stats` typed by the user — gating on the alias keeps
-- the absorb trigger cold until we know an authoritative output is en
-- route.
--
-- Format details and the cell splitter live in src/stats_parser.lua.
-- ---------------------------------------------------------------------

-- See the skills equivalents above. `score stats` is small and arrives in one
-- burst, but it can still be slow to *start* when the MUD is laggy or busy
-- answering a back-to-back `skills raw` — so wait generously for the first line.
local STATS_ARM_TIMEOUT_SECONDS = 20
local STATS_IDLE_FLUSH_SECONDS  = 3

-- Diff two stat snapshots into a sorted, human-readable changes string,
-- e.g. "strength 14 → 15, wisdom 11 → 12". Returns "" if nothing changed.
-- Unlike skills (where a refresh can light up dozens of leaves), stat
-- changes are rare and small enough to inline in the completion note,
-- so we skip the clickable-drilldown UX entirely.
local function diff_stats_inline(prev, current)
  local changes = {}
  local seen = {}
  for name, v in pairs(current.stats) do
    seen[name] = true
    local old = prev.stats and prev.stats[name]
    if v ~= old then
      changes[#changes + 1] = { name = name, old = old, new = v }
    end
  end
  if prev.stats then
    for name, v in pairs(prev.stats) do
      if not seen[name] then
        changes[#changes + 1] = { name = name, old = v, new = nil }
      end
    end
  end
  table.sort(changes, function(a, b) return a.name < b.name end)
  local function fmt(v) return v ~= nil and tostring(v) or "—" end
  local parts = {}
  for i, c in ipairs(changes) do
    parts[i] = string.format("%s %s → %s", c.name, fmt(c.old), fmt(c.new))
  end
  return table.concat(parts, ", ")
end

-- Forward-declared so on_state_change (below) can reach the on-demand
-- idle/arm watchdog; the watchdog itself is defined just after this make().
local ensure_stats_poll, stop_stats_poll
local stats_sm = stats_parser.make({
  -- Exactly five core stats in the snapshot; setting the floor at 5 means
  -- we drop interrupted/partial captures rather than persist an incomplete
  -- record over a previously-good one.
  min_stats = 5,
  on_log    = function(_level, msg) mud.note(msg) end,
  on_flush  = function(snapshot)
    local charname = gmcp.get("char.info.name")
    if not charname or charname == "" then
      mud.note("stats_parser: no char.info.name yet; dropping snapshot.")
      return
    end
    local prev = storage.get("stats/" .. charname)
    -- Stamp the fetch time (see skills on_flush) so /goals can show staleness.
    snapshot.saved_at = now_seconds()
    storage.set("stats/" .. charname, snapshot)
    storage.set("stats/_last_active", charname)
    events.emit("net.mallard.discworld.stats.updated", {
      charname = charname,
      snapshot = snapshot,
    })
    local prefix = string.format("stats-refresh: finished refreshing %d stats for %s",
      snapshot.stat_count, charname)
    if not prev then
      mud.note(prefix .. " (first refresh)")
      return
    end
    local changes = diff_stats_inline(prev, snapshot)
    if changes == "" then
      mud.note(prefix .. " (no stats changed since last refresh)")
    else
      mud.note(prefix .. " (" .. changes .. ")")
    end
  end,
  -- Start/stop the idle/arm watchdog so it only runs during an actual
  -- refresh (armed/collecting), not for the whole idle session.
  on_state_change = function(mode)
    if mode == "idle" then stop_stats_poll() else ensure_stats_poll() end
  end,
})

-- Parallel to the skills watchdog: on-demand, runs only while armed or
-- collecting. Independent of the skills poll so the state machines stay
-- decoupled and so removing either parser later is a single-section edit.
local last_stats_absorb_at = nil
local stats_poll = nil          -- last mud.every handle (may be disabled)
local stats_poll_active = false -- is it currently scheduled?
local function mark_stats_absorbed() last_stats_absorb_at = now_seconds() end

local function stats_tick()
  local now = now_seconds()
  stats_sm.try_arm_timeout(now, STATS_ARM_TIMEOUT_SECONDS)
  if last_stats_absorb_at and (now - last_stats_absorb_at) >= STATS_IDLE_FLUSH_SECONDS then
    last_stats_absorb_at = nil
    stats_sm.try_flush(now)   -- may drive the SM → idle → stop_stats_poll
  end
end

-- See ensure_skills_poll for why each window gets a fresh handle and why we
-- only remove() from arm/header context, never from inside stats_tick.
ensure_stats_poll = function()
  if stats_poll_active then return end
  if stats_poll then stats_poll:remove() end
  stats_poll = mud.every(500, stats_tick)
  stats_poll_active = true
end

stop_stats_poll = function()
  if not stats_poll_active then return end
  if stats_poll then stats_poll:disable() end
  stats_poll_active = false
end

-- Absorber: any line containing at least one stat-shaped cell. `on_line`
-- returns true only when we're actively collecting (= /stats-refresh
-- armed us), so the gag policy matches skills: hide ours, leave manual
-- `score stats` alone. `mud.trigger` fires once per regex match, so a
-- packed cols-999 line gets gagged once per cell; the effect is idempotent.
mud.trigger(stats_parser.LINE_HAS_STAT_CELL_PATTERN, function(m)
  if stats_sm.on_line(m.text) then
    m:gag()
    mark_stats_absorbed()
  end
end)

-- Client command — the only sanctioned entry point.
mud.command("stats-refresh", function()
  stats_sm.arm(now_seconds())
  mud.note("stats-refresh: working...")
  mud.send("score stats", { silent = true })
end, {
  description = "Re-fetch your stats from the MUD.",
  usage = "stats-refresh",
})

-- Late-binding read surface — same convention as skills.request.
events.on("net.mallard.discworld.stats.request", function(d)
  d = (type(d) == "table") and d or {}
  local charname = d.charname
                or gmcp.get("char.info.name")
                or storage.get("stats/_last_active")
  if not charname or charname == "" then return end
  local snapshot = storage.get("stats/" .. charname)
  if not snapshot then return end
  events.emit("net.mallard.discworld.stats.updated", {
    charname = charname,
    snapshot = snapshot,
    replay   = true,
  })
end)

-- ---------------------------------------------------------------------
-- Skill goal planning — /goal manages per-character goals (a target level
-- or bonus per skill) and /goals shows the cheapest XP path to each with a
-- self-teach comparison. All the math lives in src/{bonus,cost,forecast,
-- planner}.lua; this section is just storage, command parsing, and note
-- formatting. Goals persist under `goals/<charname>` and recompute live off
-- the same `skills.updated` event the parser emits.
-- ---------------------------------------------------------------------

-- Compact XP magnitudes for the summary line: 17.2M, 210M, 1.3B, 845k.
local function format_xp_short(n)
  if type(n) ~= "number" then return tostring(n) end
  local function trim(x) return (string.format("%.1f", x):gsub("%.0$", "")) end
  local abs = math.abs(n)
  if abs >= 1e9 then return trim(n / 1e9) .. "B" end
  if abs >= 1e6 then return trim(n / 1e6) .. "M" end
  if abs >= 1e3 then return trim(n / 1e3) .. "k" end
  return format_thousands(n)
end

local function goals_storage_key(charname) return "goals/" .. charname end

local function load_goals(charname)
  local rec = storage.get(goals_storage_key(charname))
  if type(rec) == "table" and type(rec.goals) == "table" then return rec.goals end
  return {}
end

local function save_goals(charname, list)
  storage.set(goals_storage_key(charname), { goals = list })
end

-- Current observed (level, bonus) for a skill from the cached skills snapshot.
-- Returns nil,nil when no snapshot exists yet, so a goal added before the first
-- refresh is left baseline-less for backfill rather than baselined at a bogus 0.
local function current_skill_state(charname, path)
  local snap = storage.get("skills/" .. charname)
  if type(snap) ~= "table" or type(snap.level) ~= "table" then return nil, nil end
  return snap.level[path] or 0, (snap.bonus and snap.bonus[path]) or 0
end

-- Fill in any goal baselines not captured at creation time — goals predating
-- this feature, or added before a skills snapshot existed. The current snapshot
-- becomes the baseline (progress then tracks from now forward); start_at is
-- preserved if already stamped, else set to now. Persists only on change and
-- returns the (possibly updated) goals list.
local function backfill_goal_baselines(charname)
  local snap = storage.get("skills/" .. charname)
  local list = load_goals(charname)
  if type(snap) ~= "table" or type(snap.level) ~= "table" then return list end
  local changed = false
  for _, g in ipairs(list) do
    if type(g.start_level) ~= "number" then
      g.start_level = snap.level[g.skill] or 0
      g.start_bonus = (snap.bonus and snap.bonus[g.skill]) or 0
      g.start_at    = g.start_at or now_seconds()
      changed = true
    end
  end
  if changed then save_goals(charname, list) end
  return list
end

-- The active character for goal commands. char.info.name is authoritative;
-- _last_active (set by the skills/stats flush) covers a mid-session reload
-- before char.info has re-arrived.
local function goal_charname()
  local n = gmcp.get("char.info.name")
  if type(n) == "string" and n ~= "" then return n end
  return storage.get("skills/_last_active")
end

-- Union of every skill in the stat table and every skill the character
-- actually has — so goals can target not-yet-trained skills too.
local function known_skill_paths(charname)
  local set = {}
  for path in pairs(skill_data.STAT_CODES) do set[path] = true end
  local snap = charname and storage.get("skills/" .. charname)
  if type(snap) == "table" and type(snap.level) == "table" then
    for path in pairs(snap.level) do set[path] = true end
  end
  local paths = {}
  for path in pairs(set) do paths[#paths + 1] = path end
  return paths
end

local function char_stats(charname)
  local s = storage.get("stats/" .. charname)
  return (type(s) == "table") and s.stats or nil
end

-- Assemble the inputs planner.plan needs from stored per-character state.
local function plan_inputs(charname)
  local skills = storage.get("skills/" .. charname)
  return {
    skills     = (type(skills) == "table") and skills or {},
    stats      = char_stats(charname),
    goals      = load_goals(charname),
    current_xp = last_xp,
  }
end

-- Palette for /goal + /goals output. Named ANSI colours (indices 0–15) so the
-- active theme — light or dark — resolves them to legible values; body text is
-- left unstyled to inherit the theme foreground, and emphasis leans on bold
-- rather than a white/black fg that could wash out on one theme or the other.
local GP = {
  label   = { bold = true },                      -- headers / "goals:" label
  char    = { fg = "cyan", bold = true },         -- character name
  skill   = { fg = "cyan" },                      -- skill paths / abbreviations
  target  = { bold = true },                      -- the goal value (theme-neutral)
  optimal = { fg = "light green", bold = true },  -- cheapest / headline cost
  selfc   = { fg = "yellow" },                    -- self-teach (the dear path)
  done    = { fg = "light green", bold = true },  -- met goals
  added   = { fg = "light green" },               -- added confirmation
  warn    = { fg = "yellow" },                    -- updated / soft warnings
  err     = { fg = "light red" },                 -- errors
  details = { fg = "cyan", underline = true },    -- clickable drill-down
  afford  = { fg = "light green" },               -- afford-now deltas
  cmd     = { fg = "light cyan", bold = true },   -- command literals in help
}

local function sp(text, style) return mud.span(text, style) end

-- Active command prefix (the user's `command_prefix` setting, default "/").
-- Read fresh per call so help/hint text reflects a live remap; every command
-- literal we print to the user goes through this rather than a hardcoded "/".
local function pfx() return mud.command_prefix() end

-- Display width of a UTF-8 string (counts non-continuation bytes), so a
-- divider sized to a row isn't thrown off by multi-byte glyphs like → / ✓.
-- Every glyph we emit is single-column, so a codepoint count is exact here.
local function disp_width(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

-- Resolve a user-typed skill query, printing a helpful message and returning
-- nil if it can't be pinned to exactly one skill. `label` prefixes the
-- diagnostics (e.g. "goal" / "skill") so each command speaks in its own voice.
local function resolve_skill_arg(charname, query, label)
  label = label or "goal"
  local path, candidates = planner.resolve_skill(query, known_skill_paths(charname))
  if path then return path end
  if #candidates == 0 then
    mud.note(sp(label .. ": no skill matches '" .. query .. "'.", GP.err))
  else
    mud.note(sp(label .. ": '" .. query .. "' is ambiguous — did you mean:", GP.err))
    for _, c in ipairs(candidates) do mud.note(sp("  " .. c, GP.skill)) end
  end
  return nil
end

-- Add or update a goal for an already-resolved skill path. Shared by /goal add
-- and the /skill "add goal" links, so both restart the progress baseline from
-- the current skill reading on re-add (the target — and thus what "progress"
-- means — has changed) and print the same confirmation note. A nil baseline
-- (no snapshot yet) is backfilled later.
local function upsert_goal(charname, path, kind, value)
  local cur_level, cur_bonus = current_skill_state(charname, path)
  local list = load_goals(charname)
  local replaced = false
  for _, g in ipairs(list) do
    if g.skill == path then
      g.type, g.value, g.announced = kind, value, nil
      g.start_level, g.start_bonus, g.start_at = cur_level, cur_bonus, now_seconds()
      replaced = true
      break
    end
  end
  if not replaced then
    list[#list + 1] = { skill = path, type = kind, value = value,
      start_level = cur_level, start_bonus = cur_bonus, start_at = now_seconds() }
  end
  save_goals(charname, list)
  mud.note(
    sp("goal " .. (replaced and "updated" or "added") .. ": ",
       replaced and GP.warn or GP.added),
    sp(path, GP.skill),
    sp("  " .. kind .. " "),
    sp(tostring(value), GP.target))
  return replaced
end

local function goal_add(charname, rest)
  local skill_q, kind, value_s = rest:match("^(%S+)%s+(%S+)%s+(%S+)$")
  if not skill_q then
    mud.note(sp("goal: usage — /goal add <skill> <level|bonus> <value>", GP.err))
    return
  end
  kind = kind:lower()
  if kind ~= "level" and kind ~= "bonus" then
    mud.note(sp("goal: type must be 'level' or 'bonus' (got '" .. kind .. "').", GP.err))
    return
  end
  local value = to_num(value_s)
  if not value or value <= 0 then
    mud.note(sp("goal: value must be a positive number (got '" .. value_s .. "').", GP.err))
    return
  end
  value = math.floor(value)
  local path = resolve_skill_arg(charname, skill_q, "goal")
  if not path then return end
  upsert_goal(charname, path, kind, value)
end

local function goal_rm(charname, rest)
  local skill_q = rest:match("^(%S+)")
  if not skill_q then mud.note(sp("goal: usage — /goal rm <skill>", GP.err)) return end
  local path = resolve_skill_arg(charname, skill_q, "goal")
  if not path then return end
  local list = load_goals(charname)
  local kept, found = {}, false
  for _, g in ipairs(list) do
    if g.skill == path then found = true else kept[#kept + 1] = g end
  end
  if not found then mud.note(sp("goal: no goal set for " .. path .. ".", GP.err)) return end
  save_goals(charname, kept)
  mud.note(sp("goal removed: ", GP.warn), sp(path, GP.skill))
end

local function goal_help()
  local p = pfx()
  local function line(cmd, desc)
    mud.note(sp(string.format("  %-40s", cmd), GP.cmd), sp(desc))
  end
  mud.note(sp("goal — manage skill goals (a target level or bonus per skill):", GP.label))
  line(p .. "goal add <skill> <level|bonus> <value>",  "add or update a goal")
  line(p .. "goal rm <skill>",                         "remove a goal")
  line(p .. "goal clear",                              "remove all goals")
  line(p .. "goal list   (or " .. p .. "goals)",       "show progress + XP cost")
  line(p .. "goals refresh",                           "re-fetch skills + stats from the MUD")
  line(p .. "goal help",                               "show this help")
  mud.note(sp("  skills accept abbreviations: "), sp("ma.sp.of", GP.skill),
    sp(" → "), sp("magic.spells.offensive", GP.skill))
  mud.note(sp("  examples:  "), sp(p .. "goal add fi.me.sw bonus 550", GP.cmd),
    sp("   ·   "), sp(p .. "goal add ma.sp.of level 200", GP.cmd))
end

-- A two-tone [████░░░░] bar at the given fraction: returns the filled and
-- empty runs separately so each can be coloured (green progress on a muted
-- track). `width` is the cell count; the fill rounds to the nearest cell.
local function progress_bar(pct, width)
  if type(pct) ~= "number" then pct = 0 end
  local filled = math.floor(pct * width + 0.5)
  if filled < 0 then filled = 0 elseif filled > width then filled = width end
  return string.rep("█", filled), string.rep("░", width - filled)
end

-- An absolute YYYY-MM-DD for a baseline timestamp (os.date is available in the
-- host runtime, same as os.time); "unknown" if the goal predates stamping.
local function format_date(ts)
  if type(ts) ~= "number" then return "unknown" end
  return os.date("%Y-%m-%d", ts)
end

-- Per-goal drill-down, fired by the clickable `show details` span. Leads with a
-- progress block charting started → now → target from the recorded baseline
-- (level/bonus deltas, a percent bar by XP and by levels, XP invested so far),
-- then the per-scenario remaining cost (green = optimal, yellow = self) so a
-- future "specific teacher" row drops in between without reshaping. Legacy
-- goals with no baseline fall back to a single current → target header line.
local function print_goal_detail(row)
  local prog = row.progress
  if prog then
    local muted   = { fg = "light black" }
    local target_level = row.target_level or row.from_level
    local target_bonus = row.target_bonus or row.from_bonus
    -- Right-align the bonus/level numerals across the three rows so the columns
    -- read cleanly regardless of digit count.
    local nums = { prog.start_bonus, row.from_bonus, target_bonus,
                   prog.start_level, row.from_level, target_level }
    local wb, wl = 0, 0
    for i = 1, 3 do wb = math.max(wb, #tostring(nums[i])) end
    for i = 4, 6 do wl = math.max(wl, #tostring(nums[i])) end
    -- Lead with the metric the goal actually targets — a level goal reads
    -- "level 700  (bonus 548)", a bonus goal "bonus 646  (level 922)" — with
    -- the other metric tucked in parens. The primary value is emphasised; the
    -- parenthetical stays muted.
    local is_level = row.goal_type == "level"
    local function point_row(label, bonus_v, level_v, extra_spans)
      local prim_word, prim_v, prim_w, sec_word, sec_v, sec_w
      if is_level then
        prim_word, prim_v, prim_w = "level", level_v, wl
        sec_word,  sec_v,  sec_w  = "bonus", bonus_v, wb
      else
        prim_word, prim_v, prim_w = "bonus", bonus_v, wb
        sec_word,  sec_v,  sec_w  = "level", level_v, wl
      end
      local out = {
        sp(string.format("  %-9s", label), muted),
        sp(prim_word .. " "),
        sp(string.format("%" .. prim_w .. "d", prim_v), GP.target),
        sp(string.format("  (%s %" .. sec_w .. "d)", sec_word, sec_v), muted),
      }
      for _, s in ipairs(extra_spans or {}) do out[#out + 1] = s end
      return out
    end

    -- Order the "now" deltas to match the row's lead metric: a level goal
    -- reads "+10 levels · +5 bonus", a bonus goal "+5 bonus · +10 levels".
    local bonus_delta = string.format("+%d bonus", prog.bonus_gained or 0)
    local level_delta = string.format("+%d levels", prog.levels_gained or 0)
    local now_deltas = is_level
      and (level_delta .. " · " .. bonus_delta)
      or  (bonus_delta .. " · " .. level_delta)

    mud.note(sp(row.skill, { fg = "cyan", bold = true }))
    mud.note(table.unpack(point_row("started", prog.start_bonus, prog.start_level,
      { sp("   " .. format_date(prog.start_at), muted) })))
    mud.note(table.unpack(point_row("now", row.from_bonus, row.from_level, {
      sp("   " .. now_deltas, GP.afford),
    })))
    mud.note(table.unpack(point_row("target", target_bonus, target_level)))

    -- Percent bar — by XP if priceable (the meaningful, nonlinear measure),
    -- else level fraction alone. Both percentages annotate the bar.
    local bar_pct = prog.pct_xp or prog.pct_levels
    local filled, empty = progress_bar(bar_pct, 18)
    local pct_text = prog.pct_xp
      and string.format("%d%% by xp · %d%% by levels",
        math.floor(prog.pct_xp * 100 + 0.5), math.floor(prog.pct_levels * 100 + 0.5))
      or string.format("%d%% by levels", math.floor(prog.pct_levels * 100 + 0.5))
    -- mud.span rejects empty text, so only emit the runs that are non-empty
    -- (the bar is all-empty at 0% and all-filled at 100%).
    local bar = { sp("  progress  [") }
    if filled ~= "" then bar[#bar + 1] = sp(filled, GP.afford) end
    if empty  ~= "" then bar[#bar + 1] = sp(empty, muted) end
    bar[#bar + 1] = sp("]  ")
    bar[#bar + 1] = sp(pct_text, GP.label)
    mud.note(table.unpack(bar))

    if prog.invested_xp then
      mud.note(
        sp("  invested  ", muted),
        sp("~" .. format_xp_short(prog.invested_xp) .. " xp", GP.afford),
        sp(" of ~" .. format_xp_short(prog.total_xp) .. " xp", muted))
    end
  else
    local levels = (row.target_level and row.from_level)
      and (row.target_level - row.from_level) or nil
    mud.note(
      sp(row.skill, { fg = "cyan", bold = true }),
      sp(": bonus " .. row.from_bonus .. " → "),
      sp(tostring(row.target_bonus or row.from_bonus), GP.target),
      sp(string.format("  (level %d → %d%s)",
        row.from_level, row.target_level or row.from_level,
        levels and string.format(", +%d levels", levels) or "")))
  end
  for _, sc in ipairs(row.scenarios or {}) do
    local color = (sc.key == "optimal") and "light green"
      or (sc.key == "self") and "yellow" or nil
    local cost_str = sc.reachable and (format_thousands(sc.total_xp) .. " xp") or "n/a"
    mud.note(
      sp(string.format("  %-15s : ", sc.label), color and { fg = color } or nil),
      sp(cost_str, color and { fg = color, bold = true } or nil))
  end
  if row.afford then
    mud.note(
      sp(string.format("  %-15s : ", "afford now"), GP.label),
      sp(string.format("+%d levels (+%d bonus)",
        row.afford.level - row.from_level, row.afford.bonus - row.from_bonus), GP.afford),
      sp(string.format(" for %s xp", format_thousands(row.afford.spent))))
  end
end

-- Combined skills+stats refetch — the one documented "freshen my data" action,
-- surfaced as `/goal refresh` and `/goals refresh` so the planner has a single
-- entry point and users never have to remember the two underlying *-refresh
-- aliases. Arms both parsers and fires both queries; each parser prints its own
-- completion note (and the live skills.updated handler re-announces newly met
-- goals), so nothing extra is echoed here beyond the kickoff line. Defined
-- above show_goals so the clickable freshness-line span can close over it.
local function refresh_progress()
  local now = now_seconds()
  skills_sm.arm(now)
  stats_sm.arm(now)
  mud.note(sp("goals: refreshing skills + stats...", GP.label))
  mud.send("skills raw",  { silent = true })
  mud.send("score stats", { silent = true })
end

-- Freshness footer shared by /goals and /skill: how long ago skills/stats were
-- last pulled off the wire, plus the one-stop command to update them (a
-- clickable span that runs refresh_progress directly, so no typing). Ages read
-- the saved_at stamp the parsers write at flush; "never" (no snapshot) is
-- highlighted, and a pre-stamp snapshot shows "time unknown". `refresh_cmd` is
-- the command literal to display (e.g. "goals refresh" / "skill refresh") — the
-- click bypasses parsing, so it's purely for show.
local function print_freshness_line(charname, refresh_cmd)
  local function age_label(snap)
    if type(snap) ~= "table" then return "never", true end
    if type(snap.saved_at) ~= "number" then return "time unknown", false end
    return format_duration(now_seconds() - snap.saved_at) .. " ago", false
  end
  local sk_age, sk_never = age_label(storage.get("skills/" .. charname))
  local st_age, st_never = age_label(storage.get("stats/" .. charname))
  local muted = { fg = "light black" }
  mud.note(
    sp("  skills ", muted), sp(sk_age, sk_never and GP.warn or muted),
    sp("  ·  stats ", muted), sp(st_age, st_never and GP.warn or muted),
    sp("  ·  ", muted),
    sp(pfx() .. refresh_cmd, {
      fg = "light cyan", bold = true, underline = true,
      on_click = function() refresh_progress() end,
    }),
    sp(" to update", muted))
end

local function show_goals(charname)
  backfill_goal_baselines(charname)
  local inputs = plan_inputs(charname)
  if #inputs.goals == 0 then
    mud.note(sp("goals: none set. Add one with ", GP.warn),
      sp(pfx() .. "goal add <skill> <level|bonus> <value>", GP.cmd))
    return
  end
  if type(storage.get("skills/" .. charname)) ~= "table" then
    mud.note(sp("goals: no skills snapshot yet — run ", GP.warn),
      sp(pfx() .. "goals refresh", GP.cmd),
      sp(" for accurate costs (showing from level 0 until then).", GP.warn))
  end

  local result = planner.plan(inputs)

  -- Precompute display cells + per-column widths so every column lines up
  -- regardless of how many digits the levels/bonuses/costs run to. Columns:
  -- skill (left), metric word, right-aligned from / to, and right-aligned
  -- optimal / self cost cells.
  local rows = {}
  local w_skill, w_metric, w_from, w_to, w_opt, w_self = 0, 0, 0, 0, 0, 0
  for _, row in ipairs(result.goals) do
    local cell = { row = row, skill = row.skill }
    if row.error == "no_mult" then
      cell.note = "(needs stats — run /goals refresh)"
    elseif row.error then
      cell.note = "(error: " .. row.error .. ")"
    elseif row.done then
      cell.done = true
      cell.done_text = string.format("bonus %d", row.from_bonus)
    else
      local is_level = row.goal_type == "level"
      cell.metric = is_level and "level" or "bonus"
      cell.from   = tostring(is_level and row.from_level or row.from_bonus)
      cell.to     = tostring(is_level and row.target_level or row.target_bonus)
      cell.opt    = "~" .. format_xp_short(row.cheapest_xp) .. " xp"
      cell.slf    = "~" .. format_xp_short(row.self_xp) .. " xp"
      w_metric = math.max(w_metric, #cell.metric)
      w_from   = math.max(w_from, #cell.from)
      w_to     = math.max(w_to, #cell.to)
      w_opt    = math.max(w_opt, #cell.opt)
      w_self   = math.max(w_self, #cell.slf)
    end
    w_skill = math.max(w_skill, #cell.skill)
    rows[#rows + 1] = cell
  end

  mud.note(
    sp("goals: ", GP.label),
    sp(charname, GP.char),
    sp(string.format(" — %d goal%s · ", #result.goals, #result.goals == 1 and "" or "s")),
    sp(format_xp_short(result.total_optimal) .. " xp", GP.optimal),
    sp(" (optimal) / "),
    sp(format_xp_short(result.total_self) .. " xp", GP.selfc),
    sp(" (self)"))

  -- Freshness line (clickable refresh) — shared with /skill.
  print_freshness_line(charname, "goals refresh")

  -- Build + emit each row, tracking the widest rendered line so the
  -- afford-now divider below can match the table width.
  local w_line = 0
  local function rpad(s, w) return string.rep(" ", w - #s) end
  for _, cell in ipairs(rows) do
    local skill_pad = string.format("  %-" .. w_skill .. "s  ", cell.skill)
    local out, plain = { sp(skill_pad, GP.skill) }, skill_pad
    -- mud.span rejects empty text, so skip zero-width padding / empty cells.
    local function add(text, style)
      if text == "" then return end
      out[#out + 1] = sp(text, style)
      plain = plain .. text
    end
    if cell.metric then
      add(string.format("%-" .. w_metric .. "s ", cell.metric))
      add(rpad(cell.from, w_from)); add(cell.from)
      add(" → ")
      add(rpad(cell.to, w_to)); add(cell.to, GP.target)
      add("  ")
      add(rpad(cell.opt, w_opt)); add(cell.opt, GP.optimal)
      add("  (self ")
      add(rpad(cell.slf, w_self)); add(cell.slf, GP.selfc); add(")")
      add("  ")
      add("show details", {
        fg = "cyan", underline = true,
        on_click = function() print_goal_detail(cell.row) end,
      })
    elseif cell.done then
      add(cell.done_text .. "  ")
      add("done ✓", GP.done)
    else
      add(cell.note or "", GP.warn)
    end
    w_line = math.max(w_line, disp_width(plain))
    mud.note(table.unpack(out))
  end

  -- Afford-now footer: how far your current XP takes each goal on its own,
  -- set off from the rows by a divider sized to the table.
  if inputs.current_xp then
    local parts = {}
    for _, row in ipairs(result.goals) do
      if row.afford and not row.done and not row.error then
        parts[#parts + 1] = {
          abbr  = skill_data.abbreviate(row.skill),
          delta = string.format("+%d lvl (+%d bonus)",
            row.afford.level - row.from_level, row.afford.bonus - row.from_bonus),
        }
      end
    end
    if #parts > 0 then
      mud.note(sp("  " .. string.rep("─", math.max(w_line - 2, 1)),
        { fg = "light black" }))
      local out = {
        sp("  afford now ", GP.label),
        sp(string.format("(%s xp, each): ", format_xp_short(inputs.current_xp))),
      }
      for i, p in ipairs(parts) do
        if i > 1 then out[#out + 1] = sp(" · ") end
        out[#out + 1] = sp(p.abbr, GP.skill)
        out[#out + 1] = sp(" " .. p.delta, GP.afford)
      end
      mud.note(table.unpack(out))
    end
  end
end

mud.command("goal", function(m)
  local charname = goal_charname()
  if not charname or charname == "" then
    mud.note(sp("goal: no character yet — log in first.", GP.err))
    return
  end
  local args = (m and m.args) or ""
  local verb, rest = args:match("^(%S*)%s*(.*)$")
  verb = (verb or ""):lower()
  if verb == "add" then goal_add(charname, rest)
  elseif verb == "refresh" then refresh_progress()
  elseif verb == "rm" or verb == "remove" or verb == "del" then goal_rm(charname, rest)
  elseif verb == "clear" then
    save_goals(charname, {})
    mud.note(sp("goals: cleared.", GP.warn))
  elseif verb == "help" or verb == "?" then goal_help()
  elseif verb == "" or verb == "list" then show_goals(charname)
  else
    mud.note(sp("goal: unknown subcommand '" .. verb .. "'. Try ", GP.err),
      sp(pfx() .. "goal help", GP.cmd))
  end
end, {
  description = "Manage skill goals (a target level or bonus per skill).",
  usage = "goal add <skill> <level|bonus> <value> | goal rm <skill> | " ..
    "goal clear | goal list | goal refresh",
})

mud.command("goals", function(m)
  local arg = ((m and m.args) or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if arg == "help" or arg == "?" then goal_help() return end
  local charname = goal_charname()
  if not charname or charname == "" then
    mud.note(sp("goals: no character yet — log in first.", GP.err))
    return
  end
  if arg == "refresh" then refresh_progress() return end
  show_goals(charname)
end, {
  description = "Show cheapest XP cost and progress toward your skill goals.",
  usage = "goals | goals refresh",
})

-- Panel right-click context menu (mallard-native, app >= 0.11.0). The menu
-- itself is declared UI-side in ui/vitals.js; its "Show goals" item posts
-- here so we run the exact same path as the `/goals` command's default
-- branch. Registered down here (not next to push_state) because the closure
-- needs goal_charname / show_goals, both defined earlier in the file.
panel:on_message("show_goals", function()
  local charname = goal_charname()
  if not charname or charname == "" then
    mud.note(sp("goals: no character yet — log in first.", GP.err))
    return
  end
  show_goals(charname)
end)

-- ---------------------------------------------------------------------
-- /skill — inspect a single skill: its current level/bonus, the stat
-- contributions feeding its multiplicator, and (with an optional number) a
-- dual reading of that number as a target bonus AND a target level — so the
-- user never has to say which they meant. Each not-yet-reached reading offers a
-- one-click "add goal". `/skill refresh` reuses the shared skills+stats fetch.
-- ---------------------------------------------------------------------

local function skill_help()
  local p = pfx()
  local function line(cmd, desc)
    mud.note(sp(string.format("  %-34s", cmd), GP.cmd), sp(desc))
  end
  mud.note(sp("skill — inspect one skill's level, bonus, and stat contributions:", GP.label))
  line(p .. "skill <skill>",          "show level, bonus, and stat contributions")
  line(p .. "skill <skill> <number>", "also read the number as a target bonus AND level")
  line(p .. "skill refresh",          "re-fetch skills + stats from the MUD")
  line(p .. "skill help",             "show this help")
  mud.note(sp("  skills accept abbreviations: "), sp("ma.sp.of", GP.skill),
    sp(" → "), sp("magic.spells.offensive", GP.skill))
  mud.note(sp("  examples:  "), sp(p .. "skill fi.me.sw", GP.cmd),
    sp("   ·   "), sp(p .. "skill ma.sp.of 550", GP.cmd))
end

local function show_skill(charname, query, target)
  local path = resolve_skill_arg(charname, query, "skill")
  if not path then return end

  local snap     = storage.get("skills/" .. charname)
  local has_snap = type(snap) == "table" and type(snap.level) == "table"
  local level    = (has_snap and snap.level[path]) or 0
  local bonus_v  = (has_snap and snap.bonus) and snap.bonus[path] or nil
  local stats    = char_stats(charname)

  local info = skill_query.describe({
    path = path, level = level, bonus = bonus_v, stats = stats, target = target })

  local muted = { fg = "light black" }

  -- Header: the same "name: " lead-in the rest of the family uses ("goals:",
  -- "goal added:") — bold label, cyan-bold skill path, then its abbreviation in
  -- the skill cyan so it reads as a lighter echo of the path.
  mud.note(
    sp("skill: ", GP.label),
    sp(path, { fg = "cyan", bold = true }),
    sp("  ·  " .. skill_data.abbreviate(path), GP.skill))

  -- Current level / bonus, joined by the family's muted "·" separator. (The
  -- multiplicator M still drives the target readings below, but it's an
  -- internal detail we don't surface.)
  local cur = { sp("  level ", muted), sp(tostring(info.level), GP.target) }
  if info.bonus ~= nil then
    cur[#cur + 1] = sp("  ·  bonus ", muted)
    cur[#cur + 1] = sp(tostring(info.bonus), GP.target)
  end
  mud.note(table.unpack(cur))

  -- Stat contributions: which stats feed M, their slot weight, current value.
  if info.contributions and #info.contributions > 0 then
    local out = { sp("  stats  ", muted) }
    for i, c in ipairs(info.contributions) do
      if i > 1 then out[#out + 1] = sp(" · ", muted) end
      out[#out + 1] = sp(c.stat, GP.skill)
      if c.count > 1 then out[#out + 1] = sp(" ×" .. c.count, muted) end
      if c.value then out[#out + 1] = sp(" (" .. c.value .. ")", GP.target) end
    end
    mud.note(table.unpack(out))
  end

  -- Target readings — the same number read both ways, each with a one-click
  -- "add goal" when it isn't already satisfied.
  local t = info.target
  if t then
    if t.no_mult then
      mud.note(sp("  need your stats to project a target — ", GP.warn),
        sp(pfx() .. "skill refresh", GP.cmd))
    else
      -- The same number read both ways, vertically aligned: the corresponding
      -- value (level↔bonus) right-justified into a shared column, then the
      -- signed delta-from-now right-justified inside the parens with its unit
      -- left-justified — so the two lines stack cleanly. The corresponding value
      -- is always shown (even for a target below where you stand, hence the
      -- signed delta); a clickable add-goal is appended only when the current
      -- skill doesn't already satisfy the target.
      local ab, al = t.as_bonus, t.as_level
      local function delta_str(n)
        return string.format("%s%d", n >= 0 and "+" or "-", math.abs(n))
      end
      local w_num   = math.max(#tostring(ab.level_needed), #tostring(al.bonus_reached))
      local w_delta = math.max(#delta_str(ab.extra_levels), #delta_str(al.extra_bonus))
      local w_unit  = math.max(#"levels", #"bonus")

      local function corresponds(kind_word, opp_word, num, delta_n, unit, goal_kind, already)
        local numstr = tostring(num)
        local paren  = string.format("(%" .. w_delta .. "s %-" .. w_unit .. "s)",
          delta_str(delta_n), unit)
        local out = {
          sp(string.format("  %-5s %d corresponds to : ", kind_word, t.value), muted),
          sp(opp_word .. " " .. string.rep(" ", w_num - #numstr), muted),
          sp(numstr, GP.target),
          sp(" "),
          -- A forward climb (+) is the family's green "afford" idiom; a target
          -- you've already passed (−) stays muted.
          sp(paren, delta_n > 0 and GP.afford or muted),
        }
        if not already then
          out[#out + 1] = sp("   ")
          out[#out + 1] = sp("add goal", {
            fg = "cyan", underline = true,
            on_click = function() upsert_goal(charname, path, goal_kind, t.value) end,
          })
        end
        mud.note(table.unpack(out))
      end

      corresponds("bonus", "level", ab.level_needed,  ab.extra_levels, "levels", "bonus", ab.already)
      corresponds("level", "bonus", al.bonus_reached, al.extra_bonus,  "bonus",  "level", al.already)
    end
  end

  print_freshness_line(charname, "skill refresh")
end

mud.command("skill", function(m)
  local args = ((m and m.args) or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local low = args:lower()
  if args == "" or low == "help" or low == "?" then skill_help() return end
  if low == "refresh" then refresh_progress() return end
  local charname = goal_charname()
  if not charname or charname == "" then
    mud.note(sp("skill: no character yet — log in first.", GP.err))
    return
  end
  local query, target_s = args:match("^(%S+)%s+(%S+)")
  if not query then query = args end
  local target
  if target_s then
    target = to_num(target_s)
    if not target or target <= 0 then
      mud.note(sp("skill: target must be a positive number (got '" .. target_s .. "').", GP.err))
      return
    end
  end
  show_skill(charname, query, target)
end, {
  description = "Inspect a skill's level, bonus, stat contributions, and targets.",
  usage = "skill <skill> [<level|bonus>] | skill refresh",
  -- `/sk` shortcut. Ignored by Mallard < 0.15 (unknown opts keys are silently
  -- dropped), so this stays backward-compatible without a minimum_app_version bump.
  aliases = "sk",
})

-- Announce a goal the moment a skills refresh shows it newly met. We mark the
-- goal `announced` so it only fires once, and clear the flag if it later
-- falls back below target (e.g. the goal was raised), so re-completion
-- announces again. Replays (cached re-emits) are ignored.
events.on("net.mallard.discworld.skills.updated", function(d)
  if type(d) ~= "table" or d.replay then return end
  local charname = d.charname
  if not charname or charname == "" then return end
  -- A fresh snapshot is the moment to capture any not-yet-baselined goals.
  local list = backfill_goal_baselines(charname)
  if #list == 0 then return end
  local result = planner.plan({
    skills = (type(d.snapshot) == "table") and d.snapshot or {},
    stats  = char_stats(charname),
    goals  = list,
  })
  local changed = false
  for i, row in ipairs(result.goals) do
    local g = list[i]   -- planner.plan preserves goal order
    if row.done and not g.announced then
      g.announced, changed = true, true
      mud.note(
        sp("goal met: ", GP.done),
        sp(g.skill, { fg = "cyan", bold = true }),
        sp(string.format(" → %d %s ✓", g.value, g.type), GP.done))
    elseif not row.done and g.announced then
      g.announced, changed = nil, true
    end
  end
  if changed then save_goals(charname, list) end
end)

-- ---------------------------------------------------------------------
-- Startup hydration — rehydrate the XP buffer + per-character state on
-- plugin reload. gmcp.on only catches future char.info pushes; on a
-- mid-session reload the last frame is already gone, so we'd sit with
-- an empty XP chart and an unidentified character until Discworld next
-- bumped char.info. Runs at the bottom of main.lua so `hydrate_xp_state`
-- is already assigned (it's forward-declared up top).
-- ---------------------------------------------------------------------

local cached_name = gmcp.get("char.info.name")
if type(cached_name) == "string" and cached_name ~= "" then
  hydrate_xp_state(cached_name)
  set_charname(cached_name)
end
