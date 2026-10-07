-- Behaviour tests for src/announce.lua.
-- Run from project root: `lua tests/announce_test.lua`.

package.path = "./src/?.lua;" .. package.path
local announce = require("announce")

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

-- A manual stand-in for the host's one-shot timer: `schedule` stashes the
-- flush, `run()` fires it. Everything added between the two lands on one line,
-- which is exactly the update-batch window main.lua buys with mud.delay(0).
local function make_harness(format)
  local lines, flush = {}, nil
  local a = announce.make{
    emit     = function(line) lines[#lines + 1] = line end,
    format   = format,
    schedule = function(fn) flush = fn end,
  }
  return a, lines, function()
    assert(flush ~= nil, "nothing scheduled")
    local fn = flush
    flush = nil
    fn()
  end
end

-- Mirror of main.lua's format_signed so the asserted lines are the ones the
-- plugin really prints.
local function format_signed(n)
  local s = tostring(math.floor(math.abs(n)))
  local rev = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (n < 0 and "-" or "") .. (rev:gsub("^,", ""))
end

-- ---------------------------------------------------------------------
-- Batching.
-- ---------------------------------------------------------------------
test("a single pending delta keeps the one-part shape", function()
  local a, lines, run = make_harness(format_signed)
  a.add("xp", 3728)
  eq(#lines, 0, "nothing emitted before the flush")
  run()
  eq(#lines, 1, "line count")
  eq(lines[1], "{xp: 3,728}", "line")
end)

test("deltas raised in one window combine onto one line", function()
  local a, lines, run = make_harness(format_signed)
  a.add("gp", -106)
  a.add("xp", 3728)
  run()
  eq(#lines, 1, "line count")
  eq(lines[1], "{gp: -106, xp: 3,728}", "line")
end)

test("only one flush is scheduled per window", function()
  local a, lines, run = make_harness(format_signed)
  a.add("gp", -10)
  a.add("xp", 20)
  run()
  -- A second window starts from empty and schedules its own flush.
  a.add("xp", 40)
  run()
  eq(#lines, 2, "line count")
  eq(lines[1], "{gp: -10, xp: 20}", "first line")
  eq(lines[2], "{xp: 40}", "second line")
end)

test("flushing with nothing pending emits nothing", function()
  local a, lines, run = make_harness(format_signed)
  a.add("xp", 5)
  run()
  a.flush()
  eq(#lines, 1, "no empty-brace line")
end)

-- ---------------------------------------------------------------------
-- Ordering — MXP entity callbacks arrive in host dispatch order, so the
-- rendered line must not depend on which handler fired first.
-- ---------------------------------------------------------------------
test("known keys render in canonical order regardless of add order", function()
  local a, lines, run = make_harness(format_signed)
  a.add("xp", 3728)
  a.add("gp", -106)
  run()
  eq(lines[1], "{gp: -106, xp: 3,728}", "line")
end)

test("unknown keys follow the known ones in add order", function()
  local a, lines, run = make_harness(format_signed)
  a.add("hp", -12)
  a.add("burden", 3)
  a.add("xp", 100)
  run()
  eq(lines[1], "{xp: 100, hp: -12, burden: 3}", "line")
end)

-- ---------------------------------------------------------------------
-- Accumulation + input guards.
-- ---------------------------------------------------------------------
test("a repeated key accumulates instead of overwriting", function()
  local a, lines, run = make_harness(format_signed)
  a.add("gp", -40)
  a.add("gp", -66)
  run()
  eq(lines[1], "{gp: -106}", "summed line")
end)

test("non-numeric deltas and empty keys are ignored", function()
  local a, lines, run = make_harness(format_signed)
  a.add("gp", "lots")
  a.add("", 5)
  a.add(nil, 5)
  eq(next(a.pending()), nil, "nothing queued")
  a.add("xp", 1)
  run()
  eq(lines[1], "{xp: 1}", "only the valid delta")
end)

-- ---------------------------------------------------------------------
-- Defaults — no scheduler means flush-inline, one line per add.
-- ---------------------------------------------------------------------
test("without a scheduler each add emits immediately", function()
  local lines = {}
  local a = announce.make{ emit = function(l) lines[#lines + 1] = l end }
  a.add("gp", -106)
  a.add("xp", 3728)
  eq(#lines, 2, "line count")
  eq(lines[1], "{gp: -106}", "first line")
  eq(lines[2], "{xp: 3728}", "second line (default format, no separators)")
end)

print(string.format("\n%d test(s) passed.", passed))
