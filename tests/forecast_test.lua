-- Behaviour tests for src/forecast.lua.
-- Run from project root: `lua tests/forecast_test.lua`.
--
-- These check the per-skill query primitives compose correctly over the
-- already-verified bonus/cost math: cheapest-method selection per level,
-- forward cost-to-target, the budget inverse, and the marginal next step.

package.path = "./src/?.lua;" .. package.path
local forecast = require("forecast")
local bonus    = require("bonus")
local cost     = require("cost")

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

-- A representative skill multiplicator for reuse.
local M = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })

-- ---------------------------------------------------------------------
-- multiplicator — empirical preferred, stats fallback.
-- ---------------------------------------------------------------------
test("multiplicator prefers observed (level,bonus), falls back to stats", function()
  local m, src = forecast.multiplicator({ level = 250, bonus = 320 })
  assert(m and src == "observed", "observed source")
  eq(m, bonus.derive_multiplicator(250, 320), "matches derive")

  local m2, src2 = forecast.multiplicator({
    path = "adventuring.perception",
    stats = { constitution = 14, dexterity = 12, intelligence = 12,
              strength = 16, wisdom = 18 },
  })
  assert(m2 and src2 == "stats", "stats source")

  eq(forecast.multiplicator({ path = "nope", stats = {} }), nil, "unresolvable")
  -- Level 0 has no derivable M; with no stats fallback this is nil.
  eq(forecast.multiplicator({ level = 0, bonus = 0 }), nil, "level 0, no fallback")
end)

-- ---------------------------------------------------------------------
-- resolve_target_level — level passthrough + bonus→level.
-- ---------------------------------------------------------------------
test("resolve_target_level normalises both goal forms", function()
  eq(forecast.resolve_target_level(M, { type = "level", value = 800 }), 800, "level goal")
  eq(forecast.resolve_target_level(M, { type = "bonus", value = 550 }),
     bonus.level_for_bonus(550, M), "bonus goal")
  eq(forecast.resolve_target_level(M, { type = "what", value = 1 }), nil, "bad type")
end)

-- ---------------------------------------------------------------------
-- level_cost — cheapest eligible method, with eligibility gates.
-- ---------------------------------------------------------------------
test("level_cost picks the cheapest eligible method", function()
  -- Early on, guild is far cheaper than self for a primary.
  local lc = forecast.level_cost(100, M, { { kind = "guild" }, { kind = "self" } })
  eq(lc.method, "guild", "guild wins early")
  eq(lc.cost, cost.guild_advance_cost(100), "guild cost")
end)

test("level_cost drops guild past the cap, falls to self", function()
  local lc = forecast.level_cost(300, M, { { kind = "guild" }, { kind = "self" } })
  eq(lc.method, "self", "self after guild cap")
  eq(forecast.level_cost(300, M, { { kind = "guild" } }), nil, "guild-only stalls at cap")
end)

test("level_cost drops a player teacher once you reach their ETB", function()
  local b = bonus.bonus_for_level(150, M)
  -- Teacher ETB just below the current bonus → ineligible; self is the floor.
  local lc = forecast.level_cost(150, M,
    { { kind = "player", teacher_etb = b - 1, label = "weak" }, { kind = "self" } })
  eq(lc.method, "self", "self when teacher too weak")
  -- A strong specialist teacher beats self.
  local lc2 = forecast.level_cost(150, M,
    { { kind = "player", teacher_etb = 5000, specialized = true, label = "Qu" },
      { kind = "self" } })
  eq(lc2.method, "Qu", "strong teacher wins (label passthrough)")
  assert(lc2.cost < lc.cost, "teacher cheaper than self")
end)

test("level_cost honours label passthrough and reports bonus", function()
  local lc = forecast.level_cost(100, M, { { kind = "self", label = "diy" } })
  eq(lc.method, "diy", "custom label")
  eq(lc.bonus, bonus.bonus_for_level(100, M), "reported bonus")
end)

-- ---------------------------------------------------------------------
-- cost_to_target — accumulation + per-level method switching.
-- ---------------------------------------------------------------------
test("cost_to_target with one self method matches cost.cost_to_advance", function()
  local res  = forecast.cost_to_target(M, 100, 130, { { kind = "self" } })
  local ref  = cost.cost_to_advance(100, 130, { method = "self", mult = M })
  eq(res.total_xp, ref.total_xp, "self-only total matches lower primitive")
  eq(res.reachable, true, "reachable")
end)

