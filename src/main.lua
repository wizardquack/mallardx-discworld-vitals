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

local panel = mud.panel("vitals")

-- ---------------------------------------------------------------------
-- State snapshot. Mutations route through push_state() so every change
-- triggers a fresh panel post. CCC / BUG / MS sit at "unknown" until
-- detection lands in a later session — the slots are reserved here so
-- adding them later is just a shield_set() call.
-- ---------------------------------------------------------------------

local state = {
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

local function push_state() panel:post("state", state) end

panel:on_message("ready", function() push_state() end)

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
local tracker        = xp_tracker.make(3600)
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

local function set_gp(v, m)
  if v and m then state.gp = { value = v, max = m }; push_state() end
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
    if v and m then state.gp = { value = v, max = m } end
  end
  if burden then state.burden = burden end
  if xp then
    state.xp = format_thousands(xp)
    tracker.record(now_seconds(), xp)
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
  for k, v in pairs(data) do
    local key = "char.info." .. tostring(k)
    local t = type(v)
    if t == "string" or t == "number" or t == "boolean" then
      vars.set(key, v)
    elseif v == nil then
      vars.delete(key)
    end
  end
  events.emit("net.mallard.discworld.char_info", data)
  -- char.info is the first wire-side hint of who we're logged in as.
  -- Hydrate is idempotent per (charname) — repeated info updates with the
  -- same name don't re-hydrate. A name change (alt switch) triggers a
  -- fresh hydrate and from then on saves the new alt's slot.
  if type(data.name) == "string" then hydrate_xp_state(data.name) end
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
    tracker.record(now_seconds(), x)
    announce_xp_gain(x)
  end
end)

-- ---------------------------------------------------------------------
-- XP/hour ticker — recompute every 5s, push if changed.
-- ---------------------------------------------------------------------

mud.every(5000, function()
  local r = tracker.rate(now_seconds())
  local formatted = (r ~= nil) and format_thousands(r) or nil
  if formatted ~= state.xp_rate then
    state.xp_rate = formatted
    push_state()
  end
end)

-- ---------------------------------------------------------------------
-- XP/hour chart series — one sample per minute, capped at 60 points
-- (~last hour). Each sample is the current windowed xp/hour or 0 if the
-- tracker doesn't have enough data yet, so the polyline starts at the
-- baseline rather than jumping in mid-chart. See quow's UpdateXPGraph
-- (QuowMinimap.xml:17105) for the reference implementation.
-- ---------------------------------------------------------------------

local XP_CHART_MAX_POINTS = 60

-- ---------------------------------------------------------------------
-- XP state persistence — keyed by `char.info.name` so the chart and the
-- "last shown" xp/hour figure survive plugin restart / relog. Strategy
-- is restore-verbatim with rolling-window self-heal:
--   * tracker samples replay through `trim(now)` and any older than the
--     window get dropped; if everything ages out, rate() goes nil and the
--     sticky `state.xp_rate` from the last session stays visible until
--     fresh XP arrives.
--   * chart series points slide off the right edge as fresh samples
--     arrive — after at most 60 minutes the chart is 100% live data.
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
  local series = state.xp_chart.series
  for i = #series, 1, -1 do series[i] = nil end
  if type(saved.chart_series) == "table" then
    for i, v in ipairs(saved.chart_series) do
      if type(v) == "number" then series[i] = v end
    end
  end

  tracker.replace_samples(saved.tracker_samples)

  if type(saved.last_rate) == "string" and saved.last_rate ~= "" then
    state.xp_rate = saved.last_rate
  end

  push_state()
end

local function save_xp_state()
  if not hydrated_for then return end
  storage.set("xp_state/" .. hydrated_for, {
    chart_series    = state.xp_chart.series,
    tracker_samples = tracker._samples,
    last_rate       = state.xp_rate,
    saved_at        = now_seconds(),
  })
end

