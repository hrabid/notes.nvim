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
| `<leader>mp` | preview the link/embed under the cursor (note / image) |
| `<leader>mE` | toggle inline note embeds (virtual lines) |
| `<leader>mi` | toggle inline images for this buffer |
| `<leader>me` | embed a note, image, pdf or any attachment from the vault (picker) |
| `<leader>mP` | paste the clipboard image into the vault and link it |
| `<leader>ms` | search the vault's text (global) |
| `<leader>mT` / `<leader>mF` | browse tags / frontmatter properties (global) |
| `<leader>mC` | insert/update a table of contents |
| `<leader>m]` / `<leader>m[` | next / previous link (count works) |
| `<leader>m}` / `<leader>m{` | next / previous heading (count works) |
| `<leader>m-` / `<leader>m\|` / `<leader>m+` | follow the link in a split / vsplit / tab |
| `<leader>mx` | toggle the checkbox on the line (count / visual range work) |
| `<leader>mX` | open tasks across the vault (global) |
| `<leader>mL` | convert the link under the cursor between `[[wiki]]` and `[markdown](links)` |
| `<leader>mR` | rename the note and update links to it |
| `<leader>mk` | backlinks: notes that link here |
| `<leader>mc` | check the vault for broken links/headings (quickfix) |
| `<leader>mb` | back through link-follow history         |
| `<leader>mr` | re-read templates dir                    |
| `<leader>mv` | print vault root                         |
| `gf`         | follow markdown link (native `gf` otherwise) |

`keymaps = false` disables all of them; call the Lua API instead
(`require("notes.links").insert_file_link()`, etc).

## Commands

`:TemplateInsert [name]`, `:TemplateReload`, `:NotesVault`, `:NoteNew [name]`, `:NoteMove [dir]`, `:NoteRename [name]`, `:NoteBacklinks`, `:NoteCheck [file]`, `:NoteEmbed`, `:NotePasteImage [name]`, `:NoteSearch [text]`, `:NoteTags [tag]`, `:NoteProps [key[=value]]`, `:NoteToc [maxlevel]`, `:NoteFollow [split|vsplit|tab]`, `:NoteLinkConvert [wiki|markdown]`, `:NoteTask`, `:NoteTasks [open|done|all|file]`, `:NoteReindex`, `:NoteOutline [maxlevel]`, `:NoteOutlineToggle`, `:NotePreview`, `:NoteEmbedInline`, `:NoteImageToggle`, `:NoteImageStatus`

## Capture

**Embed picker.** `<leader>me` / `:NoteEmbed` lists the vault's notes and attachments (everything inside
`attachment_dir` / `attachment_dirs`, plus images, pdf, audio and video anywhere) and embeds the pick at the
cursor: `![name](rel/path.png)` (`embed_style = "wiki"` for `![[name.png]]`). Notes, images, pdf, audio and
video are embedded with `!`; anything else (zip, ...) becomes a plain link. `<leader>ml` lists the same files
for ordinary `[text](path)` links, `<leader>mh` stays notes-only.

**Link paths.** `link_path = "shortest"` (default, Obsidian's behaviour) writes just the file name when it is unique in
the vault - `![](photo.png)`, `[note](note.md)` - and the shortest unique path (`folder/note.md`) when it is not;
`"relative"` writes `../static/photo.png`. Every feature resolves name-only links anywhere in the vault
(attachment folders first): `gf`, `<leader>mp` previews, inline images, `:NoteCheck`, backlinks, move/rename (a
name-only link is left alone when its file moves and rewritten only when the name changes). Other tools
(GitHub, static site generators, marksman) expect real relative paths - use `"relative"` for such vaults.
Applies to `<leader>ml`, `<leader>mh`, `<leader>me`, pasted images, link conversion and completion.

**Paste image.** `<leader>mP` / `:NotePasteImage [name]` saves the clipboard image (`wl-paste` on Wayland, `xclip`
on X11, `pngpaste` on macOS) into `attachment_dir` (else an existing conventional folder in the vault root, else
`<vault>/attachments`) and inserts `![name](relative/path.png)` (`embed_style = "wiki"` for `![[name.png]]`).
You are asked for the name (default `image-YYYYMMDD-HHMMSS`; `paste_name = "auto"` skips the prompt); clashes get `-1`, `-2`.

**Template prompts.** `{{prompt:Label}}` or `{{prompt:Label|default}}` in a template asks for a value when the template
is injected (same label = asked once; cancel aborts). Works in frontmatter and body.

## Search and navigation

- `<leader>ms` / `:NoteSearch [text]`: live full-text search over the vault's markdown (telescope or fzf-lua; ripgrep +
  list fallback).
- `<leader>mT` / `:NoteTags [tag]`: pick a tag (with note counts), then a note. Inline `#tags` and frontmatter
  `tags:` are both indexed (code blocks/spans, headings and urls are ignored).
- `<leader>mF` / `:NoteProps [key[=value]]`: key, then value, then note, from frontmatter
  (`key: value`, `key: [a, b]`, `- item` lists).
