-- Behaviour tests for src/cost.lua.
-- Run from project root: `lua tests/cost_test.lua`.
--
-- The per-level teaching cost is a port of teaching-math.php. To catch
-- transcription errors we keep an INDEPENDENT re-implementation of that PHP
-- below (ref_teach_cost) and assert cost.lua agrees with it across a grid of
-- inputs — so the test fails if either the port or this reference drifts.

package.path = "./src/?.lua;" .. package.path
local cost  = require("cost")
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

-- Independent reference port of teaching-math.php (CTB/STB + cost).
local function ref_capped_etb(student_bonus, etb, specialized)
  local cap
  if specialized then
    cap = math.max(student_bonus + 200, student_bonus * 1.5)
  else
    cap = math.max(student_bonus + 150, student_bonus * 1.35)
  end
  return math.min(etb, cap)
end

local function ref_teach_cost(student_level, student_bonus, cetb)
  local maximum_relevant_etb = math.max(student_bonus + 200, student_bonus * 1.5)
  local c = 250
  local minimum_k = 0.5 * student_bonus / 800 + 1
  local maximum_k = 1.5
  local simple_k = 0.5 * student_bonus / (cetb ~= 0 and cetb or 1) + 1
  local k = maximum_k
    - (cetb - student_bonus * 1.0) / (maximum_relevant_etb - student_bonus)
    * (maximum_k - minimum_k)
  if simple_k < k then k = simple_k end
  return 500 + math.floor(c * student_level * math.exp(student_level / 500.0) * k)
end

-- ---------------------------------------------------------------------
-- Guild advancement — positive, monotonically increasing with level.
-- ---------------------------------------------------------------------
test("guild_advance_cost is positive and increasing", function()
  local prev = -1
  for _, level in ipairs({ 0, 10, 50, 100, 200, 400 }) do
    local g = cost.guild_advance_cost(level)
    assert(g and g > 0, "guild cost at level " .. level)
    assert(g > prev, "guild cost should increase at level " .. level)
    prev = g
  end
  eq(cost.guild_advance_cost(0), 75, "guild cost at level 0")  -- 75*1*exp(0)
end)

-- ---------------------------------------------------------------------
-- Effective teaching bonus — wiki example: 400 taught + 200 teaching → 300,
-- with the teaching term capped at twice the taught bonus.
-- ---------------------------------------------------------------------
test("effective_teaching_bonus matches wiki example + cap", function()
  eq(cost.effective_teaching_bonus(400, 200), 300, "ETB (400,200)")
  -- teaching bonus capped at 2*taught: (100 + min(500,200))/2 = (100+200)/2.
  eq(cost.effective_teaching_bonus(100, 500), 150, "ETB cap at 2x taught")
end)

-- ---------------------------------------------------------------------
-- Capped teaching bonus (CETB) — specialist ceiling is higher.
-- ---------------------------------------------------------------------
test("capped_teaching_bonus honours specialisation ceiling", function()
  -- Huge ETB, bonus 300: non-spec cap = max(450,405)=450; spec = max(500,450)=500.
  eq(cost.capped_teaching_bonus(300, 9999, false), 450, "non-spec cap")
  eq(cost.capped_teaching_bonus(300, 9999, true),  500, "spec cap")
  -- Modest ETB below the cap passes through unchanged.
  eq(cost.capped_teaching_bonus(300, 400, false), 400, "ETB below cap")
end)

-- ---------------------------------------------------------------------
-- Per-level teaching cost agrees with the independent PHP reference.
-- ---------------------------------------------------------------------
test("teach_cost_per_level matches reference port across a grid", function()
  for _, lvl in ipairs({ 1, 25, 100, 300, 800 }) do
    for _, b in ipairs({ 50, 200, 400, 700 }) do
      for _, etb in ipairs({ b + 10, b + 200, b * 2, 5000 }) do
        for _, spec in ipairs({ false, true }) do
          local cetb = ref_capped_etb(b, etb, spec)
          local got  = cost.teach_cost_per_level(lvl, b, cetb)
          local want = ref_teach_cost(lvl, b, cetb)
          eq(got, want, string.format("cost(lvl=%d,b=%d,etb=%d,spec=%s)",
            lvl, b, etb, tostring(spec)))
        end
      end
    end
  end
end)

