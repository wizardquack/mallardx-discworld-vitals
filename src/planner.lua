-- Multi-goal skill planning for discworld-vitals.
--
-- The host-free core behind the /goal commands: it takes a character's
-- skills + stats snapshot and a list of goals (each a target level OR bonus
-- for a skill) and returns, per goal, the cost under each named SCENARIO plus
-- the cheapest figure for the headline, and grand totals across goals.
--
-- A "scenario" is just a different methods list handed to forecast — so the
-- two we ship now (optimal-teacher and self-teach) are the cheap and dear
-- ends of a band, and a future "specific teacher" scenario drops in as one
-- more entry between them without touching anything else. The headline cost
-- per goal is the cheapest scenario; the drill-down lists them all.
--
-- Guild advancement folds in automatically (per-level, via forecast) for any
-- skill the caller marks primary — we don't have the guild→primary map yet,
-- so callers pass an empty/absent `primaries` set and guild simply isn't
-- offered until that data lands.
--
-- Pure Lua apart from the sibling math modules; unit-tested under
-- tests/planner_test.lua.

local bonus      = require("bonus")
local forecast   = require("forecast")
local skill_data = require("skill_data")

local M = {}

local function split_dots(s)
  local out = {}
  for part in s:gmatch("[^.]+") do out[#out + 1] = part end
  return out
end

local function clamp01(x)
  if x < 0 then return 0 elseif x > 1 then return 1 else return x end
end

-- ---------------------------------------------------------------------
-- progress_from_baseline — how far a skill has come from a recorded starting
-- point toward its target, measured two ways:
--   by levels — a simple (gained / span) ratio, intuitive but uneven since
--               later levels cost far more XP than early ones;
--   by XP     — invested / total along the OPTIMAL path start→target, so the
--               two figures are internally consistent (invested + remaining =
--               total) and reflect the real, nonlinear effort curve.
-- The XP measure needs the start→target path to be priceable end-to-end; if a
-- level along the way has no eligible method (a stalled forecast) the XP
-- fields are left nil and only the level ratio is reported.
-- ---------------------------------------------------------------------
local function progress_from_baseline(mult, start_level, start_bonus,
                                      from_level, target_level, methods)
  local p = {
    start_level   = start_level,
    start_bonus   = start_bonus,
    levels_gained = from_level - start_level,
    levels_span   = target_level - start_level,
  }
  p.pct_levels = (p.levels_span > 0)
    and clamp01(p.levels_gained / p.levels_span) or 1

  local invested = forecast.cost_to_target(mult, start_level, from_level, methods)
  local total    = forecast.cost_to_target(mult, start_level, target_level, methods)
  if invested and invested.reachable and total and total.reachable then
    p.invested_xp = invested.total_xp
    p.total_xp    = total.total_xp
    p.pct_xp = (total.total_xp > 0)
      and clamp01(invested.total_xp / total.total_xp) or 1
  end
  return p
end

-- ---------------------------------------------------------------------
-- resolve_skill — turn a user-typed skill query into a canonical path,
-- accepting game-style abbreviations against a list of known paths.
--   exact:        "fighting.melee.sword"     -> itself
--   dotted abbrev: "fi.me.sw" / "ma.sp.of"   -> each segment a prefix, same
--                  segment count             -> magic.spells.offensive
--   bare leaf:    "sword"                    -> any skill whose leaf starts so
-- Returns (path, candidates): a single resolved `path` (candidates has just
-- it), or nil with the `candidates` array (empty = no match, >1 = ambiguous).
-- ---------------------------------------------------------------------
function M.resolve_skill(query, known_paths)
  if type(query) ~= "string" or query == "" then return nil, {} end
  query = query:lower()
  for _, p in ipairs(known_paths) do
    if p == query then return p, { p } end
  end

  local qsegs   = split_dots(query)
  local has_dot = query:find(".", 1, true) ~= nil
  local cand, seen = {}, {}
  for _, p in ipairs(known_paths) do
    local psegs = split_dots(p)
    local match = false
    if has_dot then
      if #psegs == #qsegs then
        match = true
        for i = 1, #qsegs do
          if psegs[i]:sub(1, #qsegs[i]) ~= qsegs[i] then match = false; break end
        end
      end
    else
      local leaf = psegs[#psegs]
      if leaf:sub(1, #query) == query then match = true end
    end
    if match and not seen[p] then
      seen[p] = true
      cand[#cand + 1] = p
    end
  end
  table.sort(cand)
  if #cand == 1 then return cand[1], cand end
  return nil, cand
end

-- ---------------------------------------------------------------------
-- scenarios_for — the standard scenario set for a goal. Each is a label + a
-- forecast methods list. Guild is prepended when the skill is primary.
-- "optimal" models the best-possible specialist teacher (huge ETB → the
-- specialist cap binds at every level, the cheapest the formula allows), with
-- self as the fallback floor.
-- ---------------------------------------------------------------------
function M.scenarios_for(is_primary)
  local function methods(extra)
    local m = {}
    if is_primary then m[#m + 1] = { kind = "guild" } end
    for _, e in ipairs(extra) do m[#m + 1] = e end
    return m
  end
  return {
    { key = "optimal", label = "optimal teacher", methods = methods({
        { kind = "self" },
        { kind = "player", teacher_etb = math.huge, specialized = true,
          label = "optimal teacher" },
      }) },
    { key = "self", label = "self-teach", methods = methods({
        { kind = "self" },
      }) },
  }
end

-- ---------------------------------------------------------------------
-- plan_goal — resolve one goal against the snapshot. Returns a row with the
-- starting point, the resolved target level/bonus, a per-scenario cost
-- breakdown, the cheapest (headline) figure, and — when current_xp is given —
-- how far that XP alone would take this skill (the "afford now" view).
--
-- When the goal carries a recorded baseline (goal.start_level/start_bonus,
-- captured at creation), `row.progress` reports how far it has come from that
-- baseline toward the target (see progress_from_baseline). `start_at` is
-- passed straight through for presentation.
--
-- error is set instead when the skill has no resolvable multiplicator
-- ("no_mult": zero-level and not in the stat table, or no stats given) or the
-- goal is malformed ("bad_goal"). `done` marks a goal already met.
-- ---------------------------------------------------------------------
function M.plan_goal(goal, opts)
  opts = opts or {}
  local skills  = opts.skills or {}
  local levels  = skills.level or {}
  local bonuses = skills.bonus or {}
  local path    = goal.skill

  local from_level = levels[path] or 0
  local from_bonus = bonuses[path] or 0
  local is_primary = (opts.primaries and opts.primaries[path]) or false

  local mult, mult_source = forecast.multiplicator({
    level = from_level, bonus = from_bonus, path = path, stats = opts.stats })

  local row = {
    skill = path, goal_type = goal.type,
    from_level = from_level, from_bonus = from_bonus,
    is_primary = is_primary,
  }
  if not mult then row.error = "no_mult"; return row end

  local target_level = forecast.resolve_target_level(mult, goal)
  if not target_level then row.error = "bad_goal"; return row end

  row.mult         = mult
  row.mult_source  = mult_source
  row.target_level = target_level
  row.target_bonus = (goal.type == "bonus") and math.floor(goal.value)
                     or bonus.bonus_for_level(target_level, mult)

  -- Progress from the recorded baseline, priced along the optimal path so it
  -- lines up with the cheapest headline below. Absent for legacy goals whose
  -- baseline hasn't been captured/backfilled yet. Computed before the done
  -- early-return so an already-met goal still reports 100%.
  if type(goal.start_level) == "number" then
    local start_level = goal.start_level
    local start_bonus = goal.start_bonus or bonus.bonus_for_level(start_level, mult)
    local optimal_methods = M.scenarios_for(is_primary)[1].methods
    row.progress = progress_from_baseline(mult, start_level, start_bonus,
      from_level, target_level, optimal_methods)
    row.progress.bonus_gained = from_bonus - start_bonus
    row.progress.start_at = goal.start_at
  end

  if target_level <= from_level then
    row.done = true
    row.cheapest_xp = 0
    row.scenarios = {}
    return row
  end

  local scenarios, cheapest, self_xp = {}, nil, nil
  for _, sc in ipairs(M.scenarios_for(is_primary)) do
    local ct = forecast.cost_to_target(mult, from_level, target_level, sc.methods)
    scenarios[#scenarios + 1] = {
      key = sc.key, label = sc.label,
      total_xp = ct.total_xp, reachable = ct.reachable, stalled_at = ct.stalled_at,
    }
    if ct.reachable then
      if sc.key == "self" then self_xp = ct.total_xp end
      if not cheapest or ct.total_xp < cheapest then cheapest = ct.total_xp end
    end
  end
  row.scenarios   = scenarios
  row.cheapest_xp = cheapest
  row.self_xp     = self_xp

  if type(opts.current_xp) == "number" then
    local optimal_methods = M.scenarios_for(is_primary)[1].methods
    local afford = forecast.max_under_budget(mult, from_level, opts.current_xp,
      optimal_methods)
    row.afford = { level = afford.reached_level, bonus = afford.reached_bonus,
      spent = afford.spent_xp }
  end
  return row
end

-- ---------------------------------------------------------------------
-- plan — run plan_goal over a list of goals and total the cheapest (optimal)
-- and self-teach costs across the reachable, not-yet-met ones.
--   opts = { goals = { {skill, type, value}, ... }, skills = snapshot,
--            stats = stats table, primaries = set, current_xp = N }
-- Returns { goals = {rows}, total_optimal, total_self, done_count }.
-- ---------------------------------------------------------------------
function M.plan(opts)
  opts = opts or {}
  local out = { goals = {}, total_optimal = 0, total_self = 0, done_count = 0 }
  for _, g in ipairs(opts.goals or {}) do
    local row = M.plan_goal(g, opts)
    out.goals[#out.goals + 1] = row
    if row.done then
      out.done_count = out.done_count + 1
    elseif not row.error then
      if row.cheapest_xp then out.total_optimal = out.total_optimal + row.cheapest_xp end
      if row.self_xp then out.total_self = out.total_self + row.self_xp end
    end
  end
  return out
end

return M
