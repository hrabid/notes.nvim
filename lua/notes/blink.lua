-- notes.nvim: blink.cmp source.
--   sources = {
--     default = { "lsp", "path", "snippets", "buffer", "notes" },   -- or per_filetype = { markdown = { "notes", ... } }
--     providers = { notes = { name = "notes", module = "notes.blink" } },
--   }
local Source = {}
Source.__index = Source

function Source.new(opts)
  return setmetatable({ opts = opts or {} }, Source)
end

function Source:enabled()
  return vim.bo.filetype == "markdown"
end

function Source:get_trigger_characters()
  return { "[", "(", "#", "/" }
end

function Source:get_completions(_, callback)
  callback({
    items = require("notes.completion").items_at_cursor(),
    is_incomplete_backward = false,
    is_incomplete_forward = false,
  })
  return function() end
end

return Source
