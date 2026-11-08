-- notes.nvim: editing helpers - link style conversion, checkbox tasks
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local links = require("notes.links")
local integrity = require("notes.integrity")
local index = require("notes.index")
local parse = require("notes.parse")

local M = {}

-- ── link style conversion ────────────────────────────────────────────

local function size_str(sz)
  return sz.h and (sz.w .. "x" .. sz.h) or tostring(sz.w)
end

--- New text for `ref` in style `to` ("wiki" | "markdown"), or nil, reason.
--- ctx = { idx, note_abs, loaded }
function M._convert_ref(ref, to, ctx)
  if ref.url then
    return nil
  end
  local idx, note = ctx.idx, ctx.note_abs
  local prefix = ref.embed and "!" or ""

  if to == "markdown" then
    if not ref.wiki then
      return nil
    end
    local abs = note
    if ref.path ~= "" then
      abs = integrity._resolve(idx, ref, note)
    end
    if not abs then
      return nil, "unresolved"
    end
    local rel = ""
    if ref.path ~= "" then
      rel = util.relative_path(vim.fs.dirname(note), abs):gsub(" ", "%%20")
    end
    local anchor = ref.anchor and ("#" .. util.generate_anchor(ref.anchor:match("[^#]*$"))) or ""
    local text
    if ref.embed then
      text = ref.size and ("|" .. size_str(ref.size)) or (ref.alias or "")
    else
      text = ref.alias
      if not text or text == "" then
        if ref.path ~= "" then
          text = vim.fs.basename(abs):gsub("%.md$", "")
        else
          text = ref.anchor or ""
        end
      end
    end
    return ("%s[%s](%s%s)"):format(prefix, text, rel, anchor)
  end

  if ref.wiki then
    return nil
  end
  local abs = note
  if ref.path ~= "" then
    abs = integrity._resolve(idx, ref, note)
  end
  if not abs then
    return nil, "unresolved"
  end
  local name = ""
  if ref.path ~= "" then
    local base = vim.fs.basename(abs)
    local list = idx.by_name[base]
    name = (list and #list > 1) and abs:sub(#idx.root + 2) or base -- ambiguous names keep their path
    name = name:gsub("%.md$", "")
  end
  local heading
  if ref.anchor then
    local want = util.generate_anchor(util.url_decode(ref.anchor))
    heading = ref.anchor
    local d = index.data(abs, ctx.loaded)
    for _, h in ipairs(d and d.heads or {}) do
      if h.anchor == want then
        heading = h.text
        break
      end
    end
  end
  local alias
  if ref.embed then
    if ref.size then
      alias = size_str(ref.size)
    elseif ref.text and ref.text ~= "" then
      alias = ref.text
    end
  else
    local t = (ref.text or ""):lower()
    local plain = vim.fs.basename(name):lower()
    if t ~= "" and t ~= name:lower() and t ~= plain and t ~= (heading or ""):lower() then
      alias = ref.text
    end
  end
  return ("%s[[%s%s%s]]"):format(prefix, name, heading and ("#" .. heading) or "", alias and ("|" .. alias) or "")
end

--- No argument: convert the link under the cursor to the other style.
--- "wiki" / "markdown": convert every link in the buffer to that style.
function M.convert_link(arg)
  local root = vault.require_root()
  if not root then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local ctx = {
    idx = index.get(root),
    note_abs = util.expand_path(vim.api.nvim_buf_get_name(buf)),
    loaded = {},
  }
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local refs = parse.scan_lines(lines)
  local todo = {}
  if arg == "wiki" or arg == "markdown" then
    for _, r in ipairs(refs) do
      todo[#todo + 1] = { ref = r, to = arg }
    end
  else
    local pos = vim.api.nvim_win_get_cursor(0)
    for _, r in ipairs(refs) do
      if r.lnum == pos[1] and pos[2] + 1 >= r.s and pos[2] + 1 <= r.e then
        todo[1] = { ref = r, to = r.wiki and "markdown" or "wiki" }
        break
      end
    end
    if #todo == 0 then
      util.notify("no link under the cursor", vim.log.levels.WARN)
      return
    end
  end
  table.sort(todo, function(a, b)
    if a.ref.lnum ~= b.ref.lnum then
      return a.ref.lnum > b.ref.lnum
    end
    return a.ref.s > b.ref.s
  end)
  local done, skipped = 0, 0
  for _, t in ipairs(todo) do
    local text, why = M._convert_ref(t.ref, t.to, ctx)
    if text then
      local l = lines[t.ref.lnum]
      lines[t.ref.lnum] = l:sub(1, t.ref.s - 1) .. text .. l:sub(t.ref.e + 1)
      vim.api.nvim_buf_set_lines(buf, t.ref.lnum - 1, t.ref.lnum, false, { lines[t.ref.lnum] })
      done = done + 1
    elseif why then
      skipped = skipped + 1
    end
  end
  util.notify(("converted %d link(s)%s"):format(done, skipped > 0 and (", skipped %d unresolved"):format(skipped) or ""))
end

-- ── tasks ────────────────────────────────────────────────────────────

--- Toggle the checkbox of a line: [ ] <-> [x]; a list item without one gets "[ ]";
--- plain text becomes "- [ ] text".
function M._toggle(line)
  local indent, bullet, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  if not indent then
    indent, bullet, rest = line:match("^(%s*)(%d+[.)])%s+(.*)$")
  end
  if indent then
    local mark, after = rest:match("^%[(.)%](.*)$")
    if mark and (after == "" or after:match("^%s")) then
      local new = (mark == " ") and "x" or ((mark == "x" or mark == "X") and " " or "x")
      return indent .. bullet .. " [" .. new .. "]" .. after
    end
    return indent .. bullet .. " [ ] " .. rest
  end
  local lead, text = line:match("^(%s*)(.*)$")
  if text == "" then
    return line
  end
  return lead .. "- [ ] " .. text
end

function M.toggle_range(l1, l2)
  local last = vim.api.nvim_buf_line_count(0)
  l2 = math.min(l2, last)
  local lines = vim.api.nvim_buf_get_lines(0, l1 - 1, l2, false)
  for i, l in ipairs(lines) do
    lines[i] = M._toggle(l)
  end
  vim.api.nvim_buf_set_lines(0, l1 - 1, l2, false, lines)
end

local function open(item)
  links.open_path(item.filename, nil)
  pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum or 1, 0 })
  vim.cmd("normal! zz")
