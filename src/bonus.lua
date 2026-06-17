-- Skill ↔ bonus math for discworld-vitals.
--
-- Discworld computes a skill's *bonus* as the product of a level-only term
-- and a stats-only term, then floors:
--
--   Bonus(level, stats) = floor( M(stats) * R(level) )
--
--   R(level)  — "raw level bonus", depends ONLY on the skill level.
--   M(stats)  — "stat multiplicator", depends ONLY on the five stat values
--               the skill uses (with repeats), never on the level.
--
-- Because M is level-independent, a single observed (level, bonus) pair from
-- `skills raw` pins M for that skill exactly enough to project every other
-- level's bonus — see derive_multiplicator(). That's the path the planner
-- uses for skills the character already has. M can also be computed straight
-- from stat values via stat_multiplicator() when we know which stats a skill
-- uses (needed for "what if I raise Intelligence" planning).
--
-- Pure Lua, no host-API dependencies — unit-tested under tests/bonus_test.lua.
-- Formulas: http://bonuses.irreducible.org/formulas.php (cross-checked against
-- tt_dw scripts/char/skills.tin). Worked example from that page:
--   Bonus(100, Int 12, Wis 18 → (12,12,18,18,18)) = 216.

local M = {}

-- The stat-multiplicator coefficient. The reference page gives it as 1/9.8;
-- tt_dw hard-codes the truncated 0.1020408. We use 1/9.8 (the documented
-- value); the difference is ~1.6e-8 and washes out under the final floor.
local STAT_COEFF = 1 / 9.8

-- ---------------------------------------------------------------------
-- R(level) — raw level bonus.
--
--   levels  0–20 : 5   * level
--   levels 21–40 : 2.5 * (level-20) + 100
--   levels 41–60 : 1   * (level-40) + 150
--   levels 61+   : 0.5 * (level-60) + 170
--
-- The 21–40 and 61+ tiers produce half-points; the whole result is floored,
-- which is why past level 61 the bonus only moves on even levels. Flooring
-- once at the end matches tt_dw (the other two tiers are integer-valued).
-- ---------------------------------------------------------------------
function M.raw_level_bonus(level)
  if type(level) ~= "number" or level < 0 then return nil end
  local r
  if level <= 20 then
    r = 5 * level
  elseif level <= 40 then
    r = 2.5 * (level - 20) + 100
  elseif level <= 60 then
    r = 1 * (level - 40) + 150
  else
    r = 0.5 * (level - 60) + 170
  end
  return math.floor(r)
end

-- ---------------------------------------------------------------------
-- M(stats) — stat multiplicator from explicit stat values.
--
-- `stat_values` is the array of the five stat slots a skill uses, WITH
-- repeats, e.g. people.teaching (code "IIIWW") with Int 13, Wis 11 →
-- {13,13,13,11,11}. Returns nil if any value is non-positive (ln undefined)
-- — callers projecting from real characters always have positive stats.
--
--   M = (1/9.8) * ln(product of stat values) - 0.25      (clamped to >= 0)
-- ---------------------------------------------------------------------
function M.stat_multiplicator(stat_values)
  if type(stat_values) ~= "table" then return nil end
  local product = 1
  local n = 0
  for _, v in ipairs(stat_values) do
    if type(v) ~= "number" or v <= 0 then return nil end
    product = product * v
    n = n + 1
  end
  if n == 0 then return nil end
  local m = STAT_COEFF * math.log(product) - 0.25
  if m < 0 then m = 0 end
  return m
end

-- ---------------------------------------------------------------------
-- bonus_for_level — floor(mult * R(level)). `mult` is an M value, whether
-- derived empirically or computed from stats. Returns nil on bad input.
-- ---------------------------------------------------------------------
function M.bonus_for_level(level, mult)
  if type(mult) ~= "number" then return nil end
  local r = M.raw_level_bonus(level)
  if not r then return nil end
  return math.floor(mult * r)
end

-- ---------------------------------------------------------------------
-- derive_multiplicator — back out M from an observed (level, bonus) pair.
--
-- Since bonus = floor(M_true * R(level)), the true M lies in the half-open
-- interval [bonus/R, (bonus+1)/R). We return the midpoint estimate
-- (bonus + 0.5)/R, which minimises worst-case error when projecting to
-- other levels: projected bonuses are exact at the sampled level and at
-- most ~1 off elsewhere. Needs level >= 1 (R(0) = 0 is not invertible).
-- ---------------------------------------------------------------------
function M.derive_multiplicator(level, bonus)
  if type(bonus) ~= "number" then return nil end
  local r = M.raw_level_bonus(level)
  if not r or r <= 0 then return nil end
  return (bonus + 0.5) / r
end

-- ---------------------------------------------------------------------
-- level_for_bonus — smallest integer level whose bonus is >= target_bonus,
-- given a multiplicator. Inverse of bonus_for_level.
--
-- floor(mult * R(L)) >= target  iff  R(L) >= target/mult (target integer),
-- so we find the smallest integer R value that clears the target after the
-- mult-floor, then invert R's piecewise-linear tiers and round the level up.
-- Mirrors tt_dw's @level_for_bonus. Returns nil on bad input, 0 for a
-- non-positive target.
-- ---------------------------------------------------------------------
function M.level_for_bonus(target_bonus, mult)
  if type(target_bonus) ~= "number" or type(mult) ~= "number" or mult <= 0 then
    return nil
  end
  if target_bonus <= 0 then return 0 end
  -- Smallest integer raw-bonus (R value) such that floor(mult*raw) >= target.
  local raw = math.floor(target_bonus / mult)
  if raw < 0 then raw = 0 end
  while math.floor(mult * raw) < target_bonus do raw = raw + 1 end
  -- Invert R: raw thresholds 100/150/170 are R at levels 20/40/60.
  local level
  if raw <= 100 then
    level = raw / 5
  elseif raw <= 150 then
    level = (raw - 100) / 2.5 + 20
  elseif raw <= 170 then
    level = (raw - 150) + 40
  else
    level = (raw - 170) * 2 + 60
  end
  return math.ceil(level)
end

return M
