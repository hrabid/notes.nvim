-- notes.nvim: terminal graphics via the kitty graphics protocol (Ghostty, kitty).
--
-- Images are drawn with Unicode placeholders: the image is *text* (U+10EEEE plus row/column
-- diacritics, coloured with the image id), so it scrolls, clips and survives splits and floats
-- with no cursor tracking, and it works through tmux (allow-passthrough on).
local util = require("notes.util")

local M = {}

local function cfg()
  return require("notes").config
end

-- kitty gen/rowcolumn-diacritics.txt (297 entries)
local DIACRITICS = {
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F,
  0x0346, 0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357,
  0x035B, 0x0363, 0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369,
  0x036A, 0x036B, 0x036C, 0x036D, 0x036E, 0x036F, 0x0483, 0x0484,
  0x0485, 0x0486, 0x0487, 0x0592, 0x0593, 0x0594, 0x0595, 0x0597,
  0x0598, 0x0599, 0x059C, 0x059D, 0x059E, 0x059F, 0x05A0, 0x05A1,
  0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4, 0x0610, 0x0611,
  0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657, 0x0658,
  0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
  0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2,
  0x06E4, 0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733,
  0x0735, 0x0736, 0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743,
  0x0745, 0x0747, 0x0749, 0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE,
  0x07EF, 0x07F0, 0x07F1, 0x07F3, 0x0816, 0x0817, 0x0818, 0x0819,
  0x081B, 0x081C, 0x081D, 0x081E, 0x081F, 0x0820, 0x0821, 0x0822,
  0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A, 0x082B, 0x082C,
  0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86, 0x0F87,
  0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
  0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
  0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
  0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
  0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
  0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
  0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
  0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
  0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
  0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
  0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
  0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
  0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
  0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
  0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
  0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
  0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
  0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
  0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
  0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
  0x1D244,
}

local PLACEHOLDER = 0x10EEEE

-- ── pure helpers ─────────────────────────────────────────────────────

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40,
    0x80 + cp % 0x40
  )
end
M._utf8_char = utf8_char
M.MAX_CELLS = #DIACRITICS

