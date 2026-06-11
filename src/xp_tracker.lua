-- Rolling-window XP/hour tracker for discworld-vitals.
--
-- Pure Lua, no host-API dependencies.
--
-- Reports a strict TRAILING sum: while the window is filling, rate() returns
-- the XP gained since tracking began (no projection to a full hour). Once a
-- full window has elapsed, the oldest samples slide out and rate() becomes
-- a true window_seconds-long trailing sum (i.e. xp/hour for a 3600s window).
--
-- Usage:
--   local tracker = require("xp_tracker").make(window_seconds)
--   tracker.record(now_seconds, current_xp)
--   local rate, ramping_seconds = tracker.rate(now_seconds)
--     rate              — xp gained over the trailing window (or partial)
--     ramping_seconds   — seconds since tracking began, or nil once the
--                         window is full (i.e. rate is a true per-window sum)

local M = {}

function M.make(window_seconds)
  window_seconds = window_seconds or 3600

  local samples = {}   -- array of { ts, xp }
  local started_at = nil  -- ts of the earliest sample currently held

  local function trim(now)
    while samples[1] and (now - samples[1].ts) > window_seconds do
      table.remove(samples, 1)
    end
    -- If everything got trimmed (e.g. long idle gap), forget where we started
    -- so the next record() begins a fresh ramp-up window.
    if not samples[1] then started_at = nil end
  end

  local function record(ts, xp)
    samples[#samples + 1] = { ts = ts, xp = xp }
    if started_at == nil or ts < started_at then started_at = ts end
    trim(ts)
  end

  local function rate(now)
    trim(now)
    local first = samples[1]
    local last  = samples[#samples]
    if not first or not last then return nil end
    local delta = last.xp - first.xp
    if delta < 0 then delta = 0 end                  -- xp reset / regression
    if started_at and (now - started_at) >= window_seconds then
      return delta, nil
    end
    local elapsed = started_at and (now - started_at) or 0
    return delta, elapsed
  end

  -- Replace the rolling-window samples in-place. Used to hydrate from
  -- persisted storage on relog. Preserves the `samples` table identity so
  -- existing `_samples` references stay valid (matters for tests).
  local function replace_samples(new_samples)
    for i = #samples, 1, -1 do samples[i] = nil end
    started_at = nil
    if type(new_samples) ~= "table" then return end
    for i, s in ipairs(new_samples) do
      if type(s) == "table" and type(s.ts) == "number" and type(s.xp) == "number" then
        samples[#samples + 1] = { ts = s.ts, xp = s.xp }
        if started_at == nil or s.ts < started_at then started_at = s.ts end
      end
    end
  end

  return { record = record, rate = rate, replace_samples = replace_samples, _samples = samples }
end

return M
