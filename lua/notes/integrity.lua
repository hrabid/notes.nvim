-- notes.nvim: link integrity
--   * update links when a note is moved / renamed (see move.lua)
--   * backlinks picker
--   * broken link / missing heading check -> quickfix
--
-- Links are resolved against an in-memory index of the vault, mirroring the preview lookup:
-- direct path (relative to the note / vault root), then by file name (attachment folders and
-- shallow paths preferred), case-sensitive then case-insensitive.
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local links = require("notes.links")
local template = require("notes.template")
local parse = require("notes.parse")
local index = require("notes.index")

local M = {}

local function cfg()
  return require("notes").config
end

-- ── scanning (pure; implemented in parse.lua) ────────────────────────

M._scan_line = parse.scan_line
M._scan_lines = parse.scan_lines

-- ── vault index + resolution ─────────────────────────────────────────

--- Fresh (uncached) index of the vault; callers on hot paths use index.get(root).
function M.build_index(root)
  return index.build(root)
end

local function rank(rel, attset)
  local segs = vim.split(rel, "/", { plain = true })
  local in_att = 1
  for i = 1, #segs - 1 do
    if attset[segs[i]:lower()] then
      in_att = 0
      break
    end
  end
  return in_att, #segs
end

local function best(matches, attset)
  table.sort(matches, function(a, b)
    local a1, a2 = rank(a, attset)
    local b1, b2 = rank(b, attset)
    if a1 ~= b1 then
      return a1 < b1
    end
    if a2 ~= b2 then
      return a2 < b2
    end
    return a < b
  end)
  return matches[1]
end

