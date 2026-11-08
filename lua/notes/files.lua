-- notes.nvim: what can be linked/embedded - notes plus attachments (images, pdf, audio, ...)
local util = require("notes.util")
local index = require("notes.index")
local template = require("notes.template")

local M = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

M.IMAGE = set({ "png", "jpg", "jpeg", "jfif", "gif", "webp", "bmp", "svg", "avif", "tif", "tiff", "heic", "heif", "jxl", "ico", "apng" })
M.AUDIO = set({ "mp3", "wav", "ogg", "flac", "m4a", "opus", "aac" })
M.VIDEO = set({ "mp4", "mkv", "webm", "mov", "avi" })

--- "note" | "image" | "pdf" | "audio" | "video" | "file"
function M.kind_of(path)
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if ext == "md" then
    return "note"
  end
  if M.IMAGE[ext] then
    return "image"
  end
  if ext == "pdf" then
    return "pdf"
  end
  if M.AUDIO[ext] then
    return "audio"
  end
  if M.VIDEO[ext] then
    return "video"
  end
  return "file"
end

local EMBEDDABLE = { note = true, image = true, pdf = true, audio = true, video = true }

function M.embeddable(kind)
  return EMBEDDABLE[kind] == true
end

local function in_attachment_dir(rel, attset)
  local segs = vim.split(rel, "/", { plain = true })
  for i = 1, #segs - 1 do
    if attset[segs[i]:lower()] then
      return true
    end
  end
  return false
end

--- Notes and attachments of the vault as picker items { display, rel, abs, kind, binary }.
--- Attachments = every file inside an attachment folder (attachment_dir / attachment_dirs),
--- plus images, pdf, audio and video anywhere else. opts.notes / opts.attachments (default true).
function M.list(root, opts)
  opts = opts or {}
  local want_notes, want_att = opts.notes ~= false, opts.attachments ~= false
  local idx = index.get(root)
  local out = {}
  for _, rel in ipairs(idx.files) do
    local abs = root .. "/" .. rel
    local kind = M.kind_of(rel)
    local include
    if kind == "note" then
      include = want_notes
    else
      include = want_att and (kind ~= "file" or in_attachment_dir(rel, idx.attset))
    end
    if include and not template.is_template_path(abs) then
      out[#out + 1] = {
        display = ("[%s] %s"):format(kind, rel),
        rel = rel,
        abs = abs,
        kind = kind,
        binary = kind ~= "note" or nil,
      }
    end
  end
  return out
end

--- The path to write for `abs` inside a link. o = { idx, root, note_abs, path_style }.
--- "shortest" (Obsidian default): the bare file name when it is unique in the vault, else the
--- shortest suffix that is ("folder/note.md"). "relative": relative to the current note.
function M.target_path(abs, o)
  local root = o.root or (o.idx and o.idx.root)
  if o.path_style == "shortest" and o.idx and root then
    local rel = abs:sub(#root + 2)
    local base = vim.fs.basename(rel)
    local list = o.idx.by_name[base]
    if not list or #list <= 1 then
      return base
    end
    local segs = vim.split(rel, "/", { plain = true })
    for k = 2, #segs - 1 do
      local suffix = table.concat(segs, "/", #segs - k + 1)
      local count = 0
      for _, r in ipairs(list) do
        if r == suffix or r:sub(-(#suffix + 1)) == "/" .. suffix then
          count = count + 1
        end
      end
      if count == 1 then
        return suffix
      end
    end
    return rel
  end
  local from = (o.note_abs and o.note_abs ~= "") and vim.fs.dirname(o.note_abs) or root
  return util.relative_path(from, abs)
end

--- Link / embed text for a picked item.
--- o = { style = "markdown" | "wiki", embed = bool, note_abs, root, idx, path_style, display = "filename" | "title" }
--- Things that cannot be embedded (zip, ...) become plain links.
function M.link_text(item, o)
  local kind = item.kind
  local bang = (o.embed and M.embeddable(kind)) and "!" or ""
  local base = vim.fs.basename(item.rel)
  if o.style == "wiki" then
    local name = base
    if o.idx then
      name = M.target_path(item.abs, { idx = o.idx, root = o.root, path_style = "shortest" }) -- ambiguous names keep a path
    end
    if kind == "note" then
      name = name:gsub("%.md$", "")
    end
    return ("%s[[%s]]"):format(bang, name)
  end
  local rel = M.target_path(item.abs, o):gsub(" ", "%%20")
  local stem = (base:gsub("%.%w+$", ""))
  local text = (kind == "file") and base or stem
  if kind == "note" and o.display == "title" then
    text = util.to_title_case(stem)
  end
  return ("%s[%s](%s)"):format(bang, text, rel)
end

return M
