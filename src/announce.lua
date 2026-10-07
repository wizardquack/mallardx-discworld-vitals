-- announce.lua — batches vitals' `{…}` game-output notes onto one line.
--
-- The plugin announces a few per-update deltas (an XP gain, a GP loss) as
-- short brace-wrapped notes. Each delta is detected in its own handler — gp
-- and xp arrive as separate MXP entity callbacks even when the game sent them
-- in a single update — so emitting at detection time printed one line each:
--
--   {gp: -106}
--   {xp: 3,728}
--
-- This batcher collects everything raised during one update and emits it as a
-- single note, falling back to the old single-part shape when only one delta
-- is pending:
--
--   {gp: -106, xp: 3,728}
--
-- Pure Lua, no host-API dependencies: the caller injects `emit` (print one
-- line), `schedule` (run the flush once the current update has finished
-- dispatching) and `format` (render one signed delta), so it unit-tests
-- standalone with a manual scheduler. See tests/announce_test.lua.
--
-- Usage:
--   local announcer = require("announce").make{
--     emit     = mud.note,
--     schedule = function(fn) mud.delay(0, fn) end,
--     format   = format_signed,
--   }
--   announcer.add("gp", -106)   -- queued, not printed
--   announcer.add("xp", 3728)   -- joins the same line

local M = {}

-- Canonical left-to-right order for the keys we know about, so a combined
-- line reads the same regardless of which handler happened to fire first
-- (MXP entity callbacks arrive in host dispatch order, which we don't
-- control). Keys missing from this table sort after the known ones, in the
-- order they were added.
local ORDER = { gp = 1, xp = 2 }

-- Rank offset for unknown keys. Any value above the largest ORDER entry works;
-- ranking on a single number keeps the sort comparator a total order (one that
-- can answer "true" both ways is undefined behaviour in table.sort).
local UNKNOWN_BASE = 1000

local function default_format(n) return tostring(n) end

function M.make(opts)
  opts = opts or {}
  local emit     = opts.emit     or function() end
  local format   = opts.format   or default_format
  -- No scheduler supplied means no batching: flush inline, one line per add.
  local schedule = opts.schedule or function(fn) fn() end

  local deltas  = {}     -- key → signed delta pending announcement
  local order   = {}     -- key → add-order index, tiebreak for unknown keys
  local keys    = {}     -- pending keys, in add order
  local armed   = false  -- is a flush already scheduled?

  local function rank(key)
    return ORDER[key] or (UNKNOWN_BASE + order[key])
  end

  local function flush()
    armed = false
    if #keys == 0 then return end

    local sorted = {}
    for i, k in ipairs(keys) do sorted[i] = k end
    table.sort(sorted, function(a, b) return rank(a) < rank(b) end)

    local parts = {}
    for _, k in ipairs(sorted) do
      parts[#parts + 1] = k .. ": " .. format(deltas[k])
    end

    -- Clear before emitting so anything the emit path raises re-entrantly
    -- starts a fresh batch rather than being wiped by this one.
    deltas, order, keys = {}, {}, {}
    emit("{" .. table.concat(parts, ", ") .. "}")
  end

  -- Queue one signed delta for the next flush. A key already queued
  -- accumulates rather than overwriting: if two game updates land inside the
  -- same batching window, the line should report their combined movement, not
  -- just the later one's.
  local function add(key, delta)
    if type(key) ~= "string" or key == "" or type(delta) ~= "number" then return end
    if deltas[key] == nil then
      keys[#keys + 1] = key
      order[key]      = #keys
      deltas[key]     = delta
    else
      deltas[key] = deltas[key] + delta
    end
    if not armed then
      armed = true
      schedule(flush)
    end
  end

  return {
    add     = add,
    flush   = flush,
    pending = function() return deltas end,
  }
end

return M