test("cost_to_target switches methods at the guild cap", function()
  -- Primary skill from 290 to 305: guild handles 290–299, self handles 300–304.
  local res = forecast.cost_to_target(M, 290, 305,
    { { kind = "guild" }, { kind = "self" } })
  eq(res.reachable, true, "reachable via mixed methods")
  for _, row in ipairs(res.levels) do
    if row.level < 300 then eq(row.method, "guild", "guild below 300 at " .. row.level)
    else eq(row.method, "self", "self at/above 300 at " .. row.level) end
  end
  -- Total equals the sum of the per-level winners.
  local manual = 0
  for level = 290, 304 do
    manual = manual + forecast.level_cost(level, M,
      { { kind = "guild" }, { kind = "self" } }).cost
  end
  eq(res.total_xp, manual, "summed winners")
end)

test("cost_to_target reports unreachable when a level stalls", function()
  -- Guild-only primary aiming past the cap can't get there.
  local res = forecast.cost_to_target(M, 295, 310, { { kind = "guild" } })
  eq(res.reachable, false, "not reachable")
  eq(res.stalled_at, cost.GUILD_TEACH_MAX_LEVEL, "stalled at cap")
end)

test("cost_to_target caps a pathological target instead of looping", function()
  -- A target far beyond the runaway ceiling must terminate quickly and report
  -- unreachable (stalled at the cap), not grind through millions of levels.
  local res = forecast.cost_to_target(M, 100, 10000000, { { kind = "self" } })
  eq(res.reachable, false, "absurd target is unreachable within bounds")
  eq(res.stalled_at, 5000, "stalled at the default max level")
  -- A custom cap is honoured, and the work done stays bounded by it.
  local res2 = forecast.cost_to_target(M, 100, 10000000, { { kind = "self" } },
    { max_level = 200 })
  eq(res2.reachable, false, "still unreachable under a tighter cap")
  eq(res2.stalled_at, 200, "stalled at the custom cap")
  eq(#res2.levels, 100, "only priced levels 100..199 before the cap")
end)

-- ---------------------------------------------------------------------
-- max_under_budget — the inverse, consistent with cost_to_target.
-- ---------------------------------------------------------------------
test("max_under_budget is the inverse of cost_to_target", function()
  local methods = { { kind = "self" } }
  local from = 100
  -- Pick a budget equal to the exact cost of reaching level 120, so the
  -- inverse should land exactly on 120 and spend the whole budget.
  local target_cost = forecast.cost_to_target(M, from, 120, methods).total_xp
  local res = forecast.max_under_budget(M, from, target_cost, methods)
  eq(res.reached_level, 120, "reaches the funded level exactly")
  eq(res.spent_xp, target_cost, "spends the budget")
  eq(res.limited_by, "budget", "stopped by budget")
  -- One dollar short of the next level stays at 120.
  local next_cost = forecast.level_cost(120, M, methods).cost
  local res2 = forecast.max_under_budget(M, from, target_cost + next_cost - 1, methods)
  eq(res2.reached_level, 120, "can't afford the next level")
end)

test("max_under_budget stops on no eligible method", function()
  -- Guild-only, starting below the cap, unlimited budget → stops at the cap.
  local res = forecast.max_under_budget(M, 295, 1e18, { { kind = "guild" } })
  eq(res.reached_level, cost.GUILD_TEACH_MAX_LEVEL, "stops at guild cap")
  eq(res.limited_by, "no_method", "limited by eligibility")
end)

test("max_under_budget with zero budget stays put", function()
  local res = forecast.max_under_budget(M, 100, 0, { { kind = "self" } })
  eq(res.reached_level, 100, "no advance")
  eq(res.spent_xp, 0, "nothing spent")
  eq(res.limited_by, "budget", "budget bound")
end)

-- ---------------------------------------------------------------------
-- next_step — marginal next buy.
-- ---------------------------------------------------------------------
test("next_step reports the marginal cost and bonus gain", function()
  local methods = { { kind = "self" } }
  local step = forecast.next_step(M, 100, methods)
  eq(step.cost, forecast.level_cost(100, M, methods).cost, "marginal cost")
  eq(step.from_bonus, bonus.bonus_for_level(100, M), "from bonus")
  eq(step.to_bonus, bonus.bonus_for_level(101, M), "to bonus")
  eq(step.bonus_gain, step.to_bonus - step.from_bonus, "gain")
  eq(forecast.next_step(M, 300, { { kind = "guild" } }), nil, "nil when ineligible")
end)

print(string.format("\n%d forecast tests passed.", passed))
