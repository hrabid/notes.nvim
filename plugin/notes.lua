if vim.g.loaded_notes then
  return
end
vim.g.loaded_notes = 1

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("notes.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
end
-- Call require("notes").setup({...}) from your config.
