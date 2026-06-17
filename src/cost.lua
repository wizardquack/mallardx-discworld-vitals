-- XP cost math for discworld-vitals skill/goal planning.
--
-- Three ways to advance a skill, cheapest first:
--   guild   — advance a primary at your guild; cost depends only on level.
--   player  — learn from another player; cost depends on your level, your
--             bonus, and the teacher's (capped) effective teaching bonus.
--   self    — teach yourself; same formula as player with the teacher term
--             equal to your own bonus (so the k-factor pins at its max 1.5).
--
-- The per-level learn/self-teach cost is the refined model from
-- teaching-math.php (the irreducible.org XP calculator), which extends the
-- wiki's simpler `k = 1 + 0.5*bonus/teach` with a teacher-effectiveness
-- interpolation and a specialization-aware cap. See teach_cost_per_level().
--
-- Bonus changes every level, so multi-level costs must be summed level by
-- level — that's cost_to_advance(), which leans on src/bonus.lua to get the
-- bonus at each intermediate level from a single multiplicator.
--
-- Pure Lua apart from require("bonus"); unit-tested under tests/cost_test.lua.
-- Formulas: http://bonuses.irreducible.org/formulas.php + teaching-math.php.

local bonus = require("bonus")

local M = {}

-- Guilds only teach a primary skill up to this level; past it you must learn
-- from a player or self-teach. Universal across guilds (confirmed in-game).
M.GUILD_TEACH_MAX_LEVEL = 300

-- ---------------------------------------------------------------------
-- Guild advancement (primaries only). `level` is your CURRENT level in the
-- skill; the result is the XP to advance it by one level.
--   floor( 75 * floor(level/3 + 1) * exp(level/150) )
-- Caller is responsible for knowing the skill is a primary and below its
-- guild max — this module just does the arithmetic.
-- ---------------------------------------------------------------------
function M.guild_advance_cost(level)
  if type(level) ~= "number" or level < 0 then return nil end
  return math.floor(75 * math.floor(level / 3 + 1) * math.exp(level / 150))
end

-- ---------------------------------------------------------------------
-- Effective teaching bonus (ETB) of a teacher in a skill: the average of
-- their bonus in the taught skill and their bonus in the relevant
-- people.teaching.* skill, where the teaching-skill term counts for at most
-- twice the taught-skill bonus.
--   ETB = (taught + min(teaching, 2*taught)) / 2
-- A student can only learn from a teacher whose ETB exceeds the student's
-- own bonus in the skill.
-- ---------------------------------------------------------------------
function M.effective_teaching_bonus(taught_bonus, teaching_bonus)
  if type(taught_bonus) ~= "number" or type(teaching_bonus) ~= "number" then
    return nil
  end
  local capped_teach = math.min(teaching_bonus, 2 * taught_bonus)
  return (taught_bonus + capped_teach) / 2
end

-- ---------------------------------------------------------------------
-- Capped effective teaching bonus (CETB). A teacher's ETB only helps up to
-- a ceiling set by the student's current bonus; specialising in the skill's
-- tree raises that ceiling. Mirrors teaching-math.php's CTB (non-specialist)
-- and STB (specialist).
--   cap = max(bonus+150, bonus*1.35)   non-specialist
--       = max(bonus+200, bonus*1.5)    specialist
--   CETB = min(ETB, cap)
-- ---------------------------------------------------------------------
function M.capped_teaching_bonus(student_bonus, etb, specialized)
  if type(student_bonus) ~= "number" or type(etb) ~= "number" then return nil end
  local cap
  if specialized then
    cap = math.max(student_bonus + 200, student_bonus * 1.5)
  else
    cap = math.max(student_bonus + 150, student_bonus * 1.35)
  end
  return math.min(etb, cap)
end

