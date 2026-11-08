-- :checkhealth notes
local M = {}

function M.check()
  local h = vim.health
  h.start("notes.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 is required")
  end
  if vim.fn.exists(":NoteSearch") == 2 then
    h.ok("setup() was called (commands are registered)")
  else
    h.error("commands are missing: call require('notes').setup()")
  end

  local vault = require("notes.vault")
  local root = vault.detect()
  if root then
    h.ok("vault: " .. root)
    local index = require("notes.index")
    local ok, idx = pcall(index.get, root)
    if ok then
      local st = index.stats()
      h.ok(("index: %d markdown files, %d directory watchers"):format(#idx.md, st.watchers))
      if st.watchers == 0 then
        h.warn("no directory watchers (index_watch = false, too many directories, or inotify limit); the index refreshes on focus/save/:NoteReindex")
      end
    else
      h.warn("index could not be built: " .. tostring(idx))
    end
    local names = require("notes.template").list()
    if #names > 0 then
      h.ok(#names .. " template(s)")
    else
      h.warn("no templates found (template_dir)")
    end
  else
    h.warn("vault not detected (" .. vault.reason() .. "); set vault_path or open Neovim inside the vault")
  end

  local picker = require("notes.picker")
  h.info("picker backend: " .. picker.backend())
  if vim.fn.executable("rg") == 1 then
    h.ok("ripgrep found (:NoteSearch fallback)")
  else
    h.warn("ripgrep not found (only needed for :NoteSearch without telescope/fzf-lua)")
  end

  h.start("notes.nvim: images")
  for _, l in ipairs(require("notes.image").status()) do
    h.info(l)
  end
  if not require("notes.image").converter_name("jpg") then
    h.warn("only PNG images can be rendered inline: install ImageMagick, libvips or ffmpeg to convert jpg/gif/webp/...")
  end
  if vim.fn.executable("pdftoppm") == 0 and vim.fn.executable("mutool") == 0 then
    h.info("no pdftoppm/mutool: PDF first-page previews need poppler or mupdf (or ImageMagick + ghostscript)")
  end

  h.start("notes.nvim: clipboard")
  local found
  for _, t in ipairs({ "wl-paste", "xclip", "pngpaste" }) do
    if vim.fn.executable(t) == 1 then
      found = t
      break
    end
  end
  if found then
    h.ok("image paste via " .. found)
  else
    h.warn("no clipboard tool (wl-clipboard / xclip / pngpaste): :NotePasteImage is unavailable")
  end

  h.start("notes.nvim: completion")
  if pcall(require, "blink.cmp") then
    h.ok("blink.cmp found: add the 'notes' provider (module = 'notes.blink')")
  elseif pcall(require, "cmp") then
    h.ok("nvim-cmp found: add { name = 'notes' } to sources")
  else
    h.info("no completion plugin found (optional)")
  end
end

return M
