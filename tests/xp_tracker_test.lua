-- Behaviour tests for src/xp_tracker.lua.
-- Run from project root: `lua tests/xp_tracker_test.lua`.

package.path = "./src/?.lua;" .. package.path
local xp_tracker = require("xp_tracker")

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

-- ---------------------------------------------------------------------
-- Baseline seeding + rolling rate.
-- ---------------------------------------------------------------------
test("first tick only seeds the baseline (nil rate)", function()
  local t = xp_tracker.make(10, 360)
  eq(t.tick(1000), nil, "seed tick rate")
  eq(t.baseline(), 1000, "seeded baseline")
  eq(#t.deltas(), 0, "no deltas after seed")
end)

test("subsequent ticks extrapolate the per-bucket average to per-hour", function()
  local t = xp_tracker.make(10, 360)  -- extrap = 360
  t.tick(0)
  eq(t.tick(100), 100 * 360, "one 100-delta bucket")   -- avg 100 * 360
  eq(t.tick(300), 150 * 360, "two buckets avg 150")    -- (100+200)/2 * 360
end)

test("negative deltas (xp/wire regression) clamp to zero", function()
  local t = xp_tracker.make(10, 360)
  t.tick(500)
  eq(t.tick(200), 0, "regression clamps rate to 0")
  eq(t.baseline(), 200, "baseline still follows current xp")
end)

-- ---------------------------------------------------------------------
-- reset() — wipe back to fresh-construction state.
-- ---------------------------------------------------------------------
test("reset clears deltas + baseline and rate returns nil", function()
  local t = xp_tracker.make(10, 360)
  t.tick(0)
  t.tick(100)
  t.tick(250)
  assert(t.rate() ~= nil and t.rate() > 0, "precondition: non-zero rate")

  t.reset()
  eq(t.rate(), nil, "rate after reset")
  eq(t.baseline(), nil, "baseline after reset")
  eq(#t.deltas(), 0, "deltas after reset")
end)

test("next tick after reset reseeds against current xp (no carry-over)", function()
  local t = xp_tracker.make(10, 360)
  t.tick(0)
  t.tick(1000)          -- big historical spike
  t.reset()
  eq(t.tick(5000), nil, "post-reset tick only reseeds")
  eq(t.baseline(), 5000, "reseeded baseline is current xp")
  eq(t.tick(5050), 50 * 360, "rate accumulates from zero, spike gone")
end)

print(passed .. " passed")
