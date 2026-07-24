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
- Press `q` to close the canvas. Closing is non-destructive: you land back on
  the buffer the canvas opened over, cursor and column intact. The two exits
  mean different things on purpose — `<CR>` is "I want to work on this file",
  `q` is "I'm done reading" — so a jump never changes where `q` puts you. If
  the buffer you came from was deleted meanwhile, it falls back to the file
  your review last touched, then to the alternate file, and only then to a
  blank one. `:Galley close` works from any window in the tab, not just the
  one showing the canvas.
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

## Commands

`:Galley` with no argument toggles the canvas — that's the one you'll use.
The rest exist so you can drive it from your own mappings and scripts:

```vim
:Galley             " toggle the canvas
:Galley open        " open it
:Galley close       " close it
:Galley refresh     " re-scan the repo and re-render
:Galley unstaged    " diff base: worktree vs index  (what plain `git diff` shows)
:Galley all         " diff base: worktree vs HEAD   (the default)
```

All of them complete with `<Tab>`.

`unstaged` and `all` **set** a base rather than flipping one, so they're safe
to put in a mapping — `:Galley unstaged` always lands unstaged, which a toggle
can't promise. Either will open the canvas if it isn't already showing. The
`B` key toggles between the two, because a keypress does want a flip.

> `--staged` is deliberately not accepted. In git it means index vs `HEAD` —
> the *staged* changes — which is the opposite of `unstaged` and is content
> galley can't render yet. It reports that rather than quietly showing you
> something else.

An argument that isn't one of those words is treated as a revision spec
(`:Galley main...HEAD`). Revision mode isn't implemented yet, so it says so and
does nothing — the grammar is reserved now so that adding it later won't be a
breaking change.

If the current directory isn't inside a git repository, `:Galley open`
notifies you and does nothing further (it never errors).

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
  -- Grouped by the buffer each key lives on, because the same key means
  -- different things in different places (`q` closes the canvas, but only the
  -- sidebar when pressed there). Every value takes one key or a list of them.
  keymaps = {
    canvas = {
      jump       = { "<CR>", "<2-LeftMouse>" }, -- open the file under the cursor
      collapse   = { "<Tab>", "za" },  -- toggle collapse of this file's diff
      next_file  = "]f",     -- cursor to the next file's diff start (clamps)
      prev_file  = "[f",     -- cursor to the previous file's diff start (clamps)
      next_hunk  = "]h",     -- cursor to the next hunk header (clamps)
      prev_hunk  = "[h",     -- cursor to the previous hunk header (clamps)
      cycle_next = "<C-n>",  -- scroll to the next file's diff (wraps)
      cycle_prev = "<C-p>",  -- scroll to the previous file's diff (wraps)
      refresh    = "R",      -- re-scan and re-render
      base       = "B",      -- toggle diff base: worktree vs HEAD / vs index
      close      = "q",      -- close the canvas
    },
    sidebar = {
      select = { "<CR>", "<Tab>", "za" }, -- scroll canvas here / fold a directory
      close  = "q",          -- close the sidebar (canvas stays open)
    },
    file = {
      back = "<M-CR>",       -- set on the jumped-to file buffer; return to canvas
    },
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

### Keymaps

**Every** binding the plugin installs is listed above and can be changed — there
are no hidden ones. Each value takes a single key or a list of keys:

```lua
keymaps = { canvas  = { collapse = "<Tab>" } }        -- one key: drops `za`
keymaps = { canvas  = { jump = { "<CR>", "o" } } }    -- a different pair
keymaps = { canvas  = { close = false } }             -- disable it
keymaps = { sidebar = { close = {} } }                -- also disables
```

An override **replaces** the list rather than merging into it, so
`collapse = "<Tab>"` really does remove `za`.

| Canvas | Default | Action |
| --- | --- | --- |
| `jump` | `<CR>`, `<2-LeftMouse>` | Open the file under the cursor as a real buffer |
| `collapse` | `<Tab>`, `za` | Toggle collapse of this file's diff |
| `next_file` / `prev_file` | `]f` / `[f` | Cursor to the next/previous file's diff start, clamping |
| `next_hunk` / `prev_hunk` | `]h` / `[h` | Cursor to the next/previous hunk header, clamping |
| `cycle_next` / `cycle_prev` | `<C-n>` / `<C-p>` | Scroll to the next/previous file's diff, wrapping |
| `refresh` | `R` | Re-collect changed files and re-render the canvas |
| `base` | `B` | Toggle diff base: worktree vs HEAD / vs index |
| `close` | `q` | Close the canvas, restore the previous buffer |

| Sidebar | Default | Action |
| --- | --- | --- |
| `select` | `<CR>`, `<Tab>`, `za` | Scroll the canvas to the entry, or toggle a directory's fold |
| `close` | `q` | Close the sidebar (canvas stays open) |

| File buffer (during a jump) | Default | Action |
| --- | --- | --- |
| `back` | `<M-CR>` | Return to the canvas at the same spot |

Every mapping is registered with a `desc`, so they show up in `:map`,
which-key.nvim and telescope keymaps without extra configuration.

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
