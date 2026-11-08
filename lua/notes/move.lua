-- notes.nvim: move / rename the current note (links pointing at it are updated)
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local links = require("notes.links")
local integrity = require("notes.integrity")

local M = {}

local function abs_dir(dir)
  if dir == "." or dir == "" then
    return vault.get_root()
  end
  dir = util.expand_path(dir)
  if dir:sub(1, 1) == "/" then
    return dir
  end
  local root = vault.get_root()
  return root and (root .. "/" .. dir) or nil
end

--- Move the file behind `bufnr` to the absolute path `dest`.
--- Unsaved/new files are just renamed in the buffer (written on :w).
--- For files on disk, links in the vault are updated per config.update_links
--- ("ask" | true | false). opts.confirm: prompt before moving; opts.quiet: no message
--- when already at `dest`.
function M.relocate(bufnr, dest, opts)
  opts = opts or {}
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local src = vim.api.nvim_buf_get_name(bufnr)
  if src == "" then
    util.notify("buffer has no file name", vim.log.levels.WARN)
    return false
  end
  if dest == src then
    if not opts.quiet then
      util.notify("already there")
    end
    return true
  end
  if vim.uv.fs_stat(dest) then
    util.notify("target already exists: " .. dest, vim.log.levels.WARN)
    return false
  end

  local on_disk = vim.uv.fs_stat(src) ~= nil
  local plan
  if on_disk then
    if opts.confirm then
      if vim.fn.confirm(("Move %s?"):format(vim.fs.basename(src)), "&Yes\n&No", 2) ~= 1 then
        return false
      end
    end
    if vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent write")
      end)
    end
    local mode = require("notes").config.update_links
    if mode ~= false and vault.is_in_vault(src) then
      plan = integrity.plan_move(util.expand_path(src), util.expand_path(dest))
      if plan and plan.links == 0 then
        plan = nil
      end
      if plan and mode == "ask" then
        local msg = ("Update %d link(s) in %d file(s)?"):format(plan.links, plan.files)
        local c = vim.fn.confirm(msg, "&Update links\n&Move only\n&Cancel", 1)
        if c == 0 or c == 3 then
          return false
        end
        if c == 2 then
          plan = nil
        end
      end
    end
  end

  vim.fn.mkdir(vim.fs.dirname(dest), "p")
  if on_disk then
    local ok, err = vim.uv.fs_rename(src, dest)
    if not ok then
      util.notify("move failed: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end
  end

  vim.api.nvim_buf_set_name(bufnr, dest)
  if on_disk then
    -- drop the stale buffer left behind under the old name, reload from the new path
    local old = vim.fn.bufnr(src)
    if old ~= -1 and old ~= bufnr then
      pcall(vim.api.nvim_buf_delete, old, { force = true })
    end
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! edit!")
    end)
  end
  links.rename_stack(src, dest)

  if plan then
    local res = integrity.apply(plan, { [util.expand_path(src)] = dest })
    local msg = ("moved to %s; updated %d link(s) in %d file(s)"):format(dest, res.links, res.files)
    if res.unsaved > 0 then
      msg = msg .. (" (%d open buffer(s) have unsaved changes)"):format(res.unsaved)
    end
    if res.failed > 0 then
      msg = msg .. (" - %d link(s) could not be updated, run :NoteCheck"):format(res.failed)
    end
    util.notify(msg, res.failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
  else
    util.notify("moved to " .. dest)
  end
  return true
end

--- Move the file of `bufnr` into `dir` (relative to vault root, or absolute).
function M.to_dir(bufnr, dir, opts)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local src = vim.api.nvim_buf_get_name(bufnr)
  if src == "" then
    util.notify("buffer has no file name", vim.log.levels.WARN)
    return false
  end
  local target_dir = abs_dir(dir)
  if not target_dir then
    util.notify("cannot resolve directory (vault not detected): " .. dir, vim.log.levels.WARN)
    return false
  end
  return M.relocate(bufnr, target_dir .. "/" .. vim.fs.basename(src), opts)
end

--- Rename the current note inside its folder.
function M.rename(bufnr, name)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local src = vim.api.nvim_buf_get_name(bufnr)
  if src == "" then
    util.notify("buffer has no file name", vim.log.levels.WARN)
    return
  end
  local function go(n)
    n = vim.trim(n or "")
    n = n:gsub("%.md$", "")
    if n == "" or n == "." or n == ".." then
      return
    end
    if n:find("/", 1, true) then
      util.notify("a new name cannot contain '/': use :NoteMove to change folders", vim.log.levels.WARN)
      return
    end
    local ext = src:match("%.[^./]+$") or ".md"
    M.relocate(bufnr, vim.fs.dirname(src) .. "/" .. n .. ext)
  end
  if name and name ~= "" then
    go(name)
  else
    vim.ui.input({ prompt = "Rename to: ", default = vim.fn.fnamemodify(src, ":t:r") }, function(n)
      if n then
        go(n)
      end
    end)
  end
end

--- Directory picker (vault dirs + "new directory"), then move the current file.
function M.pick(bufnr)
  local root = vault.require_root()
  if not root then
    return
  end
  local items = { { display = "/  (vault root)", dir = "." } }
  for _, d in ipairs(util.list_dirs_recursive(root)) do
    items[#items + 1] = { display = d, dir = d }
  end
  items[#items + 1] = { display = "+ new directory...", new = true }

  picker.select(items, { prompt = "Move to" }, function(item)
    if item.new then
      vim.ui.input({ prompt = "New directory (relative to vault): " }, function(d)
        if d and vim.trim(d) ~= "" then
          M.to_dir(bufnr, vim.trim(d))
        end
      end)
    else
      M.to_dir(bufnr, item.dir)
    end
  end)
end

return M
