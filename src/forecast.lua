-- Per-skill XP forecasting primitives for discworld-vitals.
--
-- This is the stateless query layer the goal planner is built on. Every
-- function is a pure function of (skill state, methods) — no goal-set
-- orchestration, no presentation, no persisted state — so it survives
-- whatever shape the eventual planner UI takes, and a future "simulate
-- spending XP over time" engine is just a loop that calls these with
-- evolving state.
--
-- The one unifying primitive is level_cost(): the cheapest ELIGIBLE way to
-- buy a single level, given the methods available. Everything else is
-- accumulation or search over that:
--   cost_to_target   — sum level_cost from here to a target            (forward)
--   max_under_budget — accumulate level_cost until an XP budget runs out (inverse)
--   next_step        — a single level_cost, framed as the marginal next buy
--
-- Methods are passed in as a list of specs; the caller decides which are
-- AVAILABLE (e.g. only include "guild" for a primary skill, only include
-- "player" when a teacher with a known ETB is around). This keeps guild-
-- primary and teacher-availability data — which we don't model yet — out of
-- the math layer.
--   { kind = "guild" }                                  -- guild advance (<=300)
--   { kind = "self" }                                   -- teach yourself
--   { kind = "player", teacher_etb = N,
--     specialized = bool, label = "Qu, ma.sp.of" }      -- learn from a player
--
-- Pure Lua apart from requiring the sibling math modules; unit-tested under
-- tests/forecast_test.lua.

local bonus      = require("bonus")
local cost       = require("cost")
local skill_data = require("skill_data")

local M = {}

-- Runaway guard for budget searches: per-level cost grows exponentially, so
-- any realistic budget exhausts far below this — it only stops a pathological
-- (infinite budget, always-eligible self-teach) loop.
local DEFAULT_MAX_LEVEL = 5000

-- ---------------------------------------------------------------------
-- multiplicator — resolve a skill's M, encoding the project policy:
-- empirical M from an observed (level, bonus) is exact and preferred; the
-- stat table is the fallback for zero-level skills and stat what-ifs.
--   opts = { level=, bonus=, path=, stats= }
-- Returns (mult, source) where source is "observed" or "stats", or nil.
-- ---------------------------------------------------------------------
function M.multiplicator(opts)
  if type(opts) ~= "table" then return nil end
  if type(opts.bonus) == "number" and type(opts.level) == "number"
     and opts.level >= 1 then
    local m = bonus.derive_multiplicator(opts.level, opts.bonus)
    if m then return m, "observed" end
  end
  if type(opts.path) == "string" and type(opts.stats) == "table" then
    local m = skill_data.multiplicator_for(opts.path, opts.stats)
    if m then return m, "stats" end
  end
  return nil
end

-- ---------------------------------------------------------------------
-- resolve_target_level — normalise a goal to a concrete integer level so
-- everything downstream works in levels.
--   goal = { type = "level", value = N }  -> N
--   goal = { type = "bonus", value = N }  -> smallest level reaching bonus N
-- The bonus form needs a multiplicator. Returns nil on bad input.
-- ---------------------------------------------------------------------
function M.resolve_target_level(mult, goal)
  if type(goal) ~= "table" or type(goal.value) ~= "number" then return nil end
  if goal.type == "level" then
    return math.floor(goal.value)
  elseif goal.type == "bonus" then
    return bonus.level_for_bonus(goal.value, mult)
  end
  return nil
end

