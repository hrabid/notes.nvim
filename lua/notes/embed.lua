-- notes.nvim: embed previews for ![[note]], ![[note#heading]], ![[img.png]], ![](img.png)
--
-- Notes: floating preview (any terminal) + optional inline virtual lines.
-- Images: ordered fallback chain from config.embed_backends, default
--   "kitty"    kitty graphics protocol (kitty, WezTerm, Ghostty; not in tmux/ssh)
--   "chafa"    unicode-block rendering via chafa   (any truecolor/256 terminal)
--   "viu"      unicode-block rendering via viu     (any truecolor/256 terminal)
--   "external" system viewer through vim.ui.open   (xdg-open etc.)
local util = require("notes.util")
local vault = require("notes.vault")

local M = {}

local IMAGE = { png = 1, jpg = 1, jpeg = 1, gif = 1, webp = 1, bmp = 1, svg = 1, avif = 1, tif = 1, tiff = 1 }
local OTHER = { pdf = 1, mp3 = 1, wav = 1, ogg = 1, flac = 1, m4a = 1, mp4 = 1, mkv = 1, webm = 1, mov = 1, zip = 1, canvas = 1 }
local KITTY_ID = 7351

local function cfg()
  return require("notes").config
end

-- ── parsing (pure) ───────────────────────────────────────────────────

--- Embeds in a line, ordered by position: { s, e, target, anchor, wiki, url }.
function M._find_embeds(line)
  local out = {}
  local init = 1
  while true do
    local s, e, inner = line:find("!%[%[([^%]]+)%]%]", init)
    if not s then
      break
    end
    local target = inner:match("^([^|]*)")
    local path, anchor = target:match("^([^#]*)#?(.*)$")
    out[#out + 1] = { s = s, e = e, target = vim.trim(path), anchor = anchor ~= "" and anchor or nil, wiki = true }
    init = e + 1
  end
  init = 1
  while true do
    local s, e, _, raw = line:find("!%[([^%]]*)%]%(([^)]*)%)", init)
    if not s then
      break
    end
    local t = raw:match("^%s*<(.-)>") or raw:match("^%s*(%S+)") or ""
    if t:match("^%a[%w+.-]*://") then
      out[#out + 1] = { s = s, e = e, target = t, url = t, wiki = false }
    else
      local path, anchor = t:match("^([^#]*)#?(.*)$")
      out[#out + 1] = { s = s, e = e, target = util.url_decode(path), anchor = anchor ~= "" and anchor or nil, wiki = false }
    end
    init = e + 1
  end
  table.sort(out, function(a, b)
    return a.s < b.s
  end)
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

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

function M._resolve(e, cur_file)
  local root = vault.get_root()
  if e.wiki then
    if not root then
      return nil
    end
    return util.find_file(root, e.target) or util.find_file(root, e.target .. ".md")
  end
  local cands = {}
  if e.target:sub(1, 1) == "/" then
    if root then
      cands[#cands + 1] = root .. e.target
    end
    cands[#cands + 1] = e.target
  else
    local base = cur_file ~= "" and vim.fs.dirname(cur_file) or vim.uv.cwd()
    cands[#cands + 1] = vim.fs.joinpath(base, e.target)
  end
  for _, c in ipairs(cands) do
    c = vim.fs.normalize(c)
    if is_file(c) then
      return c
    end
    if not c:match("%.%w+$") and is_file(c .. ".md") then
      return c .. ".md"
    end
  end
  return nil
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

function M._png_size(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(2, 4) ~= "PNG" then
    return nil
  end
  local function be32(i)
    local a, b, c, d = head:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return be32(17), be32(21)
end

-- ── floating window plumbing ─────────────────────────────────────────

local float = nil -- { win, aug, on_close, focusable }

local function close_float()
  if not float then
    return
  end
  local f = float
  float = nil
  if f.aug then
    pcall(vim.api.nvim_del_augroup_by_id, f.aug)
  end
  if f.on_close then
    pcall(f.on_close)
  end
  if vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
end

local function arm_autoclose()
  vim.schedule(function()
    if not float then
      return
    end
    float.aug = vim.api.nvim_create_augroup("NotesEmbedFloat", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertEnter", "BufLeave", "VimResized" }, {
      group = float.aug,
      callback = close_float,
    })
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

local function focus_float()
  local f = float
  if f.aug then
    pcall(vim.api.nvim_del_augroup_by_id, f.aug)
    f.aug = nil
  end
  vim.api.nvim_set_current_win(f.win)
  local b = vim.api.nvim_win_get_buf(f.win)
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, close_float, { buffer = b, nowait = true })
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

-- ── image backends ───────────────────────────────────────────────────

local function term_write(seq)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq) -- Neovim 0.11+
  else
    vim.api.nvim_chan_send(vim.v.stderr, seq)
  end
end

local function kitty_capable()
  local env = vim.env
  if env.TMUX or env.STY or env.SSH_TTY or env.SSH_CONNECTION then
    return false
  end
  return env.KITTY_WINDOW_ID ~= nil
    or env.GHOSTTY_RESOURCES_DIR ~= nil
    or env.TERM == "xterm-kitty"
    or env.TERM == "xterm-ghostty"
    or env.TERM_PROGRAM == "WezTerm"
    or env.TERM_PROGRAM == "ghostty"
end

--- Path to a PNG for `path` (converted via ImageMagick when needed), or nil.
local function to_png(path)
  if M._png_size(path) then
    return path
  end
  local tool = (vim.fn.executable("magick") == 1 and "magick") or (vim.fn.executable("convert") == 1 and "convert") or nil
  if not tool then
    return nil
  end
  local st = vim.uv.fs_stat(path)
  local dir = vim.fn.stdpath("cache") .. "/notes-embeds"
  vim.fn.mkdir(dir, "p")
  local out = dir .. "/" .. vim.fn.sha256(path .. (st and st.mtime.sec or 0)) .. ".png"
  if not is_file(out) then
    local ok, res = pcall(function()
      return vim.system({ tool, path .. "[0]", out }):wait(8000)
    end)
    if not ok or res.code ~= 0 then
      return nil
    end
  end
  return is_file(out) and out or nil
end

local function show_kitty(path)
  local png = to_png(path)
  if not png then
    return false
  end
  local w, h = M._png_size(png)
  if not w then
    return false
  end
  local maxc = math.floor(vim.o.columns * 0.7)
  local maxr = math.floor((vim.o.lines - vim.o.cmdheight) * 0.6)
  local nc, nr = math.ceil(w / 8), math.ceil(h / 16) -- assume ~8x16 px cells
  local scale = math.min(1, maxc / nc, maxr / nr)
  local cols, rows = math.max(1, math.floor(nc * scale)), math.max(1, math.floor(nr * scale))

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local win = open_win(buf, cols, rows, "none", nil, false)
  float = { win = win, focusable = false }
  vim.cmd("redraw")
  local pos = vim.fn.win_screenpos(win)
  -- ESC7/ESC8 save/restore cursor; q=2 suppresses terminal replies; C=1 keeps the cursor put
  local seq = ("\0277\27[%d;%dH\27_Ga=T,t=f,f=100,i=%d,c=%d,r=%d,C=1,q=2;%s\27\\\0278"):format(
    pos[1],
    pos[2],
    KITTY_ID,
    cols,
    rows,
    vim.base64.encode(png)
  )
  term_write(seq)
  float.on_close = function()
    term_write(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(KITTY_ID))
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
    util.notify("no image backend could display " .. path, vim.log.levels.WARN)
    return
  end
  local nextf = function()
    attempt(path, idx + 1)
  end
  if name == "kitty" then
    if not (kitty_capable() and show_kitty(path)) then
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

-- ── public: preview under cursor ─────────────────────────────────────

function M.preview()
  if float and vim.api.nvim_win_is_valid(float.win) then
    if float.focusable then
      focus_float()
    else
      close_float()
    end
    return
  end
  local embeds = M._find_embeds(vim.api.nvim_get_current_line())
  if #embeds == 0 then
    util.notify("no embed on this line")
    return
  end
  local e = M._pick_embed(embeds, vim.api.nvim_win_get_cursor(0)[2])
  local kind = M._kind(e)
  if kind == "url" then
    vim.ui.open(e.url)
    return
  end
  local path = M._resolve(e, vim.api.nvim_buf_get_name(0))
  if not path then
    util.notify("embed target not found: " .. e.target, vim.log.levels.WARN)
    return
  end
  if kind == "note" then
    show_note(path, e.anchor)
  elseif kind == "image" then
    attempt(path, 1)
  else
    vim.ui.open(path)
  end
end

-- ── inline note embeds (virtual lines) ───────────────────────────────

local ns
local inline = {}

local function render_inline(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ns = ns or vim.api.nvim_create_namespace("notes_embeds")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local cur = vim.api.nvim_buf_get_name(bufnr)
  local limit = cfg().embed_inline_lines
  local fence = false
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if line:match("^%s*```") or line:match("^%s*~~~") then
      fence = not fence
    elseif not fence then
      local e = line:find("!%[") and M._find_embeds(line)[1]
      if e then
        local kind, virt = M._kind(e), nil
        local path = kind ~= "url" and M._resolve(e, cur) or nil
        if kind == "note" and path then
          local body = M._note_lines(path, e.anchor) or {}
          virt = { { { "| " .. vim.fn.fnamemodify(path, ":t:r") .. (e.anchor and (" > " .. e.anchor) or ""), "Title" } } }
          for k = 1, math.min(#body, limit) do
            virt[#virt + 1] = { { "| " .. body[k], "Comment" } }
          end
          if #body > limit then
            virt[#virt + 1] = { { ("| ... (+%d more lines)"):format(#body - limit), "NonText" } }
          end
        elseif kind == "image" and path then
          virt = { { { "| [image] " .. vim.fn.fnamemodify(path, ":t"), "Comment" } } }
        elseif kind ~= "url" and not path then
          virt = { { { "| not found: " .. e.target, "WarningMsg" } } }
        end
        if virt then
          vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, 0, { virt_lines = virt })
        end
      end
    end
  end
end

function M.enable_inline(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  inline[bufnr] = true
  local g = vim.api.nvim_create_augroup("NotesEmbedInline" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged" }, {
    group = g,
    buffer = bufnr,
    callback = function()
      render_inline(bufnr)
    end,
  })
  render_inline(bufnr)
end

function M.disable_inline(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  inline[bufnr] = nil
  pcall(vim.api.nvim_del_augroup_by_name, "NotesEmbedInline" .. bufnr)
  if ns then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

function M.toggle_inline(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if inline[bufnr] then
    M.disable_inline(bufnr)
    util.notify("inline embeds off")
  else
    M.enable_inline(bufnr)
    util.notify("inline embeds on")
  end
end

return M
