# canvasdiff.nvim

Your whole git changeset as one buffer you can work inside.

CanvasDiff renders every changed file's diff into a single scrollable canvas.
Press Enter on any line to land in the real file — LSP, treesitter and your
autocmds attached, unsaved edits included — fix it, and jump straight back to
where you were reading. Status: pre-alpha.

<!-- TODO: demo gif -->

```
 HEAD → WORKTREE                      │ Files changed (12)  +340 −128
████ src/canvas.lua  (+12 −4) ●○ █████│ ▾ src/
   40    local M = {}                 │     canvas.lua   +12 −4  ●○
       - return nil                   │     sidebar.lua  +2 −0   ○
   41  + return M                     │   ▸ test/
████ src/sidebar.lua  (+2 −0) ○ ██████│
▸ test/helpers.lua  (3 hunks, +9 −1)  │
```

## Features

- **One canvas** — every changed file, concatenated into a single buffer with
  your own treesitter highlighting plus word-level diff emphasis
- **Edit in place** — Enter opens the real file at that exact line; Ctrl+Space
  returns to the same spot, with the diff regenerated from buffer content,
  saved or not
- **Live** — auto-refreshes on save, focus, and external changes; refreshes
  splice in what changed without moving the line you're reading
- **Lenses** — one key pivots between all / unstaged / staged changes;
  file-level stage and unstage from the canvas or the sidebar
- **Wayfinding** — file-tree sidebar, tinted per-file header bars, a pinned
  current-file header, a comparison band, and a minimap scrollbar you can drag
- **Folding with a memory** — fold files or directories away; folds persist per
  repo, and a fold whose content changes behind it gets a stale mark
- **Sessions** — folds and your (content-based, not line-number) position are
  restored per repository across restarts
- **Scales** — auto-virtualization and a page-backed canvas keep huge
  changesets responsive
- **Read-only range review** — `:CanvasDiff main..topic`, or pick two branches
  interactively

## Requirements

- **Neovim 0.12+** — the tested floor, asserted by the plugin and by
  `:checkhealth canvasdiff`; CI runs the suite against stable and nightly
