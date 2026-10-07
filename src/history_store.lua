-- Persistence for the skill increase history (SQLite via the host `db.*`
-- API — one database file per world, so every row also carries the
-- character it belongs to).
--
-- Two append-only tables, mirroring the two sources in skill_history.lua:
--
--   skill_increases  one row per exact `hskills` line. Natural key
--                    (char, skill, to_level, server_time): each hskills run
--                    repeats the whole session, and the same line can also
--                    arrive via the log backfill, so INSERT OR IGNORE makes
--                    every re-sighting a no-op. Keyed on the game's own
--                    timestamp TEXT rather than our parsed `ts`, so a change
--                    to the zone table can never split one increase in two.
--
--   skill_refreshes  one row per skill whose level rose between two
--                    /skills-refresh snapshots: the window (prev_ts, ts] and
--                    the old/new level and bonus. prev_ts is NULL when the
--                    previous snapshot predates the saved_at stamp.
--
-- Inferred rows are NOT stored — skill_history.reconstruct derives them from
-- these two tables on every read.
--
-- tools/backfill_hskills.py reads the DDL below straight out of this file
-- (every `db.exec([[ … ]])` inside migrate), so keep the DDL there.

local M = {}

function M.migrate()
  db.exec([[
    CREATE TABLE IF NOT EXISTS skill_increases (
      id          INTEGER PRIMARY KEY,
      char        TEXT    NOT NULL,
      ts          INTEGER NOT NULL,          -- unix seconds, from the game's stamp
      server_time TEXT    NOT NULL,          -- verbatim "Wed Oct  7 06:49:46 2026 [PDT]"
      skill       TEXT    NOT NULL,
      levels      INTEGER NOT NULL,
      bonus_delta INTEGER,                   -- NULL for language skills
      to_level    INTEGER NOT NULL,
      to_bonus    INTEGER,                   -- NULL for language skills
      source      TEXT    NOT NULL DEFAULT '' -- '' live trigger, 'log' backfill
    )
  ]])
  db.exec([[
    CREATE UNIQUE INDEX IF NOT EXISTS skill_increases_identity
      ON skill_increases(char, skill, to_level, server_time)
  ]])
  db.exec([[
    CREATE TABLE IF NOT EXISTS skill_refreshes (
      id        INTEGER PRIMARY KEY,
      char      TEXT    NOT NULL,
      ts        INTEGER NOT NULL,            -- this refresh's saved_at
      prev_ts   INTEGER,                     -- previous refresh's saved_at
      skill     TEXT    NOT NULL,
      old_level INTEGER NOT NULL,
      old_bonus INTEGER,
      new_level INTEGER NOT NULL,
      new_bonus INTEGER
    )
  ]])
  db.exec([[
    CREATE UNIQUE INDEX IF NOT EXISTS skill_refreshes_identity
      ON skill_refreshes(char, ts, skill)
  ]])
end

-- INSERT OR IGNORE `cols`/`vals` into `tbl`. The host binds params by
-- walking the array to its length border, so a nil in the middle (a language
-- skill's bonus) would silently truncate the bind list; nils are written as
-- literal NULLs instead and only real values are bound. Returns rows added.
local function insert_or_ignore(tbl, cols, vals)
  local marks, binds = {}, {}
  for i = 1, #cols do
    local v = vals[i]
    if v == nil then
      marks[i] = "NULL"
    else
      marks[i] = "?"
      binds[#binds + 1] = v
    end
  end
  local n = db.exec("INSERT OR IGNORE INTO " .. tbl .. " (" .. table.concat(cols, ", ")
    .. ") VALUES (" .. table.concat(marks, ", ") .. ")", binds)
  return tonumber(n) or 0
end

local INCREASE_COLS = { "char", "ts", "server_time", "skill", "levels",
  "bonus_delta", "to_level", "to_bonus", "source" }
local REFRESH_COLS = { "char", "ts", "prev_ts", "skill", "old_level",
  "old_bonus", "new_level", "new_bonus" }

-- Record one exact increase. Returns true when it was new.
function M.add_increase(char, rec, source)
  return insert_or_ignore("skill_increases", INCREASE_COLS, {
    char, rec.ts, rec.server_time, rec.skill, rec.levels, rec.bonus_delta,
    rec.to_level, rec.to_bonus, source or "",
  }) > 0
end

-- Record the level changes of one refresh (from skill_history.changes_from_diff).
function M.add_refresh(char, ts, prev_ts, changes)
  if #changes == 0 then return end
  db.transaction(function()
    for _, c in ipairs(changes) do
      insert_or_ignore("skill_refreshes", REFRESH_COLS, {
        char, ts, prev_ts, c.skill, c.old_level, c.old_bonus,
        c.new_level, c.new_bonus,
      })
    end
  end)
end

-- Everything recorded for `char`, optionally limited to one skill (`exact`)
-- or a branch and its descendants (`under`). Returns increases, refreshes —
-- the two inputs skill_history.reconstruct takes. Time windows are applied
-- after reconstruction: an inferred row's window depends on refreshes and
-- increases from outside the requested span.
function M.load(char, opts)
  opts = opts or {}
  local filter, params = "", { char }
  if opts.exact then
    filter = " AND skill = ?"
    params[#params + 1] = opts.exact
  elseif opts.under then
    -- substr rather than LIKE: skill paths contain `_`-free dotted names
    -- today, but LIKE would treat any future `_` / `%` as a wildcard.
    filter = " AND (skill = ? OR substr(skill, 1, ?) = ?)"
    params[#params + 1] = opts.under
    params[#params + 1] = #opts.under + 1
    params[#params + 1] = opts.under .. "."
  end
  local increases = db.query([[
    SELECT ts, server_time, skill, levels, bonus_delta, to_level, to_bonus
      FROM skill_increases WHERE char = ?]] .. filter, params)
  local refreshes = db.query([[
    SELECT ts, prev_ts, skill, old_level, old_bonus, new_level, new_bonus
      FROM skill_refreshes WHERE char = ?]] .. filter, params)
  return increases or {}, refreshes or {}
end

-- Distinct skill names with exact history for `char` — lets /skill-history
-- resolve skills that never appear in `skills raw` (languages: "spoken
-- Dwarfish").
function M.skills(char)
  local out = {}
  for _, r in ipairs(db.query(
      "SELECT DISTINCT skill FROM skill_increases WHERE char = ?", { char }) or {}) do
    out[#out + 1] = r.skill
  end
  return out
end

return M
