-- Regression tests for src/skills_parser.build_snapshot.
-- Run from project root: `lua tests/skills_parser_test.lua`.
-- (The fuller parser suite lives in the app repo's integration tests; this
-- locks in the orphan-cell crash guard, which is hard to reach from there.)

package.path = "./src/?.lua;" .. package.path
local skills = require("skills_parser")

local passed = 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1; print("PASS: " .. name)
  else print("FAIL: " .. name .. " — " .. tostring(err)); os.exit(1) end
end
local function eq(got, want, ctx)
  assert(got == want,
    (ctx or "value") .. ": expected " .. tostring(want) .. ", got " .. tostring(got))
end

-- A well-formed nested line: parent at depth 0, child at depth 1, grandchild
-- at depth 2 — paths reconstruct in full.
test("build_snapshot reconstructs nested dotted paths", function()
  local line = "covert.   -   -      | hiding.   -   -      | | person.   100   130"
  local snap = skills.build_snapshot({ line })
  eq(snap.level["covert.hiding.person"], 100, "leaf level")
  eq(snap.bonus["covert.hiding.person"], 130, "leaf bonus")
  eq(snap.skill_count, 1, "only the leaf has numbers")
end)

-- The crash regression: a depth-2 cell whose depth-1 parent is missing (an
-- incomplete column grid from a premature mid-stream flush). build_snapshot
-- must drop the orphan, not abort with a concat-over-nil error.
test("build_snapshot drops an orphan cell without crashing", function()
  local line = "covert.   100   130      | | person.   50   60"
  local snap = skills.build_snapshot({ line })
  -- The depth-0 root is kept; the orphan depth-2 cell is dropped.
  eq(snap.level["covert"], 100, "root kept")
  eq(snap.skill_count, 1, "orphan not counted")
  -- No bogus path was stored for the orphan.
  for path in pairs(snap.level) do
    assert(not path:find("person"), "orphan path must not be stored: " .. path)
  end
end)

-- is_partial_regression: the completeness heuristic that replaced the fixed
-- >=100 magnitude floor. A first refresh (no prior) never regresses; a large
-- drop vs. the prior count does.
test("is_partial_regression treats a missing/zero prior as non-regression", function()
  assert(not skills.is_partial_regression(3, nil, 0.75), "nil prior")
  assert(not skills.is_partial_regression(3, 0, 0.75), "zero prior")
end)

test("is_partial_regression flags a collapse but allows growth/steady", function()
  assert(skills.is_partial_regression(40, 190, 0.75), "40 vs 190 is partial")
  assert(not skills.is_partial_regression(150, 190, 0.75), "150 vs 190 is fine")
  assert(not skills.is_partial_regression(200, 190, 0.75), "growth is fine")
  assert(not skills.is_partial_regression(68, 68, 0.75), "steady is fine")
end)

-- try_flush must accept a legitimately small capture (new character) once the
-- structural floor is low, and still drop it under a high floor. This locks in
-- the fix for the reported "only 68 skills (need >= 100)" false drop.
local function drive(min_skills, line)
  local flushed
  local sm = skills.make({ min_skills = min_skills,
    on_flush = function(s) flushed = s end,
    on_log   = function() end })
  sm.arm(0)
  sm.on_header(0)
  sm.on_line(line)
  local ret = sm.try_flush(1)
  return ret, flushed
end

test("try_flush accepts a small legit capture under a low structural floor", function()
  -- Six depth-0 leaves on one line → skill_count 6.
  local line = "aa.  1  2      bb.  3  4      cc.  5  6      "
            .. "dd.  7  8      ee.  9  10      ff.  11  12"
  local ret, flushed = drive(5, line)
  eq(ret ~= nil, true, "accepted under floor 5")
  eq(flushed and flushed.skill_count, 6, "flushed six skills")
end)

test("try_flush still drops a capture below the structural floor", function()
  local line = "aa.  1  2      bb.  3  4      cc.  5  6      "
            .. "dd.  7  8      ee.  9  10      ff.  11  12"
  local ret, flushed = drive(10, line)
  eq(ret, nil, "dropped under floor 10")
  eq(flushed, nil, "on_flush not called on drop")
end)

print(string.format("\n%d skills_parser tests passed.", passed))