-- ---------------------------------------------------------------------
-- Self-teaching collapses the k-factor to 1.5:
--   cost = 500 + floor(375 * level * exp(level/500))
-- ---------------------------------------------------------------------
test("self_teach_cost_per_level pins k at 1.5", function()
  for _, lvl in ipairs({ 1, 100, 500 }) do
    for _, b in ipairs({ 100, 500 }) do
      local want = 500 + math.floor(375 * lvl * math.exp(lvl / 500.0))
      eq(cost.self_teach_cost_per_level(lvl, b), want,
        string.format("self-teach(lvl=%d,b=%d)", lvl, b))
    end
  end
end)

test("learning is never cheaper than self-teaching at the same level", function()
  -- A better teacher should always cost <= self-teaching.
  local lvl, b = 200, 400
  local self_cost = cost.self_teach_cost_per_level(lvl, b)
  local cetb = cost.capped_teaching_bonus(b, 5000, true)
  local taught_cost = cost.teach_cost_per_level(lvl, b, cetb)
  assert(taught_cost <= self_cost,
    "taught " .. taught_cost .. " should be <= self " .. self_cost)
end)

-- ---------------------------------------------------------------------
-- Teacher gain — floor(cost^0.8), halved on a failed check.
-- ---------------------------------------------------------------------
test("teacher_gain_per_level", function()
  eq(cost.teacher_gain_per_level(100000, true),
     math.floor(100000 ^ 0.8), "gain success")
  eq(cost.teacher_gain_per_level(100000, false),
     math.floor((100000 ^ 0.8) / 2), "gain on failed check")
end)

-- ---------------------------------------------------------------------
-- cost_to_advance — multi-level aggregation.
-- ---------------------------------------------------------------------
test("cost_to_advance sums per-level self-teach costs", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  local res = cost.cost_to_advance(100, 103, { method = "self", mult = m })
  assert(res, "result present")
  eq(#res.levels, 3, "three levels")
  local manual = 0
  for level = 100, 102 do
    manual = manual + cost.self_teach_cost_per_level(level,
      bonus.bonus_for_level(level, m))
  end
  eq(res.total_xp, manual, "summed total")
  eq(res.levels[1].level, 100, "first row level")
end)

test("cost_to_advance halts player learning at the teacher's ETB", function()
  local m = bonus.stat_multiplicator({ 13, 13, 13, 11, 11 })
  -- Pick a teacher ETB that the student will reach partway through the range.
  local etb = bonus.bonus_for_level(120, m)
  local res = cost.cost_to_advance(100, 200,
    { method = "player", mult = m, teacher_etb = etb })
  assert(res, "result present")
  eq(res.reason, "teacher_etb_reached", "stop reason")
  assert(res.stopped_at and res.stopped_at < 200, "stopped before target")
  -- Every learned level was strictly below the teacher's ETB.
  for _, row in ipairs(res.levels) do
    assert(row.bonus < etb, "learned level " .. row.level .. " below ETB")
  end
end)

test("cost_to_advance guild method ignores bonus/mult", function()
  local res = cost.cost_to_advance(50, 53, { method = "guild" })
  assert(res, "result present")
  local manual = cost.guild_advance_cost(50)
    + cost.guild_advance_cost(51) + cost.guild_advance_cost(52)
  eq(res.total_xp, manual, "guild total")
end)

test("cost_to_advance guild method halts at the guild teach cap", function()
  local res = cost.cost_to_advance(298, 305, { method = "guild" })
  assert(res, "result present")
  eq(res.reason, "guild_max_reached", "stop reason")
  eq(res.stopped_at, cost.GUILD_TEACH_MAX_LEVEL, "stopped at cap")
  -- Only levels 298 and 299 are learnable at the guild.
  eq(#res.levels, 2, "two learnable levels")
  eq(res.levels[#res.levels].level, 299, "last learnable level")
end)

test("cost_to_advance validates required inputs", function()
  eq(cost.cost_to_advance(100, 110, { method = "self" }), nil, "self needs mult")
  eq(cost.cost_to_advance(100, 110, { method = "player", mult = 1.0 }), nil,
    "player needs teacher_etb")
  local empty = cost.cost_to_advance(100, 100, { method = "guild" })
  eq(empty.total_xp, 0, "no-op range totals zero")
end)

print(string.format("\n%d cost tests passed.", passed))
