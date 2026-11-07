-- notes.nvim: wiring only (config, commands, autocmds, keymaps)
local M = {}

M.defaults = {
  -- vault
  vault_path = nil, -- nil = auto-detect via .obsidian/
  template_dir = "templates", -- relative to vault root, or absolute
  new_note_dir = nil, -- where :NoteNew creates notes; nil = vault root. Relative to vault root, or absolute

  -- templates
  auto_inject = true,
  default_template = nil, -- nil = open picker on new file
  inject_at_cursor = false,
  confirm_overwrite = true,

  -- formatting
  date_format = "%Y-%m-%d",
  time_format = "%H:%M",

  -- linking
  link_display = "filename", -- "filename" | "title"
  wikilinks = false,
  link_stack_max = 50,

  -- outline sidebar
  outline_width = 36,
  outline_side = "right", -- "left" | "right"

  -- embeds: image backends are tried in order until one works
  embed_backends = { "kitty", "kitty-direct", "chafa", "viu", "external" },
  embed_inline = true, -- render ![[note]] embeds as virtual lines automatically (like images)
  embed_inline_lines = 8, -- max lines shown per inline note embed

  -- native images (kitty graphics protocol: Ghostty, kitty; also through tmux)
  inline_images = "auto", -- true | false | "auto": render images below their ![[...]] line when supported
  image_protocol = "auto", -- "auto" | "kitty" (skip terminal detection) | "none" (disable kitty-protocol features)
  image_max_cols = 70,
  image_max_rows = 22,
  image_cell_ratio = 2.0, -- cell height / width in pixels; tweak if images look stretched

  -- attachments (images, pdf, ...): searched after the direct path, before a vault-wide name search
  attachment_dir = nil, -- string or list; relative to the vault root / note folders, or absolute
  attachment_dirs = { "attachments", "assets", "static", "img", "images", "files", "media", "resources", "pics" },

  -- ui
  picker = "auto", -- "auto" | "telescope" | "fzf-lua" | "vim.ui.select"
  float_border = "rounded",

  keymaps = true,
}

M.config = vim.deepcopy(M.defaults)

local vault = require("notes.vault")
local template = require("notes.template")
local links = require("notes.links")
local move = require("notes.move")
local outline = require("notes.outline")
local embed = require("notes.embed")
local image = require("notes.image")
local picker = require("notes.picker")
local util = require("notes.util")

local function validate(c)
  local function enum(key, allowed)
    if not vim.tbl_contains(allowed, c[key]) then
      util.notify(("invalid %s = %s; using '%s'"):format(key, tostring(c[key]), M.defaults[key]), vim.log.levels.WARN)
      c[key] = M.defaults[key]
    end
  end
  enum("link_display", { "filename", "title" })
  enum("picker", { "auto", "telescope", "fzf-lua", "vim.ui.select" })
  enum("outline_side", { "left", "right" })
  if type(c.embed_backends) ~= "table" then
    c.embed_backends = M.defaults.embed_backends
  end
  enum("inline_images", { true, false, "auto" })
  enum("image_protocol", { "auto", "kitty", "none" })
  if type(c.attachment_dirs) ~= "table" then
    c.attachment_dirs = M.defaults.attachment_dirs
  end
  if c.attachment_dir ~= nil and type(c.attachment_dir) ~= "string" and type(c.attachment_dir) ~= "table" then
    util.notify("attachment_dir must be a string or a list; ignoring", vim.log.levels.WARN)
    c.attachment_dir = nil
  end
  if type(c.link_stack_max) ~= "number" or c.link_stack_max < 1 then
    c.link_stack_max = M.defaults.link_stack_max
  end
end

function M.pick_template(bufnr)
  local names, err = template.list()
  if err then
    util.notify(err, vim.log.levels.WARN)
    return
  end
  if #names == 0 then
    util.notify("no templates found", vim.log.levels.WARN)
    return
  end
  picker.select(names, { prompt = "Templates" }, function(name)
    template.inject(bufnr, name)
  end)
end

--- Create a note in new_note_dir (prompts for a name if none given).
function M.new_note(name)
  local function create(n)
    if not n or vim.trim(n) == "" then
      return
    end
    local path, is_new = template.new_note(n)
    if not path or not is_new then
      return
    end
    local c = M.config
    -- BufNewFile handles injection when auto_inject applies; otherwise do it here
    if c.auto_inject and vault.is_in_vault(path) and not template.is_template_path(path) then
      return
    end
    vim.schedule(function()
      local buf = vim.api.nvim_get_current_buf()
      if c.default_template then
        template.inject(buf, c.default_template)
      else
        M.pick_template(buf)
      end
    end)
  end
  if name and name ~= "" then
    create(name)
  else
    vim.ui.input({ prompt = "New note name: " }, create)
  end
end

local function guard(fn)
  return function()
    if not vault.require_root() then
      return
    end
    if not vault.is_in_vault(vim.api.nvim_buf_get_name(0)) then
      util.notify("buffer is not inside the vault", vim.log.levels.WARN)
      return
    end
    fn()
  end