--- Absolute target of `ref` (as seen from file `source_abs`), plus how it was found
--- ("direct" | "search"); nil when it does not resolve.
function M._resolve(idx, ref, source_abs)
  local root = idx.root
  local dir = vim.fs.dirname(source_abs)
  local names = { ref.path }
  if not ref.path:match("%.%w+$") then
    names[#names + 1] = ref.path .. ".md"
  end
  local bases = ref.wiki and { root, dir } or { dir, root }

  for _, name in ipairs(names) do
    if name:sub(1, 1) == "/" then
      local c = root .. name
      if idx.set[c] then
        return c, "direct"
      end
    else
      for _, b in ipairs(bases) do
        local c = vim.fs.normalize(b .. "/" .. name)
        if idx.set[c] then
          return c, "direct"
        end
      end
    end
  end

  for _, icase in ipairs({ false, true }) do
    for _, name in ipairs(names) do
      local want = (name:gsub("^/", ""))
      local base = vim.fs.basename(want)
      local list = icase and idx.by_lname[base:lower()] or idx.by_name[base]
      if list then
        if icase then
          want = want:lower()
        end
        local matches = {}
        for _, rel in ipairs(list) do
          local cmp = icase and rel:lower() or rel
          if cmp == want or cmp:sub(-(#want + 1)) == "/" .. want then
            matches[#matches + 1] = rel
          end
        end
        if #matches > 0 then
          return root .. "/" .. best(matches, idx.attset), "search"
        end
      end
    end
  end
  return nil
end

-- ── reading files (open buffers win over disk) ───────────────────────

local function loaded_buffers()
  local map = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local n = vim.api.nvim_buf_get_name(b)
      if n ~= "" then
        map[util.expand_path(n)] = b
      end
    end
  end
  return map
end

local function file_lines(abs, loaded, strip_cr)
  local b = loaded[abs]
  if b then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false), b
  end
  local ok, lines = pcall(vim.fn.readfile, abs, "b")
  if ok then
    if strip_cr then
      for i, l in ipairs(lines) do
        lines[i] = (l:gsub("\r$", ""))
      end
    end
    return lines
  end
  return nil
end

-- ── rewriting links when a note moves ────────────────────────────────

--- New path text for `r`, or nil when it needs no change.
--- ctx = { root, old_src, new_src, old_target, new_target, how }
function M._rewrite(r, ctx)
  if ctx.old_src == ctx.new_src and ctx.old_target == ctx.new_target then
    return nil
  end
  local orig = r.path
  local target_changed = ctx.old_target ~= ctx.new_target
  -- links that omitted ".md" keep omitting it
  local drop_md = ctx.old_target:match("%.md$") and not orig:match("%.md$")
  local function fit(p)
    if drop_md then
      return (p:gsub("%.md$", ""))
    end
    return p
  end
  local function encode(p)
    if r.angle then
      return p
    end
    return (p:gsub(" ", "%%20"))
  end
  local function rel_to_root(abs)
    return abs:sub(#ctx.root + 2)
  end

  if r.wiki then
    if not target_changed then
      return nil
    end
    local new
    if orig:find("/", 1, true) then
      new = fit(rel_to_root(ctx.new_target))
    else
      new = fit(vim.fs.basename(ctx.new_target)) -- shortest-path style: only the name can change
    end
    return new ~= orig and new or nil
  end

  if orig:sub(1, 1) == "/" then
    if not target_changed then
      return nil
    end
    local new = fit("/" .. rel_to_root(ctx.new_target))
    return new ~= orig and encode(new) or nil
  end
  if ctx.how == "search" and not target_changed then
    return nil -- found by name; still found after the move
  end
  if ctx.how == "search" and not orig:find("/", 1, true) then
    local new = fit(vim.fs.basename(ctx.new_target))
    return new ~= orig and encode(new) or nil
  end
  local rel = fit(util.relative_path(vim.fs.dirname(ctx.new_src), ctx.new_target))
  if orig:sub(1, 2) == "./" and rel:sub(1, 1) ~= "." then
    rel = "./" .. rel
  end
  return rel ~= orig and encode(rel) or nil
end

--- Plan the link edits needed for moving `old` -> `new` (absolute paths).
--- Returns { edits = { [file] = { {lnum, s, e, old, text}, ... } }, links, files } | nil, err.
function M.plan_move(old, new)
  local root = vault.get_root()
  if not root then
    return nil, "vault not detected"
  end
  local idx = index.get(root)
  local loaded = loaded_buffers()
  local plan = { edits = {}, links = 0, files = 0 }
  for _, rel in ipairs(idx.md) do
    local abs = root .. "/" .. rel
    if not template.is_template_path(abs) then
      local d = index.data(abs, loaded)
      if d then
        local new_src = (abs == old) and new or abs
        for _, r in ipairs(d.refs) do
          if not r.url and r.path ~= "" and r.ps then
            local target, how = M._resolve(idx, r, abs)
            if target then
              local text = M._rewrite(r, {
                root = root,
                old_src = abs,
                new_src = new_src,
                old_target = target,
                new_target = (target == old) and new or target,
                how = how,
              })
              if text then
                local list = plan.edits[abs]
                if not list then
                  list = {}
                  plan.edits[abs] = list
                  plan.files = plan.files + 1
                end
                list[#list + 1] = { lnum = r.lnum, s = r.ps, e = r.pe, old = r.raw_path, text = text }
                plan.links = plan.links + 1
              end
            end
          end
        end
      end
    end
  end
  return plan
end

--- Apply a plan. `remap` maps planned paths to their current location (the moved file).
--- Open unmodified buffers are updated and saved; modified ones are updated and left unsaved.
--- Returns { links, files, unsaved, failed }.
function M.apply(plan, remap)
  remap = remap or {}
  local loaded = loaded_buffers()
  local res = { links = 0, files = 0, unsaved = 0, failed = 0 }
  for file, edits in pairs(plan.edits) do
    local abs = remap[file] or file
    local lines, buf = file_lines(abs, loaded)
    if not lines then
      res.failed = res.failed + #edits
    else
      table.sort(edits, function(a, b)
        if a.lnum ~= b.lnum then
          return a.lnum > b.lnum
        end
        return a.s > b.s
      end)
      local changed, touched = 0, {}
      for _, ed in ipairs(edits) do
        local line = lines[ed.lnum]
        if line and line:sub(ed.s, ed.e) == ed.old then
          lines[ed.lnum] = line:sub(1, ed.s - 1) .. ed.text .. line:sub(ed.e + 1)
          touched[ed.lnum] = true
          changed = changed + 1
        else
          res.failed = res.failed + 1
        end
      end
      if changed > 0 then
        if buf then
          local was_modified = vim.bo[buf].modified
          for lnum in pairs(touched) do
            vim.api.nvim_buf_set_lines(buf, lnum - 1, lnum, false, { lines[lnum] })
          end
          if was_modified then
            res.unsaved = res.unsaved + 1
          else
            pcall(vim.api.nvim_buf_call, buf, function()
              vim.cmd("silent write")
            end)
          end
        else
          vim.fn.writefile(lines, abs, "b")
        end
        res.links = res.links + changed
        res.files = res.files + 1
      end
    end
  end
  return res
end

-- ── backlinks ────────────────────────────────────────────────────────

function M._backlinks(idx, target, loaded)
  local out = {}
  for _, rel in ipairs(idx.md) do
    local abs = idx.root .. "/" .. rel
    if abs ~= target and not template.is_template_path(abs) then
      local d = index.data(abs, loaded)
      if d then
        local seen, lines = {}, nil
        for _, r in ipairs(d.refs) do
          if not seen[r.lnum] and not r.url and r.path ~= "" and M._resolve(idx, r, abs) == target then
            seen[r.lnum] = true -- one entry per line, however many links it holds
            lines = lines or file_lines(abs, loaded, true) or {}
            out[#out + 1] = { file = abs, rel = rel, lnum = r.lnum, text = vim.trim(lines[r.lnum] or "") }
          end
        end
      end
    end
  end
  return out
end

--- Picker of the notes that link to the current note.
function M.backlinks()
  local root = vault.require_root()
  if not root then
    return
  end
  local cur = util.expand_path(vim.api.nvim_buf_get_name(0))
  if cur == "" then
    util.notify("buffer has no file name", vim.log.levels.WARN)
    return
  end
  local hits = M._backlinks(index.get(root), cur, loaded_buffers())
  if #hits == 0 then
    util.notify("no backlinks")
    return
  end
  local items = {}
  for _, h in ipairs(hits) do
    items[#items + 1] = { display = ("%s:%d  %s"):format(h.rel, h.lnum, h.text:sub(1, 90)), filename = h.file, lnum = h.lnum }
  end
  picker.select(items, { prompt = "Backlinks", preview = true }, function(item)
    links.open_path(item.filename, nil)
    pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, 0 })
    vim.cmd("normal! zz")
  end)
end

-- ── broken link check ────────────────────────────────────────────────

local function heading_ok(set, anchor)
  if anchor:sub(1, 1) == "^" then
    return true -- block reference: not checked
  end
  return set[util.generate_anchor(util.url_decode(anchor:match("[^#]*$")))] == true
end

--- Problems in `files` (relative paths). Returns qf items, scanned count.
function M._check(idx, files, loaded)
  local problems, scanned = {}, 0
  for _, rel in ipairs(files) do
    local abs = idx.root .. "/" .. rel
    if not template.is_template_path(abs) then
      local d = index.data(abs, loaded)
      if d then
        scanned = scanned + 1
        for _, r in ipairs(d.refs) do
          if not r.url then
            local problem
            if r.path == "" then
              if r.anchor and not heading_ok(d.anchors, r.anchor) then
                problem = "missing heading: #" .. r.anchor
              end
            else
              local target = M._resolve(idx, r, abs)
              if not target then
                problem = "broken link: " .. r.path
              elseif r.anchor and target:match("%.md$") then
                local td = index.data(target, loaded)
                if td and not heading_ok(td.anchors, r.anchor) then
                  problem = ("missing heading: #%s in %s"):format(r.anchor, target:sub(#idx.root + 2))
                end
              end
            end
            if problem then
              problems[#problems + 1] = { filename = abs, lnum = r.lnum, col = r.s, text = problem }
            end
          end
        end
      end
    end
  end
  return problems, scanned
end

--- Whole vault (default) or just the current file ("file") -> quickfix list.
function M.check(scope)
  local root = vault.require_root()
  if not root then
    return
  end
  local idx = index.get(root)
  local files = idx.md
  if scope == "file" then
    local cur = util.expand_path(vim.api.nvim_buf_get_name(0))
    if cur == "" or not vault.is_in_vault(cur) then
      util.notify("current buffer is not a note inside the vault", vim.log.levels.WARN)
      return
    end
    files = { cur:sub(#root + 2) }
  end
  local problems, scanned = M._check(idx, files, loaded_buffers())
  if #problems == 0 then
    util.notify(("no broken links (%d file(s) checked)"):format(scanned))
    return
  end
  vim.fn.setqflist({}, " ", { title = "notes: broken links", items = problems })
  vim.cmd("copen")
  util.notify(("%d problem(s) found (%d file(s) checked)"):format(#problems, scanned), vim.log.levels.WARN)
end

M.loaded_buffers = loaded_buffers
M.file_lines = file_lines

return M
