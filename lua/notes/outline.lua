-- notes.nvim: heading outline (fuzzy picker + sidebar) and section operations
local util = require("notes.util")
local picker = require("notes.picker")

local M = {}

local function cfg()
  return require("notes").config
end

local LEVEL_HL = { "Title", "Statement", "Identifier", "Special", "Comment", "Comment" }

-- ── pure helpers (no editor state) ───────────────────────────────────

--- Last line (inclusive) of the section started by heads[i].
function M._section_end(heads, i, total)
  local lvl = heads[i].level
  for k = i + 1, #heads do
    if heads[k].level <= lvl then
      return heads[k].lnum - 1
    end
  end
  return total
end

--- Line edits that shift heads[i] and its sub-headings by `delta` levels.
--- Returns { {lnum, text}, ... } or nil, err.
function M._shift(lines, heads, i, delta)
  local out = {}
  for k = i, #heads do
    if k > i and heads[k].level <= heads[i].level then
      break
    end
    local nl = heads[k].level + delta
    if nl < 1 or nl > 6 then
      return nil, "heading level out of range (1-6)"
    end
    out[#out + 1] = { lnum = heads[k].lnum, text = ("#"):rep(nl) .. lines[heads[k].lnum]:sub(heads[k].level + 1) }
  end
  return out
end

--- Describe swapping heads[i]'s section with its sibling (dir > 0 down, < 0 up).
--- Returns { first, mid, last }, new_lnum_of_heading  | nil, err.
--- Block A = first..mid, block B = mid+1..last; result is B then A.
function M._sibling_swap(heads, i, dir, total)
  local h = heads[i]
  local s_i, e_i = h.lnum, M._section_end(heads, i, total)
  if dir > 0 then
    local n
    for k = i + 1, #heads do
      if heads[k].lnum > e_i then
        n = k
        break
      end
    end
    if not n or heads[n].level ~= h.level then
      return nil, "no sibling section below"
    end
    local e_n = M._section_end(heads, n, total)
    return { first = s_i, mid = e_i, last = e_n }, s_i + (e_n - e_i)
  end
  local j
  for k = i - 1, 1, -1 do
    if heads[k].level == h.level then
      j = k
      break
    end
    if heads[k].level < h.level then
      break
    end
  end
  if not j then
    return nil, "no sibling section above"
  end
  return { first = heads[j].lnum, mid = s_i - 1, last = e_i }, heads[j].lnum
end

--- block = lines first..last, a_n = number of lines in block A. Returns B..A.
function M._swap_block(block, a_n)
  local new = {}
  for k = a_n + 1, #block do
    new[#new + 1] = block[k]
  end
  for k = 1, a_n do
    new[#new + 1] = block[k]
  end
  return new
end

-- ── picker outline ───────────────────────────────────────────────────

local function center(win, lnum)
  pcall(vim.api.nvim_win_set_cursor, win, { lnum, 0 })
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! zz")
  end)
end

--- Fuzzy outline of a buffer; selecting jumps (jumplist entry, <C-o> returns).
--- maxlevel (optional) hides deeper headings.
function M.open(bufnr, maxlevel)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  maxlevel = maxlevel or 6
  local heads = util.parse_headings(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local win = vim.api.nvim_get_current_win()
  local items = {}
  for _, h in ipairs(heads) do
    if h.level <= maxlevel then
      items[#items + 1] = { display = ("  "):rep(h.level - 1) .. h.text, bufnr = bufnr, lnum = h.lnum }
    end
  end
  if #items == 0 then
    util.notify("no headings in this buffer", vim.log.levels.WARN)
    return
  end
  picker.select(items, { prompt = "Outline", preview = true }, function(item)
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd("normal! m'")
    center(win, item.lnum)
  end)
end

-- ── sidebar ──────────────────────────────────────────────────────────

local state = { win = nil, buf = nil, src = nil, collapsed = {}, maxlevel = 6, rows = {}, heads = {}, timer = nil }
local ns
local GROUP = "NotesOutline"

local function sidebar_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

local function src_valid()
  return state.src ~= nil and vim.api.nvim_buf_is_valid(state.src)
end

local function visible_rows()
  local rows, hide_below = {}, nil
  local heads = state.heads
  for i, h in ipairs(heads) do
    if h.level <= state.maxlevel then
      if not (hide_below and h.level > hide_below) then
        hide_below = nil
        local has_child = heads[i + 1] ~= nil and heads[i + 1].level > h.level
        rows[#rows + 1] = { head = h, idx = i, has_child = has_child }
        if has_child and state.collapsed[h.anchor] then
          hide_below = h.level
        end
      end
    end
  end
  return rows
end

--- Move the sidebar cursor to the heading containing the source cursor.
local function sync()
  if not (sidebar_open() and src_valid()) or vim.api.nvim_get_current_win() == state.win then
    return
  end
  local w = vim.fn.bufwinid(state.src)
  if w == -1 then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(w)[1]
  local row
  for i, r in ipairs(state.rows) do
    if r.head.lnum <= lnum then
      row = i
    else
      break
    end
  end
  if row then
    pcall(vim.api.nvim_win_set_cursor, state.win, { row, 0 })
  end
end

local function refresh()
  if not (sidebar_open() and src_valid() and vim.api.nvim_buf_is_valid(state.buf)) then
    return
  end
  ns = ns or vim.api.nvim_create_namespace("notes_outline")
  state.heads = util.parse_headings(vim.api.nvim_buf_get_lines(state.src, 0, -1, false))
  state.rows = visible_rows()

  local lines = {}
  for _, r in ipairs(state.rows) do
    local marker = r.has_child and (state.collapsed[r.head.anchor] and "+ " or "- ") or "  "
    lines[#lines + 1] = ("  "):rep(r.head.level - 1) .. marker .. r.head.text
  end
  if #lines == 0 then
    lines = { "(no headings)" }
  end

  local keep = vim.api.nvim_get_current_win() == state.win and vim.api.nvim_win_get_cursor(state.win)[1] or nil
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for i, r in ipairs(state.rows) do
    vim.api.nvim_buf_set_extmark(state.buf, ns, i - 1, 0, { end_col = #lines[i], hl_group = LEVEL_HL[r.head.level] })
  end
  if keep then
    pcall(vim.api.nvim_win_set_cursor, state.win, { math.min(keep, #lines), 0 })
  else
    sync()
  end
end

local function schedule_refresh()
  if state.timer and not state.timer:is_closing() then
    state.timer:stop()
    state.timer:close()
  end
  local t = vim.uv.new_timer()
  state.timer = t
  t:start(
    150,
    0,
    vim.schedule_wrap(function()
      if not t:is_closing() then
        t:stop()
        t:close()
      end
      refresh()
    end)
  )
end

local function current_row()
  if not sidebar_open() then
    return nil
  end
  return state.rows[vim.api.nvim_win_get_cursor(state.win)[1]]
end

local function select_lnum(lnum)
  for i, r in ipairs(state.rows) do
    if r.head.lnum == lnum then
      pcall(vim.api.nvim_win_set_cursor, state.win, { i, 0 })
      return
    end
  end
end

local function jump()
  local row = current_row()
  if not row or not src_valid() then
    return
  end
  local w = vim.fn.bufwinid(state.src)
  if w == -1 then
    util.notify("source buffer is not visible", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_set_current_win(w)
  vim.cmd("normal! m'")
  center(w, row.head.lnum)
end

local function toggle_collapse()
  local row = current_row()
  if row and row.has_child then
    state.collapsed[row.head.anchor] = not state.collapsed[row.head.anchor] or nil
    refresh()
  end
end

local function collapse_all(on)
  state.collapsed = {}
  if on then
    for i, h in ipairs(state.heads) do
      if state.heads[i + 1] and state.heads[i + 1].level > h.level then
        state.collapsed[h.anchor] = true
      end
    end
  end
  refresh()
end

local function set_maxlevel(n)
  state.maxlevel = n
  refresh()
end

--- Run a section edit on the source buffer for the heading under the sidebar cursor.
local function edit_section(fn)
  local row = current_row()
  if not row or not src_valid() then
    return
  end
  if not vim.bo[state.src].modifiable then
    util.notify("source buffer is not modifiable", vim.log.levels.WARN)
    return
  end
  refresh() -- re-parse so line numbers are current
  local lnum = row.head.lnum
  local idx
  for i, h in ipairs(state.heads) do
    if h.lnum == lnum then
      idx = i
    end
  end
  if not idx then
    util.notify("outline out of date; try again", vim.log.levels.WARN)
    return
  end
  local new_lnum = fn(state.src, state.heads, idx)
  if new_lnum then
    refresh()
    select_lnum(new_lnum)
  end
end

local function shift(delta)
  edit_section(function(buf, heads, idx)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local changes, err = M._shift(lines, heads, idx, delta)
    if not changes then
      util.notify(err, vim.log.levels.WARN)
      return nil
    end
    for _, c in ipairs(changes) do
      vim.api.nvim_buf_set_lines(buf, c.lnum - 1, c.lnum, false, { c.text })
    end
    return heads[idx].lnum
  end)
end

local function move(dir)
  edit_section(function(buf, heads, idx)
    local total = vim.api.nvim_buf_line_count(buf)
    local sw, new_lnum = M._sibling_swap(heads, idx, dir, total)
    if not sw then
      util.notify(new_lnum, vim.log.levels.WARN)
      return nil
    end
    local block = vim.api.nvim_buf_get_lines(buf, sw.first - 1, sw.last, false)
    vim.api.nvim_buf_set_lines(buf, sw.first - 1, sw.last, false, M._swap_block(block, sw.mid - sw.first + 1))
    return new_lnum
  end)
end

local function copy(text)
  vim.fn.setreg("+", text)
  vim.fn.setreg('"', text)
end

local function copy_link()
  local row = current_row()
  if row then
    copy("[" .. row.head.text .. "](#" .. row.head.anchor .. ")")
    util.notify("copied link to #" .. row.head.anchor)
  end
end

local function yank_section()
  local row = current_row()
  if not row or not src_valid() then
    return
  end
  local total = vim.api.nvim_buf_line_count(state.src)
  local last = M._section_end(state.heads, row.idx, total)
  local lines = vim.api.nvim_buf_get_lines(state.src, row.head.lnum - 1, last, false)
  copy(table.concat(lines, "\n"))
  util.notify(("yanked section (%d lines)"):format(#lines))
end

function M.close()
  if sidebar_open() then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  pcall(vim.api.nvim_del_augroup_by_name, GROUP)
  state.win, state.buf = nil, nil
end

function M.show()
  local src = vim.api.nvim_get_current_buf()
  if vim.bo[src].filetype ~= "markdown" then
    util.notify("outline sidebar works on markdown buffers", vim.log.levels.WARN)
    return
  end
  local c = cfg()
  state.src, state.collapsed, state.maxlevel = src, {}, 6

  vim.cmd((c.outline_side == "left" and "topleft " or "botright ") .. c.outline_width .. "vsplit")
  state.win = vim.api.nvim_get_current_win()
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.win, state.buf)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "notes-outline"
  vim.bo[state.buf].modifiable = false
  for opt, val in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    wrap = false,
    cursorline = true,
    foldenable = false,
    winfixwidth = true,
    list = false,
  }) do
    vim.wo[state.win][opt] = val
  end

  local function smap(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, desc = "Outline: " .. desc })
  end
  smap("<CR>", jump, "jump to heading")
  smap("o", jump, "jump to heading")
  smap("<2-LeftMouse>", jump, "jump to heading")
  smap("<Tab>", toggle_collapse, "collapse/expand")
  smap("za", toggle_collapse, "collapse/expand")
  smap("zM", function()
    collapse_all(true)
  end, "collapse all")
  smap("zR", function()
    collapse_all(false)
  end, "expand all")
  for n = 1, 6 do
    smap(tostring(n), function()
      set_maxlevel(n)
    end, "show levels <= " .. n)
  end
  smap("0", function()
    set_maxlevel(6)
  end, "show all levels")
  smap(">", function()
    shift(1)
  end, "demote section")
  smap("<", function()
    shift(-1)
  end, "promote section")
  smap("J", function()
    move(1)
  end, "move section down")
  smap("K", function()
    move(-1)
  end, "move section up")
  smap("y", copy_link, "copy link to heading")
  smap("Y", yank_section, "yank section")
  smap("r", refresh, "refresh")
  smap("q", M.close, "close")

  local g = vim.api.nvim_create_augroup(GROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = g,
    callback = function(args)
      if not sidebar_open() or args.buf == state.buf or args.buf == state.src then
        return
      end
      if vim.bo[args.buf].filetype == "markdown" and vim.bo[args.buf].buftype == "" then
        state.src, state.collapsed = args.buf, {}
        refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = g,
    callback = function(args)
      if args.buf == state.src then
        schedule_refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = g,
    callback = function(args)
      if args.buf == state.src then
        sync()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = g,
    pattern = tostring(state.win),
    callback = function()
      state.win, state.buf = nil, nil
      pcall(vim.api.nvim_del_augroup_by_name, GROUP)
    end,
  })

  refresh()
  vim.cmd("wincmd p")
  sync()
end

function M.toggle()
  if sidebar_open() then
    M.close()
  else
    M.show()
  end
end

return M