end

local function reload()
  local names, err = template.list()
  if err then
    util.notify(err, vim.log.levels.WARN)
  else
    util.notify(("%d template(s) found"):format(#names))
  end
end

local function show_vault()
  local root = vault.get_root()
  print(root and ("notes vault: " .. root) or ("notes: vault not detected (" .. vault.reason() .. ")"))
end

local function attach(bufnr)
  if vim.bo[bufnr].buftype ~= "" then
    return
  end
  embed.auto_attach(bufnr)
  if not M.config.keymaps then
    return
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, desc = "Notes: " .. desc })
  end
  map("gf", function()
    links.follow_link(bufnr)
  end, "follow link")
  map("<leader>mt", guard(function()
    M.pick_template(bufnr)
  end), "insert template")
  map("<leader>ml", guard(function()
    links.insert_file_link(bufnr)
  end), "link file")
  map("<leader>mh", guard(function()
    links.insert_header_link(bufnr)
  end), "link header")
  map("<leader>mb", guard(links.go_back), "go back")
  map("<leader>mo", function()
    outline.open(bufnr)
  end, "outline picker")
  map("<leader>mO", outline.toggle, "outline sidebar")
  map("<leader>me", embed.preview, "preview link/embed")
  map("<C-LeftMouse>", embed.preview_mouse, "preview link/embed under mouse")
  map("<leader>mE", function()
    embed.toggle_inline(bufnr)
  end, "toggle inline note embeds")
  map("<leader>mi", function()
    embed.toggle_images(bufnr)
  end, "toggle inline images")
  map("<leader>mm", guard(function()
    move.pick(bufnr)
  end), "move note")
  map("<leader>mr", reload, "reload templates")
  map("<leader>mv", show_vault, "show vault")
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  validate(M.config)
  picker.reset()
  vault.detect()

  vim.api.nvim_create_user_command("TemplateInsert", function(o)
    local buf = vim.api.nvim_get_current_buf()
    if o.args ~= "" then
      template.inject(buf, o.args)
    else
      M.pick_template(buf)
    end
  end, {
    nargs = "?",
    desc = "Insert a template (picker if no name)",
    complete = function()
      return (template.list())
    end,
  })
  vim.api.nvim_create_user_command("TemplateReload", reload, { desc = "Re-read the templates directory" })
  vim.api.nvim_create_user_command("NotesVault", show_vault, { desc = "Print detected vault root" })
  vim.api.nvim_create_user_command("NoteNew", function(o)
    M.new_note(o.args)
  end, { nargs = "?", desc = "Create a note in new_note_dir" })
  vim.api.nvim_create_user_command("NoteOutline", function(o)
    outline.open(nil, tonumber(o.args))
  end, { nargs = "?", desc = "Heading outline picker (optional max level)" })
  vim.api.nvim_create_user_command("NoteOutlineToggle", outline.toggle, { desc = "Toggle the outline sidebar" })
  vim.api.nvim_create_user_command("NoteEmbedPreview", embed.preview, { desc = "Preview the embed under the cursor" })
  vim.api.nvim_create_user_command("NoteEmbedInline", function()
    embed.toggle_inline()
  end, { desc = "Toggle inline note embeds" })
  vim.api.nvim_create_user_command("NoteImageToggle", function()
    embed.toggle_images()
  end, { desc = "Toggle inline images in this buffer" })
  vim.api.nvim_create_user_command("NoteImageStatus", function()
    print(table.concat(image.status(), "\n"))
  end, { desc = "Show image rendering capabilities" })
  vim.api.nvim_create_user_command("NoteMove", function(o)
    local buf = vim.api.nvim_get_current_buf()
    if o.args ~= "" then
      move.to_dir(buf, o.args)
    else
      move.pick(buf)
    end
  end, {
    nargs = "?",
    desc = "Move current note to a directory (picker if none given)",
    complete = function(lead)
      local root = vault.get_root()
      if not root then
        return {}
      end
      return vim.tbl_filter(function(d)
        return d:find(lead, 1, true) == 1
      end, util.list_dirs_recursive(root))
    end,
  })
  if M.config.keymaps then
    vim.keymap.set("n", "<leader>mn", function()
      M.new_note()
    end, { desc = "Notes: new note" })
  end

  local group = vim.api.nvim_create_augroup("Notes", { clear = true })

  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    pattern = "*.md",
    callback = function(args)
      if not M.config.auto_inject then
        return
      end
      local path = vim.api.nvim_buf_get_name(args.buf)
      if not vault.is_in_vault(path) or template.is_template_path(path) then
        return
      end
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) or not template.is_empty(args.buf) then
          return
        end
        if M.config.default_template then
          template.inject(args.buf, M.config.default_template)
        else
          M.pick_template(args.buf)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "markdown",
    callback = function(args)
      attach(args.buf)
    end,
  })

  -- setup() may run after markdown buffers already exist (lazy loading)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "markdown" then
      attach(b)
    end
  end
end

return M