local dia_cache = {}
local function dia(i) -- i is 0-based
  local s = dia_cache[i]
  if not s then
    s = utf8_char(DIACRITICS[i + 1] or DIACRITICS[#DIACRITICS])
    dia_cache[i] = s
  end
  return s
end

--- rows x cols grid of placeholder cells: one string per row.
function M._placeholder_lines(rows, cols)
  local ph = utf8_char(PLACEHOLDER)
  local lines = {}
  for r = 0, rows - 1 do
    local prefix = ph .. dia(r)
    local parts = {}
    for c = 0, cols - 1 do
      parts[c + 1] = prefix .. dia(c)
    end
    lines[#lines + 1] = table.concat(parts)
  end
  return lines
end

--- Fit a w x h px image into at most maxc x maxr cells. `ratio` = cell height / width.
--- Small images are not upscaled (assumes ~9 px wide cells).
function M._fit(w, h, maxc, maxr, ratio)
  maxc = math.max(1, math.min(maxc, M.MAX_CELLS))
  maxr = math.max(1, math.min(maxr, M.MAX_CELLS))
  local cols = math.max(1, math.min(maxc, math.ceil(w / 9)))
  local rows = math.max(1, math.ceil(cols * (h / w) / ratio))
  if rows > maxr then
    rows = maxr
    cols = math.max(1, math.min(cols, math.floor(rows * ratio * w / h)))
  end
  return cols, rows
end

local counter = 0
--- Image ids live in the placeholder colour (24 bit); pid-derived so several Neovims don't collide.
function M._alloc_id(pid)
  counter = counter + 1
  return (pid % 4000) * 4096 + (counter % 4095) + 1
end

function M._wrap_tmux(seq)
  return "\27Ptmux;" .. (seq:gsub("\27", "\27\27")) .. "\27\\"
end

function M.png_size(path)
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

-- ── terminal output ──────────────────────────────────────────────────

local function raw_write(seq)
  if vim.api.nvim_ui_send then
    vim.api.nvim_ui_send(seq) -- Neovim 0.11+
  else
    vim.api.nvim_chan_send(vim.v.stderr, seq)
  end
end
M.raw_write = raw_write

local function send(seq)
  if vim.env.TMUX then
    seq = M._wrap_tmux(seq)
  end
  raw_write(seq)
end

-- ── capability detection ─────────────────────────────────────────────

local function tmux_query(args)
  local ok, res = pcall(function()
    return vim.system(args, { text = true }):wait(1000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local out = vim.trim(res.stdout or "")
  return out ~= "" and out or nil
end

local function term_from_name(n)
  if not n then
    return nil
  end
  n = n:lower()
  if n:find("ghostty", 1, true) then
    return "ghostty"
  end
  if n:find("kitty", 1, true) then
    return "kitty"
  end
  return nil
end

local function term_from_env()
  local env = vim.env
  if env.GHOSTTY_RESOURCES_DIR or env.TERM_PROGRAM == "ghostty" then
    return "ghostty"
  end
  if env.KITTY_WINDOW_ID then
    return "kitty"
  end
  return term_from_name(env.TERM)
end

local function detect_term()
  if vim.env.TMUX then
    -- inside tmux, TERM_PROGRAM is "tmux": ask tmux for the real (outer) terminal
    return term_from_name(tmux_query({ "tmux", "display-message", "-p", "#{client_termname}" })) or term_from_env()
  end
  return term_from_env()
end

local function tmux_passthrough()
  for _, args in ipairs({
    { "tmux", "show-options", "-Apv", "allow-passthrough" },
    { "tmux", "show-options", "-pv", "allow-passthrough" },
    { "tmux", "show-options", "-gv", "allow-passthrough" },
  }) do
    local v = tmux_query(args)
    if v then
      return v == "on" or v == "all"
    end
  end
  return false
end

local cap

local function compute()
  local c = cfg()
  if c.image_protocol == "none" then
    return false, 'disabled (image_protocol = "none")'
  end
  if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
    return false, "ssh session: the terminal cannot read image files that live on the remote host"
  end
  local term = "kitty protocol (forced)"
  if c.image_protocol ~= "kitty" then
    term = detect_term()
    if not term then
      return false, "terminal is not Ghostty/kitty (no unicode-placeholder support)"
    end
  end
  if vim.env.TMUX and not tmux_passthrough() then
    return false, "tmux allow-passthrough is off (add `set -g allow-passthrough on` to tmux.conf)"
  end
  return true, term .. (vim.env.TMUX and " via tmux" or "")
end

--- Can we draw placeholder images? Returns ok, reason.
function M.capable()
  if not vim.o.termguicolors then
    return false, "'termguicolors' is off (image ids are encoded in colours)"
  end
  if not cap then
    local ok, reason = compute()
    cap = { ok = ok, reason = reason }
  end
  return cap.ok, cap.reason
end

function M.reset_cache()
  cap = nil
  if M._clear_failures then
    M._clear_failures()
  end
end

--- Direct (cursor-positioned) kitty placement: no tmux/ssh; kitty, Ghostty, WezTerm.
function M.direct_capable()
  local env = vim.env
  if cfg().image_protocol == "none" or env.TMUX or env.STY or env.SSH_TTY or env.SSH_CONNECTION then
    return false
  end
  return term_from_env() ~= nil or env.TERM_PROGRAM == "WezTerm"
end

-- ── conversion to PNG (the protocol's only file format) ──────────────

local function is_file(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil and st.type == "file"
end

local function exe(name)
  return vim.fn.executable(name) == 1
end

local function png_cache_path(path)
  local st = vim.uv.fs_stat(path)
  local dir = vim.fn.stdpath("cache") .. "/notes-embeds"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. vim.fn.sha256(path .. (st and st.mtime.sec or 0) .. (st and st.size or 0)) .. ".png"
end

--- Is `name` usable? ("pil" = python3 with Pillow). Replaceable in tests.
function M._has(name)
  if name == "pil" then
    if M._pil == nil then
      M._pil = false
      if vim.fn.executable("python3") == 1 then
        local ok, res = pcall(function()
          return vim.system({ "python3", "-c", "import PIL" }):wait(3000)
        end)
        M._pil = ok and res ~= nil and res.code == 0
      end
    end
    return M._pil
  end
  return vim.fn.executable(name) == 1
end

local function exe(name)
  return M._has(name)
end

local PIL_CODE = "import sys\nfrom PIL import Image\nim = Image.open(sys.argv[1])\nim.seek(0)\nim.convert('RGBA').save(sys.argv[2], 'PNG')"

local BUILD = {
  pdftoppm = function(i, o)
    return { "pdftoppm", "-png", "-f", "1", "-l", "1", "-r", "110", "-singlefile", i, (o:gsub("%.png$", "")) }
  end,
  mutool = function(i, o)
    return { "mutool", "draw", "-r", "110", "-o", o, i, "1" }
  end,
  gs = function(i, o)
    return { "gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=png16m", "-r110", "-dFirstPage=1", "-dLastPage=1", "-sOutputFile=" .. o, i }
  end,
  ["rsvg-convert"] = function(i, o)
    return { "rsvg-convert", "-w", "1600", "-o", o, i }
  end,
  inkscape = function(i, o)
    return { "inkscape", i, "--export-type=png", "--export-filename=" .. o, "-w", "1600" }
  end,
  dwebp = function(i, o)
    return { "dwebp", i, "-o", o }
  end,
  ["heif-convert"] = function(i, o)
    return { "heif-convert", i, o }
  end,
  avifdec = function(i, o)
    return { "avifdec", i, o }
  end,
  djxl = function(i, o)
    return { "djxl", i, o }
  end,
  magick = function(i, o)
    return { "magick", i .. "[0]", "-resize", "2000x2000>", o }
  end,
  convert = function(i, o)
    return { "convert", i .. "[0]", "-resize", "2000x2000>", o }
  end,
  gm = function(i, o)
    return { "gm", "convert", i .. "[0]", "-resize", "2000x2000>", o }
  end,
  vips = function(i, o)
    return { "vips", "copy", i, o }
  end,
  ffmpeg = function(i, o)
    return { "ffmpeg", "-y", "-loglevel", "error", "-i", i, "-frames:v", "1", o }
  end,
  pil = function(i, o)
    return { "python3", "-c", PIL_CODE, i, o }
  end,
}

-- converters tried in order, per source format (first one installed wins)
local GENERIC = { "magick", "convert", "gm", "vips", "ffmpeg", "pil" }
local ORDER = {
  pdf = { "pdftoppm", "mutool", "gs", "magick", "convert" },
  svg = { "rsvg-convert", "inkscape", "magick", "convert", "gm", "vips" },
  webp = { "dwebp", "magick", "convert", "gm", "vips", "ffmpeg", "pil" },
  heic = { "heif-convert", "magick", "convert", "vips", "ffmpeg" },
  heif = { "heif-convert", "magick", "convert", "vips", "ffmpeg" },
  avif = { "avifdec", "magick", "convert", "vips", "ffmpeg", "pil" },
  jxl = { "djxl", "magick", "convert", "vips" },
}

local function ext_of(path)
  return (path:match("%.(%w+)$") or ""):lower()
end

--- Name of the converter that would be used for files with extension `ext`, or nil.
function M.converter_name(ext)
  for _, tool in ipairs(ORDER[ext] or GENERIC) do
    if exe(tool) then
      return tool
    end
  end
  return nil
end

local function converter_argv(path, out)
  local tool = M.converter_name(ext_of(path))
  return tool and BUILD[tool](path, out) or nil
end
M._converter_argv = converter_argv

--- Blocking conversion (used by the direct-placement preview). Returns a PNG path or nil.
function M.png_sync(path)
  if M.png_size(path) then
    return path
  end
  local out = png_cache_path(path)
  if is_file(out) then
    return out
  end
  local argv = converter_argv(path, out)
  if not argv then
    return nil
  end
  local ok, res = pcall(function()
    return vim.system(argv):wait(8000)
  end)
  if ok and res and res.code == 0 and is_file(out) then
    return out
  end
  return nil
end

local pending, failures = {}, {}
M._clear_failures = function()
  failures = {}
end

local function tool_hint(ext)
  if ext == "pdf" then
    return "install poppler (pdftoppm) or mupdf-tools"
  end
  return "install ImageMagick, libvips or ffmpeg"
end

-- returns png | nil, "pending" | nil, "convert: reason"
local function png_for(path, on_done)
  if M.png_size(path) then
    return path
  end
  local out = png_cache_path(path)
  if is_file(out) then
    return out
  end
  if failures[out] then
    return nil, failures[out] -- do not retry a failed conversion on every redraw
  end
  local argv = converter_argv(path, out)
  if not argv then
    local ext = ext_of(path)
    return nil, ("convert: .%s needs a converter (%s)"):format(ext, tool_hint(ext))
  end
  if pending[out] then
    table.insert(pending[out], on_done)
    return nil, "pending"
  end
  pending[out] = { on_done }
  local started = pcall(
    vim.system,
    argv,
    { text = true },
    vim.schedule_wrap(function(res)
      local cbs = pending[out] or {}
      pending[out] = nil
      local ok = res.code == 0 and is_file(out)
      if not ok then
        local err = vim.trim((res.stderr or ""):match("[^\n]+") or "")
        failures[out] = ("convert: %s failed%s"):format(argv[1], err ~= "" and (": " .. err:sub(1, 80)) or "")
      end
      for _, f in ipairs(cbs) do
        f(ok and out or nil, failures[out])
      end
    end)
  )
  if not started then
    pending[out] = nil
    return nil, "convert: could not run " .. argv[1]
  end
  return nil, "pending"
end

-- ── images ───────────────────────────────────────────────────────────

local cache = {} -- key -> entry
local by_slot = {} -- path|slot -> entry currently shown
local armed = false

local function transmit(e)
  send(
    ("\27_Ga=t,f=100,t=f,i=%d,q=2;%s\27\\"):format(e.id, vim.base64.encode(e.png))
      .. ("\27_Ga=p,U=1,i=%d,c=%d,r=%d,q=2\27\\"):format(e.id, e.cols, e.rows)
  )
end

local function delete(e)
  send(("\27_Ga=d,d=I,i=%d,q=2\27\\"):format(e.id))
end

function M.retransmit()
  for _, e in pairs(cache) do
    transmit(e)
  end
end

function M.cleanup()
  for _, e in pairs(cache) do
    pcall(delete, e)
  end
  cache, by_slot = {}, {}
end

local function ensure_autocmds()
  if armed then
    return
  end
  armed = true
  local g = vim.api.nvim_create_augroup("NotesImage", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = g,
    callback = function()
      for _, e in pairs(cache) do
        vim.api.nvim_set_hl(0, e.hl, { fg = e.id })
      end
    end,
  })
  -- re-send after tmux re-attach / suspend
  pcall(vim.api.nvim_create_autocmd, { "FocusGained", "VimResume" }, { group = g, callback = M.retransmit })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = g, callback = M.cleanup })
end

--- Prepare an image for placeholder display.
--- opts = { maxc, maxr, slot }. Returns entry | nil, "pending" | nil, reason.
--- When pending, cb(entry | nil, err) is called later.
--- entry = { id, cols, rows, lines, hl }
function M.prepare(path, opts, cb)
  local ok, reason = M.capable()
  if not ok then
    return nil, reason
  end
  cb = cb or function() end
  ensure_autocmds()
  local slot = path .. "|" .. (opts.slot or "")

  local function finish(png)
    local w, h = M.png_size(png)
    if not w or w == 0 or h == 0 then
      return nil, "unreadable image"
    end
    if opts.want_w then -- requested display width in px, e.g. ![[img.png|300]]
      h = opts.want_h or math.max(1, math.floor(h * opts.want_w / w))
      w = opts.want_w
    end
    local cols, rows = M._fit(w, h, opts.maxc, opts.maxr, cfg().image_cell_ratio or 2.0)
    local key = png .. ":" .. cols .. "x" .. rows .. "|" .. (opts.slot or "")
    local e = cache[key]
    if not e then
      e = { key = key, id = M._alloc_id(vim.uv.os_getpid()), cols = cols, rows = rows, png = png }
      e.lines = M._placeholder_lines(rows, cols)
      e.hl = "NotesImg" .. e.id
      vim.api.nvim_set_hl(0, e.hl, { fg = e.id })
      cache[key] = e
      transmit(e)
    end
    local prev = by_slot[slot]
    if prev and prev ~= e then
      cache[prev.key] = nil
      delete(prev) -- superseded size variant (e.g. after a window resize)
    end
    by_slot[slot] = e
    return e
  end

  local png, st = png_for(path, function(p, why)
    if not p then
      cb(nil, why or "convert: failed")
      return
    end
    local e, err = finish(p)
    cb(e, err)
  end)
  if png then
    return finish(png)
  end
  return nil, st
end

function M.virt_lines(e)
  local v = {}
  for _, l in ipairs(e.lines) do
    v[#v + 1] = { { l, e.hl } }
  end
  return v
end

function M.status()
  M.reset_cache()
  local env = vim.env
  local ok, reason = M.capable()
  local lines = {
    "inline images: " .. (ok and "available" or "unavailable") .. " - " .. reason,
    "TERM=" .. (env.TERM or "?") .. "  TERM_PROGRAM=" .. (env.TERM_PROGRAM or "?"),
    "termguicolors: " .. tostring(vim.o.termguicolors),
    "tmux: "
      .. (
        env.TMUX
          and (
            "yes (outer terminal: "
            .. (tmux_query({ "tmux", "display-message", "-p", "#{client_termname}" }) or "?")
            .. ", allow-passthrough "
            .. (tmux_passthrough() and "on" or "off")
            .. ")"
          )
        or "no"
      ),
    "direct placement (kitty-direct backend): " .. (M.direct_capable() and "yes" or "no"),
    "raw terminal output: " .. (vim.api.nvim_ui_send and "nvim_ui_send" or "stderr channel (Neovim < 0.11)"),
  }
  local found = {}
  for _, t in ipairs({ "magick", "convert", "gm", "vips", "ffmpeg", "rsvg-convert", "inkscape", "dwebp", "heif-convert", "pdftoppm", "mutool", "gs", "chafa", "viu" }) do
    if exe(t) then
      found[#found + 1] = t
    end
  end
  lines[#lines + 1] = "tools found: " .. (#found > 0 and table.concat(found, ", ") or "none")
  for _, ext in ipairs({ "jpg", "gif", "webp", "svg", "heic", "pdf" }) do
    lines[#lines + 1] = ("convert .%s -> png: %s"):format(ext, M.converter_name(ext) or ("MISSING - " .. tool_hint(ext)))
  end
  return lines
end

return M
