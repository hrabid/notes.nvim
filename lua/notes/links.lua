-- notes.nvim: markdown link insertion, following, and back-navigation
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")

local M = {}

local stack = {}

local function cfg()
  return require("notes").config
end

-- ── stack ────────────────────────────────────────────────────────────

function M._push_stack(file, line, col)
  stack[#stack + 1] = { file = file, line = line, col = col }
  local max = cfg().link_stack_max or 50
  while #stack > max do
    table.remove(stack, 1)
  end
end

function M._pop_stack()
  return table.remove(stack)
end

-- ── insertion ────────────────────────────────────────────────────────

local function capture_cursor()
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  return { win = win, buf = vim.api.nvim_win_get_buf(win), row = pos[1], col = pos[2] }
end

-- insert `text` after the cursor character (like `a`), then park cursor on its last char
local function insert_text(ctx, text)
  if not vim.api.nvim_buf_is_valid(ctx.buf) then
    return
  end
  local line = vim.api.nvim_buf_get_lines(ctx.buf, ctx.row - 1, ctx.row, false)[1] or ""
  local col = ctx.col
  if #line > 0 then
    col = col + 1 + vim.str_utf_end(line, col + 1)
  end
  col = math.min(col, #line)
  vim.api.nvim_buf_set_text(ctx.buf, ctx.row - 1, col, ctx.row - 1, col, { text })
  if vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_buf(ctx.win) == ctx.buf then
    vim.api.nvim_set_current_win(ctx.win)
    pcall(vim.api.nvim_win_set_cursor, ctx.win, { ctx.row, col + #text - 1 })
  end
end

local function pick_file(cb)
  local root = vault.require_root()
  if not root then
    return
  end
  local files = util.list_md_recursive(root)
  if #files == 0 then
    util.notify("no markdown files in vault", vim.log.levels.WARN)
    return
  end
  picker.select(files, { prompt = "Link to file" }, function(rel)
    cb(root .. "/" .. rel, rel)
  end)
end

local function link_path(from_buf, target_abs)
  local name = vim.api.nvim_buf_get_name(from_buf)
  local from_dir = name ~= "" and vim.fs.dirname(name) or vault.get_root()
  local rel = util.relative_path(from_dir, target_abs)
  return (rel:gsub(" ", "%%20"))
end

local function display_for(rel)
  local base = vim.fn.fnamemodify(rel, ":t:r")
  if cfg().link_display == "title" then
    return util.to_title_case(base)
  end
  return base
end

function M.insert_file_link(_)
  local ctx = capture_cursor()
  pick_file(function(abs, rel)
    insert_text(ctx, "[" .. display_for(rel) .. "](" .. link_path(ctx.buf, abs) .. ")")
  end)
end

function M.insert_header_link(_)
  local ctx = capture_cursor()
  pick_file(function(abs, _)
    local lines = util.read_lines(abs)
    local heads = lines and util.parse_headings(lines) or {}
    if #heads == 0 then
      util.notify("no headings found in " .. vim.fn.fnamemodify(abs, ":t"), vim.log.levels.WARN)
      return
    end
    local items = {}
    for _, h in ipairs(heads) do
      items[#items + 1] = { display = ("  "):rep(h.level - 1) .. h.text, heading = h }
    end
    picker.select(items, { prompt = "Link to header" }, function(item)
      local h = item.heading
      insert_text(ctx, "[" .. h.text .. "](" .. link_path(ctx.buf, abs) .. "#" .. h.anchor .. ")")
    end)
  end)
end

-- ── following ────────────────────────────────────────────────────────

--- Find a link under the cursor. col is 0-based (as from nvim_win_get_cursor).
--- Returns { path, anchor, wiki, url } or nil.
function M._parse_link_under_cursor(line, col)
  local c = col + 1
  local init = 1
  while true do
    local s, e, _, target = line:find("%[([^%]]*)%]%(([^)]*)%)", init)
    if not s then
      break
    end
    if c >= s and c <= e then
      local t = target:match("^%s*<(.-)>") or target:match("^%s*(%S+)") or ""
      if t:match("^%a[%w+.-]*://") or t:match("^mailto:") then
        return { url = t }
      end
      local path, anchor = t:match("^([^#]*)#?(.*)$")
      return { path = util.url_decode(path), anchor = anchor ~= "" and anchor or nil }
    end
    init = e + 1
  end

  if cfg().wikilinks then
    init = 1
    while true do
      local s, e, inner = line:find("%[%[([^%]]+)%]%]", init)
      if not s then
        break
      end
      if c >= s and c <= e then
        local target = inner:match("^([^|]*)")
        local name, anchor = target:match("^([^#]*)#?(.*)$")
        return { path = name, anchor = anchor ~= "" and anchor or nil, wiki = true }
      end
      init = e + 1
    end
  end
  return nil
end

function M._generate_anchor(text)
  return util.generate_anchor(text)
end

--- Line number of the heading matching `anchor` in bufnr, or nil.
function M._resolve_anchor(bufnr, anchor)
  local want = util.generate_anchor(util.url_decode(anchor))
  local heads = util.parse_headings(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  for _, h in ipairs(heads) do
    if h.anchor == want then
      return h.lnum
    end
  end
  return nil
end

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

local function resolve_target(link, cur_file)
  local root = vault.get_root()
  local path = link.path
  local cands = {}

  if link.wiki then
    if not root then
      return nil
    end
    local want = path:gsub("%.md$", "") .. ".md"
    for _, rel in ipairs(util.list_md_recursive(root)) do
      if rel == want or rel:sub(-(#want + 1)) == "/" .. want then
        return root .. "/" .. rel
      end
    end
    return nil
  end

  if path:sub(1, 1) == "/" then
    if root then
      cands[#cands + 1] = root .. path
    end
    cands[#cands + 1] = path
  else
    cands[#cands + 1] = vim.fs.joinpath(vim.fs.dirname(cur_file), path)
  end

  for _, cand in ipairs(cands) do
    cand = vim.fs.normalize(cand)
    if is_file(cand) then
      return cand
    end
    if not cand:match("%.%w+$") and is_file(cand .. ".md") then
      return cand .. ".md"
    end
  end
  return nil
end

local function native_gf()
  local ok, err = pcall(vim.cmd, "normal! gf")
  if not ok then
    util.notify(tostring(err), vim.log.levels.WARN)
  end
end

function M.follow_link(_)
  local pos = vim.api.nvim_win_get_cursor(0)
  local link = M._parse_link_under_cursor(vim.api.nvim_get_current_line(), pos[2])
  if not link then
    return native_gf()
  end
  if link.url then
    vim.ui.open(link.url)
    return
  end

  local cur_file = vim.api.nvim_buf_get_name(0)

  -- same-file anchor: [x](#heading)
  if link.path == "" and link.anchor then
    local lnum = M._resolve_anchor(0, link.anchor)
    if not lnum then
      util.notify("anchor not found: #" .. link.anchor, vim.log.levels.WARN)
      return
    end
    if cur_file ~= "" then
      M._push_stack(cur_file, pos[1], pos[2])
    end
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zz")
    return
  end

  local target = resolve_target(link, cur_file)
  if not target then
    util.notify("linked file not found: " .. (link.path or ""), vim.log.levels.WARN)
    return
  end

  if target ~= cur_file then
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(target))
    if not ok then
      util.notify(tostring(err), vim.log.levels.ERROR)
      return
    end
  end
  if cur_file ~= "" then
    M._push_stack(cur_file, pos[1], pos[2])
  end

  if link.anchor then
    local lnum = M._resolve_anchor(0, link.anchor)
    if lnum then
      vim.api.nvim_win_set_cursor(0, { lnum, 0 })
      vim.cmd("normal! zz")
    else
      util.notify("anchor not found: #" .. link.anchor, vim.log.levels.WARN)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
    end
  end
end

function M.go_back()
  local entry = M._pop_stack()
  if not entry then
    util.notify("no link history")
    return
  end
  if vim.api.nvim_buf_get_name(0) ~= entry.file then
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(entry.file))
    if not ok then
      util.notify(tostring(err), vim.log.levels.ERROR)
      M._push_stack(entry.file, entry.line, entry.col) -- keep history intact
      return
    end
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { entry.line, entry.col })
end

return M
