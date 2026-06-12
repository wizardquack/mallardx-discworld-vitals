-- Bucket-based XP/hour tracker for discworld-vitals.
--
-- Pure Lua, no host-API dependencies.
--
-- The caller drives the tracker by ticking it on a fixed cadence (default
-- 10s buckets, 360 buckets ≈ 1 hour of history). Each tick records the XP
-- gained since the previous tick into a delta bucket; the reported rate is
-- the per-bucket average across the buffer, extrapolated to per-hour:
--
--   rate = floor((sum(deltas) / N) * (3600 / bucket_seconds))
--
-- During idle stretches each new tick contributes a 0-delta, so the rate
-- naturally drops as zeros displace older non-zero buckets — no stickiness.
-- After a full window of idle, the buffer is all zeros and rate is 0.
--
-- Modeled on Quow's UpdateXPGraph (QuowMinimap.xml:17105) but at finer
-- 10s granularity instead of his 1-minute cadence so the chart line is
-- smoother on mallard's 360-point window.
--
-- Usage:
--   local tracker = require("xp_tracker").make(10, 360)
--   local r = tracker.tick(current_xp)   -- call on a regular cadence
--   tracker.restore(saved_deltas, saved_baseline_xp)  -- on hydrate

local M = {}

function M.make(bucket_seconds, max_buckets)
  bucket_seconds = bucket_seconds or 10
  max_buckets    = max_buckets or 360
  local extrap   = 3600 / bucket_seconds

  local deltas      = {}
  local last_bucket = nil  -- XP value at the upper edge of the most recent
                           -- bucket; baseline for the next tick's delta.

  local function compute_rate()
    if #deltas == 0 then return nil end
    local sum = 0
    for i = 1, #deltas do sum = sum + deltas[i] end
    return math.floor((sum / #deltas) * extrap)
  end

  -- Record one bucket using current_xp as the upper edge of the delta. The
  -- first call after construction (or after restore() without a baseline)
  -- only seeds the baseline and skips appending — we need two readings to
  -- compute a delta. Subsequent calls append a non-negative delta and return
  -- the new rate. Negative deltas (xp reset / wire regression) clamp to 0.
  local function tick(current_xp)
    if type(current_xp) ~= "number" then return compute_rate() end
    if last_bucket == nil then
      last_bucket = current_xp
      return compute_rate()
    end
    local d = current_xp - last_bucket
    if d < 0 then d = 0 end
    last_bucket = current_xp
    deltas[#deltas + 1] = d
    if #deltas > max_buckets then table.remove(deltas, 1) end
    return compute_rate()
  end

  -- Drop the buffer + baseline back in verbatim. Used on hydrate so the
  -- chart and rate at moment-of-reconnect match moment-of-disconnect
  -- exactly; the next tick then naturally resumes the rolling window.
  local function restore(saved_deltas, saved_baseline)
    for i = #deltas, 1, -1 do deltas[i] = nil end
    if type(saved_deltas) == "table" then
      for i, v in ipairs(saved_deltas) do
        if type(v) == "number" then deltas[#deltas + 1] = v end
      end
    end
    last_bucket = (type(saved_baseline) == "number") and saved_baseline or nil
  end

  return {
    tick     = tick,
    rate     = compute_rate,
    restore  = restore,
    deltas   = function() return deltas end,
    baseline = function() return last_bucket end,
  }
end

return M
