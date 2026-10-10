-- notes.nvim: picker adapter (telescope / fzf-lua / vim.ui.select)
-- items: list of strings, or tables { display = "text", ... }
-- on_select receives the original item.
local util = require("notes.util")

local M = {}

local cached = nil
local ORDER = { "telescope", "fzf-lua", "vim.ui.select" }

local function cfg()
  return require("notes").config
end

local function display_of(item)
  return type(item) == "table" and item.display or tostring(item)
end

local function available(name)
  if name == "telescope" then
    return (pcall(require, "telescope.pickers"))
  elseif name == "fzf-lua" then
    return (pcall(require, "fzf-lua"))
  end
  return name == "vim.ui.select"
end

local function detect()
  if cached then
    return cached
  end
  local pref = cfg().picker or "auto"
  if pref ~= "auto" then
    if available(pref) then
      cached = pref
      return cached
    end
    util.notify(pref .. " not available, falling back", vim.log.levels.WARN)
  end
  for _, name in ipairs(ORDER) do
    if available(name) then
      cached = name
      return cached
    end
  end
  cached = "vim.ui.select"
  return cached
end

local backends = {}

function backends.telescope(items, opts, cb)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers
    .new({}, {
      prompt_title = opts.prompt or "Select",
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          local d = display_of(item)
          return { value = item, display = d, ordinal = d }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local sel = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            cb(sel.value)
          end
        end)
        return true
      end,
    })
    :find()
end

backends["fzf-lua"] = function(items, opts, cb)
  local lookup, displays = {}, {}
  for _, item in ipairs(items) do
    local d = display_of(item)
    while lookup[d] do
      d = d .. " " -- keep duplicate displays distinct
    end
    lookup[d] = item
    displays[#displays + 1] = d
  end
  require("fzf-lua").fzf_exec(displays, {
    prompt = (opts.prompt or "Select") .. "> ",
    actions = {
      default = function(selected)
        if selected and selected[1] then
          cb(lookup[selected[1]])
        end
      end,
    },
  })
end

backends["vim.ui.select"] = function(items, opts, cb)
  vim.ui.select(items, { prompt = opts.prompt, format_item = display_of }, function(item)
    cb(item)
  end)
end

function M.select(items, opts, on_select)
  opts = opts or {}
  local function cb(item)
    if item ~= nil then
      -- schedule so chained pickers open after this one has fully closed
      vim.schedule(function()
        on_select(item)
      end)
    end
  end
  backends[detect()](items, opts, cb)
end

function M.reset()
  cached = nil
end

return M
