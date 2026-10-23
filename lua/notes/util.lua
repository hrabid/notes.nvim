-- notes.nvim: pure helpers (no plugin state)
local M = {}

local seeded = false

function M.notify(msg, level)
  vim.notify("[notes] " .. msg, level or vim.log.levels.INFO)
end

function M.date(fmt)
  return os.date(fmt)
end

function M.time(fmt)
  return os.date(fmt)
end

function M.uuid()
  if not seeded then
    math.randomseed(os.time() + (vim.uv.hrtime() % 1000000))
    seeded = true
  end
  local tpl = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return (tpl:gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end))
end

function M.to_title_case(str)
  local s = str:gsub("[-_]+", " ")
  s = s:gsub("%f[%w]%w[%w']*", function(w)
    return w:sub(1, 1):upper() .. w:sub(2)
  end)
  return s
end

function M.url_decode(s)
  local r = s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end)
  return r
end

--- heading text -> anchor (lowercase, spaces -> '-', ASCII punctuation removed,
--- non-ASCII preserved, consecutive '-' collapsed)
function M.generate_anchor(str)
  local s = str:gsub("^[#%s]+", "")
  s = vim.fn.tolower(s)
  s = s:gsub("%s", "-")
  s = s:gsub("[^%w%-_\128-\255]", "")
  s = s:gsub("%-+", "-")
  s = s:gsub("^%-+", "")
  s = s:gsub("%-+$", "")
  return s
end

--- Parse ATX headings (skips frontmatter and fenced code blocks).
--- Returns { {level, text, lnum, anchor}, ... }. Duplicate anchors get -1, -2 ...
function M.parse_headings(lines)
  local out, seen, fence = {}, {}, nil
  local start = 1
  if lines[1] == "---" then
    for j = 2, #lines do
      if lines[j] == "---" then
        start = j + 1
        break
      end
    end
  end
  for i = start, #lines do
    local line = lines[i]
    local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f:sub(1, 3)
      elseif f:sub(1, 3) == fence then
        fence = nil
      end
    elseif not fence then
      local hashes, text = line:match("^(#+)%s+(.-)%s*$")
      if hashes and #hashes <= 6 and text ~= "" then
        local base = M.generate_anchor(text)
        local n = seen[base]
        local anchor = n and (base .. "-" .. n) or base
        seen[base] = (n or 0) + 1
        out[#out + 1] = { level = #hashes, text = text, lnum = i, anchor = anchor }
      end
    end
  end
  return out
end

function M.expand_path(path)
  local p = vim.fs.normalize(path)
  p = p:gsub("(.)/+$", "%1")
  return p
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local c = f:read("*a")
  f:close()
  return c
end

function M.read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or nil
end

--- Files directly inside `path`, optionally filtered by extension (no dot).
function M.list_dir(path, ext)
  local out = {}
  local ok, iter = pcall(vim.fs.dir, path)
  if not ok then
    return out
  end
  for name, t in iter do
    if t == "file" or t == "link" then
      if not ext or name:sub(-(#ext + 1)) == "." .. ext then
        out[#out + 1] = name
      end
    end
  end
  table.sort(out)
  return out
end

local function walk(dir, rel, out, depth)
  if depth > 20 then
    return
  end
  for name, t in vim.fs.dir(dir) do
    if name:sub(1, 1) ~= "." then
      local r = rel == "" and name or (rel .. "/" .. name)
      if t == "directory" then
        walk(dir .. "/" .. name, r, out, depth + 1)
      elseif t == "file" and name:sub(-3) == ".md" then
        out[#out + 1] = r
      end
    end
  end
end

local function walk_dirs(dir, rel, out, depth)
  if depth > 20 then
    return
  end
  for name, t in vim.fs.dir(dir) do
    if name:sub(1, 1) ~= "." and t == "directory" then
      local r = rel == "" and name or (rel .. "/" .. name)
      out[#out + 1] = r
      walk_dirs(dir .. "/" .. name, r, out, depth + 1)
    end
  end
end

--- All directories under root (relative paths, hidden dirs skipped).
function M.list_dirs_recursive(root)
  local out = {}
  walk_dirs(root, "", out, 0)
  table.sort(out)
  return out
end

--- All .md files under root (relative paths, hidden dirs skipped).
function M.list_md_recursive(root)
  local out = {}
  walk(root, "", out, 0)
  table.sort(out)
  return out
end

--- Relative path from directory `from_dir` to file/dir `to`.
function M.relative_path(from_dir, to)
  local f = vim.split(vim.fs.normalize(from_dir), "/", { trimempty = true })
  local t = vim.split(vim.fs.normalize(to), "/", { trimempty = true })
  local i = 1
  while i <= #f and i <= #t and f[i] == t[i] do
    i = i + 1
  end
  local parts = {}
  for _ = i, #f do
    parts[#parts + 1] = ".."
  end
  for j = i, #t do
    parts[#parts + 1] = t[j]
  end
  return table.concat(parts, "/")
end

return M