-- ---------------------------------------------------------------------
-- level_cost — cheapest eligible way to advance ONE level, the primitive
-- everything else builds on. Returns { cost, kind, method, bonus } for the
-- winning method (`kind` is the category — guild/self/player; `method` is the
-- caller's label, defaulting to the kind, so multiple teachers stay
-- distinguishable), or nil if no method is eligible at this level (e.g. a
-- guild-only skill past 300, or a player teacher whose ETB you've reached).
--
-- `mult` may be nil if the only method is guild (guild cost ignores bonus);
-- self/player are skipped without a multiplicator since their cost needs the
-- current bonus.
-- ---------------------------------------------------------------------
function M.level_cost(level, mult, methods)
  if type(level) ~= "number" or type(methods) ~= "table" then return nil end
  local skill_bonus = bonus.bonus_for_level(level, mult)
  local best
  for _, spec in ipairs(methods) do
    local c, label
    local kind = spec.kind
    if kind == "guild" then
      if level < cost.GUILD_TEACH_MAX_LEVEL then
        c = cost.guild_advance_cost(level)
        label = spec.label or "guild"
      end
    elseif kind == "self" then
      if skill_bonus then
        c = cost.self_teach_cost_per_level(level, skill_bonus)
        label = spec.label or "self"
      end
    elseif kind == "player" then
      if type(spec.teacher_etb) == "number" and skill_bonus
         and skill_bonus < spec.teacher_etb then
        local cetb = cost.capped_teaching_bonus(skill_bonus, spec.teacher_etb,
          spec.specialized)
        c = cost.teach_cost_per_level(level, skill_bonus, cetb)
        label = spec.label or "player"
      end
    end
    if c and (not best or c < best.cost) then
      best = { cost = c, kind = kind, method = label, bonus = skill_bonus }
    end
  end
  return best
end

-- ---------------------------------------------------------------------
-- cost_to_target — total XP to advance from one level to another, picking
-- the cheapest eligible method at EACH level (so a single skill can be
-- guild-advanced early, then learned from a player, then self-taught). To go
-- from L0 to L1 you pay at levels L0..L1-1.
--
-- Returns { total_xp, levels = { {level,bonus,cost,method}, ... },
--           reachable = bool, stalled_at = L | nil }
-- reachable is false (with stalled_at set) if some level has no eligible
-- method before the target — e.g. a guild-only primary aiming past 300.
--
-- The climb is bounded by opts.max_level (default DEFAULT_MAX_LEVEL) so a
-- pathological target can't spin this loop for millions of iterations — e.g. a
-- bonus goal whose tiny multiplicator resolves to an astronomically high level,
-- or a fat-fingered `level 999999` goal. A target beyond the cap is reported as
-- unreachable (stalled_at = the cap), the same shape callers already handle for
-- a level with no eligible method. Real Discworld goals sit far below the cap,
-- so this never affects a legitimate plan.
-- ---------------------------------------------------------------------
function M.cost_to_target(mult, from_level, to_level, methods, opts)
  if type(from_level) ~= "number" or type(to_level) ~= "number" then return nil end
  local max_level = (opts and opts.max_level) or DEFAULT_MAX_LEVEL
  local capped_to = (to_level > max_level) and max_level or to_level
  local rows, total = {}, 0
  local reachable, stalled_at = true, nil
  for level = from_level, capped_to - 1 do
    local lc = M.level_cost(level, mult, methods)
    if not lc then
      reachable, stalled_at = false, level
      break
    end
    rows[#rows + 1] = { level = level, bonus = lc.bonus,
      cost = lc.cost, method = lc.method }
    total = total + lc.cost
  end
  -- The real target lies beyond the sane cap — we stopped short, so it's not
  -- reachable within bounds (don't pass off the partial total as the answer).
  if reachable and capped_to < to_level then
    reachable, stalled_at = false, max_level
  end
  return { total_xp = total, levels = rows,
    reachable = reachable, stalled_at = stalled_at }
end

-- ---------------------------------------------------------------------
-- max_under_budget — the inverse: how far can a skill advance on a fixed XP
-- budget, again taking the cheapest eligible method each level. This is the
-- "what can I afford right now" query.
--
-- Returns { reached_level, reached_bonus, spent_xp,
--           levels = {...}, limited_by = "budget"|"no_method"|"max_level" }
-- reached_level is the level you END at (levels from_level..reached_level-1
-- were bought). limited_by says what stopped the advance.
-- ---------------------------------------------------------------------
function M.max_under_budget(mult, from_level, budget, methods, opts)
  opts = opts or {}
  local max_level = opts.max_level or DEFAULT_MAX_LEVEL
  if type(from_level) ~= "number" or type(budget) ~= "number" then return nil end
  local rows, spent = {}, 0
  local level = from_level
  local limited_by = "max_level"
  while level < max_level do
    local lc = M.level_cost(level, mult, methods)
    if not lc then limited_by = "no_method"; break end
    if spent + lc.cost > budget then limited_by = "budget"; break end
    spent = spent + lc.cost
    rows[#rows + 1] = { level = level, bonus = lc.bonus,
      cost = lc.cost, method = lc.method }
    level = level + 1
  end
  return {
    reached_level = level,
    reached_bonus = bonus.bonus_for_level(level, mult),
    spent_xp      = spent,
    levels        = rows,
    limited_by    = limited_by,
  }
end

-- ---------------------------------------------------------------------
-- next_step — the marginal cost of buying the next single level, framed for
-- cross-skill comparison (a greedy long-horizon allocator picks the skill
-- with the best cost per bonus_gain). Returns nil if no method is eligible.
-- bonus_gain can be 0 on odd levels past 61, where the floor doesn't move —
-- callers comparing cost-per-bonus should handle that.
-- ---------------------------------------------------------------------
function M.next_step(mult, level, methods)
  local lc = M.level_cost(level, mult, methods)
  if not lc then return nil end
  local to_bonus = bonus.bonus_for_level(level + 1, mult)
  local gain
  if to_bonus and lc.bonus then gain = to_bonus - lc.bonus end
  return {
    cost       = lc.cost,
    method     = lc.method,
    from_level = level,
    to_level   = level + 1,
    from_bonus = lc.bonus,
    to_bonus   = to_bonus,
    bonus_gain = gain,
  }
end

return M
