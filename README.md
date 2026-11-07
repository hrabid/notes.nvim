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
| `<leader>me` | preview the link/embed under the cursor (note / image) |
| `<C-LeftMouse>` | ctrl+click a link/embed to preview it (needs `mouse` enabled) |
| `<leader>mE` | toggle inline note embeds (virtual lines) |
| `<leader>mi` | toggle inline images for this buffer |
| `<leader>mb` | back through link-follow history         |
| `<leader>mr` | re-read templates dir                    |
| `<leader>mv` | print vault root                         |
| `gf`         | follow markdown link (native `gf` otherwise) |

`keymaps = false` disables all of them; call the Lua API instead
(`require("notes.links").insert_file_link()`, etc).

## Commands

`:TemplateInsert [name]`, `:TemplateReload`, `:NotesVault`, `:NoteNew [name]`, `:NoteMove [dir]`, `:NoteOutline [maxlevel]`, `:NoteOutlineToggle`, `:NoteEmbedPreview`, `:NoteEmbedInline`, `:NoteImageToggle`, `:NoteImageStatus`

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

`<leader>me` (or ctrl+click) previews the link or embed under the cursor (or the embed on the line):
`![[note]]`, `![[note#heading]]`, `![alt](note.md)`, `![[img.png]]`, `![alt](img.png)`.
Plain links work too: `[text](note.md#heading)`, `[[note]]`, `[pic](img.png)`, `[x](#heading)`.

The preview stays until you dismiss it: `Esc` / `q` close it, `Enter` opens the previewed note in the current window
(markdown only; `<leader>mb` returns, and the heading is jumped to), `<C-d>` / `<C-u>` scroll long notes.
Pressing `<leader>me` again moves into the float; ctrl+clicking another link replaces it. The keys are temporary
buffer-local mappings; your own buffer-local `Esc`/`q`/`Enter` mappings come back when the preview closes.
Ctrl+click needs `set mouse=a` (and `set -g mouse on` in tmux); hold shift if the terminal grabs the click.
Note embeds are rendered inline as virtual lines by default, just like images (`embed_inline = false` to disable, `<leader>mE` toggles per buffer).

Images try `embed_backends` in order until one works (default `{ "kitty", "kitty-direct", "chafa", "viu", "external" }`):

| Backend | Needs | Works in |
|---------|-------|----------|
| `kitty` | kitty graphics protocol (unicode placeholders); ImageMagick for non-PNG | Ghostty, kitty; also inside tmux |
| `kitty-direct` | kitty graphics protocol, cursor-positioned; ImageMagick for non-PNG | WezTerm, kitty, Ghostty (not tmux/ssh) |
| `chafa` | `chafa` | any 256-color/truecolor terminal (unicode blocks) |
| `viu` | `viu` | any 256-color/truecolor terminal (unicode blocks) |
| `external` | a default viewer for `xdg-open` | anywhere with a GUI |

Reorder or trim the list to taste, e.g. `embed_backends = { "chafa", "external" }`.

## Inline images (Ghostty, kitty)

Images are rendered right below their `![[x.png]]` / `![](x.png)` line by default (`inline_images = "auto"`),
as Unicode-placeholder text, so they scroll, clip and follow splits like normal text. Everything is
detected automatically; `:NoteImageStatus` tells you what was found and why something is unavailable.

- Needs `termguicolors` (image ids are carried in colours) and a local session (not ssh).
- Non-PNG images are converted once (cached) with ImageMagick, else ffmpeg / rsvg-convert (svg).
- Sizing: `image_max_cols`, `image_max_rows`; if images look stretched change `image_cell_ratio`
  (cell height / width in pixels, ~2).
- `<leader>mi` toggles it per buffer, `inline_images = false` turns it off, `true` warns when unavailable.
- Not supported (WezTerm, foot, alacritty, ...): nothing is drawn inline; `<leader>me` falls back through
  `embed_backends` (direct kitty placement, chafa, viu, external viewer).

### tmux

Add to `~/.tmux.conf` (needs tmux >= 3.3a):

```tmux
set -g allow-passthrough on
set -g focus-events on     # lets images re-appear after detach/attach
```

The outer terminal is read from tmux (`client_termname`), so Ghostty is recognised inside tmux.
If detection ever misjudges, set `image_protocol = "kitty"` to skip it, or `"none"` to disable.

### Where attachments are found

Works for any file type (images, pdf, ...) and from notes anywhere in the vault. For `![[x.png]]` / `![](x.png)` the lookup tries, in order:

1. the path as written: relative to the note, or from the vault root (a leading `/` is vault-relative)
2. `attachment_dir` (string or list; relative folders are checked next to the note and in every parent folder up to the vault root, absolute paths as-is; searched recursively, hidden folders like `.attachments` are fine here)
3. the conventional folders in `attachment_dirs` (default `attachments assets static img images files media resources pics`), same rules. Hugo-style `/img/x.png` therefore resolves to `static/img/x.png`
4. any file in the vault with that name (case-sensitive, then case-insensitive)

```lua
opts = { attachment_dir = "Attachments", attachment_dirs = { "assets", "static" } }
```

Other image plugins can reuse this lookup: `require("notes.embed").resolve_path(src, current_file)`.

## Notes

- Outline picker jumps are in the jumplist (`<C-o>`); its preview pane is telescope-only.

- `:NoteNew projects/foo` creates `<new_note_dir>/projects/foo.md` (subfolders are created) and applies `default_template` or opens the picker.
- The vault is found by walking up to the nearest `.obsidian/` from the file, so any child directory works (unless `vault_path` pins it).
- Spaces in link paths are written as `%20` and decoded on follow.
- Duplicate headings get `-1`, `-2` anchor suffixes (GitHub style).
- `[[wikilinks]]` followed on `gf` when `wikilinks = true`.
