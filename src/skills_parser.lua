-- `skills raw` parser for discworld-vitals.
--
-- The wire output is a column-major depth-first tree walk. The header line
--   =======SKILLS=======Level/Unmodified bonus=========================...
-- is the start marker. Each data line is sliced into N variable-width cells
-- (separated by 6+ spaces); cells are read column-by-column (all of col 1
-- top-to-bottom, then col 2, then col 3) to recover the depth-first sequence.
-- Each cell carries its own absolute depth via leading `| ` prefixes; we walk
-- those with a stack to reconstruct dotted paths (`covert.hiding.person`).
--
-- Pure Lua, no host-API dependencies. The state machine is driven by external
-- callbacks (arm/on_header/on_line/try_flush) so tests don't need timers.

local M = {}

-- ---------------------------------------------------------------------
-- Patterns. Tuned against real `skills raw` output captured 2026-06-10.
-- ---------------------------------------------------------------------

-- Start-of-output marker for `mud.trigger` (PCRE/regex flavour, not Lua
-- patterns). Tolerant about trailing `=` count.
M.HEADER_PATTERN = [[^=+SKILLS=+Level/Unmodified bonus=+$]]

-- Absorber pattern: fires on any line containing a skill-shaped cell.
-- Deliberately ignores cell boundaries — the canonical splitter (below) is
-- structural, not whitespace-counted, so this trigger only needs to detect
-- "the line contains the cell pattern at all". A cell is recognisable by
-- `<letter-or-hyphen>+ <dots>+ <ws> <num-or-dash> <ws> <num-or-dash>`.
M.LINE_HAS_SKILL_CELL_PATTERN =
  [[[A-Za-z][\w-]*\.+\s+(?:[\d,]+|-)\s+(?:[\d,]+|-)]]

-- ---------------------------------------------------------------------
-- Pure helpers — exposed so they can be unit-tested in isolation.
-- ---------------------------------------------------------------------

-- Split a raw line into cells by walking the cell *structure* — not by
-- whitespace count. The screen-rendered output uses an 8-space inter-cell
-- gap, but `cols 999` (which is what `skills raw` is rendered against when
-- the server-side width is wider than the screen) packs cells with only
-- 4-space gaps. Intra-cell whitespace also tops out at ~4 spaces (e.g.
-- `    -    -`), so a whitespace-count splitter can't disambiguate.
--
-- Each cell is `<(| )*><name><dots><ws><level><ws><bonus>`. We strictly
-- consume the `| ` depth prefix (2 chars at a time), then match the rest
-- of the cell as a single regex. Advance past the matched cell and repeat.
function M.split_columns(line)
  local cells = {}
  local pos = 1
  local len = #line
  while pos <= len do
    -- Skip inter-cell whitespace.
    local start = line:find("%S", pos)
    if not start then break end
    -- Strictly consume the `| ` depth prefix: 2 chars at a time. Stops at
    -- the first position that isn't exactly `| `. This avoids confusing
    -- a `|` inside the prefix with a `|` from a malformed cell.
    local depth_end = start
    while line:sub(depth_end, depth_end + 1) == "| " do
      depth_end = depth_end + 2
    end
    -- Match the body of the cell at `depth_end`. If it doesn't match we
    -- bail rather than try to recover — real `skills raw` output never
    -- produces malformed cells, and silently skipping junk is preferable
    -- to corrupting the depth-stack walk downstream.
    local _, cell_end = line:find("^[%w%-]+%.+%s+[%d%-,]+%s+[%d%-,]+", depth_end)
    if not cell_end then break end
    cells[#cells + 1] = line:sub(start, cell_end)
    pos = cell_end + 1
  end
  return cells
end

-- Match a single cell. Returns { depth, name, level, bonus } where level/
-- bonus are numbers or nil (for the `-` sentinel). Returns nil on no match.
--
-- Lua patterns don't allow `*` on parenthesised groups (only on character
-- classes), so the depth prefix uses `[| ]*` — depth chars are exactly `|`
-- and space, never anything else, so the over-broad class is safe here.
-- Each level of depth contributes 2 chars (`| `); we count and divide.
function M.parse_cell(cell)
  local depth_prefix, name, level_raw, bonus_raw =
    cell:match("^([| ]*)([%w%-]+)%.*%s+([%d%-,]+)%s+([%d%-,]+)$")
  if not depth_prefix then return nil end
  -- Depth prefix must be `| ` repeated; reject malformed shapes like `||`.
  -- Lua patterns can't quantify capture groups, so validate by walking.
  if #depth_prefix % 2 ~= 0 then return nil end
  for i = 1, #depth_prefix, 2 do
    if depth_prefix:sub(i, i + 1) ~= "| " then return nil end
  end
  local depth = #depth_prefix / 2
  local function parse_num(s)
    if s == "-" then return nil, true end           -- dash sentinel
    -- Tolerate comma thousands separators (e.g. "1,234") — strip then parse.
    local stripped = s:gsub(",", "")
    if stripped:match("^%d+$") then return tonumber(stripped), true end
    return nil, false                                -- malformed
  end
  local level, level_ok = parse_num(level_raw)
  local bonus, bonus_ok = parse_num(bonus_raw)
  if not (level_ok and bonus_ok) then return nil end
  return {
    depth = depth,
    name  = name,
    level = level,                                   -- nil if `-`
    bonus = bonus,                                   -- nil if `-`
  }