end

--- Task picker: "open" (default), "done", "all" across the vault, or "file" (current note, all states).
function M.tasks(mode)
  mode = (mode and mode ~= "") and mode or "open"
  local items = {}
  local function add(rel, abs, tasks)
    for _, t in ipairs(tasks) do
      if mode == "all" or mode == "file" or (mode == "done") == t.done then
        items[#items + 1] = { display = ("%s:%d  [%s] %s"):format(rel, t.lnum, t.mark, t.text), filename = abs, lnum = t.lnum }
      end
    end
  end
  if mode == "file" then
    local abs = util.expand_path(vim.api.nvim_buf_get_name(0))
    add(vim.fn.fnamemodify(abs, ":t"), abs, parse.note(vim.api.nvim_buf_get_lines(0, 0, -1, false)).tasks)
  else
    local root = vault.require_root()
    if not root then
      return
    end
    local idx, loaded = index.get(root), integrity.loaded_buffers()
    local template = require("notes.template")
    for _, rel in ipairs(idx.md) do
      local abs = root .. "/" .. rel
      if not template.is_template_path(abs) then
        local d = index.data(abs, loaded)
        if d then
          add(rel, abs, d.tasks)
        end
      end
    end
  end
  if #items == 0 then
    util.notify("no " .. (mode == "done" and "completed" or "open") .. " tasks")
    return
  end
  picker.select(items, { prompt = "Tasks", preview = true }, open)
end

return M
