-- Rolling-window XP/hour tracker for discworld-vitals.
--
-- Pure Lua, no host-API dependencies. Tests load this file directly
-- into a vanilla mlua::Lua state (see src-tauri/tests/discworld_vitals_plugin.rs).
--
-- Usage:
--   local tracker = require("xp_tracker").make(window_seconds, min_seconds)
--   tracker.record(now_seconds, current_xp)
--   local rate = tracker.rate(now_seconds)   -- xp/hour, or nil if not enough data

local M = {}

-- window_seconds: max sample age (default 3600 = 1 hr).
-- min_seconds:    minimum span before rate is reported (default 30s).
function M.make(window_seconds, min_seconds)
  window_seconds = window_seconds or 3600
  min_seconds    = min_seconds    or 30

  local samples = {}   -- array of { ts, xp }

  local function trim(now)
    while samples[1] and (now - samples[1].ts) > window_seconds do
      table.remove(samples, 1)
    end
  end

  local function record(ts, xp)
    samples[#samples + 1] = { ts = ts, xp = xp }
    trim(ts)
  end

  local function rate(now)
    trim(now)
    local first = samples[1]
    local last  = samples[#samples]
    if not first or not last then return nil end
    local span = last.ts - first.ts
    if span < min_seconds then return nil end
    local delta = last.xp - first.xp
    if delta < 0 then return 0 end                   -- xp reset / regression
    return math.floor(delta / span * 3600 + 0.5)
  end

  return { record = record, rate = rate, _samples = samples }
end

return M
