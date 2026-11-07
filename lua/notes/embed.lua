-- notes.nvim: embeds: ![[note]], ![[note#heading]], ![[img.png]], ![](img.png)
--
-- Preview (<leader>mp): notes in a float; images through an ordered fallback chain
-- (config.embed_backends, first one that works wins):
--   "kitty"        Unicode-placeholder image in a float   (Ghostty, kitty; works in tmux)
--   "kitty-direct" cursor-positioned kitty protocol        (WezTerm etc.; no tmux/ssh)
--   "chafa"/"viu"  unicode-block art                       (any 256-colour terminal)
--   "external"     system viewer through vim.ui.open
-- Inline: note embeds as virtual lines, images rendered below their line (placeholders).
local util = require("notes.util")
local vault = require("notes.vault")
local image = require("notes.image")

local M = {}

local IMAGE = { png = 1, jpg = 1, jpeg = 1, gif = 1, webp = 1, bmp = 1, svg = 1, avif = 1, tif = 1, tiff = 1 }
local OTHER = { pdf = 1, mp3 = 1, wav = 1, ogg = 1, flac = 1, m4a = 1, mp4 = 1, mkv = 1, webm = 1, mov = 1, zip = 1, canvas = 1 }
local DIRECT_ID = 7351

local function cfg()
  return require("notes").config
end

-- ── parsing (pure) ───────────────────────────────────────────────────

local function parse_wiki(inner)
  local target = inner:match("^([^|]*)")
  local path, anchor = target:match("^([^#]*)#?(.*)$")
  return vim.trim(path), anchor ~= "" and anchor or nil
end

--- Links and embeds in a line, ordered by position:
--- { s, e, target, anchor, wiki, url, embed }  (embed = preceded by "!").
function M._find_refs(line)
  local out = {}
  local init = 1
  while true do
    local s, e, inner = line:find("%[%[([^%]]+)%]%]", init)
    if not s then
      break
    end
    local path, anchor = parse_wiki(inner)
    local emb = s > 1 and line:sub(s - 1, s - 1) == "!"
    out[#out + 1] = { s = emb and s - 1 or s, e = e, target = path, anchor = anchor, wiki = true, embed = emb }
    init = e + 1
  end
  init = 1
  while true do
    local s, e, _, raw = line:find("%[([^%]]*)%]%(([^)]*)%)", init)
    if not s then
      break
    end
    local emb = s > 1 and line:sub(s - 1, s - 1) == "!"
    local t = raw:match("^%s*<(.-)>") or raw:match("^%s*(%S+)") or ""
    local ref = { s = emb and s - 1 or s, e = e, wiki = false, embed = emb }
    if t:match("^%a[%w+.-]*://") then
      ref.target, ref.url = t, t
    else
      local path, anchor = t:match("^([^#]*)#?(.*)$")
      ref.target, ref.anchor = util.url_decode(path), anchor ~= "" and anchor or nil
    end
    out[#out + 1] = ref
    init = e + 1
  end
  table.sort(out, function(x, y)
    return x.s < y.s
  end)
  return out
end

--- Only the embeds (![[...]] / ![](...)).
function M._find_embeds(line)
  local out = {}
  for _, r in ipairs(M._find_refs(line)) do
    if r.embed then
      out[#out + 1] = r
    end
  end
  return out
end

--- Embed containing the cursor column (0-based), else the first on the line.
function M._pick_embed(embeds, col)
  local c = col + 1
  for _, e in ipairs(embeds) do
    if c >= e.s and c <= e.e then
      return e
    end
  end
  return embeds[1]
end

--- Ref under the cursor column (0-based); else the first embed on the line, else the first ref.
function M._pick_ref(refs, col)
  local c = col + 1
  for _, r in ipairs(refs) do
    if c >= r.s and c <= r.e then
      return r
    end
  end
  for _, r in ipairs(refs) do
    if r.embed then
      return r
    end
  end
  return refs[1]
end

function M._kind(e)
  if e.url then
    return "url"
  end
  local ext = e.target:match("%.(%w+)$")
  ext = ext and ext:lower()
  if ext and IMAGE[ext] then
    return "image"
  end
  if ext and OTHER[ext] then
    return "other"
  end
  return "note"
end

M._png_size = image.png_size

-- ── resolving ────────────────────────────────────────────────────────

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

-- note dir and its ancestors up to the vault root
local function ancestor_dirs(base, root)
  local out, d, n = {}, base, 0
  local limit = root and 20 or 3
  while d and d ~= "" and n < limit do
    out[#out + 1] = d
    if root and d == root then
      break
    end
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    d, n = parent, n + 1
  end
  if root and out[#out] ~= root and (base == root or base:sub(1, #root + 1) == root .. "/") then
    out[#out + 1] = root
  end
  return out
end

-- configured attachment_dir(s) first, then the conventional folder names
local function attachment_names()
  local c = cfg()
  local list = {}
  local ad = c.attachment_dir
  if type(ad) == "string" then
    ad = { ad }
  end
  for _, d in ipairs(ad or {}) do
    list[#list + 1] = d
  end
  for _, d in ipairs(c.attachment_dirs or {}) do
    list[#list + 1] = d
  end
  return list
end

function M._resolve(e, cur_file)
  local root = vault.get_root()
  local base = cur_file ~= "" and vim.fs.dirname(cur_file) or vim.uv.cwd()
  local names = { e.target }
  if not e.target:match("%.%w+$") then
    names[#names + 1] = e.target .. ".md"
  end

  -- 1. direct: relative to this note, or from the vault root
  local dirs = { base }
  if root then
    dirs[#dirs + 1] = root
  end
  for _, name in ipairs(names) do
    if name:sub(1, 1) == "/" then
      if root and is_file(root .. name) then
        return root .. name
      end
      if is_file(name) then
        return name
      end
    else
      for _, d in ipairs(dirs) do
        local c = vim.fs.normalize(vim.fs.joinpath(d, name))
        if is_file(c) then
          return c
        end
      end
    end
  end

  -- 2. attachment folders: configured first, then conventional names, looked up next to
  --    the note, in each parent folder up to the vault root, and (absolute paths) as-is
  local bases = ancestor_dirs(base, root)
  for _, ad in ipairs(attachment_names()) do
    local att_dirs = {}
    local expanded = util.expand_path(ad)
    if expanded:sub(1, 1) == "/" then
      att_dirs[1] = expanded
    else
      for _, b in ipairs(bases) do
        att_dirs[#att_dirs + 1] = b .. "/" .. expanded
      end
    end
    for _, att in ipairs(att_dirs) do
      if vim.fn.isdirectory(att) == 1 then
        for _, name in ipairs(names) do
          local rel = (name:gsub("^/", ""))
          local c = vim.fs.normalize(vim.fs.joinpath(att, rel))
          if is_file(c) then
            return c
          end
          local f = util.find_file(att, rel)
          if f then
            return f
          end
        end
      end
    end
  end

  -- 3. search by name anywhere in the vault (cwd if no vault): Obsidian "shortest path" style
  local search = root or vim.uv.cwd()
  for _, icase in ipairs({ false, true }) do
    for _, name in ipairs(names) do
      local f = util.find_file(search, (name:gsub("^/", "")), icase)
      if f then
        return f
      end
    end
  end
  return nil
end

--- Public: resolve a reference as written in a link (attachment or note) to an
--- absolute path using the same lookup as the preview.
function M.resolve_path(src, cur_file)
  local path = util.url_decode((src:gsub("#.*$", "")))
  return M._resolve({ target = path, wiki = false }, cur_file or vim.api.nvim_buf_get_name(0))
end

local resolved, missing = {}, {}
local function resolve_cached(e, cur)
  local key = cur .. "\0" .. (e.wiki and "w" or "m") .. e.target
  local p = resolved[key]
  if p and is_file(p) then
    return p
  end
  local t = missing[key]
  if t and (vim.uv.now() - t) < 5000 then
    return nil
  end
  p = M._resolve(e, cur)
  if p then
    resolved[key], missing[key] = p, nil
  else
    missing[key] = vim.uv.now()
  end
  return p
end

--- Body of a note (frontmatter stripped), or just the section under `anchor`.
function M._note_lines(path, anchor)
  local lines = util.read_lines(path)
  if not lines then
    return nil
  end
  local first = 1
  if lines[1] == "---" then
    for j = 2, #lines do
      if lines[j] == "---" then
        first = j + 1
        break
      end
    end
  end
  local last = #lines
  if anchor then
    local heads = util.parse_headings(lines)
    local want = util.generate_anchor(util.url_decode(anchor))
    for i, h in ipairs(heads) do
      if h.anchor == want then
        first = h.lnum
        for k = i + 1, #heads do
          if heads[k].level <= h.level then
            last = heads[k].lnum - 1
            break
          end
        end
        break
      end
    end
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  local out = {}
  for k = first, last do
    out[#out + 1] = lines[k]
  end
  return out
end

-- ── floating window plumbing ─────────────────────────────────────────

local float = nil -- { win, aug, on_close, focusable, src, target, keys, saved }
local ctx = { buf = nil, target = nil } -- who asked for the preview (set by M.preview)
local close_float, enter_note

local function restore_keys(f)
  local b = f.src
  if not (b and f.keys and vim.api.nvim_buf_is_valid(b)) then
    return
  end
  for _, lhs in ipairs(f.keys) do
    pcall(vim.keymap.del, "n", lhs, { buffer = b })
    local saved = f.saved and f.saved[lhs]
    if saved then
      pcall(vim.api.nvim_buf_call, b, function()
        vim.fn.mapset("n", false, saved)
      end)
    end
  end
  f.keys = nil
end

close_float = function()
  if not float then
    return
  end
  local f = float
  float = nil
  if f.aug then
    pcall(vim.api.nvim_del_augroup_by_id, f.aug)
  end
  restore_keys(f)
  if f.on_close then
    pcall(f.on_close)
  end
  if vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
end

-- Enter: open the previewed note in the source window (link stack + heading jump)
enter_note = function()
  local f = float
  if not (f and f.target) then
    return
  end
  local t, src = f.target, f.src
  close_float()
  local w = src and vim.fn.bufwinid(src) or -1
  if w ~= -1 then
    vim.api.nvim_set_current_win(w)
  end
  require("notes.links").open_path(t.path, t.anchor)
end

local function scroll(f, key)
  if vim.api.nvim_win_is_valid(f.win) then
    vim.api.nvim_win_call(f.win, function()
      vim.cmd("normal! " .. key)
    end)
  end
end

-- While a preview is open the source buffer gets temporary keys; the previous
-- buffer-local mappings (if any) are restored on close.
local function install_keys(f)
  local b = f.src
  if not (b and vim.api.nvim_buf_is_valid(b)) then
    return
  end
  f.keys, f.saved = {}, {}
  local function map(lhs, fn)
    local m = vim.api.nvim_buf_call(b, function()
      return vim.fn.maparg(lhs, "n", false, true)
    end)
    if type(m) == "table" and m.buffer == 1 then
      f.saved[lhs] = m
    end
    vim.keymap.set("n", lhs, fn, { buffer = b, nowait = true, desc = "Notes: preview" })
    f.keys[#f.keys + 1] = lhs
  end
  map("<Esc>", close_float)
  map("q", close_float)
  if f.target then
    map("<CR>", enter_note)
    map("<C-d>", function()
      scroll(f, "\4")
    end)
    map("<C-u>", function()
      scroll(f, "\21")
    end)
  end
end

--- Called right after a float is created: the preview stays until Esc/q (or <CR> for notes).
local function arm_autoclose()
  local f = float
  if not f then
    return
  end
  f.src, f.target = ctx.buf, ctx.target
  vim.schedule(function()
    if float ~= f then
      return
    end
    f.aug = vim.api.nvim_create_augroup("NotesEmbedFloat", { clear = true })
    if f.src and vim.api.nvim_buf_is_valid(f.src) then
      vim.api.nvim_create_autocmd({ "InsertEnter", "BufLeave" }, { group = f.aug, buffer = f.src, callback = close_float })
    end
    vim.api.nvim_create_autocmd("VimResized", { group = f.aug, callback = close_float })
    install_keys(f)
  end)
end

local function open_win(buf, w, h, border, title, focusable)
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local extra = (border and border ~= "none") and 2 or 0
  w = math.max(1, math.min(w, cols - extra))
  h = math.max(1, math.min(h, rows - extra - 1))
  local conf = {
    relative = "editor",
    width = w,
    height = h,
    row = math.max(0, math.floor((rows - h - extra) / 2)),
    col = math.max(0, math.floor((cols - w - extra) / 2)),
    style = "minimal",
    border = border or "none",
    focusable = focusable,
  }
  if title and extra > 0 then
    conf.title = " " .. title .. " "
    conf.title_pos = "center"
  end
  return vim.api.nvim_open_win(buf, false, conf)
end

-- second <leader>mp on a note preview: move into the float to scroll/read it
local function focus_float()
  local f = float
  if f.aug then
    pcall(vim.api.nvim_del_augroup_by_id, f.aug)
    f.aug = nil
  end
  restore_keys(f)
  vim.api.nvim_set_current_win(f.win)
  local b = vim.api.nvim_win_get_buf(f.win)
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, close_float, { buffer = b, nowait = true })
  end
  if f.target then
    vim.keymap.set("n", "<CR>", enter_note, { buffer = b, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = b,
    once = true,
    callback = function()
      vim.schedule(close_float)
    end,
  })
end

-- ── note preview ─────────────────────────────────────────────────────

local function show_note(path, anchor)
  local lines = M._note_lines(path, anchor)
  if not lines then
    util.notify("cannot read " .. path, vim.log.levels.ERROR)
    return
  end
  if #lines == 0 then
    lines = { "(empty)" }
  end
  local w = 20
  for _, l in ipairs(lines) do
    w = math.max(w, vim.fn.strdisplaywidth(l))
  end
  w = math.min(w, math.floor(vim.o.columns * 0.7))
  local h = math.min(#lines, math.floor(vim.o.lines * 0.6))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  local title = vim.fn.fnamemodify(path, ":t:r") .. (anchor and (" > " .. anchor) or "")
  local win = open_win(buf, w, h, cfg().float_border, title, true)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  float = { win = win, focusable = true }
  arm_autoclose()
end

-- ── image preview backends ───────────────────────────────────────────

-- "kitty": placeholder image inside a float (text, so no cursor maths; works in tmux)
local function show_placeholders(path, on_fail)
  local maxc = math.floor(vim.o.columns * 0.7)
  local maxr = math.floor((vim.o.lines - vim.o.cmdheight) * 0.6)
  local function go(img)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, img.lines)
    local pns = vim.api.nvim_create_namespace("notes_preview_img")
    for i, l in ipairs(img.lines) do
      vim.api.nvim_buf_set_extmark(buf, pns, i - 1, 0, { end_col = #l, hl_group = img.hl })
    end
    vim.bo[buf].modifiable = false
    local win = open_win(buf, img.cols, img.rows, cfg().float_border, vim.fn.fnamemodify(path, ":t"), false)
    vim.wo[win].wrap = false
    float = { win = win, focusable = false }
    arm_autoclose()
  end
  local img, st = image.prepare(path, { maxc = maxc, maxr = maxr, slot = "float" }, function(e)
    if e then
      go(e)
    else
      on_fail()
    end
  end)
  if img then
    go(img)
  elseif st ~= "pending" then
    on_fail()
  end
end

-- "kitty-direct": cursor-positioned placement drawn over a blank float
local function show_direct(path)
  local png = image.png_sync(path)
  if not png then
    return false
  end
  local w, h = image.png_size(png)
  if not w then
    return false
  end
  local maxc = math.floor(vim.o.columns * 0.7)
  local maxr = math.floor((vim.o.lines - vim.o.cmdheight) * 0.6)
  local nc, nr = math.ceil(w / 8), math.ceil(h / 16)
  local scale = math.min(1, maxc / nc, maxr / nr)
  local cols, rows = math.max(1, math.floor(nc * scale)), math.max(1, math.floor(nr * scale))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = open_win(buf, cols, rows, "none", nil, false)
  float = { win = win, focusable = false }
  vim.cmd("redraw")
  local pos = vim.fn.win_screenpos(win)
  image.raw_write(
    ("\0277\27[%d;%dH\27_Ga=T,t=f,f=100,i=%d,c=%d,r=%d,C=1,q=2;%s\27\\\0278"):format(
      pos[1],
      pos[2],
      DIRECT_ID,
      cols,
      rows,
      vim.base64.encode(png)
    )
  )
  float.on_close = function()
    image.raw_write(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(DIRECT_ID))
  end
  arm_autoclose()
  return true
end

local ANSI_ARGV = {
  chafa = function(path, w, h)
    return {
      "chafa",
      "--format=symbols",
      "--size=" .. w .. "x" .. h,
      "--colors=" .. (vim.o.termguicolors and "full" or "256"),
      "--animate=off",
      "--polite=on",
      path,
    }
  end,
  viu = function(path, w, h)
    return { "viu", "-b", "-w", tostring(w), "-h", tostring(h), path }
  end,
}

local function show_ansi(tool, path, on_fail)
  if vim.fn.executable(tool) ~= 1 then
    return on_fail()
  end
  local maxw = math.floor(vim.o.columns * 0.7)
  local maxh = math.floor((vim.o.lines - vim.o.cmdheight) * 0.6)
  local ok = pcall(vim.system, ANSI_ARGV[tool](path, maxw, maxh), { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
      return on_fail()
    end
    local out = res.stdout:gsub("\r?\n$", "")
    local lines = vim.split(out, "\n", { plain = true })
    local w = 1
    for _, l in ipairs(lines) do
      local plain = l:gsub("\27%[[%?%d;:]*%a", "")
      w = math.max(w, vim.fn.strdisplaywidth(plain))
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    local win = open_win(buf, w, #lines, cfg().float_border, vim.fn.fnamemodify(path, ":t"), false)
    local chan = vim.api.nvim_open_term(buf, {})
    vim.api.nvim_chan_send(chan, (out:gsub("\n", "\r\n")))
    float = { win = win, focusable = false }
    arm_autoclose()
  end))
  if not ok then
    on_fail()
  end
end

local function attempt(path, idx)
  local name = cfg().embed_backends[idx]
  if not name then
    util.notify("no image backend could display " .. path .. " (see :NoteImageStatus)", vim.log.levels.WARN)
    return
  end
  local nextf = function()
    attempt(path, idx + 1)
  end
  if name == "kitty" then
    if image.capable() then
      show_placeholders(path, nextf)
    else
      nextf()
    end
  elseif name == "kitty-direct" then
    if not (image.direct_capable() and show_direct(path)) then
      nextf()
    end
  elseif name == "chafa" or name == "viu" then
    show_ansi(name, path, nextf)
  elseif name == "external" then
    if not vim.ui.open(path) then
      nextf()
    end
  else
    nextf()
  end
end

-- ── public: preview under cursor ──────────────────────────────────

--- Preview the link or embed under the cursor.
--- Esc/q close it, <CR> opens a previewed note, <C-d>/<C-u> scroll it.
function M.preview()
  if float and vim.api.nvim_win_is_valid(float.win) then
    if float.focusable then
      focus_float()
    else
      close_float()
    end
    return
  end
  local refs = M._find_refs(vim.api.nvim_get_current_line())
  local e = M._pick_ref(refs, vim.api.nvim_win_get_cursor(0)[2])
  if not e then
    util.notify("no link or embed on this line")
    return
  end
  local kind = M._kind(e)
  if kind == "url" then
    vim.ui.open(e.url)
    return
  end
  local cur = vim.api.nvim_buf_get_name(0)
  local path
  if e.target == "" then
    path = e.anchor and cur ~= "" and cur or nil -- [x](#heading): section of this note
  else
    path = M._resolve(e, cur)
  end
  if not path then
    local base = vim.fs.dirname(cur)
    util.notify(
      ("target not found: %s (tried %s and %s)"):format(e.target, base, vault.get_root() or "no vault detected - see :NotesVault"),
      vim.log.levels.WARN
    )
    return
  end
  ctx.buf, ctx.target = vim.api.nvim_get_current_buf(), nil
  if kind == "note" then
    ctx.target = { path = path, anchor = e.anchor }
    show_note(path, e.anchor)
  elseif kind == "image" then
    attempt(path, 1)
  else
    vim.ui.open(path)
  end
end

-- ── inline rendering (notes as virtual lines, images as placeholders) ─

local ns
local state = { notes = {}, images = {} } -- bufnr -> true
local timers = {}
local warned = false
local schedule_render

local function label(text, hl)
  return { { { "| " .. text, hl or "Comment" } } }
end

local function embed_virt(bufnr, e, cur, want_notes, want_images, width, c)
  local kind = M._kind(e)
  if kind == "url" or kind == "other" then
    return nil
  end
  local path = resolve_cached(e, cur)
  if not path then
    return label("not found: " .. e.target, "WarningMsg")
  end
  if kind == "note" then
    if not want_notes then
      return nil
    end
    local limit = c.embed_inline_lines
    local body = M._note_lines(path, e.anchor) or {}
    local virt = { { { "| " .. vim.fn.fnamemodify(path, ":t:r") .. (e.anchor and (" > " .. e.anchor) or ""), "Title" } } }
    for k = 1, math.min(#body, limit) do
      virt[#virt + 1] = { { "| " .. body[k], "Comment" } }
    end
    if #body > limit then
      virt[#virt + 1] = { { ("| ... (+%d more lines)"):format(#body - limit), "NonText" } }
    end
    return virt
  end
  -- image
  local name = vim.fn.fnamemodify(path, ":t")
  if want_images then
    local img, st = image.prepare(path, {
      maxc = math.min(c.image_max_cols, math.max(1, width)),
      maxr = c.image_max_rows,
      slot = "inline",
    }, function()
      schedule_render(bufnr)
    end)
    if img then
      return image.virt_lines(img)
    end
    if st == "pending" then
      return label("[image] " .. name .. " (converting...)")
    end
  end
  if want_notes then
    return label("[image] " .. name)
  end
  return nil
end

local function render(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ns = ns or vim.api.nvim_create_namespace("notes_embeds")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local want_notes, want_images = state.notes[bufnr], state.images[bufnr]
  if not (want_notes or want_images) then
    return
  end
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return
  end
  local width = vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff - 1
  local c = cfg()
  local cur = vim.api.nvim_buf_get_name(bufnr)
  local fence = false
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence and line:find("![", 1, true) then
      local e = M._find_embeds(line)[1]
      if e then
        local virt = embed_virt(bufnr, e, cur, want_notes, want_images, width, c)
        if virt then
          vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, { virt_lines = virt })
        end
      end
    end
  end
end

schedule_render = function(bufnr, delay)
  local t = timers[bufnr]
  if t and not t:is_closing() then
    t:stop()
    t:close()
  end
  t = vim.uv.new_timer()
  timers[bufnr] = t
  t:start(
    delay or 120,
    0,
    vim.schedule_wrap(function()
      if not t:is_closing() then
        t:stop()
        t:close()
      end
      if timers[bufnr] == t then
        timers[bufnr] = nil
      end
      render(bufnr)
    end)
  )
end

local function sync(bufnr)
  local name = "NotesEmbedInline" .. bufnr
  if state.notes[bufnr] or state.images[bufnr] then
    local g = vim.api.nvim_create_augroup(name, { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufWritePost", "TextChanged" }, {
      group = g,
      buffer = bufnr,
      callback = function()
        schedule_render(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
      group = g,
      callback = function()
        schedule_render(bufnr)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = g,
      buffer = bufnr,
      callback = function()
        state.notes[bufnr], state.images[bufnr] = nil, nil
      end,
    })
    schedule_render(bufnr, 0)
  else
    pcall(vim.api.nvim_del_augroup_by_name, name)
    if ns and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
  end
end

local function cur_buf(bufnr)
  return (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
end

-- inline note embeds
function M.enable_inline(bufnr)
  bufnr = cur_buf(bufnr)
  state.notes[bufnr] = true
  sync(bufnr)
end

function M.disable_inline(bufnr)
  bufnr = cur_buf(bufnr)
  state.notes[bufnr] = nil
  sync(bufnr)
end

function M.toggle_inline(bufnr)
  bufnr = cur_buf(bufnr)
  if state.notes[bufnr] then
    M.disable_inline(bufnr)
    util.notify("inline note embeds off")
  else
    M.enable_inline(bufnr)
    util.notify("inline note embeds on")
  end
end

-- inline images
function M.enable_images(bufnr)
  bufnr = cur_buf(bufnr)
  state.images[bufnr] = true
  sync(bufnr)
end

function M.disable_images(bufnr)
  bufnr = cur_buf(bufnr)
  state.images[bufnr] = nil
  sync(bufnr)
end

function M.toggle_images(bufnr)
  bufnr = cur_buf(bufnr)
  if state.images[bufnr] then
    M.disable_images(bufnr)
    util.notify("inline images off")
    return
  end
  local ok, reason = image.capable()
  if not ok then
    util.notify("inline images unavailable: " .. reason, vim.log.levels.WARN)
    return
  end
  M.enable_images(bufnr)
  util.notify("inline images on")
end

--- Called for every markdown buffer: applies embed_inline / inline_images config.
function M.auto_attach(bufnr)
  local c = cfg()
  if c.embed_inline then
    M.enable_inline(bufnr)
  end
  local want = c.inline_images
  if want == true or want == "auto" then
    local ok, reason = image.capable()
    if ok then
      M.enable_images(bufnr)
    elseif want == true and not warned then
      warned = true
      util.notify("inline images unavailable: " .. reason, vim.log.levels.WARN)
    end
  end
end

return M
