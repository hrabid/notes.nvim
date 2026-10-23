# notes.nvim

Minimal Neovim plugin for Obsidian vaults: template injection + markdown linking.
Filesystem only — no Obsidian app/API involved. Neovim >= 0.10.

## Install (lazy.nvim)

```lua
{
  "you/notes.nvim",          -- or dir = "~/path/to/notes.nvim"
  lazy = false,
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional
  opts = {
    -- vault_path = "~/vaults/main",   -- omit to auto-detect via .obsidian/
    -- default_template = "daily",
  },
}
```

`setup()` must be called (`opts = {}` is enough).

## Templates

Drop `.md` files into `<vault>/templates/` (or set `template_dir`). Each file is
self-contained, frontmatter included. See `examples/templates/`.

Variables: `{{date}} {{time}} {{datetime}} {{filename}} {{title}} {{uuid}} {{cursor}}`

## Keys (markdown buffers)

| Key          | Action                                   |
|--------------|------------------------------------------|
| `<leader>mt` | template picker → inject                 |
| `<leader>ml` | file picker → `[name](rel/path.md)`      |
| `<leader>mh` | file picker → header picker → `[h](f.md#anchor)` |
| `<leader>mn` | new note in `new_note_dir` (global map, prompts for name) |
| `<leader>mm` | move current note to another directory (picker) |
| `<leader>mb` | back through link-follow history         |
| `<leader>mr` | re-read templates dir                    |
| `<leader>mv` | print vault root                         |
| `gf`         | follow markdown link (native `gf` otherwise) |

`keymaps = false` disables all of them; call the Lua API instead
(`require("notes.links").insert_file_link()`, etc).

## Commands

`:TemplateInsert [name]`, `:TemplateReload`, `:NotesVault`, `:NoteNew [name]`, `:NoteMove [dir]`

## Notes

- `:NoteNew projects/foo` creates `<new_note_dir>/projects/foo.md` (subfolders are created) and applies `default_template` or opens the picker.
- The vault is found by walking up to the nearest `.obsidian/` from the file, so any child directory works (unless `vault_path` pins it).
- Spaces in link paths are written as `%20` and decoded on follow.
- Duplicate headings get `-1`, `-2` anchor suffixes (GitHub style).
- `[[wikilinks]]` followed on `gf` when `wikilinks = true`.
