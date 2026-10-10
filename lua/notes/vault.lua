-- notes.nvim: vault root detection
local util = require("notes.util")

local M = {}

local root = nil
local pinned = false -- true when root comes from an explicit, valid vault_path
local reason = "not detected yet"
local warned = false

local function cfg()
  return require("notes").config
end

--- Walk up from `start` (a directory, or a path whose ancestors exist)
--- looking for .obsidian/. Works from any child directory of the vault.
local function find_upward(start)
  if not start or start == "" then
    return nil
  end
  -- new files may live in directories that don't exist yet
  while vim.fn.isdirectory(start) == 0 do
    local parent = vim.fs.dirname(start)
    if not parent or parent == start then
      return nil
    end
    start = parent
  end
  local found = vim.fs.find(".obsidian", { path = start, upward = true, type = "directory" })[1]
  return found and vim.fs.dirname(found) or nil
end

local function inside(path, base)
  return path == base or path:sub(1, #base + 1) == base .. "/"
end

--- Detect and cache the vault root. Silent; use require_root() to warn.
function M.detect()
  local c = cfg()
  pinned = false
  if c.vault_path and c.vault_path ~= "" then
    local p = util.expand_path(c.vault_path)
    if vim.fn.isdirectory(p) == 1 then
      root, pinned, reason = p, true, nil
      return root
    end
    reason = "vault_path does not exist: " .. p
  end

  local name = vim.api.nvim_buf_get_name(0)
  local r = find_upward(name ~= "" and vim.fs.dirname(name) or nil) or find_upward(vim.uv.cwd())
  if r then
    root, reason = util.expand_path(r), nil
    return root
  end
  reason = reason or "no .obsidian/ directory found above buffer or cwd"
  return nil
end

function M.get_root()
  return root or M.detect()
end

--- Like get_root(), but warns once per session on failure.
function M.require_root()
  local r = M.get_root()
  if not r and not warned then
    warned = true
    util.notify("vault not detected (" .. M.reason() .. "); vault features disabled", vim.log.levels.WARN)
  end
  return r
end

function M.reason()
  return reason or "ok"
end

--- True if `path` is inside the vault. Unless vault_path pins the root,
--- the vault is re-detected from the path itself (child dirs, other vaults).
function M.is_in_vault(path)
  if not path or path == "" then
    return false
  end
  local p = util.expand_path(path)
  local r = M.get_root()
  if r and inside(p, r) then
    return true
  end
  if pinned then
    return false
  end
  local found = find_upward(vim.fs.dirname(p))
  if found then
    root, reason = util.expand_path(found), nil
    return true
  end
  return false
end

function M.resolve(rel_path)
  local r = M.get_root()
  return r and (r .. "/" .. rel_path) or nil
end

return M
