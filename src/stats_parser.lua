-- `score stats` parser for discworld-vitals.
--
-- The wire output is a 2-D grid of `<Name> <dots>+ <value> [unit]` cells.
-- Unlike `skills raw`, the grid is reading-order top-to-bottom-then-left-
-- to-right under cols-driven wrapping, but since every stat name is unique
-- in the snapshot we don't need to recover any tree structure — we just
-- collect every parsed cell into a flat name → value map.
--
-- Pure Lua, no host-API dependencies. The state machine is driven by
-- external callbacks (arm/on_line/try_flush/try_arm_timeout) so tests
-- don't need timers.

local M = {}

-- ---------------------------------------------------------------------
-- Patterns. Tuned against `score stats` output captured 2026-06-12.
-- ---------------------------------------------------------------------

-- Absorber pattern: fires on any line containing a stat-shaped cell.
-- Deliberately coarse — `split_columns` (below) is the structural
-- splitter; this trigger only needs to detect "the line contains the
-- cell shape at all". PCRE/regex flavour, not Lua patterns.
M.LINE_HAS_STAT_CELL_PATTERN = [[[A-Z][a-z]+\s+\.+\s+[\d.]+]]

-- The five core stats that we persist. The grid also carries Height and
-- Weight (with `cm`/`kg` units); we walk those cells to keep the splitter
-- aligned but discard them at the build_snapshot step.
M.KEPT_STATS = {
  constitution = true,
  dexterity    = true,
  intelligence = true,
  strength     = true,
  wisdom       = true,
}

-- ---------------------------------------------------------------------
-- Pure helpers — exposed so they can be unit-tested in isolation.
-- ---------------------------------------------------------------------

