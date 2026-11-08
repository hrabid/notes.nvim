-- notes.nvim: capture - clipboard image paste, and the embed picker (<leader>me)
local util = require("notes.util")
local vault = require("notes.vault")
local picker = require("notes.picker")
local files = require("notes.files")
local index = require("notes.index")

local M = {}

local function cfg()
  return require("notes").config
end

-- ── clipboard image paste ────────────────────────────────────────────

local TYPES = { "image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp" }
local EXT = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/webp"] = "webp", ["image/gif"] = "gif", ["image/bmp"] = "bmp" }

--- Best image type out of a newline separated clipboard type list.
function M._pick_type(list_text)
  local have = {}
  for t in list_text:gmatch("[^\r\n]+") do
    have[vim.trim(t)] = true
  end
  for _, t in ipairs(TYPES) do
    if have[t] then
      return t
    end
  end
  return nil
end

--- Folder pasted images go to: attachment_dir (first entry), else an existing conventional
--- folder in the vault root, else <vault>/attachments.
function M._paste_dir(root, c)
  local ad = c.attachment_dir
  if type(ad) == "table" then
    ad = ad[1]
  end
  if type(ad) == "string" and ad ~= "" then
    ad = util.expand_path(ad)
    return ad:sub(1, 1) == "/" and ad or (root .. "/" .. ad)
  end
  for _, d in ipairs(c.attachment_dirs or {}) do
    if vim.fn.isdirectory(root .. "/" .. d) == 1 then
      return root .. "/" .. d
    end
  end
  return root .. "/attachments"
end

local function sanitize(name, ext)
  name = vim.trim(name)
  name = name:gsub("%." .. ext .. "$", "")
  name = name:gsub("[%c/\\]", "-")
  name = name:gsub("%s+", "-")
  name = name:gsub("^%.+", "")
  return name
end

local function unique_path(dir, name, ext)
  local path = dir .. "/" .. name .. "." .. ext
  local i = 0
  while vim.uv.fs_stat(path) do
    i = i + 1
    path = ("%s/%s-%d.%s"):format(dir, name, i, ext)
  end
  return path
end

local function exe(n)
  return vim.fn.executable(n) == 1
end

local function backend()
  local env = vim.env
  if env.WAYLAND_DISPLAY and exe("wl-paste") then
    return {
      name = "wl-paste",
      list = { "wl-paste", "--list-types" },
      get = function(t)
        return { "wl-paste", "--no-newline", "--type", t }
      end,
    }
  end
  if env.DISPLAY and exe("xclip") then
    return {
      name = "xclip",
      list = { "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" },
      get = function(t)
        return { "xclip", "-selection", "clipboard", "-t", t, "-o" }
      end,
    }
  end
  if exe("pngpaste") then
    return { name = "pngpaste", direct = true } -- macOS: `pngpaste <file>`, png only
  end
  return nil
end

local function run(cmd)
  local ok, res = pcall(function()
    return vim.system(cmd):wait(8000)
  end)
  if ok and res and res.code == 0 then
    return res
  end
  return nil
end

--- Save the clipboard image into the attachment folder and embed it at the cursor.
function M.paste_image(name_arg)
  local root = vault.require_root()
  if not root then
    return
  end
  local be = backend()
  if not be then
    util.notify("no clipboard tool found (install wl-clipboard, xclip or pngpaste)", vim.log.levels.WARN)
    return
  end
  local itype = "image/png"
  if not be.direct then
    local res = run(be.list)
    itype = res and M._pick_type(res.stdout or "")
    if not itype then
      util.notify("the clipboard does not contain an image", vim.log.levels.WARN)
      return
    end
  end
  local ext = EXT[itype]
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()

  local function save(name)
    name = sanitize(name or "", ext)
    if name == "" then
      return
    end
    local c = cfg()
    local dir = M._paste_dir(root, c)
    vim.fn.mkdir(dir, "p")
    local path = unique_path(dir, name, ext)
    if be.direct then
      if not run({ "pngpaste", path }) then
        util.notify("pngpaste failed", vim.log.levels.ERROR)
        return
      end
    else
      local res = run(be.get(itype))
      if not res or not res.stdout or #res.stdout == 0 then
        util.notify("could not read the image from the clipboard", vim.log.levels.ERROR)
        return
      end
      local f, err = io.open(path, "wb")
      if not f then
        util.notify("cannot write " .. path .. ": " .. tostring(err), vim.log.levels.ERROR)
        return
      end
      f:write(res.stdout)
      f:close()
    end
    index.invalidate()
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
      util.notify("saved " .. path .. " (the original window changed, link not inserted)", vim.log.levels.WARN)
      return
    end
    local item = { kind = "image", abs = path, rel = vim.fs.basename(path) }
    local text = files.link_text(item, {
      style = c.embed_style,
      embed = true,
      note_abs = vim.api.nvim_buf_get_name(buf),
      root = root,
      idx = index.get(root),
      path_style = c.link_path,
    })
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_put({ text }, "c", true, true)
    end)
    util.notify("saved " .. path)
  end

  local default = os.date("image-%Y%m%d-%H%M%S")
  if name_arg and name_arg ~= "" then
    save(name_arg)
  elseif cfg().paste_name == "auto" then
    save(default)
  else
    vim.ui.input({ prompt = "Image name: ", default = default }, function(n)
      if n and vim.trim(n) ~= "" then
        save(n)
      end
    end)
  end
end

-- ── embed picker ─────────────────────────────────────────────────────

--- Pick a note or attachment (images, pdf, audio, anything in the attachment folders)
--- and embed it at the cursor in the configured style.
function M.embed()
  local root = vault.require_root()
  if not root then
    return
  end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local cur = util.expand_path(vim.api.nvim_buf_get_name(buf))
  local items = {}
  for _, it in ipairs(files.list(root, { notes = true, attachments = true })) do
    if it.abs ~= cur then
      items[#items + 1] = it
    end
  end
  if #items == 0 then
    util.notify("nothing to embed in the vault", vim.log.levels.WARN)
    return
  end
  picker.select(items, { prompt = "Embed", preview = true }, function(item)
    if not (vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
      util.notify("the original window changed, nothing inserted", vim.log.levels.WARN)
      return
    end
    local c = cfg()
    local text = files.link_text(item, {
      style = c.embed_style,
      embed = true,
      note_abs = vim.api.nvim_buf_get_name(buf),
      root = root,
      idx = index.get(root),
      path_style = c.link_path,
      display = c.link_display,
    })
    vim.api.nvim_win_call(win, function()
      vim.api.nvim_put({ text }, "c", true, true)
    end)
  end)
end

return M
