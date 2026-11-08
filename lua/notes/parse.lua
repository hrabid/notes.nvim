-- notes.nvim: pure markdown parsing (links, frontmatter, tags, tasks). No editor state.
local util = require("notes.util")

local M = {}

local function clean(l)
  return (l:gsub("\r$", ""))
end

local function mask_code(line)
  return (line:gsub("`[^`]*`", function(m)
    return (" "):rep(#m)
  end))
end

--- Links/embeds in a line with the byte range (ps..pe) of the *path part* of each target:
--- { s, e, ps, pe, path (decoded), raw_path, anchor, wiki, embed, url, angle,
---   text (markdown link text/alt), alias (wiki alias), size = {w, h} }.
--- Inline code spans are ignored.
function M.scan_line(line)
  local masked = mask_code(line)
  local out = {}

  local init = 1
  while true do
    local s, e = masked:find("%[%[([^%]]+)%]%]", init)
    if not s then
      break
    end
    local inner = line:sub(s + 2, e - 2)
    local target = inner:match("^([^|]*)")
    local alias = inner:match("|(.*)$")
    local path, anchor = target:match("^([^#]*)#?(.*)$")
    local tp = vim.trim(path)
    local emb = s > 1 and line:sub(s - 1, s - 1) == "!"
    local ref = {
      s = emb and s - 1 or s,
      e = e,
      wiki = true,
      embed = emb,
      path = tp,
      raw_path = tp,
      anchor = anchor ~= "" and anchor or nil,
      alias = alias and vim.trim(alias) or nil,
    }
    if ref.alias then
      local w, h = util.parse_size(ref.alias)
      if w then
        ref.size = { w = w, h = h }
      end
    end
    if tp ~= "" then
      ref.ps = s + 2 + #(path:match("^%s*"))
      ref.pe = ref.ps + #tp - 1
    end
    out[#out + 1] = ref
    init = e + 1
  end

  init = 1
  while true do
    local s, e, text_m, raw = masked:find("%[([^%]]*)%]%(([^)]*)%)", init)
    if not s then
      break
    end
    local emb = s > 1 and line:sub(s - 1, s - 1) == "!"
    local cs = e - #raw -- first byte of the (...) content
    local lead = #(raw:match("^%s*"))
    local rest = raw:sub(lead + 1)
    local tok, tok_start, angle
    if rest:sub(1, 1) == "<" then
      tok, tok_start, angle = rest:match("^<(.-)>"), cs + lead + 1, true
    else
      tok, tok_start = rest:match("^(%S+)"), cs + lead
    end
    if tok then
      local text = line:sub(s + 1, s + #text_m)
      local ref = { s = emb and s - 1 or s, e = e, wiki = false, embed = emb, angle = angle, text = text }
      local sz = text:match("|([%dx]+)$")
      if sz then
        local w, h = util.parse_size(sz)
        if w then
          ref.size = { w = w, h = h }
        end
      end
      if tok:match("^%a[%w+.-]*://") or tok:match("^mailto:") then
        ref.url, ref.path = true, tok
      else
        local path, anchor = tok:match("^([^#]*)#?(.*)$")
        ref.raw_path, ref.path = path, util.url_decode(path)
        ref.anchor = anchor ~= "" and anchor or nil
        if path ~= "" then
          ref.ps, ref.pe = tok_start, tok_start + #path - 1
        end
      end
      out[#out + 1] = ref
    end
    init = e + 1
  end

  table.sort(out, function(a, b)
    return a.s < b.s
  end)
  return out
end

--- All refs in a file's lines (fenced code blocks skipped); each gets .lnum.
function M.scan_lines(lines)
  local refs, fence = {}, nil
  for i, line in ipairs(lines) do
    local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f:sub(1, 3)
      elseif f:sub(1, 3) == fence then
        fence = nil
      end
    elseif not fence and line:find("[", 1, true) then
      for _, r in ipairs(M.scan_line(line)) do
        r.lnum = i
        refs[#refs + 1] = r
      end
    end
  end
  return refs
end

local function unquote(s)
  s = vim.trim(s)
  return s:match('^"(.*)"$') or s:match("^'(.*)'$") or s
end

--- Minimal YAML frontmatter: scalars, [a, b] lists and "- item" lists. All values are
--- lists of strings. Returns fm, end_line, key_line_numbers  (nil, 0 when absent).
function M.frontmatter(lines)
  if not lines[1] or clean(lines[1]) ~= "---" then
    return nil, 0
  end
  local fm, at, key = {}, {}, nil
  for i = 2, #lines do
    local l = clean(lines[i])
    if l == "---" or l == "..." then
      return fm, i, at
    end
    local k, v = l:match("^([%w_%-]+):%s*(.-)%s*$")
    if k then
      key, at[k] = k, i
      if v == "" then
        fm[k] = {}
      elseif v:match("^%[.*%]$") then
        local list = {}
        for item in v:sub(2, -2):gmatch("[^,]+") do
          local x = unquote(item)
          if x ~= "" then
            list[#list + 1] = x
          end
        end
        fm[k] = list
      elseif k == "tags" or k == "tag" then
        local list = {}
        for item in v:gmatch("[^,%s]+") do
          list[#list + 1] = unquote(item)
        end
        fm[k] = list
      else
        fm[k] = { unquote(v) }
      end
    else
      local item = l:match("^%s*%-%s+(.-)%s*$")
      if item and key and fm[key] then
        local x = unquote(item)
        if x ~= "" then
          table.insert(fm[key], x)
        end
      end
    end
  end
  return nil, 0
end

--- Inline #tags in a line (not headings, urls, or inside code spans).
function M.tags_in_line(line)
  local masked = mask_code(line)
  -- link targets / wikilinks are not tags: [x](#anchor), [[#Heading]]
  masked = masked:gsub("%]%([^)]*%)", function(m)
    return (" "):rep(#m)
  end)
  masked = masked:gsub("%[%[[^%]]*%]%]", function(m)
    return (" "):rep(#m)
  end)
  local out = {}
  for s, tag in masked:gmatch("()#([%w_/%-]+)") do
    local prev = s > 1 and masked:sub(s - 1, s - 1) or ""
    if not prev:match("[%w_/&#]") and tag:match("[^%d/%-_]") then
      tag = tag:gsub("[/%-]+$", "")
      if tag ~= "" then
        out[#out + 1] = tag
      end
    end
  end
  return out
end

--- Checkbox of a list item: mark (" ", "x", ...) and text, or nil.
function M.task(line)
  local mark, rest = line:match("^%s*[-*+]%s+%[(.)%](.*)$")
  if not mark then
    mark, rest = line:match("^%s*%d+[.)]%s+%[(.)%](.*)$")
  end
  if mark and (rest == "" or rest:match("^%s")) then
    return mark, vim.trim(rest)
  end
  return nil
end

--- Everything derived from a note's lines, in one pass:
--- { refs, heads, anchors (set), fm, fm_at, tags = {{tag, lnum, text}}, tasks = {{lnum, mark, done, text}} }
function M.note(lines)
  local data = { refs = M.scan_lines(lines), heads = util.parse_headings(lines), anchors = {}, tags = {}, tasks = {} }
  for _, h in ipairs(data.heads) do
    data.anchors[h.anchor] = true
  end
  local fm, fm_end, at = M.frontmatter(lines)
  data.fm, data.fm_at = fm, at
  local start = 1
  if fm then
    start = fm_end + 1
    for k, vals in pairs(fm) do
      if k == "tags" or k == "tag" then
        for _, v in ipairs(vals) do
          data.tags[#data.tags + 1] = { tag = (v:gsub("^#", "")), lnum = at[k], text = "tags: " .. v }
        end
      end
    end
  end
  local fence
  for i = start, #lines do
    local line = lines[i]
    local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f:sub(1, 3)
      elseif f:sub(1, 3) == fence then
        fence = nil
      end
    elseif not fence then
      if line:find("#", 1, true) then
        local seen = {}
        for _, t in ipairs(M.tags_in_line(line)) do
          if not seen[t] then
            seen[t] = true
            data.tags[#data.tags + 1] = { tag = t, lnum = i, text = vim.trim(line) }
          end
        end
      end
      local mark, text = M.task(line)
      if mark then
        data.tasks[#data.tasks + 1] = { lnum = i, mark = mark, done = mark:lower() == "x", text = text }
      end
    end
  end
  return data
end

return M
