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

print(string.format("\n%d skills_parser tests passed.", passed))
