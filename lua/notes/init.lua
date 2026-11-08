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
  update_links = "ask", -- "ask" | true | false: rewrite links when a note is moved/renamed

  -- capture
  embed_style = "markdown", -- "markdown" | "wiki": style of embeds from <leader>me and pasted images
  link_path = "shortest", -- "shortest" (file name when unique, like Obsidian) | "relative" (../dir/file.ext)
  paste_name = "ask", -- "ask" | "auto": prompt for the pasted image's name

  -- housekeeping
  index_watch = true, -- watch vault directories so the cached index notices new/removed/renamed files

  -- table of contents
  toc_min_level = 1,
  toc_max_level = 3,
  toc_auto_update = true, -- refresh an existing <!-- toc --> block on save

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
local integrity = require("notes.integrity")
local capture = require("notes.capture")
local search = require("notes.search")
local nav = require("notes.nav")
local index = require("notes.index")
local edit = require("notes.edit")
local completion = require("notes.completion")
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
  enum("update_links", { "ask", true, false })
  enum("embed_style", { "markdown", "wiki" })
  enum("link_path", { "shortest", "relative" })
  enum("paste_name", { "ask", "auto" })
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
  if M.config.toc_auto_update then
    local g = vim.api.nvim_create_augroup("NotesToc", { clear = false })
    vim.api.nvim_clear_autocmds({ group = g, buffer = bufnr })
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = g,
      buffer = bufnr,
      callback = function()
        nav.update_toc(bufnr)
      end,
    })
  end
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
  map("<leader>mp", embed.preview, "preview link/embed")
  map("<leader>mR", guard(function()
    move.rename(bufnr)
  end), "rename note")
  map("<leader>mk", guard(integrity.backlinks), "backlinks")
  map("<leader>mP", guard(function()
    capture.paste_image()
  end), "paste image from clipboard")
  map("<leader>me", guard(function()
    capture.embed()
  end), "embed a note / image / pdf / attachment")
  map("<leader>mC", function()
    nav.toc()
  end, "table of contents")
  map("<leader>mL", function()
    edit.convert_link()
  end, "convert link style (wiki <-> markdown)")
  map("<leader>mx", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    edit.toggle_range(row, row + vim.v.count1 - 1)
  end, "toggle checkbox")
  vim.keymap.set("x", "<leader>mx", function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    if a > b then
      a, b = b, a
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    edit.toggle_range(a, b)
  end, { buffer = bufnr, desc = "Notes: toggle checkboxes" })
  map("<leader>m]", function()
    nav.jump_link(1)
  end, "next link")
  map("<leader>m[", function()
    nav.jump_link(-1)
  end, "previous link")
  map("<leader>m}", function()
    nav.jump_heading(1)
  end, "next heading")
  map("<leader>m{", function()
    nav.jump_heading(-1)
  end, "previous heading")
  map("<leader>m-", function()
    links.follow_link(bufnr, { open = "split" })
  end, "follow link in split")
  map("<leader>m|", function()
    links.follow_link(bufnr, { open = "vsplit" })
  end, "follow link in vsplit")
  map("<leader>m+", function()
    links.follow_link(bufnr, { open = "tab" })
  end, "follow link in tab")
  map("<leader>mc", guard(function()
    integrity.check()
  end), "check links")
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
  index.setup()
  completion.setup()
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
  vim.api.nvim_create_user_command("NotePreview", function()
    embed.preview()
  end, { desc = "Preview the link/embed under the cursor" })
  vim.api.nvim_create_user_command("NoteEmbedInline", function()
    embed.toggle_inline()
  end, { desc = "Toggle inline note embeds" })
  vim.api.nvim_create_user_command("NoteImageToggle", function()
    embed.toggle_images()
  end, { desc = "Toggle inline images in this buffer" })
  vim.api.nvim_create_user_command("NoteImageStatus", function()
    print(table.concat(image.status(), "\n"))
  end, { desc = "Show image rendering capabilities" })
  vim.api.nvim_create_user_command("NoteEmbed", function()
    capture.embed()
  end, { desc = "Embed a note / image / pdf / attachment at the cursor" })
  vim.api.nvim_create_user_command("NotePasteImage", function(o)
    capture.paste_image(o.args)
  end, { nargs = "?", desc = "Save the clipboard image into the vault and link it" })
  vim.api.nvim_create_user_command("NoteSearch", function(o)
    search.text(o.args)
  end, { nargs = "?", desc = "Search the vault's text" })
  vim.api.nvim_create_user_command("NoteTags", function(o)
    search.tags(o.args)
  end, { nargs = "?", desc = "Browse tags" })
  vim.api.nvim_create_user_command("NoteProps", function(o)
    search.props(o.args)
  end, { nargs = "?", desc = "Browse frontmatter properties (key or key=value)" })
  vim.api.nvim_create_user_command("NoteToc", function(o)
    nav.toc(tonumber(o.args))
  end, { nargs = "?", desc = "Insert/update the table of contents (optional max level)" })
  vim.api.nvim_create_user_command("NoteFollow", function(o)
    links.follow_link(nil, { open = (o.args ~= "" and o.args or "split") })
  end, {
    nargs = "?",
    complete = function()
      return { "split", "vsplit", "tab" }
    end,
    desc = "Follow the link under the cursor in a split/vsplit/tab",
  })
  vim.api.nvim_create_user_command("NoteLinkConvert", function(o)
    edit.convert_link(o.args ~= "" and o.args or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "wiki", "markdown" }
    end,
    desc = "Convert the link under the cursor (or all links to wiki/markdown)",
  })
  vim.api.nvim_create_user_command("NoteTask", function(o)
    edit.toggle_range(o.line1, o.line2)
  end, { range = true, desc = "Toggle checkbox(es) on the line(s)" })
  vim.api.nvim_create_user_command("NoteTasks", function(o)
    edit.tasks(o.args)
  end, {
    nargs = "?",
    complete = function()
      return { "open", "done", "all", "file" }
    end,
    desc = "Task picker: open (default), done, all, or file",
  })
  vim.api.nvim_create_user_command("NoteReindex", function()
    local root = vault.require_root()
    if not root then
      return
    end
    index.invalidate()
    local st = index.get(root)
    util.notify(("indexed %d markdown file(s)"):format(#st.md))
  end, { desc = "Rebuild the vault index" })
  vim.api.nvim_create_user_command("NoteRename", function(o)
    move.rename(nil, o.args)
  end, { nargs = "?", desc = "Rename the current note and update links to it" })
  vim.api.nvim_create_user_command("NoteBacklinks", integrity.backlinks, { desc = "Notes that link to this one" })
  vim.api.nvim_create_user_command("NoteCheck", function(o)
    integrity.check(o.args == "file" and "file" or nil)
  end, {
    nargs = "?",
    complete = function()
      return { "file" }
    end,
    desc = "Find broken links/headings (vault, or `file`) -> quickfix",
  })
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
    vim.keymap.set("n", "<leader>ms", function()
      search.text()
    end, { desc = "Notes: search vault" })
    vim.keymap.set("n", "<leader>mT", function()
      search.tags()
    end, { desc = "Notes: tags" })
    vim.keymap.set("n", "<leader>mF", function()
      search.props()
    end, { desc = "Notes: frontmatter properties" })
    vim.keymap.set("n", "<leader>mX", function()
      edit.tasks()
    end, { desc = "Notes: open tasks" })
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
