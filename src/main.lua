-- Discworld Vitals — custom HTML panel (ui/vitals.{html,css,js}).
--
-- Maintains a single state table and pushes the full snapshot to the iframe
-- via `panel:post("state", ...)` after every mutation. The iframe replaces
-- the DOM wholesale, same pattern as discworld-sailing / discworld-grouping.
--
-- XP/hour math lives in src/xp_tracker.lua and GP optimistic-regen in
-- src/gp_tracker.lua — both are unit-tested at the Lua level under
-- src-tauri/tests/discworld_vitals_plugin.rs.

local xp_tracker = require("xp_tracker")
local gp_tracker = require("gp_tracker")

local panel = mud.panel("vitals")

-- ---------------------------------------------------------------------
-- State snapshot. Mutations route through push_state() so every change
-- triggers a fresh panel post. CCC / BUG / MS sit at "unknown" until
-- detection lands in a later session — the slots are reserved here so
-- adding them later is just a shield_set() call.
-- ---------------------------------------------------------------------

local state = {
  hp      = nil,          -- { value, max } | nil
  gp      = nil,          -- { value, max } | nil
  burden  = nil,          -- 0..100 | nil
  xp      = nil,          -- formatted string | nil
  xp_rate = nil,          -- formatted string | nil
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

local xp_window      = settings.get("xp_window")
local gp_regen       = settings.get("gp_regen")
local window_seconds = ({ ["5m"] = 300, ["30m"] = 1800, ["1h"] = 3600 })[xp_window] or 3600
local tracker        = xp_tracker.make(window_seconds, 30)
local gp             = gp_tracker.make(gp_regen)

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

-- ---------------------------------------------------------------------
-- GMCP — `char.vitals` carries authoritative HP/GP/burden/XP on login
-- and (on some Discworld configs) periodic refreshes. MXP entity pushes
-- below are the primary real-time update mechanism.
-- ---------------------------------------------------------------------

gmcp.on("char.vitals", function(_pkg, data)
  if type(data) ~= "table" then return end
  if data.hp and data.maxhp then state.hp = { value = data.hp, max = data.maxhp } end
  if data.gp and data.maxgp then
    gp.set(data.gp, data.maxgp)
    local v, m = gp.current()
    if v and m then state.gp = { value = v, max = m } end
  end
  if data.burden then state.burden = data.burden end
  if type(data.xp) == "number" then
    state.xp = format_thousands(data.xp)
    tracker.record(now_seconds(), data.xp)
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
end)

-- ---------------------------------------------------------------------
-- MXP entity pushes — primary real-time path (Plan #9c).
-- ---------------------------------------------------------------------

local function refresh_hp()
  local v = tonumber(mxp.get_entity("hp"))
  local m = tonumber(mxp.get_entity("maxhp"))
  set_hp(v, m)
end

local function refresh_gp_from_mxp()
  local v = tonumber(mxp.get_entity("gp"))
  local m = tonumber(mxp.get_entity("maxgp"))
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
  local b = tonumber(v)
  if b then set_burden(b) end
end)

mxp.on_entity("xp", function(_, v)
  local x = tonumber(v)
  if x then
    set_xp(x)
    tracker.record(now_seconds(), x)
  end
end)

-- ---------------------------------------------------------------------
-- XP/hour ticker — recompute every 5s, push if changed.
-- ---------------------------------------------------------------------

mud.timer.every(5000, function()
  local r = tracker.rate(now_seconds())
  local formatted = (r ~= nil) and format_thousands(r) or nil
  if formatted ~= state.xp_rate then
    state.xp_rate = formatted
    push_state()
  end
end)

-- ---------------------------------------------------------------------
-- GP optimistic regen — one combat round (~2s). Authoritative sources
-- overwrite the optimistic value when they arrive.
-- ---------------------------------------------------------------------

mud.timer.every(2000, function()
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
mud.timer.every(1000, function()
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
  [==[^Hp: (?P<hp>\d+) ?\((?P<maxhp>\d+)\) +(?:Gp\: (?P<gp>\d+) ?\((?P<maxgp>\d+)\)) +(?:Xp\: (?P<xp>\d+))(?:  Burden: (?P<burden>\d+)\%)?$]==],
  function(m)
    if m.hp and m.maxhp then
      state.hp = { value = m.hp, max = m.maxhp }
    end
    if m.gp and m.maxgp then
      gp.set(m.gp, m.maxgp)
      local v, mx = gp.current()
      if v and mx then state.gp = { value = v, max = mx } end
    end
    -- Quow's logic (QuowMinimap.xml:13783-13791): only update xp+burden
    -- when the burden capture is non-empty. Lines without a burden field
    -- are combat-monitor lines, not regular vitals — updating xp from
    -- them would poison the rolling-window tracker.
    if m.burden and m.xp then
      state.burden = m.burden
      state.xp     = format_thousands(m.xp)
      tracker.record(now_seconds(), m.xp)
    end
    push_state()
  end
)
