-- notes.nvim: navigation inside a note - link/heading jumps, table of contents
local util = require("notes.util")
local integrity = require("notes.integrity")

local M = {}

local function cfg()
  return require("notes").config
end

-- ── link / heading jumps ─────────────────────────────────────────────

--- Next (dir = 1) or previous (dir = -1) ref relative to (row, col0); wraps around.
function M._next_ref(refs, row, col, dir)
  if #refs == 0 then
    return nil
  end
  if dir > 0 then
    for _, r in ipairs(refs) do
      if r.lnum > row or (r.lnum == row and r.s - 1 > col) then
        return r
      end
    end
    return refs[1]
  end
  for i = #refs, 1, -1 do
    local r = refs[i]
    if r.lnum < row or (r.lnum == row and r.s - 1 < col) then
      return r
    end
  end
  return refs[#refs]
end

local function jump_to(row, col)
  vim.cmd("normal! m'")
  vim.api.nvim_win_set_cursor(0, { row, col })
end

--- Jump to the next/previous link or embed (count supported).
function M.jump_link(dir)
  local refs = integrity._scan_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  if #refs == 0 then
    util.notify("no links in this note")
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local row, col = pos[1], pos[2]
  for _ = 1, vim.v.count1 do
    local r = M._next_ref(refs, row, col, dir)
    row, col = r.lnum, r.s - 1
  end
  jump_to(row, col)
end

--- Jump to the next/previous heading (count supported).
function M.jump_heading(dir)
  local heads = util.parse_headings(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  if #heads == 0 then
    util.notify("no headings in this note")
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for _ = 1, vim.v.count1 do
    local target
    if dir > 0 then
      for _, h in ipairs(heads) do
        if h.lnum > row then
          target = h.lnum
          break
        end
      end
      target = target or heads[1].lnum
    else
      for i = #heads, 1, -1 do
        if heads[i].lnum < row then
          target = heads[i].lnum
          break
        end
      end
      target = target or heads[#heads].lnum
    end
    row = target
  end
  jump_to(row, 0)
  vim.cmd("normal! zz")
end

-- ── table of contents ────────────────────────────────────────────────

local TOC_START, TOC_END = "<!-- toc -->", "<!-- /toc -->"

--- Line range of the marker block, or nil.
function M._find_toc(lines)
  local s
  for i, l in ipairs(lines) do
    if not s and l:match("^%s*<!%-%-%s*toc%s*%-%->%s*$") then
      s = i
    elseif s and l:match("^%s*<!%-%-%s*/toc%s*%-%->%s*$") then
      return s, i
    end
  end
  return nil
end

--- "- [Heading](#anchor)" lines for headings in [minl, maxl], indented relative to the shallowest.
function M._toc_lines(heads, minl, maxl)
  local base = 7
  for _, h in ipairs(heads) do
    if h.level >= minl and h.level <= maxl then
      base = math.min(base, h.level)
    end
  end
  local out = {}
  for _, h in ipairs(heads) do
    if h.level >= minl and h.level <= maxl then
      local text = h.text:gsub("[%[%]]", "")
      out[#out + 1] = ("  "):rep(h.level - base) .. "- [" .. text .. "](#" .. h.anchor .. ")"
    end
  end
  return out
end

local function same(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

--- Rebuild the TOC between its markers. opts.insert: create the block below the cursor
--- when none exists. Returns true when the buffer changed.
function M.update_toc(bufnr, opts)
  opts = opts or {}
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local c = cfg()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local s, e = M._find_toc(lines)
  if not s and not opts.insert then
    return false
  end
  local block = { TOC_START }
  for _, l in ipairs(M._toc_lines(util.parse_headings(lines), c.toc_min_level, opts.maxlevel or c.toc_max_level)) do
    block[#block + 1] = l
  end
  block[#block + 1] = TOC_END
  if s then
    local old = {}
    for i = s, e do
      old[#old + 1] = lines[i]
    end
    if same(old, block) then
      return false
    end
    vim.api.nvim_buf_set_lines(bufnr, s - 1, e, false, block)
  else
    local row = vim.api.nvim_win_get_cursor(0)[1]
    vim.api.nvim_buf_set_lines(bufnr, row, row, false, block)
  end
  return true
end

--- :NoteToc - update the TOC, or insert one at the cursor.
function M.toc(maxlevel)
  if not M.update_toc(0, { insert = true, maxlevel = maxlevel }) then
    util.notify("table of contents is up to date")
  end
end

return M