-- Push a chart sample every minute regardless of wire activity. rate() is
-- sticky during quiet stretches (trim is anchored on the newest sample's
-- ts, not wall-clock), so an idle plateau truthfully extends the last
-- observed rate. The chart renderer treats each slot as one minute of real
-- time, so we must keep advancing it or the x-axis stops corresponding to
-- real time.
mud.every(60000, function()
  local series = state.xp_chart.series
  local r = tracker.rate(now_seconds()) or 0
  series[#series + 1] = r
  if #series > XP_CHART_MAX_POINTS then table.remove(series, 1) end
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
local tpa_started_at   = nil
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
  tpa_started_at   = nil
  tpa_down_summary = nil
  push_state()
end)

-- TPA: rich detail. While up we show "<percent>% · <Glow> · <age>". On
-- break we freeze a "Broken · N hits · duration" summary and stop ticking.
-- (Tracking locals declared above so shield.cleared can reset them.)

local function tpa_format_up()
  local pct  = (tpa_percent ~= nil) and (tpa_percent .. "%") or "?%"
  local glow = (tpa_glow   ~= "")   and title_case(tpa_glow)  or "?"
  local age  = tpa_started_at and format_duration(os.time() - tpa_started_at) or "?"
  return pct .. " · " .. glow .. " · " .. age
end

events.on("net.mallard.discworld.shield.up", function(data)
  if type(data) ~= "table" or data.subject ~= "self" or data.type ~= "tpa" then return end
  if state.shields.tpa.state ~= "up" then
    tpa_started_at = os.time()
  end
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
  tpa_started_at = nil
  shield_set("tpa", "down", tpa_down_summary)
end)

-- Keep the "age" segment fresh while the shield is up. 1s tick is
-- plenty for second-resolution duration; idle when state != "up" so
-- we don't churn the panel unnecessarily.
mud.every(1000, function()
  if state.shields.tpa.state == "up" then
    shield_set("tpa", "up", tpa_format_up())
  end
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
      if v and mx then state.gp = { value = v, max = mx } end
    end
    -- Quow's logic (QuowMinimap.xml:13783-13791): only update xp+burden
    -- when the burden capture is non-empty. Lines without a burden field
    -- are combat-monitor lines, not regular vitals — updating xp from
    -- them would poison the rolling-window tracker.
    if burden and xp then
      state.burden = burden
      state.xp     = format_thousands(xp)
      tracker.record(now_seconds(), xp)
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

local SKILLS_ARM_TIMEOUT_SECONDS = 5

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
  for _, c in ipairs(changes) do
    mud.note(string.format("  %s: %s → %s",
      c.path, fmt(c.old_lvl, c.old_bonus), fmt(c.new_lvl, c.new_bonus)))
  end
end

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
    local charname = vars.get("char.info.name")
    if not charname or charname == "" then
      mud.note("skills_parser: no char.info.name yet; dropping snapshot.")
      return
    end
    local prev = storage.get("skills/" .. charname)
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
})

-- A single 250 ms poll handles both arm-timeout and idle-flush. We
-- previously used `mud.delay` reschedule-on-each-absorb, but that churned
-- one scheduled-callback handle per absorbed line and was racy: the engine
-- could fire a handle on the same tick we removed it, producing
-- `invoke_callback: unknown callback id N` warnings. A single recurring
-- poll is both cheaper and immune to that race.
local last_absorb_at = nil
local SKILLS_IDLE_FLUSH_SECONDS = 1
local function mark_absorbed() last_absorb_at = now_seconds() end

mud.every(250, function()
  local now = now_seconds()
  skills_sm.try_arm_timeout(now, SKILLS_ARM_TIMEOUT_SECONDS)
  if last_absorb_at and (now - last_absorb_at) >= SKILLS_IDLE_FLUSH_SECONDS then
    last_absorb_at = nil
    skills_sm.try_flush(now)
  end
end)

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

-- Slash alias — the only sanctioned entry point.
mud.alias([[^/skills-refresh$]], function()
  skills_sm.arm(now_seconds())
  mud.note("skills-refresh: working...")
  mud.send("skills raw", { silent = true })
end, { name = "skills_refresh" })

-- Late-binding read surface. A consumer plugin that loaded after the parse
-- can fire this event with an optional `charname`; we reply by re-emitting
-- `skills.updated` with the cached snapshot, marked `replay = true` so
-- consumers can distinguish on-demand replies from live updates.
events.on("net.mallard.discworld.skills.request", function(d)
  d = (type(d) == "table") and d or {}
  local charname = d.charname
                or vars.get("char.info.name")
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
