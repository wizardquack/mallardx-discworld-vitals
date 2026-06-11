-- Rolling-window XP/hour tracker for discworld-vitals.
--
-- Pure Lua, no host-API dependencies.
--
-- Reports a strict TRAILING sum: while the window is filling, rate() returns
-- the XP gained since tracking began (no projection to a full hour). Once a
-- full window has elapsed, the oldest samples slide out and rate() becomes
-- a true window_seconds-long trailing sum (i.e. xp/hour for a 3600s window).
--
-- Trim is anchored on the NEWEST sample's ts, not wall-clock now, so the
-- window doesn't silently empty during a long quiet stretch (disconnect,
-- sleep, extended AFK). When fresh XP eventually arrives after a gap larger
-- than the window, record() collapses the gap by shifting the prior samples
-- forward so the trailing math continues from where it left off — see the
-- "Why collapse the gap?" note inside record() for the rationale.
--
-- Usage:
--   local tracker = require("xp_tracker").make(window_seconds)
--   tracker.record(now_seconds, current_xp)
--   local rate = tracker.rate(now_seconds)
--     rate — xp gained over the trailing window (or partial during ramp-up)

local M = {}

function M.make(window_seconds)
  window_seconds = window_seconds or 3600

  local samples = {}   -- array of { ts, xp }
  local started_at = nil  -- ts of the earliest sample currently held

  local function trim(reference_ts)
    while samples[1] and (reference_ts - samples[1].ts) > window_seconds do
      table.remove(samples, 1)
    end
    if not samples[1] then started_at = nil end
  end

  local function record(ts, xp)
    local newest = samples[#samples]
    if newest and (ts - newest.ts) > window_seconds then
      -- Why collapse the gap? After a disconnect / sleep / long AFK, the
      -- previously-collected samples sit unchanged in memory. Without a
      -- shift, the first record() after wake-up would treat the entire gap
      -- as elapsed window time and trim every prior sample away, leaving a
      -- single fresh sample whose rate() reads 0 — the display would jump
      -- from the sticky last value to zero on the first new XP event.
      -- Sliding the old samples forward so the previous newest lands 1s
      -- before the incoming one preserves the prior session's trailing-
      -- hour delta; the old samples then age out naturally as fresh play
      -- resumes.
      local shift = (ts - 1) - newest.ts
      for i = 1, #samples do samples[i].ts = samples[i].ts + shift end
      if started_at then started_at = started_at + shift end
    end
    samples[#samples + 1] = { ts = ts, xp = xp }
    if started_at == nil or ts < started_at then started_at = ts end
    trim(ts)
  end

  local function rate(_now)
    -- Anchor on the newest sample, not wall-clock now, so a long quiet
    -- stretch doesn't silently empty the window. The display stays sticky
    -- until either fresh activity arrives (via record) or the caller
    -- replaces the samples (via replace_samples).
    local newest = samples[#samples]
    if newest then trim(newest.ts) end
    local first = samples[1]
    local last  = samples[#samples]
    if not first or not last then return nil end
    local delta = last.xp - first.xp
    if delta < 0 then delta = 0 end                  -- xp reset / regression
    return delta
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
