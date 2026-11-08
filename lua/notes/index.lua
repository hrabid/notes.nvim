-- notes.nvim: cached vault index
--   * file structure (set / by name / markdown list) - rebuilt only when something was added,
--     removed or renamed (directory watchers + FocusGained/BufWritePost) or on :NoteReindex
--   * per-note parse results (links, headings, tags, tasks, frontmatter) - revalidated by
--     mtime/size, so unchanged notes are never re-read
local util = require("notes.util")
local parse = require("notes.parse")

local M = {}

local state = { root = nil, idx = nil, dirty = true, watchers = {}, notes = {}, rebuilds = 0 }

local function cfg()
  return require("notes").config
end

local function attachment_set()
  local set, c = {}, cfg()
  local ad = c.attachment_dir
  if type(ad) == "string" then
    ad = { ad }
  end
  for _, d in ipairs(ad or {}) do
    set[vim.fs.basename(util.expand_path(d)):lower()] = true
  end
  for _, d in ipairs(c.attachment_dirs or {}) do
    set[d:lower()] = true
  end
  return set
end

--- Fresh index of `root` (no caching).
function M.build(root)
  local idx = { root = root, set = {}, by_name = {}, by_lname = {}, md = {}, attset = attachment_set() }
  for _, rel in ipairs(util.list_files_recursive(root)) do
    idx.set[root .. "/" .. rel] = true
    local base = vim.fs.basename(rel)
    local lbase = base:lower()
    idx.by_name[base] = idx.by_name[base] or {}
    table.insert(idx.by_name[base], rel)
    idx.by_lname[lbase] = idx.by_lname[lbase] or {}
    table.insert(idx.by_lname[lbase], rel)
    if rel:sub(-3) == ".md" then
      idx.md[#idx.md + 1] = rel
    end
  end
  return idx
end

local function stop_watch()
  for _, h in ipairs(state.watchers) do
    pcall(function()
      h:stop()
      h:close()
    end)
  end
  state.watchers = {}
end

local function start_watch(root)
  stop_watch()
  if cfg().index_watch == false then
    return
  end
  local dirs = { root }
  for _, d in ipairs(util.list_dirs_recursive(root)) do
    dirs[#dirs + 1] = root .. "/" .. d
  end
  if #dirs > 4000 then
    return -- too many for inotify; FocusGained / BufWritePost still invalidate
  end
  for _, d in ipairs(dirs) do
    local h = vim.uv.new_fs_event()
    if h then
      local ok, rc = pcall(
        h.start,
        h,
        d,
        {},
        vim.schedule_wrap(function(err, _, events)
          if not err and events and events.rename then
            state.dirty = true -- entries were created, deleted or renamed
          end
        end)
      )
      if ok and rc == 0 then
        state.watchers[#state.watchers + 1] = h
      else
        pcall(h.close, h)
      end
    end
  end
end

--- The (cached) index of the vault at `root`.
function M.get(root)
  if state.root ~= root then
    M.reset()
    state.root = root
  end
  if state.dirty or not state.idx then
    state.idx = M.build(root)
    state.dirty = false
    state.rebuilds = state.rebuilds + 1
    start_watch(root)
  end
  return state.idx
end

--- Parsed data of one note (see parse.note). Open buffers are parsed from their current text.
function M.data(abs, loaded)
  local b = loaded and loaded[abs]
  if b then
    return parse.note(vim.api.nvim_buf_get_lines(b, 0, -1, false))
  end
  local st = vim.uv.fs_stat(abs)
  if not st then
    return nil
  end
  local mt = st.mtime or {}
  local key = (mt.sec or 0) .. "." .. (mt.nsec or 0) .. ":" .. (st.size or 0)
  local c = state.notes[abs]
  if c and c.key == key then
    return c.data
  end
  local ok, lines = pcall(vim.fn.readfile, abs, "b")
  if not ok then
    return nil
  end
  for i, l in ipairs(lines) do
    lines[i] = (l:gsub("\r$", ""))
  end
  local data = parse.note(lines)
  state.notes[abs] = { key = key, data = data }
  return data
end

--- Force a structure rescan on the next get().
function M.invalidate()
  state.dirty = true
end

function M.reset()
  stop_watch()
  state.root, state.idx, state.dirty, state.notes = nil, nil, true, {}
end

function M.stats()
  local n = 0
  for _ in pairs(state.notes) do
    n = n + 1
  end
  return {
    root = state.root,
    files = state.idx and #state.idx.md or 0,
    notes_cached = n,
    watchers = #state.watchers,
    rebuilds = state.rebuilds,
  }
end

function M.setup()
  M.reset()
  local g = vim.api.nvim_create_augroup("NotesIndex", { clear = true })
  vim.api.nvim_create_autocmd({ "FocusGained", "BufWritePost", "BufDelete", "DirChanged" }, {
    group = g,
    callback = M.invalidate,
  })
end

return M
