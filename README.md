# galley

Galley proofs for your git diff — read the whole change as one continuous strip, fix it in place.

Every changed file's diff, concatenated into a single scrollable buffer. Jump into any hunk as a real, LSP-attached buffer and jump back to the exact spot. Status: pre-alpha MVP.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-name/galley", -- adjust to wherever this repo lives
  cmd = "Galley",
  opts = {}, -- optional; see Configuration below
}
```

`opts = {}` (or omitting `opts`/`config` entirely) is enough — the plugin
works with its defaults even if `setup()` is never called.

## Usage

Run `:Galley` in any window inside a git repository. It replaces the
current window's buffer with a single scrollable "canvas": every changed
file's diff, one after another, in alphabetical path order, each with a
`▎ path (+adds −dels)` header and unified-diff-style hunks (3 lines of
context by default -- configurable via `context`, see Configuration below).
Diff content is syntax-highlighted with your own treesitter setup (whatever
parsers/queries you already have installed), plus intra-line word-diff
emphasis on changed spans within a hunk's paired `-`/`+` lines.

- Move the cursor onto any line and press `<CR>` to jump into that file as a
  real `:edit` buffer, landing on the corresponding line (LSP/treesitter/
  autocmds all attach normally — it's not a preview).
- Edit the file as usual (saved or not), then press `<M-CR>` to jump back to
  the canvas. The diff for that file is regenerated from the file's current
  content (including unsaved edits) and the canvas view is restored to
  roughly where you left it.
- Press `q` to close the canvas and restore whatever buffer was in the
  window before.
- Press `R` to refresh the whole canvas: re-scan the repo for changed files
  and re-render everything from scratch.
- Press `<C-n>` / `<C-p>` to jump straight to the next/previous file's diff,
  wrapping around at either end. Focus stays in the canvas.

A file-tree sidebar opens automatically alongside the canvas (a fixed,
non-focused vsplit), listing every changed file in an indented directory
tree and tracking your scroll position with a highlighted active entry.
From the sidebar: `<CR>` (or `<Tab>`/`za` on a directory) scrolls the canvas
to the entry under the cursor / toggles that directory's fold, and `q`
closes just the sidebar (the canvas stays open). Set `sidebar.enabled =
false` to turn it off.

A 1-column scrollbar minimap floats over the canvas's right edge, showing
file boundaries (─), add/del density per stretch of lines (│, colored), and
a highlighted thumb tracking your current viewport across the whole canvas.
Double-click a line in the canvas (`<2-LeftMouse>`) to jump into that file,
same as `<CR>`. It's purely visual and non-focusable — your mouse wheel still
works normally on the canvas window underneath it. satellite.nvim / nvim-scrollbar
still function on the canvas window, but they draw at the same right edge as
the built-in bar — disable one (`scrollbar = { enabled = false }`).

Press `<Tab>` (or `za`) on any line to collapse that line's file down to a
single placeholder row (`▸ path  (N hunks, +adds −dels)`), and again to
expand it back. Pressing `<CR>` on a collapsed placeholder expands it
instead of jumping. For very large changesets (past `virt.max_files` files
or `virt.max_lines` fully-expanded canvas lines), the same collapse
mechanism kicks in automatically: sections far from your current viewport
auto-collapse and ones you scroll near auto-expand, keeping at most
`virt.max_expanded` sections rendered in full at once. Both thresholds
describe the changeset itself, so what is collapsed right now never changes
whether virtualization is on. This auto-virtualization never touches (or
persists) anything you collapsed yourself.

Use `]f` / `[f` to jump the cursor to the next/previous file's diff start
(clamping at the ends, honoring a count), and `]h` / `[h` to step between
hunk headers across every non-collapsed section. A statuscolumn shows each
visible line's number in the file it belongs to (not the canvas buffer's own
line number) — blank for headers and collapsed placeholders, `·` for pure
deletions.

`:Galley base` toggles the diff base between the worktree vs `HEAD`
(default — everything changed, staged or not) and the worktree vs the index
(unstaged content only — what a plain `git diff --cached` would show is
excluded, since it's comparing against what's already staged), refreshing
the canvas and notifying which mode is now active.

`:Galley` with no argument toggles the canvas (open if not showing,
close if showing). It also accepts an explicit subcommand, with completion:

```vim
:Galley open
:Galley close
:Galley toggle
:Galley refresh
:Galley base
```

If the current directory isn't inside a git repository, `:Galley
open` notifies you and does nothing further (it never errors).

The canvas remembers, per repository, which files you collapsed, which
sidebar directories you folded, and roughly where you were scrolled/where
your cursor was — restored the next time you open the canvas there, even
across a Neovim restart. It's saved when you close the canvas and again on
Neovim exit, to a small JSON file under `stdpath("state") ..
"/galley/"`, keyed by the repo root. Nothing here is a raw line
number: the saved position is content-based (which line, near what text), so
it still lands close to the right spot even if the file changed since you
last looked. Set `session.enabled = false` to turn this off entirely.

## Configuration

```lua
require("galley").setup({
  keymaps = {
    jump = "<CR>",       -- jump into the file under the cursor
    back = "<M-CR>",     -- jump back to the canvas from an excursion
    close = "q",         -- close the canvas
    refresh = "R",       -- re-scan and re-render
    cycle_next = "<C-n>", -- scroll to the next file's diff (wraps)
    cycle_prev = "<C-p>", -- scroll to the previous file's diff (wraps)
    collapse = "<Tab>",   -- toggle collapse of the section under the cursor
    next_file = "]f",     -- cursor to the next file's diff start (clamps)
    prev_file = "[f",     -- cursor to the previous file's diff start (clamps)
    next_hunk = "]h",     -- cursor to the next hunk header (clamps)
    prev_hunk = "[h",     -- cursor to the previous hunk header (clamps)
  },
  context = 3,          -- unified-diff context lines around each hunk
  base = "HEAD",        -- diff base: "HEAD" or "index" (staged-only review)
  highlight = {
    enabled = true,     -- syntax + word-diff highlighting of hunk content
    margin = 100,       -- rows beyond the viewport kept highlighted
    debounce_ms = 30,   -- scroll debounce before re-applying highlights
  },
  watch = {
    enabled = true,     -- auto-refresh the canvas on save/focus/external changes
    debounce_ms = 200,  -- delay before reconciling after a detected change
  },
  sidebar = {
    enabled = true,     -- auto-open the file-tree sidebar alongside the canvas
    width = 32,         -- sidebar window width, in columns
  },
  scrollbar = {
    enabled = true,     -- overlay the minimap scrollbar on the canvas
  },
  statuscolumn = {
    enabled = true,     -- show each line's number in the file it belongs to
  },
  virt = {
    enabled = true,     -- tier-1 auto-virtualization for huge changesets
    max_files = 200,    -- section count past which auto-collapse activates
    max_lines = 100000, -- fully-expanded canvas lines past which it activates
    margin = 100,       -- rows around the viewport treated as "near"
    max_expanded = 20,  -- sections kept rendered in full at once, once active
  },
  session = {
    enabled = true,     -- remember collapse/folds/view per repo across restarts
  },
})
```

Any subset of these can be overridden; unspecified keys keep their default.

| Keymap (canvas buffer only) | Default | Action |
| --- | --- | --- |
| `jump` | `<CR>` | Open the file under the cursor as a real buffer |
| `back` | `<M-CR>` | (set on the excursed file buffer) return to the canvas |
| `close` | `q` | Close the canvas, restore the previous buffer |
| `refresh` | `R` | Re-collect changed files and re-render the canvas |
| `cycle_next` | `<C-n>` | Scroll to the next file's diff, wrapping |
| `cycle_prev` | `<C-p>` | Scroll to the previous file's diff, wrapping |
| `collapse` / `za` | `<Tab>` | Toggle collapse of the section under the cursor |
| `next_file` / `prev_file` | `]f` / `[f` | Cursor to the next/previous file's diff start, clamping |
| `next_hunk` / `prev_hunk` | `]h` / `[h` | Cursor to the next/previous hunk header, clamping |
| (mouse) | `<2-LeftMouse>` | Double-click a line to jump into that file, same as `jump` |

| Keymap (sidebar buffer only) | Default | Action |
| --- | --- | --- |
| `<CR>` / `<Tab>` / `za` | -- | Scroll the canvas to the entry, or toggle a directory's fold |
| `q` | -- | Close the sidebar (canvas stays open) |

Diff content is highlighted lazily: only sections within `margin` rows of
the current viewport get real treesitter syntax highlighting (using
whatever parser/highlight query you already have for that filetype) plus
word-level diff emphasis, applied/evicted as you scroll (debounced by
`debounce_ms`). Word-diff spans use two highlight groups you can link to
whatever you like -- `GalleyWordAdd` and `GalleyWordDel`, both linked to `DiffText`
by default.

The canvas auto-refreshes on `:write`, on regaining focus, and on file
changes made outside Neovim, debounced by `watch.debounce_ms` (200ms
default) so a burst of changes settles into a single reconcile. Only
sections that actually changed are touched -- untouched sections keep their
scroll position, so you generally never notice the refresh happen under
you. Because Linux `inotify` has no recursive watch, external-change
detection watches the repo root and `.git` non-recursively plus the parent
directories of files currently shown on the canvas; a change to a file in
some other, not-yet-watched subdirectory is picked up the next time you
save or refocus Neovim (or with a manual `R`) rather than instantly. Set
`watch.enabled = false` to go back to manual-refresh-only behavior. The
watcher keeps running while the canvas is merely hidden (so it's already
fresh when you return to it) and only stops when the canvas is closed with
`q` or its buffer is wiped.

## MVP scope

What's here today:

- One scrollable canvas per invocation, built from `git status` +
  `git show HEAD:<path>` + current worktree/buffer content.
- Line-tier highlighting (`+`/`-`/context lines, file and hunk headers)
  plus lazy treesitter syntax highlighting and intra-line word-diff
  emphasis of the diffed code itself, applied within `margin` rows of the
  viewport.
- Auto-refresh on save, focus, and external filesystem changes (see
  Configuration above), plus manual refresh (`R` / `:Galley
  refresh`) for a full re-scan on demand.
- Jump/back round-trip preserves your semantic position (same hunk/line)
  across edits, not just a raw line number.
- A persistent file-tree sidebar (directory folding, scroll-synced active
  entry, `<CR>`-to-scroll) plus `<C-n>`/`<C-p>` section cycling, both live
  updated as the canvas reconciles.
- A scrollbar minimap (file boundaries, add/del density, viewport thumb)
  overlaid on the canvas, plus double-click-to-jump.
- Manual section collapse (`<Tab>`/`za`) plus tier-1 auto-virtualization that
  collapses far-from-viewport sections once a changeset crosses configurable
  file/line thresholds, so huge diffs stay responsive.
- `]f [f ]h [h` file/hunk motions and a statuscolumn showing each line's
  number in the file it belongs to.
- A worktree-vs-HEAD / worktree-vs-index diff base toggle (`:Galley
  base`) for reviewing staged-only changes.
- Session persistence: collapse state, sidebar folds, and semantic
  scroll/cursor position are remembered per repo across Neovim restarts.

## Roadmap

All phases from the original plan (virtualization, session persistence) are
now implemented; there's no pending roadmap.
