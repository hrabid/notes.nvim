-- notes.nvim: move the current note to another directory
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local links = require("notes.links")

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

--- Move the file behind `bufnr` into `dir` (relative to vault root, or absolute).
--- Unsaved/new files are just renamed in the buffer (written on :w).
--- opts.confirm: prompt first when the file already exists on disk.
--- opts.quiet:   no message when already in the target directory.
function M.to_dir(bufnr, dir, opts)
  opts = opts or {}
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
  local dest = target_dir .. "/" .. vim.fs.basename(src)
  if dest == src then
    if not opts.quiet then
      util.notify("already in " .. dir)
    end
    return true
  end
  if vim.uv.fs_stat(dest) then
    util.notify("target already exists: " .. dest, vim.log.levels.WARN)
    return false
  end

  local on_disk = vim.uv.fs_stat(src) ~= nil
  if on_disk and opts.confirm then
    local msg = ("Move %s to %s?"):format(vim.fs.basename(src), dir)
    if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
      return false
    end
  end

  vim.fn.mkdir(target_dir, "p")
  if on_disk then
    if vim.bo[bufnr].modified then
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd("silent write")
      end)
    end
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
  util.notify("moved to " .. dest)
  return true
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
