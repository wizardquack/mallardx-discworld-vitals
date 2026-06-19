-- Single-skill inspection for discworld-vitals.
--
-- The host-free core behind the /skill command: given a character's current
-- (level, bonus) for one skill plus their stats, it assembles a structured
-- view of where that skill stands — its level, bonus, the multiplicator M and
-- where M came from, and the per-stat breakdown of which stats feed M (the
-- "contributions" from the skill→stat table).
--
-- When the user also supplies a number, the skill is a target *either* way:
-- read as a desired BONUS it answers "what level reaches it", read as a
-- desired LEVEL it answers "what bonus does it give" — so the user never has
-- to disambiguate which they meant. Each reading flags when the current skill
-- already satisfies it.
--
-- This mirrors the policy in src/forecast.lua: an empirical M backed out of an
-- observed (level, bonus) is exact and preferred; the stat-table M is the
-- fallback for untrained skills (and is reported alongside for context).
--
-- Pure Lua apart from the sibling math modules; unit-tested under
-- tests/skill_query_test.lua.

local bonus      = require("bonus")
local skill_data = require("skill_data")

local M = {}

-- Canonical display order for the five core stats, so contribution lists read
-- consistently regardless of a skill's internal slot ordering in the code.
local STAT_ORDER = { "C", "D", "I", "S", "W" }

-- ---------------------------------------------------------------------
-- stat_contributions — break a skill's 5-letter stat code into a per-stat
-- summary, in canonical C/D/I/S/W order, listing only the stats the skill
-- actually uses. Each entry is { letter, stat, count, value }, where `count`
-- is how many of the five slots that stat fills (its weight) and `value` is
-- the character's current stat reading (nil when no stats are available — we
-- still know the slot count from the code alone).
-- ---------------------------------------------------------------------
local function stat_contributions(code, stats)
  local counts = {}
  for i = 1, #code do
    local letter = code:sub(i, i)
    counts[letter] = (counts[letter] or 0) + 1
  end
  local out = {}
  for _, letter in ipairs(STAT_ORDER) do
    local n = counts[letter]
    if n then
      local name = skill_data.STAT_LETTERS[letter]
      out[#out + 1] = {
        letter = letter, stat = name, count = n,
        value = (type(stats) == "table") and stats[name] or nil,
      }
    end
  end
  return out
end

-- ---------------------------------------------------------------------
-- describe — assemble the full view of one skill.
--   opts = { path=, level=, bonus=, stats=, target= }
-- `level`/`bonus` are the character's current readings (level defaults to 0,
-- bonus is optional — projected from M when absent). `target` is the optional
-- number to read both ways.
--
-- Returns {
--   path, level, bonus,                 -- current state (bonus may be nil)
--   mult, mult_source,                  -- effective M ("observed"|"stats") or nil
--   stat_code, stat_mult,               -- the 5-letter code + stat-derived M
--   contributions = { {letter,stat,count,value}, ... },
--   target = {                          -- present only when a number was given
--     value,
--     no_mult = true,                   -- ...when M couldn't be resolved
--     as_bonus = { value, level_needed, bonus_at_level, already, extra_levels },
--     as_level = { value, bonus_reached, already, extra_bonus },
--   },
-- }
-- ---------------------------------------------------------------------
function M.describe(opts)
  opts = opts or {}
  local path  = opts.path
  local level = (type(opts.level) == "number") and opts.level or 0
  local stats = (type(opts.stats) == "table") and opts.stats or nil
  local code  = skill_data.STAT_CODES[path]

  -- Empirical M is exact when we have an observed (level, bonus); stat-derived
  -- M is the fallback (and kept around for the contributions readout).
  local obs_bonus = (type(opts.bonus) == "number") and opts.bonus or nil
  local mult, mult_source
  if level >= 1 and obs_bonus then
    mult = bonus.derive_multiplicator(level, obs_bonus)
    if mult then mult_source = "observed" end
  end
  local stat_mult = (code and stats) and skill_data.multiplicator_for(path, stats) or nil
  if not mult and stat_mult then
    mult, mult_source = stat_mult, "stats"
  end

  -- Current bonus: the observed reading if we have it, else projected from M.
  local cur_bonus = obs_bonus
  if not cur_bonus and mult then cur_bonus = bonus.bonus_for_level(level, mult) end

  local info = {
    path          = path,
    level         = level,
    bonus         = cur_bonus,
    mult          = mult,
    mult_source   = mult_source,
    stat_code     = code,
    stat_mult     = stat_mult,
    contributions = code and stat_contributions(code, stats) or nil,
  }

  if type(opts.target) ~= "number" then return info end
  local t = math.floor(opts.target)
  if not mult then
    info.target = { value = t, no_mult = true }
    return info
  end

  -- Read t as a target BONUS: the first level whose bonus reaches it.
  local level_needed = bonus.level_for_bonus(t, mult)
  local as_bonus = {
    value          = t,
    level_needed   = level_needed,
    bonus_at_level = level_needed and bonus.bonus_for_level(level_needed, mult) or nil,
    already        = (cur_bonus ~= nil) and (cur_bonus >= t) or false,
  }
  if level_needed then as_bonus.extra_levels = level_needed - level end

  -- Read t as a target LEVEL: the bonus you'd have once there.
  local bonus_reached = bonus.bonus_for_level(t, mult)
  local as_level = {
    value         = t,
    bonus_reached = bonus_reached,
    already       = level >= t,
  }
  if bonus_reached and cur_bonus then as_level.extra_bonus = bonus_reached - cur_bonus end

  info.target = { value = t, as_bonus = as_bonus, as_level = as_level }
  return info
end

return M