-- Split a raw line into cells by walking the cell *structure* — not by
-- whitespace count. Inter-cell gaps shrink as `cols` widens (7 spaces at
-- cols 80, ~3 spaces at cols 999 when a unit-bearing cell is in play),
-- so a whitespace-count splitter can't disambiguate. Each cell is
-- `<name><ws><dots>+<ws><value>[<sp><unit>]`. We strictly match name+
-- dots+value, then optionally extend through a single-space-separated
-- unit if the result is followed by end-of-line or a 2+ space inter-cell
-- gap (distinguishing "176 cm" from the leading space of "       Dexterity").
function M.split_columns(line)
  local cells = {}
  local pos = 1
  local len = #line
  while pos <= len do
    local start = line:find("%S", pos)
    if not start then break end
    -- Match name + dots + value. Anchored at `start` via `^`.
    local _, value_end = line:find("^%a+%s+%.+%s+[%d%.]+", start)
    if not value_end then break end
    -- Optionally consume a unit (` cm`, ` kg`, ...). Only single-space
    -- separation counts as a unit; multi-space means a fresh inter-cell
    -- gap and the next token starts a new cell.
    local _, unit_end = line:find("^ %a+", value_end + 1)
    if unit_end then
      if unit_end >= len or line:sub(unit_end + 1, unit_end + 2) == "  " then
        value_end = unit_end
      end
    end
    cells[#cells + 1] = line:sub(start, value_end)
    pos = value_end + 1
  end
  return cells
end

-- Match a single cell. Returns { name (lowercase), value (number),
-- unit (string or nil) } or nil on no match.
function M.parse_cell(cell)
  local name, value_raw, unit =
    cell:match("^(%a+)%s+%.+%s+([%d%.]+)%s+(%a+)$")
  if not name then
    name, value_raw = cell:match("^(%a+)%s+%.+%s+([%d%.]+)$")
  end
  if not name then return nil end
  local value = tonumber(value_raw)
  if not value then return nil end
  return { name = name:lower(), value = value, unit = unit }
end

-- Predicate: does this line look like it contains any stat-cell data?
-- Used as a cheap absorb-or-not check in main.lua's trigger callback.
function M.line_has_cells(line)
  for _, cell in ipairs(M.split_columns(line)) do
    if M.parse_cell(cell) then return true end
  end
  return false
end

-- Build a snapshot from a list of buffered raw lines. Returns
--   { stats = { [name] = N }, stat_count = K, cell_count = total parsed }
-- where `stats` contains only the five core stats (constitution, dexterity,
-- intelligence, strength, wisdom); Height/Weight cells are parsed but
-- discarded.
function M.build_snapshot(lines)
  local stats      = {}
  local stat_count = 0
  local cell_count = 0
  for _, line in ipairs(lines) do
    for _, cell in ipairs(M.split_columns(line)) do
      local parsed = M.parse_cell(cell)
      if parsed then
        cell_count = cell_count + 1
        if M.KEPT_STATS[parsed.name] and stats[parsed.name] == nil then
          stats[parsed.name] = parsed.value
          stat_count = stat_count + 1
        end
      end
    end
  end
  return {
    stats      = stats,
    stat_count = stat_count,
    cell_count = cell_count,
  }
end

-- ---------------------------------------------------------------------
-- State machine. Two modes:
--   idle       — passive; on_line is a no-op
--   collecting — /stats-refresh sent `score stats`; absorbing cells.
--                Returns to idle via try_flush (lines stopped arriving)
--                or try_arm_timeout (no lines arrived at all).
--
-- `score stats` has no sniffable header line, so unlike skills_parser
-- we go straight idle → collecting on arm() rather than having an
-- intermediate "armed waiting for header" mode.
-- ---------------------------------------------------------------------

function M.make(opts)
  opts = opts or {}
  local min_stats       = opts.min_stats or 5
  local on_flush        = opts.on_flush or function() end
  local on_log          = opts.on_log or function() end
  local on_state_change = opts.on_state_change or function() end

  local mode       = "idle"
  local buffer     = {}
  local armed_at   = nil
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

  -- Called from /stats-refresh BEFORE mud.send("score stats").
  local function arm(now_seconds)
    buffer = {}
    armed_at = now_seconds
    started_at = now_seconds
    set_mode("collecting")
  end

  -- Called from the absorber trigger when a stat-shaped line fires.
  -- Returns true if the line is relevant (caller resets its idle-flush
  -- timer in that case), false otherwise.
  --
  -- `mud.trigger` fires once per regex *match*, not per line — a packed
  -- cols-999 line with 7 cells calls us 7 times with the same `line`.
  -- Dedupe by checking against the most recent buffer entry.
  local function on_line(line)
    if mode ~= "collecting" then return false end
    if buffer[#buffer] == line then return true end
    buffer[#buffer + 1] = line
    return true
  end

  -- Called from the idle-flush timer N ms after the last absorbed line.
  -- Returns the snapshot if accepted, or nil if the sanity gate dropped
  -- it (in which case any previous stored snapshot is preserved). Either
  -- way the state machine returns to `idle`.
  local function try_flush(now_seconds)
    if mode ~= "collecting" then return nil end
    local snapshot = M.build_snapshot(buffer)
    snapshot.captured_at = now_seconds
    snapshot.duration_seconds =
      (started_at and now_seconds) and (now_seconds - started_at) or nil
    if snapshot.stat_count < min_stats then
      on_log("warn", string.format(
        "stats_parser: dropped snapshot — only %d stats (need >= %d). " ..
        "Was `score stats` interrupted, or did the format change?",
        snapshot.stat_count, min_stats))
      reset()
      return nil
    end
    reset()
    on_flush(snapshot)
    return snapshot
  end

  -- Called from a watchdog timer to give up on a collecting state that
  -- never absorbed any lines. Returns true if the timeout was hit and
  -- state was reset.
  local function try_arm_timeout(now_seconds, timeout_seconds)
    if mode ~= "collecting" then return false end
    if not armed_at then return false end
    if #buffer > 0 then return false end
    if (now_seconds - armed_at) < (timeout_seconds or 5) then return false end
    on_log("warn",
      "stats_parser: armed timeout — no `score stats` output arrived " ..
      "after /stats-refresh. Returning to idle.")
    reset()
    return true
  end

  -- For testing / debugging.
  local function state() return mode end
  local function buffer_size() return #buffer end

  return {
    arm             = arm,
    on_line         = on_line,
    try_flush       = try_flush,
    try_arm_timeout = try_arm_timeout,
    state           = state,
    buffer_size     = buffer_size,
  }
end

return M
