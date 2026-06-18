-- Behaviour tests for src/planner.lua.
-- Run from project root: `lua tests/planner_test.lua`.

package.path = "./src/?.lua;" .. package.path
local planner    = require("planner")
local forecast   = require("forecast")
local bonus      = require("bonus")
local skill_data = require("skill_data")

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

local KNOWN = {}
for path in pairs(skill_data.STAT_CODES) do KNOWN[#KNOWN + 1] = path end

local STATS = { constitution = 14, dexterity = 13, intelligence = 18,
                strength = 16, wisdom = 17 }

-- ---------------------------------------------------------------------
-- resolve_skill — exact, dotted abbreviation, bare leaf, ambiguity.
-- ---------------------------------------------------------------------
test("resolve_skill exact and dotted abbreviations", function()
  eq((planner.resolve_skill("magic.spells.offensive", KNOWN)),
     "magic.spells.offensive", "exact")
  eq((planner.resolve_skill("ma.sp.of", KNOWN)),
     "magic.spells.offensive", "ma.sp.of")
  eq((planner.resolve_skill("fi.me.sw", KNOWN)),
     "fighting.melee.sword", "fi.me.sw")
end)

test("resolve_skill bare leaf and ambiguity", function()
  eq((planner.resolve_skill("sword", KNOWN)), "fighting.melee.sword", "leaf sword")
  -- "of" as a dotted-less leaf prefix shouldn't resolve uniquely; "teaching"
  -- is a unique leaf though.
  eq((planner.resolve_skill("teaching", KNOWN)), "people.teaching", "leaf teaching")
  local m, cand = planner.resolve_skill("zzzznope", KNOWN)
  eq(m, nil, "no match")
  eq(#cand, 0, "no candidates")
  -- Ambiguous bare leaf returns candidates, not a match ("self" is the leaf
  -- of faith.rituals.{curing,defensive,misc}.self).
  local m2, cand2 = planner.resolve_skill("self", KNOWN)
  eq(m2, nil, "self ambiguous")
  assert(#cand2 > 1, "several *.self candidates")
end)

-- ---------------------------------------------------------------------
-- scenarios_for — optimal + self, guild only when primary.
-- ---------------------------------------------------------------------
test("scenarios_for shape and guild gating", function()
  local s = planner.scenarios_for(false)
  eq(#s, 2, "two scenarios")
  eq(s[1].key, "optimal", "optimal first (cheapest headline)")
  eq(s[2].key, "self", "self second")
  -- No guild method when not primary.
  for _, m in ipairs(s[1].methods) do assert(m.kind ~= "guild", "no guild") end
  -- Guild present when primary.
  local sp = planner.scenarios_for(true)
  local has_guild = false
  for _, m in ipairs(sp[1].methods) do if m.kind == "guild" then has_guild = true end end
  assert(has_guild, "guild added for primary")
end)

-- ---------------------------------------------------------------------
-- plan_goal — observed skill, bonus target, scenario ordering.
-- ---------------------------------------------------------------------
test("plan_goal costs an observed skill, optimal <= self", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 550 },
    { skills = skills })
  eq(row.error, nil, "no error")
  eq(row.mult_source, "observed", "empirical M")
  eq(row.target_bonus, 550, "target bonus")
  assert(row.target_level > 612, "target level beyond current")
  -- Two scenarios, optimal headline <= self.
  eq(#row.scenarios, 2, "two scenarios")
  assert(row.cheapest_xp <= row.self_xp, "optimal <= self")
  -- Headline equals the optimal scenario total.
  eq(row.cheapest_xp, row.scenarios[1].total_xp, "headline is optimal")
end)

test("plan_goal marks an already-met goal done", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 500 },
    { skills = skills })
  eq(row.done, true, "done")
  eq(row.cheapest_xp, 0, "zero cost")
end)

test("plan_goal uses the stat table for a zero-level skill", function()
  local row = planner.plan_goal(
    { skill = "magic.spells.offensive", type = "bonus", value = 200 },
    { skills = {}, stats = STATS })
  eq(row.error, nil, "no error")
  eq(row.mult_source, "stats", "stat-table M")
  eq(row.from_level, 0, "starts at zero")
  assert(row.cheapest_xp and row.cheapest_xp > 0, "has a cost")
end)

test("plan_goal reports no_mult when M is unresolvable", function()
  -- Zero-level skill, no stats → cannot resolve M.
  local row = planner.plan_goal(
    { skill = "magic.spells.offensive", type = "bonus", value = 200 },
    { skills = {} })
  eq(row.error, "no_mult", "no_mult error")
end)

test("plan_goal afford-now reports reachable level under a budget", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 600 },
    { skills = skills, current_xp = 5e6 })
  assert(row.afford, "afford present")
  assert(row.afford.level >= 612, "afford level sane")
  assert(row.afford.spent <= 5e6, "within budget")
