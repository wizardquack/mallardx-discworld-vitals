-- Behaviour tests for src/bonus.lua.
-- Run from project root: `lua tests/bonus_test.lua`.
--
-- Ground truth is the worked examples on
-- http://bonuses.irreducible.org/formulas.php, reproduced here as fixed
-- assertions so a formula regression is caught against the published numbers
-- rather than against our own re-derivation.

package.path = "./src/?.lua;" .. package.path
local bonus = require("bonus")

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

local function approx(got, want, tol, ctx)
  assert(got and math.abs(got - want) <= tol,
    (ctx or "value") .. ": expected ~" .. tostring(want) .. ", got " .. tostring(got))
end

-- ---------------------------------------------------------------------
-- R(level) — raw level bonus tier boundaries + published values.
-- ---------------------------------------------------------------------
test("raw_level_bonus tier boundaries", function()
  eq(bonus.raw_level_bonus(0),   0,   "R(0)")
  eq(bonus.raw_level_bonus(20),  100, "R(20)")    -- 5*20
  eq(bonus.raw_level_bonus(21),  102, "R(21)")    -- floor(2.5*1+100)=102
  eq(bonus.raw_level_bonus(40),  150, "R(40)")    -- 2.5*20+100
  eq(bonus.raw_level_bonus(60),  170, "R(60)")    -- 1*20+150
  eq(bonus.raw_level_bonus(100), 190, "R(100)")   -- page: 190
  eq(bonus.raw_level_bonus(137), 208, "R(137)")   -- page: 208
end)

test("raw_level_bonus only moves on even levels past 61", function()
  eq(bonus.raw_level_bonus(61), 170, "R(61)")     -- floor(0.5+170)=170
  eq(bonus.raw_level_bonus(62), 171, "R(62)")
  eq(bonus.raw_level_bonus(63), 171, "R(63)")
  eq(bonus.raw_level_bonus(64), 172, "R(64)")
end)

test("raw_level_bonus rejects bad input", function()
  eq(bonus.raw_level_bonus(-1), nil, "R(-1)")
  eq(bonus.raw_level_bonus("x"), nil, "R(string)")
end)

-- ---------------------------------------------------------------------
-- M(stats) — stat multiplicator. Page example: Int 12, Wis 18 on a skill
-- using Int twice + Wis thrice → M ≈ 1.14195.
-- ---------------------------------------------------------------------
test("stat_multiplicator matches page example", function()
  local m = bonus.stat_multiplicator({ 12, 12, 18, 18, 18 })
  approx(m, 1.14195, 1e-4, "M(12,12,18,18,18)")
end)

test("stat_multiplicator clamps to >= 0 and rejects non-positive", function()
  -- All-1 stats → ln(1)=0 → -0.25 → clamped to 0.
  eq(bonus.stat_multiplicator({ 1, 1, 1, 1, 1 }), 0, "M(all 1)")
  eq(bonus.stat_multiplicator({ 13, 0, 13, 13, 13 }), nil, "M(zero stat)")
  eq(bonus.stat_multiplicator({}), nil, "M(empty)")
end)

-- ---------------------------------------------------------------------
-- bonus_for_level — the headline composition, against page values.
--   Bonus(100, (12,12,18,18,18)) = 216
--   Bonus(137, (12,12,18,18,18)) = 237  (watch-high uses this internally)
-- ---------------------------------------------------------------------
test("bonus_for_level reproduces page worked examples", function()
  local m = bonus.stat_multiplicator({ 12, 12, 18, 18, 18 })
  eq(bonus.bonus_for_level(100, m), 216, "Bonus(100)")
  eq(bonus.bonus_for_level(137, m), 237, "Bonus(137)")
end)

-- ---------------------------------------------------------------------
-- derive_multiplicator — empirical M from an observed (level, bonus) pair
-- round-trips: projecting back to the sampled level reproduces the bonus,
-- and projecting to a *true* future level matches the stat-based formula.
-- ---------------------------------------------------------------------
test("derive_multiplicator round-trips at the sampled level", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  for _, level in ipairs({ 5, 25, 55, 100, 300, 800 }) do
    local observed = bonus.bonus_for_level(level, m)
    local derived  = bonus.derive_multiplicator(level, observed)
    eq(bonus.bonus_for_level(level, derived), observed,
      "re-project at level " .. level)
  end
end)

test("derive_multiplicator projects future levels within 1 of truth", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  local sample_level = 200
  local derived = bonus.derive_multiplicator(sample_level,
    bonus.bonus_for_level(sample_level, m))
  for _, level in ipairs({ 210, 300, 500, 800 }) do
    local truth     = bonus.bonus_for_level(level, m)
    local projected = bonus.bonus_for_level(level, derived)
    assert(math.abs(projected - truth) <= 1,
      "projection at level " .. level .. ": truth " .. truth
        .. ", projected " .. projected)
  end
end)

test("derive_multiplicator needs an invertible level", function()
  eq(bonus.derive_multiplicator(0, 0), nil, "derive at level 0")
end)

-- ---------------------------------------------------------------------
-- level_for_bonus — inverse of bonus_for_level. The returned level is the
-- smallest that meets or exceeds the target, and is consistent with the
-- forward function.
-- ---------------------------------------------------------------------
test("level_for_bonus is the minimal level meeting the target", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  for _, target in ipairs({ 50, 143, 200, 300, 550, 700 }) do
    local level = bonus.level_for_bonus(target, m)
    assert(bonus.bonus_for_level(level, m) >= target,
      "level " .. level .. " should reach bonus " .. target)
    if level > 0 then
      assert(bonus.bonus_for_level(level - 1, m) < target,
        "level " .. (level - 1) .. " should fall short of bonus " .. target)
    end
  end
end)

test("level_for_bonus edge cases", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  eq(bonus.level_for_bonus(0, m), 0, "target 0")
  eq(bonus.level_for_bonus(-5, m), 0, "negative target")
  eq(bonus.level_for_bonus(100, 0), nil, "zero multiplicator")
end)

print(string.format("\n%d bonus tests passed.", passed))
