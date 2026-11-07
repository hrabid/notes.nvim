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
| `<leader>mo` | outline picker for the buffer (telescope preview), jump to heading |
| `<leader>mO` | toggle outline sidebar |
| `<leader>me` | preview the embed under the cursor (note / image) |
| `<leader>mE` | toggle inline note embeds (virtual lines) |
| `<leader>mb` | back through link-follow history         |
| `<leader>mr` | re-read templates dir                    |
| `<leader>mv` | print vault root                         |
| `gf`         | follow markdown link (native `gf` otherwise) |

`keymaps = false` disables all of them; call the Lua API instead
(`require("notes.links").insert_file_link()`, etc).

## Commands

`:TemplateInsert [name]`, `:TemplateReload`, `:NotesVault`, `:NoteNew [name]`, `:NoteMove [dir]`, `:NoteOutline [maxlevel]`, `:NoteOutlineToggle`, `:NoteEmbedPreview`, `:NoteEmbedInline`

## Outline sidebar (`<leader>mO`)

Live tree of the buffer's headings (follows the cursor, refreshes on edit).
Keys inside the sidebar:

| Key | Action |
|-----|--------|
| `<CR>` / `o` | jump to heading |
| `<Tab>` / `za` | collapse / expand branch (`zM` / `zR`: all) |
| `1`-`6` / `0` | show only levels <= n / all |
| `>` / `<` | demote / promote the section (and its sub-headings) |
| `J` / `K` | move the section down / up past its sibling |
| `y` / `Y` | copy `[heading](#anchor)` / yank the whole section |
| `r` / `q` | refresh / close |

`outline_width` and `outline_side` (`"left"`/`"right"`) configure it.

## Embeds

`<leader>me` previews the embed under the cursor (or the one on the line):
`![[note]]`, `![[note#heading]]`, `![alt](note.md)`, `![[img.png]]`, `![alt](img.png)`.
Notes open in a floating window (press `<leader>me` again to enter and scroll it, `q` closes).
`<leader>mE` shows note embeds inline as virtual lines (`embed_inline = true` to enable automatically).

Images try `embed_backends` in order until one works (default `{ "kitty", "chafa", "viu", "external" }`):

| Backend | Needs | Works in |
|---------|-------|----------|
| `kitty` | kitty graphics protocol; ImageMagick for non-PNG | kitty, WezTerm, Ghostty (not tmux/ssh) |
| `chafa` | `chafa` | any 256-color/truecolor terminal (unicode blocks) |
| `viu` | `viu` | any 256-color/truecolor terminal (unicode blocks) |
| `external` | a default viewer for `xdg-open` | anywhere with a GUI |

Reorder or trim the list to taste, e.g. `embed_backends = { "chafa", "external" }`.

## Notes

- Outline picker jumps are in the jumplist (`<C-o>`); its preview pane is telescope-only.

- `:NoteNew projects/foo` creates `<new_note_dir>/projects/foo.md` (subfolders are created) and applies `default_template` or opens the picker.
- The vault is found by walking up to the nearest `.obsidian/` from the file, so any child directory works (unless `vault_path` pins it).
- Spaces in link paths are written as `%20` and decoded on follow.
- Duplicate headings get `-1`, `-2` anchor suffixes (GitHub style).
- `[[wikilinks]]` followed on `gf` when `wikilinks = true`.
