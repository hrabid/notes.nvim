-- notes.nvim: vault search - full text, tags, frontmatter properties
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local links = require("notes.links")
local integrity = require("notes.integrity")
local template = require("notes.template")
local parse = require("notes.parse")
local index = require("notes.index")

local M = {}

-- ── parsing (pure; implemented in parse.lua) ───────────────────────

M._frontmatter = parse.frontmatter
M._tags_in_line = parse.tags_in_line

--- Scan the vault: returns tags (tag -> entries) and props (key -> value -> entries),
--- entry = { abs, rel, lnum, text }.
function M._index(idx, loaded)
  local tags, props = {}, {}
  for _, rel in ipairs(idx.md) do
    local abs = idx.root .. "/" .. rel
    if not template.is_template_path(abs) then
      local d = index.data(abs, loaded)
      if d then
        for _, t in ipairs(d.tags) do
          tags[t.tag] = tags[t.tag] or {}
          table.insert(tags[t.tag], { abs = abs, rel = rel, lnum = t.lnum, text = t.text })
        end
        for k, vals in pairs(d.fm or {}) do
          for _, v in ipairs(vals) do
            props[k] = props[k] or {}
            props[k][v] = props[k][v] or {}
            table.insert(props[k][v], { abs = abs, rel = rel, lnum = d.fm_at[k], text = k .. ": " .. v })
          end
        end
      end
    end
  end
  return tags, props
end

-- ── pickers ──────────────────────────────────────────────────────────

local function distinct_files(entries)
  local seen, n = {}, 0
  for _, e in ipairs(entries) do
    if not seen[e.abs] then
      seen[e.abs] = true
      n = n + 1
    end
  end
  return n
end

local function note_items(entries)
  local items = {}
  for _, e in ipairs(entries) do
    items[#items + 1] = {
      display = ("%s:%d  %s"):format(e.rel, e.lnum or 1, (e.text or ""):sub(1, 90)),
      filename = e.abs,
      lnum = e.lnum or 1,
    }
  end
  table.sort(items, function(a, b)
    return a.display < b.display
  end)
  return items
end

local function open(item)
  links.open_path(item.filename, nil)
  pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum or 1, 0 })
  vim.cmd("normal! zz")
end

local function pick_notes(prompt, entries)
  picker.select(note_items(entries), { prompt = prompt, preview = true }, open)
end

local function sorted_keys(map)
  local keys = {}
  for k in pairs(map) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

local function scan()
  local root = vault.require_root()
  if not root then
    return nil
  end
  return M._index(index.get(root), integrity.loaded_buffers())
end

--- Full text search over the vault's markdown files (live grep with the configured picker).
function M.text(query)
  local root = vault.require_root()
  if not root then
    return
  end
  query = (query and query ~= "") and query or nil
  local b = picker.backend()
  if b == "telescope" then
    require("telescope.builtin").live_grep({ cwd = root, prompt_title = "Vault search", glob_pattern = "*.md", default_text = query })
  elseif b == "fzf-lua" then
    require("fzf-lua").live_grep({
      cwd = root,
      prompt = "Vault> ",
      search = query,
      rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 --glob=*.md -e",
    })
  else
    if vim.fn.executable("rg") ~= 1 then
      util.notify(":NoteSearch needs telescope, fzf-lua or ripgrep", vim.log.levels.WARN)
      return
    end
    local function run(q)
      if not q or vim.trim(q) == "" then
        return
      end
      local res = vim.system({ "rg", "--vimgrep", "--smart-case", "--glob=*.md", "--", q, root }, { text = true }):wait(10000)
      local items = {}
      for line in (res.stdout or ""):gmatch("[^\n]+") do
        local file, lnum, text = line:match("^(.-):(%d+):%d+:(.*)$")
        if file then
          items[#items + 1] = { display = ("%s:%s  %s"):format(file:sub(#root + 2), lnum, vim.trim(text):sub(1, 90)), filename = file, lnum = tonumber(lnum) }
        end
      end
      if #items == 0 then
        util.notify("no matches")
        return
      end
      picker.select(items, { prompt = "Matches" }, open)
    end
    if query then
      run(query)
    else
      vim.ui.input({ prompt = "Search vault: " }, run)
    end
  end
end

--- Tags: pick a tag (with note counts), then a note. `tag` skips the first step.
function M.tags(tag)
  local tags = scan()
  if not tags then
    return
  end
  if tag and tag ~= "" then
    tag = tag:gsub("^#", "")
    if not tags[tag] then
      util.notify("no notes tagged #" .. tag)
      return
    end
    pick_notes("#" .. tag, tags[tag])
    return
  end
  local items = {}
  for _, t in ipairs(sorted_keys(tags)) do
    items[#items + 1] = { display = ("#%s  (%d)"):format(t, distinct_files(tags[t])), tag = t }
  end
  if #items == 0 then
    util.notify("no tags found")
    return
  end
  picker.select(items, { prompt = "Tags" }, function(item)
    pick_notes("#" .. item.tag, tags[item.tag])
  end)
end

--- Frontmatter properties: key -> value -> note. `arg` = "key" or "key=value" skips steps.
function M.props(arg)
  local _, props = scan()
  if not props then
    return
  end
  local function values_of(key)
    local items = {}
    for _, v in ipairs(sorted_keys(props[key])) do
      items[#items + 1] = { display = ("%s  (%d)"):format(v, distinct_files(props[key][v])), value = v }
    end
    picker.select(items, { prompt = key }, function(item)
      pick_notes(key .. ": " .. item.value, props[key][item.value])
    end)
  end
  if arg and arg ~= "" then
    local key, value = arg:match("^([^=]+)=?(.*)$")
    key, value = vim.trim(key), vim.trim(value)
    if not props[key] then
      util.notify("no notes have the property '" .. key .. "'")
    elseif value == "" then
      values_of(key)
    elseif props[key][value] then
      pick_notes(key .. ": " .. value, props[key][value])
    else
      util.notify(("no notes with %s: %s"):format(key, value))
    end
    return
  end
  local items = {}
  for _, k in ipairs(sorted_keys(props)) do
    local files = {}
    for _, entries in pairs(props[k]) do
      for _, e in ipairs(entries) do
        files[e.abs] = true
      end
    end
    local n = 0
    for _ in pairs(files) do
      n = n + 1
    end
    items[#items + 1] = { display = ("%s  (%d)"):format(k, n), key = k }
  end
  if #items == 0 then
    util.notify("no frontmatter properties found")
    return
  end
  picker.select(items, { prompt = "Properties" }, function(item)
    values_of(item.key)
  end)
end

return M
