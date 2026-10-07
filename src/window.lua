-- Time-window parsing for /skill-history. Copied verbatim from the sibling
-- mallardx-discworld-teaching plugin (src/window.lua) so both plugins accept
-- exactly the same lookback grammar — keep the two in sync.
--
-- Accepted forms (case-insensitive):
--
--   <n>h  <n>hr  <n>hour  <n>hours      last n hours
--   <n>d  <n>day <n>days                last n days
--   <n>w  <n>wk  <n>week <n>weeks       last n weeks
--   <n>m  <n>mon <n>month <n>months     last n calendar months
--   <n>y  <n>yr  <n>year <n>years       last n calendar years
--   <n>                                 bare number = days
--   today                               since local midnight
--   yesterday                           the previous local day, only
--   all  alltime  all-time  ever  *     no bounds
--
-- Default when no window is given: 1w.
--
-- Hours/days/weeks are fixed spans back from now, which is what you want
-- for "the last 3 days". Months and years walk the calendar instead, so
-- "3m" from the 31st lands on the 31st (clamped to the month's length)
-- rather than 90 days ago. `today` and `yesterday` snap to local
-- midnight, and `yesterday` is the only form with an upper bound.
--
-- Returns a table: { from = unix|nil, to = unix|nil, label = string,
--                    phrase = string, spec = string,
--                    bucket = "hour"|"day"|"week"|"month" }
--
-- `label` names the window ("last week"); `phrase` is the same window as an
-- adverbial, for sentences ("in the last week", "today", "ever"). Two
-- fields rather than one because "No teaching recorded in the yesterday"
-- is what a single field gets you.
--
-- `bucket` is the natural grain for the activity chart over that span,
-- so /teach xp 1d bars by hour and /teach xp all bars by month.

local M = {}

M.DEFAULT = "1w"

local UNIT = {
  h = "hour", hr = "hour", hrs = "hour", hour = "hour", hours = "hour",
  d = "day", day = "day", days = "day",
  w = "week", wk = "week", wks = "week", week = "week", weeks = "week",
  m = "month", mo = "month", mon = "month", month = "month", months = "month",
  y = "year", yr = "year", yrs = "year", year = "year", years = "year",
}

local ALL = {
  all = true, alltime = true, ["all-time"] = true, ever = true,
  ["*"] = true, everything = true,
}

local SECONDS = { hour = 3600, day = 86400, week = 604800 }

-- Local midnight at the start of the day containing `t`.
local function midnight(t)
  local d = os.date("*t", t)
  d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
  return os.time(d)
end

-- Walk back n months (or years) on the calendar, keeping the clock time.
-- os.time normalises out-of-range fields, so month 0 becomes December of
-- the previous year; day-of-month past the end of the target month rolls
-- forward, which we clamp back so "3m" from Mar 31 gives Dec 31, not Jan 1.
local function calendar_back(t, n, unit)
  local d = os.date("*t", t)
  local day = d.day
  if unit == "month" then
    d.month = d.month - n
  else
    d.year = d.year - n
  end
  d.day = 1
  d.isdst = nil
  local first = os.date("*t", os.time(d))
  -- Days in the target month: day 0 of the following month.
  local probe = { year = first.year, month = first.month + 1, day = 0,
                  hour = 12, min = 0, sec = 0 }
  local last_day = os.date("*t", os.time(probe)).day
  first.day = math.min(day, last_day)
  first.hour, first.min, first.sec = d.hour, d.min, d.sec
  first.isdst = nil
  return os.time(first)
end

local function plural(n, noun)
  if n == 1 then return noun end
  return noun .. "s"
end

-- A word that could be a window spec? Used by the command dispatcher to
-- tell `/teach who 3w` from `/teach who Kiki` without ordering rules.
function M.looks_like_spec(word)
  if type(word) ~= "string" then return false end
  local w = word:lower()
  if ALL[w] or w == "today" or w == "yesterday" then return true end
  local n, unit = w:match("^(%d+)(%a*)$")
  if not n then return false end
  return unit == "" or UNIT[unit] ~= nil
end

-- parse(spec, now) -> window | nil, err
function M.parse(spec, now)
  now = now or os.time()
  spec = (spec == nil or spec == "") and M.DEFAULT or tostring(spec)
  local w = spec:lower():gsub("^%s+", ""):gsub("%s+$", "")

  if ALL[w] then
    return { from = nil, to = nil, label = "all time", phrase = "ever",
             spec = "all", bucket = "month" }
  end

  if w == "today" then
    return { from = midnight(now), to = nil, label = "today",
             phrase = "today", spec = "today", bucket = "hour" }
  end

  if w == "yesterday" then
    local start_today = midnight(now)
    return { from = midnight(start_today - 3600), to = start_today,
             label = "yesterday", phrase = "yesterday", spec = "yesterday",
             bucket = "hour" }
  end

  local count, unit_word = w:match("^(%d+)%s*(%a*)$")
  if not count then
    return nil, "unknown time window: " .. spec
  end
  local n = tonumber(count)
  if n < 1 then
    return nil, "time window must be at least 1"
  end
  local unit = (unit_word == "") and "day" or UNIT[unit_word]
  if not unit then
    return nil, "unknown time unit: " .. unit_word
  end

  local from
  if SECONDS[unit] then
    from = now - n * SECONDS[unit]
  else
    from = calendar_back(now, n, unit)
  end

  -- "last week" reads better than "last 1 week"; keep the number for n > 1.
  local label = (n == 1) and ("last " .. unit)
                          or ("last " .. n .. " " .. plural(n, unit))

  -- Pick a bar grain that yields a readable number of buckets.
  local bucket
  if unit == "hour" then
    bucket = "hour"
  elseif unit == "day" then
    bucket = (n <= 2) and "hour" or "day"
  elseif unit == "week" then
    bucket = (n <= 6) and "day" or "week"
  elseif unit == "month" then
    bucket = (n <= 2) and "day" or ((n <= 12) and "week" or "month")
  else
    bucket = "month"
  end

  return { from = from, to = nil, label = label, phrase = "in the " .. label,
           spec = w, bucket = bucket }
end

return M