end

-- Predicate: does this line look like it contains any skill-cell data?
-- Used as a cheap absorb-or-not check in main.lua's trigger callback.
function M.line_has_cells(line)
  for _, cell in ipairs(M.split_columns(line)) do
    if M.parse_cell(cell) then return true end
  end
  return false
end

-- Build a snapshot from a list of buffered raw lines. Splits each line into
-- cells, reads cells column-major (all col-1 cells in order, then col-2,
-- etc.) — that reassembles the depth-first walk that the renderer flattened
-- into a 2-D layout. A depth-stack reconstructs full dotted paths.
--
-- Returns { bonus = { [path] = N }, level = { [path] = N }, skill_count = K }
-- where `skill_count` counts only cells with non-nil level (category-only
-- dash rows are walked through but not stored).
function M.build_snapshot(lines)
  -- Phase 1: split every line, retain cells in a column-indexed grid.
  --   columns[c][r] = raw cell string from row r, column c
  local columns = {}
  for _, line in ipairs(lines) do
    local cells = M.split_columns(line)
    for c, cell in ipairs(cells) do
      columns[c] = columns[c] or {}
      columns[c][#columns[c] + 1] = cell
    end
  end

  -- Phase 2: walk columns in order, parse each cell, drive depth-stack.
  local stack       = {}
  local bonus_map   = {}
  local level_map   = {}
  local skill_count = 0
  local seen_cells  = 0

  for c = 1, #columns do
    for _, cell in ipairs(columns[c]) do
      local parsed = M.parse_cell(cell)
      if parsed then
        seen_cells = seen_cells + 1
        -- Truncate stack to ancestor range, then push the new node.
        for i = parsed.depth + 2, #stack do stack[i] = nil end
        stack[parsed.depth + 1] = parsed.name
        local path = table.concat(stack, ".", 1, parsed.depth + 1)
        if parsed.level ~= nil then
          level_map[path] = parsed.level
          bonus_map[path] = parsed.bonus
          skill_count = skill_count + 1
        end
      end
      -- Unparseable cells are silently skipped — split_columns is tolerant
      -- enough that this should never trigger on real `skills raw` output;
      -- if it does, we'd rather drop the cell than abort the whole snapshot.
    end
  end

  return {
    bonus       = bonus_map,
    level       = level_map,
    skill_count = skill_count,
    cell_count  = seen_cells,
  }
end

-- ---------------------------------------------------------------------
-- State machine. Three modes:
--   idle       — passive; on_line / on_header are no-ops
--   armed      — /skills-refresh sent `skills raw`; waiting for header.
--                Falls back to `idle` if try_arm_timeout() is called past
--                the arm timeout without a header appearing.
--   collecting — header seen; appending lines into the buffer. Idle flush
--                (via try_flush) is the canonical end signal.
-- ---------------------------------------------------------------------

function M.make(opts)
  opts = opts or {}
  local min_skills     = opts.min_skills     or 200
  local on_flush       = opts.on_flush       or function() end
  local on_log         = opts.on_log         or function() end
  local on_state_change = opts.on_state_change or function() end

  local mode      = "idle"
  local buffer    = {}
  local armed_at  = nil           -- seconds (caller-supplied clock)
  local started_at = nil

  local function set_mode(new_mode)
    if new_mode == mode then return end
    mode = new_mode
    on_state_change(mode)
  end

  local function reset()
    buffer = {}
    armed_at = nil
    started_at = nil
    set_mode("idle")
  end

  -- Called from /skills-refresh BEFORE mud.send("skills raw").
  local function arm(now_seconds)
    buffer = {}
    armed_at = now_seconds
    started_at = nil
    set_mode("armed")
  end

  -- Called when the `===SKILLS===Level/Unmodified bonus===` header fires.
  -- Only flips state if currently armed — protects against parsing a
  -- header that arrived without our slash command (e.g. user typed
  -- `skills raw` directly).
  local function on_header(now_seconds)
    if mode ~= "armed" then return end
    started_at = now_seconds
    set_mode("collecting")
  end

  -- Called from the absorber trigger when a skill-shaped line fires.
  -- Returns true if the line is relevant (caller resets its idle-flush
  -- timer in that case), false otherwise.
  --
  -- Mallard's `mud.trigger` fires once per regex *match*, not per line —
  -- so a packed `skills raw` line with N cells will call us N times with
  -- the same `line`. Dedupe by checking against the most recent buffer
  -- entry. Same-content non-adjacent lines (unlikely for `skills raw`
  -- given unique skill names per parent) would still be stored once each.
  local function on_line(line)
    if mode ~= "collecting" then return false end
    if buffer[#buffer] == line then return true end   -- duplicate fire
    buffer[#buffer + 1] = line
    return true
  end

  -- Called from the idle-flush timer N ms after the last absorbed line.
  -- Returns the snapshot if accepted, or nil if the sanity gate dropped it
  -- (in which case the previous stored snapshot, if any, is preserved by
  -- the caller). Either way the state machine returns to `idle`.
  local function try_flush(now_seconds)
    if mode ~= "collecting" then return nil end
    local snapshot = M.build_snapshot(buffer)
    snapshot.captured_at = now_seconds
    snapshot.duration_seconds =
      (started_at and now_seconds) and (now_seconds - started_at) or nil
    if snapshot.skill_count < min_skills then
      on_log("warn", string.format(
        "skills_parser: dropped snapshot — only %d skills (need >= %d). " ..
        "Was `skills raw` interrupted, or did the format change?",
        snapshot.skill_count, min_skills))
      reset()
      return nil
    end
    reset()
    on_flush(snapshot)
    return snapshot
  end

  -- Called from a watchdog timer to give up on an armed state that never
  -- saw a header. Returns true if the timeout was hit and state was reset.
  local function try_arm_timeout(now_seconds, timeout_seconds)
    if mode ~= "armed" then return false end
    if not armed_at then return false end
    if (now_seconds - armed_at) < (timeout_seconds or 5) then return false end
    on_log("warn",
      "skills_parser: armed timeout — no SKILLS header arrived after " ..
      "/skills-refresh sent `skills raw`. Returning to idle.")
    reset()
    return true
  end

  -- For testing / debugging.
  local function state() return mode end
  local function buffer_size() return #buffer end

  return {
    arm              = arm,
    on_header        = on_header,
    on_line          = on_line,
    try_flush        = try_flush,
    try_arm_timeout  = try_arm_timeout,
    state            = state,
    buffer_size      = buffer_size,
  }
end

return M
