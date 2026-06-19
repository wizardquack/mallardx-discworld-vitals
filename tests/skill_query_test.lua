-- Behaviour tests for src/skill_query.lua.
-- Run from project root: `lua tests/skill_query_test.lua`.

package.path = "./src/?.lua;" .. package.path
local skill_query = require("skill_query")
local bonus       = require("bonus")
local skill_data  = require("skill_data")

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

local STATS = { constitution = 14, dexterity = 13, intelligence = 18,
                strength = 16, wisdom = 17 }

-- ---------------------------------------------------------------------
-- Current state — observed skill prefers empirical M, projects its bonus.
-- ---------------------------------------------------------------------
test("describe reports observed M and current state", function()
  local info = skill_query.describe({
    path = "fighting.melee.sword", level = 200, bonus = 240, stats = STATS })
  eq(info.path, "fighting.melee.sword", "path")
  eq(info.level, 200, "level")
  eq(info.bonus, 240, "observed bonus passed through")
  eq(info.mult_source, "observed", "empirical M preferred")
  -- Empirical M reproduces the observed bonus exactly at the sampled level.
  eq(bonus.bonus_for_level(200, info.mult), 240, "M reproduces observed bonus")
  -- stat_mult is still computed for context (and differs from empirical here).
  assert(info.stat_mult, "stat-derived M present too")
end)

-- ---------------------------------------------------------------------
-- Contributions — canonical C/D/I/S/W order, slot counts, current values.
-- ---------------------------------------------------------------------
test("describe breaks out stat contributions", function()
  -- magic.spells.offensive = "WSSII" → I x2, S x2, W x1.
  local info = skill_query.describe({
    path = "magic.spells.offensive", level = 100, bonus = 180, stats = STATS })
  eq(info.stat_code, "WSSII", "code")
  local c = info.contributions
  eq(#c, 3, "three distinct stats")
  eq(c[1].stat, "intelligence", "I first (canonical order)")
  eq(c[1].count, 2, "intelligence x2")
  eq(c[1].value, 18, "intelligence value from stats")
  eq(c[2].stat, "strength", "strength second")
  eq(c[2].count, 2, "strength x2")
  eq(c[3].stat, "wisdom", "wisdom last")
  eq(c[3].count, 1, "wisdom x1")
end)

test("describe lists contributions even without stats (no values)", function()
  local info = skill_query.describe({
    path = "magic.spells.offensive", level = 100, bonus = 180 })
  assert(info.contributions, "contributions present")
  eq(info.contributions[1].value, nil, "no value without stats")
  eq(info.contributions[1].count, 2, "count still known from the code")
end)

-- ---------------------------------------------------------------------
-- M fallback — untrained skill falls back to the stat-table M.
-- ---------------------------------------------------------------------
test("describe falls back to stat-table M for an untrained skill", function()
  local info = skill_query.describe({
    path = "magic.spells.offensive", level = 0, stats = STATS })
  eq(info.mult_source, "stats", "stat-table M")
  assert(info.mult and info.mult > 0, "has a multiplicator")
  -- Bonus is projected from M at level 0 → 0.
  eq(info.bonus, 0, "projected bonus at level 0")
end)

test("describe leaves M nil when it can't be resolved", function()
  -- Untrained, no stats → no empirical, no stat-table input.
  local info = skill_query.describe({ path = "magic.spells.offensive", level = 0 })
  eq(info.mult, nil, "no M")
  eq(info.bonus, nil, "no bonus without M")
end)

-- ---------------------------------------------------------------------
-- Target — read both ways, with consistency + already-reached flags.
-- ---------------------------------------------------------------------
test("describe reads a target as both a bonus and a level", function()
  local info = skill_query.describe({
    path = "fighting.melee.sword", level = 100, bonus = 190, stats = STATS,
    target = 260 })
  local t = info.target
  eq(t.value, 260, "target value")

  -- As a bonus: the first level reaching bonus 260, and it really reaches it.
  local ln = t.as_bonus.level_needed
  assert(ln and ln > 100, "level needed beyond current")
  assert(bonus.bonus_for_level(ln, info.mult) >= 260, "that level reaches the bonus")
  assert(bonus.bonus_for_level(ln - 1, info.mult) < 260, "the level before doesn't")
  eq(t.as_bonus.extra_levels, ln - 100, "extra levels from current")
  eq(t.as_bonus.already, false, "bonus not yet reached")

  -- As a level: the bonus you'd have at level 260.
  eq(t.as_level.bonus_reached, bonus.bonus_for_level(260, info.mult), "bonus at level 260")
  eq(t.as_level.already, false, "level not yet reached")
  eq(t.as_level.extra_bonus, t.as_level.bonus_reached - info.bonus, "extra bonus")
end)

test("describe flags an already-reached bonus and level", function()
  -- Current level 300, bonus ~290; target 150 is below both readings.
  local info = skill_query.describe({
    path = "fighting.melee.sword", level = 300, bonus = 290, stats = STATS,
    target = 150 })
  eq(info.target.as_bonus.already, true, "bonus 150 already reached")
  eq(info.target.as_level.already, true, "level 150 already reached")
end)

test("describe target needs M (no_mult when unresolvable)", function()
  local info = skill_query.describe({
    path = "magic.spells.offensive", level = 0, target = 200 })
  eq(info.target.no_mult, true, "target flagged no_mult")
  eq(info.target.as_bonus, nil, "no readings without M")
end)

test("describe target truncates a fractional value", function()
  local info = skill_query.describe({
    path = "fighting.melee.sword", level = 100, bonus = 190, stats = STATS,
    target = 260.9 })
  eq(info.target.value, 260, "floored target")
end)

print(string.format("\n%d skill_query tests passed.", passed))