-- ---------------------------------------------------------------------
-- XP cost to learn ONE level, from teaching-math.php::compute_teaching_cost.
--
--   student_level — current level in the skill
--   student_bonus — current bonus in the skill (on unmodified stats)
--   cetb          — capped effective teaching bonus (use capped_teaching_bonus
--                   for a player teacher; pass student_bonus for self-teach)
--
-- The k-factor blends two caps: `simple_k` is the wiki's 1 + 0.5*bonus/cetb;
-- the interpolated `k` ramps from 1.5 down toward a floor as the teacher's
-- effectiveness approaches the most that's relevant for this student. The
-- smaller of the two wins.
--   cost = 500 + floor( 250 * level * exp(level/500) * k )
-- Self-teach (cetb == bonus) collapses both to k = 1.5.
-- ---------------------------------------------------------------------
function M.teach_cost_per_level(student_level, student_bonus, cetb)
  if type(student_level) ~= "number" or type(student_bonus) ~= "number" then
    return nil
  end
  if type(cetb) ~= "number" or cetb <= 0 then cetb = student_bonus end
  local denom_etb = cetb > 0 and cetb or 1   -- guard the bonus==0 edge

  local maximum_relevant_etb = math.max(student_bonus + 200, student_bonus * 1.5)
  local cost      = 250
  local minimum_k = 0.5 * student_bonus / 800 + 1
  local maximum_k = 1.5
  local simple_k  = 0.5 * student_bonus / denom_etb + 1

  local k
  local denom = maximum_relevant_etb - student_bonus
  if denom <= 0 then
    k = simple_k
  else
    k = maximum_k - (cetb - student_bonus) / denom * (maximum_k - minimum_k)
  end
  if simple_k < k then k = simple_k end

  return 500 + math.floor(cost * student_level
    * math.exp(student_level / 500.0) * k)
end

-- Convenience: self-teaching one level (teacher term == own bonus).
function M.self_teach_cost_per_level(student_level, student_bonus)
  return M.teach_cost_per_level(student_level, student_bonus, student_bonus)
end

-- ---------------------------------------------------------------------
-- XP the TEACHER gains for teaching one level, derived from the student's
-- per-level cost: gain = floor(cost^0.8), halved on a failed teaching check.
-- ---------------------------------------------------------------------
function M.teacher_gain_per_level(student_cost, success)
  if type(student_cost) ~= "number" or student_cost < 0 then return nil end
  local g = student_cost ^ 0.8
  if success == false then g = g / 2 end
  return math.floor(g)
end

-- ---------------------------------------------------------------------
-- Aggregate the XP to advance a skill from one level to another, summing
-- the per-level cost at each intermediate level (bonus is recomputed per
-- level from the multiplicator). Going from L0 to L1 means paying the cost
-- at levels L0, L0+1, ..., L1-1.
--
-- opts:
--   method       "self" (default) | "player" | "guild"
--   mult         skill multiplicator (required for self/player)
--   teacher_etb  teacher's effective teaching bonus (required for player)
--   specialized  teacher is specialised in the skill's tree (player)
--
-- Returns:
--   { total_xp, levels = { {level, bonus, cost}, ... },
--     stopped_at = L | nil, reason = string | nil }
-- Advancement halts early in two cases, flagged via stopped_at/reason with
-- total_xp covering only the levels actually reachable:
--   "player": the student's bonus reaches the teacher's ETB (can't learn past
--             a teacher).
--   "guild" : the level reaches GUILD_TEACH_MAX_LEVEL (guilds stop teaching).
-- Returns nil on missing required inputs.
-- ---------------------------------------------------------------------
function M.cost_to_advance(from_level, to_level, opts)
  opts = opts or {}
  local method = opts.method or "self"
  if type(from_level) ~= "number" or type(to_level) ~= "number" then return nil end

  local needs_mult = (method == "self" or method == "player")
  if needs_mult and type(opts.mult) ~= "number" then return nil end
  if method == "player" and type(opts.teacher_etb) ~= "number" then return nil end

  local rows = {}
  local total = 0
  local stopped_at, reason

  for level = from_level, to_level - 1 do
    local row_bonus, row_cost
    if method == "guild" then
      if level >= M.GUILD_TEACH_MAX_LEVEL then
        stopped_at = level
        reason = "guild_max_reached"
        break
      end
      row_cost = M.guild_advance_cost(level)
    else
      row_bonus = bonus.bonus_for_level(level, opts.mult)
      if not row_bonus then return nil end
      if method == "player" then
        if row_bonus >= opts.teacher_etb then
          stopped_at = level
          reason = "teacher_etb_reached"
          break
        end
        local cetb = M.capped_teaching_bonus(row_bonus, opts.teacher_etb,
          opts.specialized)
        row_cost = M.teach_cost_per_level(level, row_bonus, cetb)
      else
        row_cost = M.self_teach_cost_per_level(level, row_bonus)
      end
    end
    if not row_cost then return nil end
    rows[#rows + 1] = { level = level, bonus = row_bonus, cost = row_cost }
    total = total + row_cost
  end

  return {
    total_xp   = total,
    levels     = rows,
    stopped_at = stopped_at,
    reason     = reason,
  }
end

return M