end)

-- ---------------------------------------------------------------------
-- plan_goal — progress from a recorded baseline.
-- ---------------------------------------------------------------------
test("plan_goal reports progress from a baseline", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 550,
      start_level = 600, start_bonus = 532, start_at = 1000 },
    { skills = skills })
  assert(row.progress, "progress present")
  eq(row.progress.start_level, 600, "start level")
  eq(row.progress.start_bonus, 532, "start bonus")
  eq(row.progress.levels_gained, 12, "levels gained (612-600)")
  eq(row.progress.bonus_gained, 8, "bonus gained (540-532)")
  eq(row.progress.start_at, 1000, "start_at passed through")
  -- Span is start→target; we're partway, so strictly between 0 and 1 both ways.
  assert(row.progress.levels_span > 0, "positive span")
  assert(row.progress.pct_levels > 0 and row.progress.pct_levels < 1, "level pct partial")
  assert(row.progress.pct_xp and row.progress.pct_xp > 0 and row.progress.pct_xp < 1,
    "xp pct partial")
  -- invested + remaining(optimal) == total along the same optimal path.
  eq(row.progress.invested_xp + row.cheapest_xp, row.progress.total_xp,
    "invested + remaining == total")
end)

test("plan_goal progress is 100% for an already-met goal", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 500,
      start_level = 580, start_bonus = 520, start_at = 1000 },
    { skills = skills })
  eq(row.done, true, "done")
  assert(row.progress, "progress present even when done")
  eq(row.progress.pct_levels, 1, "100% by levels")
  eq(row.progress.pct_xp, 1, "100% by xp")
end)

test("plan_goal omits progress without a baseline", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612 },
    bonus = { ["fighting.melee.sword"] = 540 },
  }
  local row = planner.plan_goal(
    { skill = "fighting.melee.sword", type = "bonus", value = 550 },
    { skills = skills })
  eq(row.progress, nil, "no progress without baseline")
end)

-- ---------------------------------------------------------------------
-- plan — multi-goal totals.
-- ---------------------------------------------------------------------
test("plan totals cheapest and self across goals", function()
  local skills = {
    level = { ["fighting.melee.sword"] = 612, ["adventuring.perception"] = 100 },
    bonus = { ["fighting.melee.sword"] = 540, ["adventuring.perception"] = 130 },
  }
  local res = planner.plan({
    skills = skills,
    goals = {
      { skill = "fighting.melee.sword", type = "bonus", value = 550 },
      { skill = "adventuring.perception", type = "level", value = 150 },
      { skill = "fighting.melee.sword", type = "bonus", value = 500 }, -- already done
    },
  })
  eq(#res.goals, 3, "three rows")
  eq(res.done_count, 1, "one already met")
  -- Totals are the sum of the two active goals' optimal / self figures.
  local g1, g2 = res.goals[1], res.goals[2]
  eq(res.total_optimal, g1.cheapest_xp + g2.cheapest_xp, "optimal total")
  eq(res.total_self, g1.self_xp + g2.self_xp, "self total")
  assert(res.total_optimal <= res.total_self, "optimal cheaper overall")
end)

print(string.format("\n%d planner tests passed.", passed))