- **git** on your `$PATH`
- Developed on Linux; macOS should work (nothing platform-specific is used);
  Windows is untested

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "reklai/canvasdiff.nvim",
  opts = {}, -- optional; the defaults work with no setup() at all
}
```

Load at startup if you want the global `<leader>lb` (compare) and `<leader>lc`
(checkout) mappings available immediately — a `cmd = "CanvasDiff"`-only lazy
spec can't install mappings until the command has loaded the plugin.

After installing, run `:checkhealth canvasdiff` — it verifies the version
floor and git, and audits your `setup()` table for misspelled or removed
options, which would otherwise merge silently and do nothing.

## Quick start

1. `:CanvasDiff` in any window inside a git repository. The canvas opens with
   every changed file's diff, plus the file-tree sidebar.
2. Scroll. The winbar names the comparison (`HEAD → WORKTREE`), a pinned
   header names the file you're in, and the sidebar tracks you.
3. Press **Enter** on a line to open that file for real, at that line.
4. Edit, then hold **Ctrl** and press **Space** to jump back — the diff
   re-renders from your buffer, saved or not.
5. Press **Tab** to pivot the lens: all → unstaged → staged.
6. Press **q** when you're done reading. You land back on the buffer you
   opened the canvas over, cursor intact.

## Usage

### The canvas

Each file gets a full-width tinted header bar — `▎ path (+adds −dels)` plus its
stage markers — followed by unified-diff-style hunks (3 context lines by
default). Deleted lines render as dimmed, struck-through **ghost** lines above
the row that replaced them, so every real row maps 1:1 to a line of the file:
Enter always opens exactly the line under your cursor, and the statuscolumn
shows each row's line number *in its file*. A wholly deleted file keeps its
deletions as real rows — see [ghost deletions](docs/design.md#ghost-deletions-the-result-view)
for the reasoning and limits.

A 1-column minimap floats over the right edge: file boundaries, add/delete
density, and a thumb tracking your viewport. Drag the thumb to scrub, or click
the track to jump. Clicks off that column are untouched — single-click places
the cursor, double-click jumps into the file like Enter. If you run
satellite.nvim or nvim-scrollbar, disable one side
(`scrollbar = { enabled = false }`) — they draw at the same edge.

### Staging and the stage markers

**s** stages every unstaged change in the file under the cursor; **u** unstages
it without touching the worktree. Each key does one thing and says so when
there's nothing to do (`already staged` / `nothing staged`). Staging is refused
while a modified loaded buffer aliases the path, so unsaved text can't be
silently replaced by disk content.

Every file row — sidebar, header bar, folded placeholder — carries its stage
state from git's own XY pair:

| Marker | Colour | Means |
| --- | --- | --- |
| `●` | green (`Added`) | **staged** — the index differs from HEAD |
| `○` | yellow (`DiagnosticWarn`) | **unstaged** — the worktree differs from the index |
| `●○` | green + yellow | staged, then changed again |
| `●` | red (`DiagnosticError`) + bold | **stale** — changed since you folded it |

The stale mark is always last, and clears when you unfold — you've seen it. Why
the same dot twice, and why bold: [the stale marker](docs/design.md#the-stale-marker).

### Lenses

The canvas always compares two sides; the **lens** is which pair. **Tab** and
**Shift+Tab** cycle it; the commands *set* one, so they're safe in mappings.

| Lens | Old side | New side | Equivalent |
| --- | --- | --- | --- |
| `all` | `HEAD` | worktree | `git diff HEAD` |
| `unstaged` | index | worktree | `git diff` |
| `staged` | `HEAD` | index | `git diff --staged` |

Pivoting is non-destructive: files identical through both lenses aren't
re-rendered, so your position holds. In the `staged` lens the new side is the
index, which isn't a file, so Enter declines rather than opening a buffer whose
content isn't what you're looking at.

Ranges (`main..topic`, `A...B`) compare committed content and are **read-only**
— the band says so and tints, and staging and jumps decline. A bare revision
(`:CanvasDiff main`) is still a worktree lens: that ref against your editable
worktree. Tab (or q) leaves a range and returns to the working view you came
from.

### Folding

- the **sidebar folds directories** — **z** then **a**, or just **c**, on a directory row
- the **canvas folds files** — same keys, anywhere in the file's diff

One state, two views: a directory folded in the tree renders each file under it
as its one-row placeholder, `▸ path  (N hunks, +adds −dels)`, on the canvas.
Motions still land on placeholders (`3]f` is three sections forward regardless
of fold state), Enter still opens the file without unfolding, and folds persist
per repo until the changes they cover are gone. Very large changesets
auto-collapse far-from-viewport sections on top of this (see `virt` and `paged`
below); that bookkeeping is never persisted and never marked.

### Commands

`:CanvasDiff` with no argument toggles the canvas — that's the one you'll use.
The rest exist for your own mappings and scripts:

```vim
:CanvasDiff              " toggle the canvas
:CanvasDiff toggle       " the same, spelled out
:CanvasDiff open         " open it
:CanvasDiff close        " always closes, from any window in the tab
:CanvasDiff refresh      " re-scan and splice in what changed, keeping your place
:CanvasDiff sidebar      " toggle the file-tree sidebar
:CanvasDiff compare      " pick two local branches and compare them
:CanvasDiff checkout     " switch to a local branch
:CanvasDiff track        " create a local branch tracking a remote ref, and switch
:CanvasDiff all          " lens: HEAD → worktree (the default)
:CanvasDiff unstaged     " lens: index → worktree
:CanvasDiff staged       " lens: HEAD → index
:CanvasDiff main..topic  " compare two tips (read-only)
:CanvasDiff main...topic " compare since the merge base (read-only)
```

All complete with Tab. Subcommand words are matched before revision parsing, so
a branch literally named `close` can't hijack them — spell such a branch a way
only git reads, like `heads/close`. An omitted range endpoint means `HEAD`.
`checkout` and `track` refuse to run with unsaved changes in repository
buffers, and offer no force, stash, detached-HEAD, or deletion operations.

Outside a git repository, `:CanvasDiff open` notifies and does nothing further.

## Configuration

Defaults shown; any subset can be overridden, unspecified keys keep their
default:

```lua
require("canvasdiff").setup({
  -- Grouped by context. `global` is process-wide; the others name the buffer
  -- each key lives on. Every value takes one key or a list of them.
  keymaps = {
    global = {
      compare = "<leader>lb", -- pick two local branches, open their read-only diff
      checkout = "<leader>lc", -- switch to a local branch
    },
    canvas = {
      jump       = { "<CR>", "<2-LeftMouse>" }, -- open the file under the cursor
      collapse   = { "za", "c" },     -- fold this file away / bring it back
      next_file  = "]f",     -- cursor to the next file's diff start (clamps)
      prev_file  = "[f",     -- cursor to the previous file's diff start (clamps)
      next_hunk  = "]h",     -- cursor to the next hunk header (clamps)
      prev_hunk  = "[h",     -- cursor to the previous hunk header (clamps)
      cycle_next = "<C-n>",  -- scroll to the next file's diff (wraps)
      cycle_prev = "<C-p>",  -- scroll to the previous file's diff (wraps)
      refresh    = "r",      -- re-scan, splice in what changed, keep your place
      stage      = "s",      -- stage this file's changes
      unstage    = "u",      -- unstage this file (never touches the worktree)
      lens_next  = "<Tab>",  -- cycle the lens forward (all / unstaged / staged)
      lens_prev  = "<S-Tab>",-- and back
      sidebar    = "o",      -- toggle the file-tree sidebar
      close      = "q",      -- back out of a comparison, else close the canvas
      help       = "<leader>lh", -- show the keybind cheatsheet
    },
    sidebar = {
      select = { "<CR>", "za", "c", "<2-LeftMouse>" }, -- scroll here / fold a dir
      stage   = "s",         -- same file-level stage
      unstage = "u",         -- same file-level unstage
      close  = "q",          -- close the sidebar (canvas stays open)
      help   = "<leader>lh", -- show the keybind cheatsheet
    },
    file = {
      -- Set on the jumped-to file buffer; the only way back.
      back = "<C-Space>",
    },
  },
  context = 3,          -- unified-diff context lines around each hunk
  base = "HEAD",        -- lens the canvas opens in: "HEAD" (all) or "index" (unstaged)
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
    enabled = true,     -- remember folds/view per repo across restarts
  },
  paged = {
    enabled = true,     -- page-backed canvas for very large reviews
    min_rows = 20000,   -- canvas rows past which pages replace the eager buffer
  },
  glyphs = {            -- every drawn glyph; or the string "ascii" for the
    ctx = " ", del = "-", add = "+",            -- ASCII-only set
    file = "▎", folded = "▸", open = "▾", minus = "−",
    gutter = "▎",
    staged = "●", unstaged = "○", stale = " ●",
    scroll_file = "‒", scroll_bar = "❘",
  },
})
```

A misspelled glyph or option name is reported (by `setup()` and by
`:checkhealth canvasdiff`) rather than silently ignored. `glyphs = "ascii"`
switches everything to single-cell ASCII, for restricted fonts or
`ambiwidth=double` (why the defaults can't be:
[glyphs and ambiwidth](docs/design.md#glyphs-and-ambiwidth)).

## Keymaps

Every binding the plugin installs is listed here — there are no hidden ones. An
override **replaces** the value (so `collapse = "za"` really drops `c`);
`false`, `""`, or `{}` disables one. **Chords** are held together; **sequences**
are tapped one after the other (with about a second between taps).

| Canvas | Default | How you press it | Action |
| --- | --- | --- | --- |
| `jump` | `<CR>`, `<2-LeftMouse>` | **Enter**, or **double-click** | Open the file under the cursor as a real buffer. Never changes its fold |
| `collapse` | `za`, `c` | tap **z** then **a**, or just **c** | Fold or unfold this file — unfolds the directory when that is what's hiding it |
| `next_file` / `prev_file` | `]f` / `[f` | tap **]** then **f** / **[** then **f** | Cursor to the next/previous file's diff start, clamping. Lands on folded files too; takes a count |
| `next_hunk` / `prev_hunk` | `]h` / `[h` | tap **]** then **h** / **[** then **h** | Cursor to the next/previous hunk header, clamping. A folded file counts as one stop; takes a count |
| `cycle_next` / `cycle_prev` | `<C-n>` / `<C-p>` | hold **Ctrl** + **N** / **P** | Scroll to the next/previous file's diff, wrapping. Takes a count |
| `refresh` | `r` | **r** | Re-scan and splice in what changed, keeping your place |
| `stage` | `s` | **s** | Stage every unstaged change in this file |
| `unstage` | `u` | **u** | Unstage this file; never touches the worktree |
| `lens_next` / `lens_prev` | `<Tab>` / `<S-Tab>` | **Tab** / hold **Shift** + **Tab** | Cycle the lens: all ⇄ unstaged ⇄ staged |
| `sidebar` | `o` | **o** | Toggle the file-tree sidebar (works even with `sidebar.enabled = false`) |
| `close` | `q` | **q** | Back out: leave a stacked comparison, else close the canvas and restore the previous buffer |
| `help` | `<leader>lh` | leader, then **l**, then **h** | Show the keybind cheatsheet |

| Sidebar | Default | How you press it | Action |
| --- | --- | --- | --- |
| `select` | `<CR>`, `za`, `c`, `<2-LeftMouse>` | **Enter**, **z** then **a**, just **c**, or **double-click** | Scroll the canvas to the file (without unfolding it), or fold the directory |
| `stage` / `unstage` | `s` / `u` | **s** / **u** | Exactly as on the canvas |
| `close` | `q` | **q** | Close the sidebar (canvas stays open) |
| `help` | `<leader>lh` | leader, then **l**, then **h** | Show the keybind cheatsheet |

| File buffer (during a jump) | Default | How you press it | Action |
| --- | --- | --- | --- |
| `back` | `<C-Space>` | hold **Ctrl** + **Space** | Return to the canvas at the same spot |

Two things worth knowing before you rely on the defaults:

- **`q` costs macro-record on the canvas** — the usual scratch-buffer trade.
  `keymaps = { canvas = { close = "Q" } }` if you'd rather keep it. The other
  bare letters are free: the canvas is `nomodifiable`, so every editing key is
  already inert there.
- **Test Ctrl+Space in your terminal** before relying on it — it sends byte
  `0x00`, which most but not all terminals transmit:
  `:nnoremap <C-Space> <Cmd>echo "ok"<CR>`.

The reasoning behind all of this — why bare letters, why Tab, why exactly one
way back — is in [keymap philosophy](docs/design.md#keymap-philosophy). Global
entry points for toggle/lens are easy to add from your plugin manager:

```lua
keys = {
  { "<leader><leader>", function() require("canvasdiff").toggle() end,
    desc = "CanvasDiff: toggle canvas" },
  { "<leader>ll", function() require("canvasdiff").cycle_lens(1) end,
    desc = "CanvasDiff: cycle the lens" },
},
```

CanvasDiff never replaces an existing global mapping — an occupied key wins and
is reported as a collision. Every mapping carries a `desc` for `:map`,
which-key, and pickers.

## Highlight groups

All groups are defined with `default = true`, so your colourscheme (or your own
`nvim_set_hl`) always wins. The diff palette is *derived* from your live
colourscheme by measured factors rather than linked — the measurements are in
[how diff rows are coloured](docs/design.md#how-diff-rows-are-coloured).

| Group | Default | Marks |
| --- | --- | --- |
| `CanvasDiffAdd` | derived neutral elevation | an added row's background |
| `CanvasDiffDel` | elevation + dimmed fg | a wholly deleted file's real rows |
| `CanvasDiffGhost` | dimmed fg + strikethrough | ghost deletion lines |
| `CanvasDiffPrefixAdd` / `CanvasDiffPrefixDel` | derived green/red fg | the `+`/`-` prefix cell |
| `CanvasDiffGutterAdd` / `CanvasDiffGutterDel` | the same green/red | the statuscolumn bar |
| `CanvasDiffWordAdd` / `CanvasDiffWordDel` | bold + underline | the changed span within a line |
| `CanvasDiffFileBar` | derived bar elevation | the file header row and its pinned copy |
| `CanvasDiffFileHeader` | `Title` | the filename on the bar |
| `CanvasDiffHunkHeader` | `Comment` | `@@ … @@` hunk header rows |
| `CanvasDiffBinary` | `Comment` | binary-file notices |
| `CanvasDiffWinbar` / `CanvasDiffWinbarReadOnly` | `WinBar` / `Visual` | the top band / its read-only tint |
| `CanvasDiffStaged` / `CanvasDiffUnstaged` | `Added` / `DiagnosticWarn` | the stage markers |
| `CanvasDiffStale` / `CanvasDiffStaleEmphasis` | `DiagnosticError` / bold | the stale mark |
| `CanvasDiffSidebarDir` / `CanvasDiffSidebarActive` | `Directory` / `Visual` | sidebar directories / active row |
| `CanvasDiffScrollFile` / `CanvasDiffScrollAdd` / `CanvasDiffScrollDel` / `CanvasDiffScrollChanged` / `CanvasDiffScrollThumb` | `Title` / `DiffAdd` / `DiffDelete` / `DiffChange` / `PmenuThumb` | the minimap |

```lua
-- point the margin at your scheme's own diff colours:
vim.api.nvim_set_hl(0, "CanvasDiffPrefixAdd", { link = "Added" })
vim.api.nvim_set_hl(0, "CanvasDiffPrefixDel", { link = "Removed" })

-- or bring back the two-pane vimdiff wash, if that's the loudness you want:
vim.api.nvim_set_hl(0, "CanvasDiffAdd", { link = "DiffAdd" })
vim.api.nvim_set_hl(0, "CanvasDiffDel", { link = "DiffDelete" })
```

## Sessions

The canvas remembers, per repository: folded files and directories, the lens
you were looking through, and roughly where you were — saved on close and on
exit to a small JSON file under `stdpath("state") .. "/canvasdiff/"`. Positions
are content-based, not line numbers, so restore lands close even after the file
changed. A remembered comparison whose branch was deleted degrades to the
default lens with a message. `session = { enabled = false }` turns it off.

## Similar plugins

- [diffview.nvim](https://github.com/sindrets/diffview.nvim) — the established
  review plugin; navigates file-by-file through a panel, stages by editing the
  index buffer. CanvasDiff instead renders the whole changeset as one buffer.
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) /
  mini.diff — per-buffer hunks and inline previews in files you already have
  open; complementary rather than competing.
- Terminal review TUIs — hunk,
  [critique](https://github.com/remorses/critique), and friends — render
  continuous diff streams in a separate process. Being outside your editor,
  they can't attach your LSP or see unsaved buffers, which is the half
  CanvasDiff is built around.

## Documentation

- `:h canvasdiff` — the full reference, including the Lua API and
  troubleshooting
- [docs/design.md](docs/design.md) — why it looks and behaves the way it does
  (measured, not felt)
- [docs/architecture.md](docs/architecture.md) — module boundaries and state
  ownership, each rule backed by an executable test

## Contributing

Tests are grouped by intent, and every boundary rule has an executable
counterpart:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff.log make test   # everything
make unit                                     # one intent group
make architecture                             # the boundary rules alone
```

## License

[MIT](LICENSE)
