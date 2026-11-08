-- notes.nvim: completion source for blink.cmp / nvim-cmp
--   [[note     [[note#Heading     [text](path     [text](path#anchor     #tag
local util = require("notes.util")
local vault = require("notes.vault")
local index = require("notes.index")
local integrity = require("notes.integrity")

local M = {}

local MEDIA = { png = 1, jpg = 1, jpeg = 1, gif = 1, webp = 1, svg = 1, bmp = 1, avif = 1, pdf = 1 }
local KIND = { file = 17, heading = 18, tag = 14 } -- LSP CompletionItemKind: File, Reference, Keyword

--- What is being completed, from the text before the cursor. `start` is the 0-based byte
--- column where the replaced text begins.
function M._context(before)
  local wiki = before:match("%[%[([^%]|]*)$")
  if wiki then
    local name, anchor = wiki:match("^([^#]*)#(.*)$")
    if name then
      return { kind = "wiki_heading", name = name, partial = anchor, start = #before - #anchor }
    end
    return { kind = "wiki_note", partial = wiki, start = #before - #wiki }
  end
  local md = before:match("%]%(([^%)%s]*)$")
  if md then
    local path, anchor = md:match("^([^#]*)#(.*)$")
    if path then
      return { kind = "md_heading", path = path, partial = anchor, start = #before - #anchor }
    end
    return { kind = "md_path", partial = md, start = #before - #md }
  end
  local tag = before:match("[%s(]#([%w_/%-]*)$") or before:match("^#([%w_/%-]+)$")
  if tag then
    return { kind = "tag", partial = tag, start = #before - #tag }
  end
  return nil
end

local function strip_md(s)
  return (s:gsub("%.md$", ""))
end

local function candidate_files(idx, skip)
  local out = {}
  for base, rels in pairs(idx.by_name) do
    local ext = base:match("%.(%w+)$")
    ext = ext and ext:lower()
    if ext == "md" or (ext and MEDIA[ext]) then
      for _, rel in ipairs(rels) do
        if not (skip and skip(idx.root .. "/" .. rel)) then
          out[#out + 1] = rel
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- Items for a context. env = { idx, note_abs, headings = function(abs) -> heads, tags = {names} }.
--- Returns { {label, insert, detail, kind}, ... }.
function M._items(ctx, env)
  local idx, note = env.idx, env.note_abs
  local items = {}
  if ctx.kind == "wiki_note" then
    for _, rel in ipairs(candidate_files(idx, env.skip)) do
      local base = vim.fs.basename(rel)
      local dup = #idx.by_name[base] > 1
      local label = strip_md(dup and rel or base) -- ambiguous names get their path
      items[#items + 1] = { label = label, insert = label, detail = rel, kind = "file" }
    end
  elseif ctx.kind == "md_path" then
    for _, rel in ipairs(candidate_files(idx, env.skip)) do
      local from = note ~= "" and vim.fs.dirname(note) or idx.root
      local rp = util.relative_path(from, idx.root .. "/" .. rel)
      items[#items + 1] = { label = rp, insert = (rp:gsub(" ", "%%20")), detail = rel, kind = "file" }
    end
  elseif ctx.kind == "wiki_heading" or ctx.kind == "md_heading" then
    local abs = note
    local name = ctx.kind == "wiki_heading" and ctx.name or util.url_decode(ctx.path)
    if name ~= "" then
      abs = integrity._resolve(idx, { path = name, wiki = ctx.kind == "wiki_heading" }, note)
    end
    for _, h in ipairs(abs and env.headings(abs) or {}) do
      items[#items + 1] = {
        label = h.text,
        insert = ctx.kind == "wiki_heading" and h.text or h.anchor,
        detail = "#" .. h.anchor,
        kind = "heading",
      }
    end
  elseif ctx.kind == "tag" then
    for _, t in ipairs(env.tags or {}) do
      items[#items + 1] = { label = t, insert = t, detail = "tag", kind = "tag" }
    end
  end
  return items
end

local tag_cache = { at = 0, list = {} }

local function all_tags(idx, loaded)
  if vim.uv.now() - tag_cache.at < 10000 then
    return tag_cache.list
  end
  local seen, list = {}, {}
  for _, rel in ipairs(idx.md) do
    local d = index.data(idx.root .. "/" .. rel, loaded)
    for _, t in ipairs(d and d.tags or {}) do
      if not seen[t.tag] then
        seen[t.tag] = true
        list[#list + 1] = t.tag
      end
    end
  end
  table.sort(list)
  tag_cache = { at = vim.uv.now(), list = list }
  return list
end

local function to_u16(line, col)
  local ok, v = pcall(vim.str_utfindex, line, "utf-16", col) -- Neovim 0.11
  if ok and type(v) == "number" then
    return v
  end
  local ok2, _, u = pcall(vim.str_utfindex, line, col) -- Neovim 0.10
  if ok2 and u then
    return u
  end
  return col
end

--- LSP-style completion items for the cursor position of the current window.
function M.items_at_cursor()
  local root = vault.get_root()
  if not root then
    return {}
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_get_current_line()
  local ctx = M._context(line:sub(1, pos[2]))
  if not ctx then
    return {}
  end
  local loaded = integrity.loaded_buffers()
  local idx = index.get(root)
  local raw = M._items(ctx, {
    idx = idx,
    note_abs = util.expand_path(vim.api.nvim_buf_get_name(0)),
    skip = require("notes.template").is_template_path, -- the templates folder is not link material
    headings = function(abs)
      local d = index.data(abs, loaded)
      return d and d.heads or {}
    end,
    tags = ctx.kind == "tag" and all_tags(idx, loaded) or nil,
  })
  local row = pos[1] - 1
  local range = {
    start = { line = row, character = to_u16(line, ctx.start) },
    ["end"] = { line = row, character = to_u16(line, pos[2]) },
  }
  local out = {}
  for i, it in ipairs(raw) do
    if i > 3000 then
      break
    end
    out[i] = {
      label = it.label,
      kind = KIND[it.kind],
      detail = it.detail,
      filterText = it.label,
      textEdit = { newText = it.insert, range = range },
    }
  end
  return out
end

--- Register the nvim-cmp source "notes" when nvim-cmp is installed (blink.cmp uses notes.blink).
function M.setup()
  local ok, cmp = pcall(require, "cmp")
  if not (ok and cmp.register_source) then
    return
  end
  local source = {}
  function source:is_available()
    return vim.bo.filetype == "markdown"
  end
  function source:get_trigger_characters()
    return { "[", "(", "#", "/" }
  end
  function source:complete(_, callback)
    callback({ items = M.items_at_cursor(), isIncomplete = false })
  end
  pcall(cmp.register_source, "notes", setmetatable({}, { __index = source }))
end

return M