- `<leader>m]` / `[`: next/previous link or embed, `<leader>m}` / `{`: next/previous heading (wrap around; `3<leader>m]` jumps 3).
- `<leader>m-` / `|` / `+` (`:NoteFollow [split|vsplit|tab]`): follow the link under the cursor in a new split / vsplit / tab.
- `<leader>mC` / `:NoteToc [maxlevel]`: inserts `<!-- toc -->` ... `<!-- /toc -->` with a nested list of heading links at the
  cursor, or refreshes the existing block. With `toc_auto_update = true` (default) the block is refreshed on every
  save. `toc_min_level` / `toc_max_level` (1-3) pick the levels.

## Editing

- **Completion** (blink.cmp / nvim-cmp): `[[` notes and attachments, `[[note#` headings, `](` relative paths,
  `](note.md#` anchors and `#tags`. blink.cmp: add the provider
  `providers = { notes = { name = "notes", module = "notes.blink" } }` and `"notes"` to `sources.default`
  (or `per_filetype.markdown`). nvim-cmp: the source `notes` is registered automatically, add `{ name = "notes" }`.
- **Link style conversion**: `<leader>mL` / `:NoteLinkConvert` converts the link under the cursor between
  `[[Note#Heading|text]]` and `[text](../Note.md#heading)`; `:NoteLinkConvert wiki` / `markdown` converts every
  link in the buffer. Unresolvable links are skipped. Ambiguous note names keep their path in wiki form.
- **Tasks**: `<leader>mx` toggles `- [ ]` / `- [x]` (adds a checkbox to list items and plain lines; works on a
  count or a visual range). `<leader>mX` / `:NoteTasks [open|done|all|file]` lists tasks across the vault
  (telescope preview), `file` for the current note.
- **Embed sizes**: `![[img.png|300]]`, `![[img.png|300x200]]` and `![alt|300](img.png)` set the width (px) of the
  inline image (roughly 9 px per terminal column).
- **Image formats**: PNG is drawn as is. Everything else (`jpg jpeg jfif gif webp bmp svg avif tif tiff heic heif jxl
  ico apng`, first frame) is converted to PNG once, cached, by the first converter installed:
  ImageMagick (`magick`/`convert`), GraphicsMagick, libvips, ffmpeg or Pillow, and for specific formats
  `rsvg-convert`/`inkscape` (svg), `dwebp` (webp), `heif-convert` (heic), `avifdec`, `djxl`.
  Without any converter only PNG renders and the embed shows a label saying what to install
  (`:NoteImageStatus` / `:checkhealth notes` list what was found). Arch: `sudo pacman -S imagemagick` (or `libvips`).
- **PDF**: `![[doc.pdf]]` / `[](doc.pdf)` previews and renders the first page inline (needs `pdftoppm` or `mutool`,
  or ImageMagick + ghostscript); `<leader>mp` falls back to opening the PDF in the system viewer.

## Housekeeping

- **Vault index**: the file structure and the per-note parse results (links, headings, tags, tasks, properties)
  are cached. Unchanged notes are never re-read (mtime/size check), the file list is rebuilt only when files were
  added, removed or renamed: directory watchers (`index_watch = true`), plus `FocusGained` and saves.
  `:NoteReindex` forces a rebuild. Backlinks, `:NoteCheck`, move/rename, tags, properties, tasks and completion
  all share it.
- **`:checkhealth notes`** reports Neovim version, vault, index, templates, picker, image support (terminal, tmux,
  converters), clipboard tool and completion plugin.

## Link integrity

`:NoteMove` / `<leader>mm` and `:NoteRename` / `<leader>mR` rewrite links pointing at the note and the
relative links inside it (`update_links = "ask"` asks first; `true` always, `false` never).
Link styles are preserved: markdown `[](../x.md#h)` and wiki `[[x]]` / `[[folder/x]]`, `![]()` embeds,
`%20` escaping, `<angle brackets>`, a dropped `.md` stays dropped, vault-absolute `/a/b.md`, anchors untouched.
Name-only links (`[[x]]`) are only rewritten when the file *name* changes. Links in code blocks/spans
and in your templates folder are left alone. Open buffers are updated; unmodified ones are saved,
modified ones stay unsaved.

`<leader>mk` lists the notes linking to the current one (telescope preview), `<leader>mc` /
`:NoteCheck` puts every broken link and missing `#heading` in the vault into the quickfix list
(`:NoteCheck file` for just the current note). Resolution matches the preview lookup (direct path,
attachment folders, then file name anywhere in the vault).

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

`<leader>mp` previews the link or embed under the cursor (or the embed on the line):
`![[note]]`, `![[note#heading]]`, `![alt](note.md)`, `![[img.png]]`, `![alt](img.png)`.
Plain links work too: `[text](note.md#heading)`, `[[note]]`, `[pic](img.png)`, `[x](#heading)`.

The preview stays until you dismiss it: `Esc` / `q` close it, `Enter` opens the previewed note in the current window
(markdown only; `<leader>mb` returns, and the heading is jumped to), `<C-d>` / `<C-u>` scroll long notes.
Pressing `<leader>mp` again moves into the float. The keys are temporary
buffer-local mappings; your own buffer-local `Esc`/`q`/`Enter` mappings come back when the preview closes.
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
- Not supported (WezTerm, foot, alacritty, ...): nothing is drawn inline; `<leader>mp` falls back through
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
