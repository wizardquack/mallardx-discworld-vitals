-- panel_push.lua — a change-gate around panel:post.
--
-- Mallard re-posts the entire vitals `state` snapshot on every mutation, and
-- many of those mutations don't actually change anything the panel renders: a
-- periodic char.vitals refresh carrying identical numbers, a GP optimistic-regen
-- tick whose formatted value didn't move, an XP bucket whose rate is unchanged.
-- Each post pays fixed iframe-bridge overhead (and lands on the shared 2-worker
-- plugin runtime), so suppressing the redundant ones is the cheapest win — it
-- cuts post *frequency*, which dominates the per-post cost, without touching the
-- wire protocol or the iframe (the panel still receives a full snapshot).
--
-- The caller reuses one `state` table across pushes, so the gate snapshots by
-- value (a deep copy of the last posted state) and compares the next push
-- against that snapshot — never against the live, about-to-mutate reference.

local M = {}

-- Deep value-equality for the plain-data tables vitals posts (scalars, nested
-- tables, arrays). No cycles, functions, or metatables to worry about.
local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, av in pairs(a) do
    if not deep_equal(av, b[k]) then return false end
  end
  -- Catch keys present in b but absent in a (e.g. a key was added).
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do
    out[k] = deep_copy(val)
  end
  return out
end

-- new(post_fn) → { push(state) → bool, post_count }
-- push returns true if it forwarded the state to post_fn, false if suppressed.
function M.new(post_fn)
  local last = nil
  local self = { post_count = 0 }
  function self.push(state)
    if last ~= nil and deep_equal(state, last) then
      return false
    end
    last = deep_copy(state)
    self.post_count = self.post_count + 1
    post_fn(state)
    return true
  end
  -- Unconditional post that reseats the suppression baseline. Used by the panel
  -- "ready" handshake: a freshly (re)opened iframe holds no state, so it must be
  -- repainted even if nothing changed since the last gated post.
  function self.force(state)
    last = deep_copy(state)
    self.post_count = self.post_count + 1
    post_fn(state)
    return true
  end
  return self
end

return M
