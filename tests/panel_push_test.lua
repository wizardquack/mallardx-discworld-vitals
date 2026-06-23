-- Behaviour tests for src/panel_push.lua.
-- Run from project root: `lua tests/panel_push_test.lua`.
--
-- panel_push is a change-gate around panel:post. Mallard re-posts the entire
-- vitals state on every mutation, and most mutations are no-ops (a periodic
-- char.vitals refresh with identical numbers, a GP regen tick that didn't move
-- the formatted value, an XP bucket whose rate is unchanged). Each post pays
-- fixed iframe-bridge overhead, so suppressing the redundant ones is the win.
-- These tests pin the suppression contract, including the in-place-mutation
-- case: callers reuse one `state` table across pushes, so the gate must snapshot
-- by value, not by reference.

package.path = "./src/?.lua;" .. package.path
local panel_push = require("panel_push")

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

-- A recording post function: counts calls and remembers the last payload.
local function recorder()
  local r = { calls = 0, last = nil }
  r.post = function(payload)
    r.calls = r.calls + 1
    r.last = payload
  end
  return r
end

-- ---------------------------------------------------------------------
-- First push always posts.
-- ---------------------------------------------------------------------
test("first push always posts", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  local posted = p.push({ hp = { value = 10, max = 20 } })
  eq(posted, true, "returns true on post")
  eq(r.calls, 1, "post called once")
end)

-- ---------------------------------------------------------------------
-- An identical follow-up push is suppressed.
-- ---------------------------------------------------------------------
test("identical follow-up push is suppressed", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ hp = { value = 10, max = 20 }, burden = 5 })
  local posted = p.push({ hp = { value = 10, max = 20 }, burden = 5 })
  eq(posted, false, "returns false when suppressed")
  eq(r.calls, 1, "post not called again")
end)

-- ---------------------------------------------------------------------
-- A changed scalar re-posts.
-- ---------------------------------------------------------------------
test("changed scalar re-posts", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ hp = { value = 10, max = 20 } })
  local posted = p.push({ hp = { value = 11, max = 20 } })
  eq(posted, true, "returns true on change")
  eq(r.calls, 2, "post called twice")
end)

-- ---------------------------------------------------------------------
-- A deep/nested change re-posts (shields.tpa.detail).
-- ---------------------------------------------------------------------
test("nested change re-posts", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ shields = { tpa = { state = "up", detail = "age 1s" } } })
  local posted = p.push({ shields = { tpa = { state = "up", detail = "age 2s" } } })
  eq(posted, true, "nested mutation detected")
  eq(r.calls, 2, "post called twice")
end)

-- ---------------------------------------------------------------------
-- A change inside an array (xp_chart.series append) re-posts.
-- ---------------------------------------------------------------------
test("array growth re-posts", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ series = { 1, 2, 3 } })
  local posted = p.push({ series = { 1, 2, 3, 4 } })
  eq(posted, true, "array length change detected")
  -- A shrink (oldest dropped) must also re-post.
  local posted2 = p.push({ series = { 2, 3, 4 } })
  eq(posted2, true, "array shift detected")
end)

-- ---------------------------------------------------------------------
-- nil-vs-absent are equivalent: setting a key to nil that was absent is a
-- no-op, and clearing a present key to nil is a change.
-- ---------------------------------------------------------------------
test("clearing a present key re-posts", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ hp = { value = 10, max = 20 }, xp = "1,000" })
  local posted = p.push({ hp = { value = 10, max = 20 } }) -- xp dropped
  eq(posted, true, "key removal detected")
end)

-- ---------------------------------------------------------------------
-- The post forwards the live state object (so the iframe gets the real data,
-- not the internal snapshot copy).
-- ---------------------------------------------------------------------
test("forwards the caller's state object", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  local state = { hp = { value = 1, max = 2 } }
  p.push(state)
  eq(r.last, state, "posts the same table the caller passed")
end)

-- ---------------------------------------------------------------------
-- The in-place-mutation trap: callers reuse one `state` table across pushes.
-- If the gate stored the reference instead of a value snapshot, the second
-- push would compare the table against itself and wrongly suppress.
-- ---------------------------------------------------------------------
test("detects in-place mutation of a reused table", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  local state = { hp = { value = 10, max = 20 } }
  p.push(state)              -- first post
  state.hp.value = 11        -- mutate in place, same table reference
  local posted = p.push(state)
  eq(posted, true, "in-place change detected despite shared reference")
  eq(r.calls, 2, "post called twice")
end)

-- ---------------------------------------------------------------------
-- ...and the converse: a reused table pushed unchanged is still suppressed.
-- ---------------------------------------------------------------------
test("suppresses a reused table that did not change", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  local state = { hp = { value = 10, max = 20 } }
  p.push(state)
  local posted = p.push(state) -- same table, no mutation
  eq(posted, false, "unchanged reused table suppressed")
  eq(r.calls, 1, "post not called again")
end)

-- ---------------------------------------------------------------------
-- force() always posts, even when state is unchanged. The panel "ready"
-- handshake fires on every (re)connect — a freshly opened panel has no state,
-- so its repaint must bypass the gate or it would render blank.
-- ---------------------------------------------------------------------
test("force always posts even when unchanged", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  p.push({ hp = { value = 10, max = 20 } })
  local posted = p.force({ hp = { value = 10, max = 20 } }) -- identical
  eq(posted, true, "force posts despite no change")
  eq(r.calls, 2, "post called twice")
end)

-- ...and force() reseats the baseline, so a following identical normal push is
-- then correctly suppressed.
test("force reseats the suppression baseline", function()
  local r = recorder()
  local p = panel_push.new(r.post)
  local state = { hp = { value = 10, max = 20 } }
  p.force(state)
  local posted = p.push({ hp = { value = 10, max = 20 } })
  eq(posted, false, "normal push after force is suppressed when unchanged")
  eq(r.calls, 1, "force posted once, push suppressed")
end)

print(string.format("\n%d passed", passed))
