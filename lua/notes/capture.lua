-- notes.nvim: capture - daily/weekly notes and clipboard image paste
local util = require("notes.util")
local vault = require("notes.vault")
local template = require("notes.template")

local M = {}

local function cfg()
  return require("notes").config
end

-- ── dates (pure) ─────────────────────────────────────────────────────

--- `t` shifted by n days (noon-based, so DST changes cannot skip/repeat a day).
function M._add_days(t, n)
  local d = os.date("*t", t)
  d.day = d.day + n
  d.hour, d.min, d.sec = 12, 0, 0
  d.isdst = nil
  return os.time(d)
end

local function iso_weekday(t)
  local wday = os.date("*t", t).wday -- 1 = Sunday
  return wday == 1 and 7 or wday - 1 -- 1 = Monday
end

function M._monday_of(t)
  return M._add_days(t, -(iso_weekday(t) - 1))
end

--- Monday of ISO week `w` of ISO year `y`.
function M._iso_monday(y, w)
  local jan4 = os.time({ year = y, month = 1, day = 4, hour = 12 }) -- always in week 1
  return M._add_days(jan4, -(iso_weekday(jan4) - 1) + (w - 1) * 7)
end

--- Lua pattern + token names for an os.date format made of %Y %G %m %d %V and literals.
function M._fmt_pattern(fmt)
  local names, parts = {}, {}
  local i = 1
  while i <= #fmt do
    local c = fmt:sub(i, i)
    if c == "%" then
      local t = fmt:sub(i + 1, i + 1)
      if t == "Y" or t == "G" then
        parts[#parts + 1] = "(%d%d%d%d)"
        names[#names + 1] = t
      elseif t == "m" or t == "d" or t == "V" then
        parts[#parts + 1] = "(%d%d)"
        names[#names + 1] = t
      elseif t == "%" then
        parts[#parts + 1] = "%%"
      else
        return nil -- unsupported token: cannot parse names back into dates
      end
      i = i + 2
    else
      parts[#parts + 1] = (c:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
      i = i + 1
    end
  end
  return "^" .. table.concat(parts) .. "$", names
end

function M._parse(fmt, name)
  local pat, names = M._fmt_pattern(fmt)
  if not pat then
    return nil
  end
  local caps = { name:match(pat) }
  if #caps == 0 then
    return nil
  end
  local out = {}
  for i, n in ipairs(names) do
    out[n] = tonumber(caps[i])
  end
  return out
end

function M._time_of(p)
  if p.Y and p.m and p.d then
    return os.time({ year = p.Y, month = p.m, day = p.d, hour = 12 })
  end
  if p.G and p.V then
    return M._iso_monday(p.G, p.V)
  end
  return nil
end

-- ── periodic notes ───────────────────────────────────────────────────

local function period_dir(root, kind)
  local c = cfg()
  local d = util.expand_path(kind == "daily" and c.daily_dir or c.weekly_dir)
  return d:sub(1, 1) == "/" and d or (root .. "/" .. d)
end

local function period_ctx(kind, t)
  local c = cfg()
  if kind == "daily" then
    return {
      date = os.date(c.date_format, t),
      yesterday = os.date(c.daily_format, M._add_days(t, -1)),
      tomorrow = os.date(c.daily_format, M._add_days(t, 1)),
      weekday = os.date("%A", t),
    }
  end
  local monday = M._monday_of(t)
  return {
    date = os.date(c.date_format, monday),
    week_start = os.date(c.date_format, monday),
    prev_week = os.date(c.weekly_format, M._add_days(t, -7)),
    next_week = os.date(c.weekly_format, M._add_days(t, 7)),
  }
end

local function open_period(kind, t)
  local root = vault.require_root()
  if not root then
    return
  end
  local c = cfg()
  local name = os.date(kind == "daily" and c.daily_format or c.weekly_format, t)
  local dir = period_dir(root, kind)
  local path = util.expand_path(dir .. "/" .. name .. ".md")
  local is_new = vim.uv.fs_stat(path) == nil
  vim.fn.mkdir(dir, "p")
  template.forced[path] = false -- the periodic template replaces the default auto-inject
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  template.forced[path] = nil
  if not ok then
    util.notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  if is_new then
    local tname = kind == "daily" and c.daily_template or c.weekly_template
    if tname then
      local ctx = period_ctx(kind, t)
      vim.schedule(function()
        template.inject(vim.api.nvim_get_current_buf(), tname, { ctx = ctx })
      end)
    end
  end
end

local function parse_when(arg, step_days)
  local now = os.time()
  if not arg or arg == "" then
    return now
  end
  local y, m, d = arg:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if y then
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  end
  local n = tonumber(arg)
  if n then
    return M._add_days(now, n * step_days)
  end
  return nil
end

--- Open (creating from daily_template) today's note, or arg = offset in days / YYYY-MM-DD.
function M.daily(arg)
  local t = parse_when(arg, 1)
  if not t then
    util.notify("usage: :NoteDaily [days-offset | YYYY-MM-DD]", vim.log.levels.WARN)
    return
  end
  open_period("daily", t)
end

--- Open this week's note, or arg = offset in weeks / any YYYY-MM-DD inside the week.
function M.weekly(arg)
  local t = parse_when(arg, 7)
  if not t then
    util.notify("usage: :NoteWeekly [weeks-offset | YYYY-MM-DD]", vim.log.levels.WARN)
    return
  end
  open_period("weekly", t)
end

--- Which periodic note is the current buffer? Returns kind, time | nil.
local function current_period()
  local root = vault.get_root()
  local abs = util.expand_path(vim.api.nvim_buf_get_name(0))
  if not root or abs == "" then
    return nil
  end
  local c = cfg()
  local name = vim.fn.fnamemodify(abs, ":t:r")
  for _, kind in ipairs({ "daily", "weekly" }) do
    if vim.fs.dirname(abs) == util.expand_path(period_dir(root, kind)) then
      local p = M._parse(kind == "daily" and c.daily_format or c.weekly_format, name)
      local t = p and M._time_of(p)
      if t then
        return kind, t
      end
    end
  end
  return nil
end

--- Next (dir = 1) / previous (dir = -1) daily or weekly note relative to the current one.
function M.step(dir)
  local kind, t = current_period()
  if not kind then
    util.notify("not in a daily/weekly note (or its format cannot be parsed back)", vim.log.levels.WARN)
    return
  end
  open_period(kind, M._add_days(t, dir * (kind == "daily" and 1 or 7)))
end

-- ── clipboard image paste ────────────────────────────────────────────

local TYPES = { "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp" }
local EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/webp"] = "webp", ["image/gif"] = "gif", ["image/bmp"] = "bmp" }

--- Best image type out of a newline separated clipboard type list.
function M._pick_type(list_text)
  local have = {}
  for t in list_text:gmatch("[^\r\n]+") do
    have[vim.trim(t)] = true
  end
  for _, t in ipairs(TYPES) do
    if have[t] then
      return t
    end
  end
  return nil
end

--- Folder pasted images go to: attachment_dir (first entry), else an existing conventional
--- folder in the vault root, else <vault>/attachments.
function M._paste_dir(root, c)
  local ad = c.attachment_dir
  if type(ad) == "table" then
    ad = ad[1]
  end
  if type(ad) == "string" and ad ~= "" then
    ad = util.expand_path(ad)
    return ad:sub(1, 1) == "/" and ad or (root .. "/" .. ad)
  end
  for _, d in ipairs(c.attachment_dirs or {}) do
    if vim.fn.isdirectory(root .. "/" .. d) == 1 then
      return root .. "/" .. d
    end
  end
  return root .. "/attachments"
end

function M._link_text(style, img_abs, note_abs, root)
  local fname = vim.fs.basename(img_abs)
  if style == "wiki" then
    return "![[" .. fname .. "]]"
  end
  local from = note_abs ~= "" and vim.fs.dirname(note_abs) or root
  local rel = util.relative_path(from, img_abs)
  rel = rel:gsub(" ", "%%20")
  local alt = fname:gsub("%.%w+$", "")
  return ("![%s](%s)"):format(alt, rel)
end

local function sanitize(name, ext)
  name = vim.trim(name)
  name = name:gsub("%." .. ext .. "$", "")
  name = name:gsub("[%c/\\]", "-")
  name = name:gsub("%s+", "-")
  name = name:gsub("^%.+", "")
  return name
end

local function unique_path(dir, name, ext)
  local path = dir .. "/" .. name .. "." .. ext
  local i = 0
  while vim.uv.fs_stat(path) do
    i = i + 1
    path = ("%s/%s-%d.%s"):format(dir, name, i, ext)
  end
  return path
end

local function exe(n)
  return vim.fn.executable(n) == 1
end

local function backend()
  local env = vim.env
  if env.WAYLAND_DISPLAY and exe("wl-paste") then
    return {
      name = "wl-paste",
      list = { "wl-paste", "--list-types" },
      get = function(t)
        return { "wl-paste", "--no-newline", "--type", t }
      end,
    }
  end
  if env.DISPLAY and exe("xclip") then
    return {
      name = "xclip",
      list = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
      get = function(t)
        return { "xclip", "-selection", "clipboard", "-t", t, "-o" }
      end,
    }
  end
  if exe("pngpaste") then
    return { name = "pngpaste", direct = true } -- macOS: `pngpaste <file>`, png only
  end
  return nil
end

local function run(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd):wait(8000)
  end)
  if ok and res and res.code == 0 then
    return res
  end
  return nil
end

--- Save the clipboard image into the attachment folder and insert a link at the cursor.
function M.paste_image(name_arg)
  local root = vault.require_root()
  if not root then
    return
  end
  local be = backend()
  if not be then
    util.notify("no clipboard tool found (install wl-clipboard, xclip or pngpaste)", vim.log.levels.WARN)
    return
  end
  local itype = "image/png"
  if not be.direct then
    local res = run(be.list)
    itype = res and M._pick_type(res.stdout or "")
    if not itype then
      util.notify("the clipboard does not contain an image", vim.log.levels.WARN)
      return
    end
  end
  local ext = EXT[itype]
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()

  local function save(name)
    name = sanitize(name or "", ext)
    if name == "" then
      return
    end
    local c = cfg()
    local dir = M._paste_dir(root, c)
    vim.fn.mkdir(dir, "p")
    local path = unique_path(dir, name, ext)
    if be.direct then
      if not run({ "pngpaste", path }) then
        util.notify("pngpaste failed", vim.log.levels.ERROR)
        return
      end
    else
      local res = run(be.get(itype))
      if not res or not res.stdout or #res.stdout == 0 then
        util.notify("could not read the image from the clipboard", vim.log.levels.ERROR)
        return
      end
      local f, err = io.open(path, "wb")
      if not f then
        util.notify("cannot write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      f:write(res.stdout)
      f:close()
    end
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
      util.notify("saved " .. path .. " (the original window changed, link not inserted)", vim.log.levels.WARN)
      return
    end
    local text = M._link_text(c.paste_link_style, path, vim.api.nvim_buf_get_name(buf), root)
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_put({ text }, "c", true, true)
    end)
    util.notify("saved " .. path)
  end

  local default = os.date("image-%Y%m%d-%H%M%S")
  if name_arg and name_arg ~= "" then
    save(name_arg)
  elseif cfg().paste_name == "auto" then
    save(default)
  else
    vim.ui.input({ prompt = "Image name: ", default = default }, function(n)
      if n and vim.trim(n) ~= "" then
        save(n)
      end
    end)
  end
end

return M
