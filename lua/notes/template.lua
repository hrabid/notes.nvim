-- notes.nvim: template discovery, variable resolution, injection
local util = require("notes.util")
local vault = require("notes.vault")

local M = {}

local function cfg()
  return require("notes").config
end

local function template_dir()
  local d = util.expand_path(cfg().template_dir or "templates")
  if d:sub(1, 1) == "/" then
    return d
  end
  local root = vault.get_root()
  return root and (root .. "/" .. d) or nil
end

function M.is_template_path(path)
  local d = template_dir()
  return d ~= nil and path:sub(1, #d + 1) == d .. "/"
end

--- Template names (no extension). Returns names, err.
function M.list()
  local dir = template_dir()
  if not dir then
    return {}, "template_dir is relative and no vault was detected"
  end
  if vim.fn.isdirectory(dir) == 0 then
    return {}, "template_dir not found: " .. dir
  end
  local names = {}
  for _, f in ipairs(util.list_dir(dir, "md")) do
    names[#names + 1] = f:sub(1, -4)
  end
  return names
end

function M.load(name)
  local dir = template_dir()
  if not dir then
    util.notify("template_dir could not be resolved", vim.log.levels.ERROR)
    return nil
  end
  local path = dir .. "/" .. name .. ".md"
  local content = util.read_file(path)
  if not content then
    util.notify("template unreadable: " .. path, vim.log.levels.ERROR)
  end
  return content
end

--- Substitute {{variables}}. Returns { lines, cursor_line, cursor_col }.
function M.resolve(content, ctx, name)
  local src = vim.split(content:gsub("\r", ""), "\n", { plain = true })
  if #src > 1 and src[#src] == "" then
    table.remove(src)
  end

  local out, unknown = {}, {}
  local cursor_line, cursor_col
  local warn_fm, warn_multi = false, false
  local in_fm = (src[1] == "---")

  for i, line in ipairs(src) do
    local fm_line = in_fm
    if in_fm and i > 1 and line == "---" then
      in_fm = false
    end

    line = line:gsub("{{%s*([%w_]+)%s*}}", function(var)
      if var == "cursor" then
        return nil -- handled below
      end
      local v = ctx[var]
      if v == nil then
        unknown[var] = true
        return nil
      end
      return v
    end)

    local s, e = line:find("{{%s*cursor%s*}}")
    while s do
      if fm_line then
        warn_fm = true
        break
      elseif cursor_line then
        warn_multi = true
        break
      end
      cursor_line, cursor_col = #out + 1, s - 1
      line = line:sub(1, s - 1) .. line:sub(e + 1)
      s, e = line:find("{{%s*cursor%s*}}")
    end

    out[#out + 1] = line
  end

  local label = name and (" in template '" .. name .. "'") or ""
  for var in pairs(unknown) do
    util.notify("unknown variable {{" .. var .. "}}" .. label, vim.log.levels.WARN)
  end
  if warn_fm then
    util.notify("{{cursor}} in frontmatter ignored" .. label, vim.log.levels.WARN)
  end
  if warn_multi then
    util.notify("multiple {{cursor}} markers; using the first" .. label, vim.log.levels.WARN)
  end

  return { lines = out, cursor_line = cursor_line, cursor_col = cursor_col }
end

local function note_dir()
  local d = cfg().new_note_dir
  local root = vault.get_root()
  if d and d ~= "" then
    d = util.expand_path(d)
    if d:sub(1, 1) == "/" then
      return d
    end
    return root and (root .. "/" .. d) or nil
  end
  return root
end

--- Create/open a note by name inside new_note_dir (subpaths like "a/b" allowed).
--- Returns absolute path, is_new  (nil on failure).
function M.new_note(name)
  local n = vim.trim(name or "")
  n = n:gsub("%.md$", "")
  n = n:gsub("^/+", "")
  if n == "" then
    util.notify("empty note name", vim.log.levels.WARN)
    return nil
  end
  if vim.tbl_contains(vim.split(n, "/", { plain = true }), "..") then
    util.notify("note name may not contain '..'", vim.log.levels.WARN)
    return nil
  end
  local dir = note_dir()
  if not dir then
    util.notify("new_note_dir is relative and no vault was detected", vim.log.levels.WARN)
    return nil
  end
  local path = dir .. "/" .. n .. ".md"
  local is_new = vim.uv.fs_stat(path) == nil
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok then
    util.notify(tostring(err), vim.log.levels.ERROR)
    return nil
  end
  return path, is_new
end

function M.is_empty(bufnr)
  return vim.api.nvim_buf_line_count(bufnr) == 1
    and (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or "") == ""
end

function M.inject(bufnr, name)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local c = cfg()

  local content = M.load(name)
  if not content then
    return false
  end

  local fname = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t:r")
  local now = {
    date = util.date(c.date_format),
    time = util.time(c.time_format),
  }
  local ctx = {
    date = now.date,
    time = now.time,
    datetime = now.date .. " " .. now.time,
    filename = fname,
    title = util.to_title_case(fname),
    uuid = util.uuid(),
  }
  local res = M.resolve(content, ctx, name)

  local start
  if M.is_empty(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, res.lines)
    start = 0
  else
    if c.confirm_overwrite then
      local choice = vim.fn.confirm("Buffer has content. Insert template '" .. name .. "'?", "&Yes\n&No", 2)
      if choice ~= 1 then
        return false
      end
    end
    start = 0
    if c.inject_at_cursor and bufnr == vim.api.nvim_get_current_buf() then
      start = vim.api.nvim_win_get_cursor(0)[1] -- insert below the cursor line
    end
    vim.api.nvim_buf_set_lines(bufnr, start, start, false, res.lines)
  end

  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    local pos
    if res.cursor_line then
      pos = { start + res.cursor_line, res.cursor_col }
    else
      pos = { vim.api.nvim_buf_line_count(bufnr), 0 }
    end
    pcall(vim.api.nvim_win_set_cursor, win, pos)
  end
  return true
end

return M
