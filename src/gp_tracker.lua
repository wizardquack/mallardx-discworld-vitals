-- Optimistic GP regen tracker for discworld-vitals.
--
-- Ported from Quow's UpdateGPGeneration (QuowMinimap.xml:26121). A
-- combat round on Discworld is ~2s; each tick we add `regen` to the
-- current gp and cap at maxgp. Authoritative sources (MXP entity
-- push, char.vitals GMCP, score-brief text trigger) call set() to
-- reconcile — the real value just overwrites the optimistic one.
--
-- Pure Lua, no host-API dependencies. Tests load this file directly
-- into a vanilla mlua::Lua state.

local M = {}

-- regen_per_round: gp added per round (Quow allows 0..6, default 3).
function M.make(regen_per_round)
  local state = {
    gp    = nil,
    maxgp = nil,
    regen = regen_per_round or 3,
  }

  local function set(gp, maxgp)
    state.gp    = gp
    state.maxgp = maxgp
  end

  local function set_regen(n)
    state.regen = n or 0
  end

  -- Advance one combat round. Returns the new gp value if it changed
  -- (so callers know whether to repaint), or nil otherwise.
  local function tick()
    if not state.gp or not state.maxgp or state.regen <= 0 then
      return nil
    end
    if state.gp >= state.maxgp then
      return nil
    end
    local next_gp = state.gp + state.regen
    if next_gp > state.maxgp then
      next_gp = state.maxgp
    end
    state.gp = next_gp
    return next_gp
  end

  local function current()
    return state.gp, state.maxgp
  end

  return {
    set       = set,
    set_regen = set_regen,
    tick      = tick,
    current   = current,
    _state    = state,
  }
end

return M
