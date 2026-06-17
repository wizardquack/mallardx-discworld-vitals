-- Behaviour tests for src/skill_data.lua.
-- Run from project root: `lua tests/skill_data_test.lua`.
--
-- Spot-checks the ported table against data.tin entries and exercises the
-- code-expansion + multiplicator helpers. The full 251-row table is trusted
-- from its mechanical port; these tests guard the access logic and a sample
-- of entries that the planner relies on.

package.path = "./src/?.lua;" .. package.path
local skill_data = require("skill_data")
local bonus      = require("bonus")

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

local function same(a, b, ctx)
  assert(#a == #b, (ctx or "array") .. ": length " .. #a .. " vs " .. #b)
  for i = 1, #a do eq(a[i], b[i], (ctx or "array") .. "[" .. i .. "]") end
end

-- ---------------------------------------------------------------------
-- Table coverage + spot checks against data.tin.
-- ---------------------------------------------------------------------
test("known sample skills carry their data.tin codes", function()
  eq(skill_data.STAT_CODES["people.teaching"], "IIIWW", "people.teaching")
  eq(skill_data.STAT_CODES["people.teaching.magic"], "IISWW", "people.teaching.magic")
  eq(skill_data.STAT_CODES["magic.spells.offensive"], "WSSII", "ma.sp.offensive")
  eq(skill_data.STAT_CODES["fighting.melee.sword"], "DDDSS", "melee.sword")
  eq(skill_data.STAT_CODES["magic.methods.mental.animating"], "IIIII", "animating")
  eq(skill_data.STAT_CODES["adventuring.perception"], "IIWWW", "perception")
end)

test("is_known distinguishes table membership", function()
  eq(skill_data.is_known("people.teaching"), true, "known")
  eq(skill_data.is_known("not.a.real.skill"), false, "unknown")
  eq(skill_data.is_known(42), false, "non-string")
end)

test("table covers all seven roots", function()
  for _, root in ipairs({ "adventuring", "covert", "crafts", "faith",
    "fighting", "magic", "people" }) do
    assert(skill_data.is_known(root), "root " .. root .. " present")
  end
end)

-- ---------------------------------------------------------------------
-- teaching_skill_for — relevant people.teaching.<root>.
-- ---------------------------------------------------------------------
test("teaching_skill_for maps to people.teaching.<root>", function()
  eq(skill_data.teaching_skill_for("magic.spells.offensive"),
     "people.teaching.magic", "magic branch")
  eq(skill_data.teaching_skill_for("fighting.melee.sword"),
     "people.teaching.fighting", "fighting branch")
  eq(skill_data.teaching_skill_for("adventuring"),
     "people.teaching.adventuring", "bare root")
  eq(skill_data.teaching_skill_for(nil), nil, "nil input")
end)

-- ---------------------------------------------------------------------
-- stat_values_for — expand a code into the five stat values, in order.
-- ---------------------------------------------------------------------
test("stat_values_for expands codes against a stats table", function()
  local stats = { constitution = 14, dexterity = 12, intelligence = 18,
                  strength = 16, wisdom = 11 }
  -- people.teaching = IIIWW → Int,Int,Int,Wis,Wis.
  same(skill_data.stat_values_for("people.teaching", stats),
       { 18, 18, 18, 11, 11 }, "IIIWW")
  -- fighting.melee.sword = DDDSS → Dex,Dex,Dex,Str,Str.
  same(skill_data.stat_values_for("fighting.melee.sword", stats),
       { 12, 12, 12, 16, 16 }, "DDDSS")
end)

test("stat_values_for fails closed on unknown skill or missing stat", function()
  local stats = { constitution = 14, dexterity = 12, intelligence = 18,
                  strength = 16, wisdom = 11 }
  eq(skill_data.stat_values_for("not.real", stats), nil, "unknown skill")
  -- adventuring.perception = IIWWW needs wisdom; drop it.
  local partial = { intelligence = 18 }
  eq(skill_data.stat_values_for("adventuring.perception", partial), nil,
     "missing stat")
end)

-- ---------------------------------------------------------------------
-- multiplicator_for — the "from stats" M, consistent with bonus.lua.
-- ---------------------------------------------------------------------
test("multiplicator_for matches stat_multiplicator of expanded values", function()
  local stats = { constitution = 14, dexterity = 12, intelligence = 12,
                  strength = 16, wisdom = 18 }
  -- adventuring.perception = IIWWW → (12,12,18,18,18), the page example → 1.14195.
  local m = skill_data.multiplicator_for("adventuring.perception", stats)
  assert(m and math.abs(m - 1.14195) < 1e-4,
    "perception M ~1.14195, got " .. tostring(m))
  -- Equivalent to expanding then calling bonus.stat_multiplicator directly.
  local direct = bonus.stat_multiplicator(
    skill_data.stat_values_for("adventuring.perception", stats))
  eq(m, direct, "consistent with bonus.stat_multiplicator")
end)

print(string.format("\n%d skill_data tests passed.", passed))
