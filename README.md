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
   40    local M = {}                 │     canvas.lua  +12 −4 ●○
       - return nil                   │       @@ 41  return M  +1 −1
   41  + return M                     │     sidebar.lua  +2 −0 ○
████ src/sidebar.lua  (+2 −0) ○ ██████│ ▸ test/  (1 files, +9 −1)
▸ test/helpers.lua  (3 hunks, +9 −1)  │
```

## Features

- **One canvas** — every changed file, concatenated into a single buffer with
  your own treesitter highlighting
- **Edit in place** — Enter opens the real file at that exact line; Ctrl+Space
  returns to the same spot, with the diff regenerated from buffer content,
  saved or not
- **Live** — auto-refreshes on save, focus, and external changes; refreshes
  splice in what changed without moving the line you're reading
- **Lenses** — one key pivots between all / unstaged / staged changes; stage
  and unstage a hunk or a whole file, from the canvas or the sidebar
- **Wayfinding** — a file-and-hunk sidebar, tinted per-file header bars, a
  pinned header naming the file *and the hunk* you're in, a comparison band,
  and a minimap scrollbar you can drag
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

With [lazy.nvim](https://github.com/folke/lazy.nvim) — or a distro built on
it, like [LazyVim](https://github.com/LazyVim/LazyVim), where this table goes
in its own file under `lua/plugins/`:

```lua
{
  "reklai/canvasdiff.nvim",
  opts = {}, -- optional; the defaults work with no setup() at all
}
```

That loads at startup, which is the simplest correct spec: the built-in global
`<leader>lb` (compare) and `<leader>lc` (checkout) mappings exist immediately.

To **lazy-load** instead, trigger on the command and own the entry points in
the `keys` spec — pressing any of them loads the plugin and runs the action:

```lua
{
  "reklai/canvasdiff.nvim",
  cmd = "CanvasDiff",
  keys = {
    { "<leader><leader>", function() require("canvasdiff").toggle() end,
      desc = "CanvasDiff: toggle canvas" },
    { "<leader>lb", function() require("canvasdiff").compare() end,
      desc = "CanvasDiff: compare branches" },
    { "<leader>lc", function() require("canvasdiff").checkout() end,
      desc = "CanvasDiff: checkout branch" },
  },
  -- The keys above replace the plugin's own globals, so turn those off --
  -- otherwise they can't exist until something else loads the plugin anyway.
  opts = { keymaps = { global = { compare = false, checkout = false } } },
}
```

The point of routing `<leader>lb`/`<leader>lc` through `keys` rather than
relying on the built-ins: a lazy-loaded plugin can't install a global mapping
before it loads, so the built-ins would be dead until the first `:CanvasDiff`.
The `keys` spec inverts that — the mapping exists from startup and *causes*
the load. Everything inside the canvas (Enter, q, Tab, …) needs nothing here;
those are buffer-local and installed when the canvas opens.

After installing, run `:checkhealth canvasdiff` — it verifies the version
floor and git, and audits your `setup()` table for misspelled or removed
options, which would otherwise merge silently and do nothing.

## Quick start

1. `:CanvasDiff` in any window inside a git repository. The canvas opens with
   every changed file's diff, plus the file-tree sidebar.
2. Scroll. The winbar names the comparison (`HEAD → WORKTREE`), a pinned
   header names the file and hunk you're in, and the sidebar tracks you.
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

### The sidebar

The tree has two levels of content under each directory: the **files** in the
review, and under each unfolded file, one row per **hunk** —
`@@ 88  render(state)  +3 −1`: the new-side line the hunk starts at, the first
line it writes, and its own counts. Press Enter on a hunk row to scroll the
canvas to that hunk; press **s**/**u** on it to stage or unstage just that
hunk. A hunk taken from a deleted line is struck through, exactly as it is on
the canvas.

The tree mirrors the canvas's folds and nothing else. Fold a file (**c** on the
canvas, or **z** then **a**) and its hunk rows collapse into the one row the
canvas shows, carrying the same summary its placeholder does —
`▸ helpers.lua  (3 hunks, +9 −1)`. Fold a directory and it becomes one row
summarising what it hides, `▸ test/  (2 files, +9 −1)`. Auto-virtualization is
*not* a fold and never removes hunk rows: it collapses far-from-viewport
sections on the canvas for speed, and if that reflowed the tree it would move
rows under your cursor on every scroll.

### Knowing where you are

Three things answer it, and each answers exactly one question:

- the **band** across the top names the *comparison* (`HEAD → WORKTREE`) and
  never changes while you scroll
- the **pinned header** under it names the *file* — a copy of that file's
  header bar, stage markers and all — and then, once the *top line of the
  window* is inside a hunk, the hunk after it:
  `▎ src/canvas.lua  (+12 −4) ●○ → @@ 88  render(state) · 3/5`. The `3/5` is
  the hunk's ordinal in that file, so you know how much of it is left. It
  follows the topline rather than your cursor, so `]h` can leave you inside
  hunk 4 while the crumb still reads `3/5`. On the rows before a file's first
  hunk there is no hunk to name and the crumb is absent; a narrow window keeps
  the ordinal and cuts the label around it, and drops the crumb whole rather
  than clipping the ordinal off the edge
- the **sidebar** highlights the row for whatever is under the window top, at
  hunk depth when the tree is showing that hunk

The hunk is named identically in the crumb and in the tree, so closing the
sidebar loses no information about where you are.

### Staging and the stage markers

**s** stages the hunk under your cursor; **u** unstages it, without touching the
worktree. On a row that names no hunk — a file header bar, a folded
placeholder, or a sidebar file row — the same key takes the whole file instead.
Hold **Shift** and press **S**/**U** to take the whole file from anywhere
inside it.

Staging writes the index directly: the hunk's lines are spliced into the staged
blob, rather than a patch being generated and re-applied. Each key does one
thing and says so when there's nothing to do (`hunk already staged` /
`nothing staged here`, and `already staged` / `nothing staged` for the file
verbs). Staging is refused while a modified loaded buffer aliases the path, so
unsaved text can't be silently replaced by disk content. A rename's index
identity is two paths rather than a line splice, so a hunk press inside one
declines and points you at **Shift+S**; a binary file publishes no hunk rows at
all, so **s** on one is already the whole-file verb.

In the `unstaged` lens a staged hunk *vanishes* — that lens shows what is not
staged yet, so the disappearance is the confirmation. One **Tab** later, in the
`staged` lens, it's there.

The two whole-file verbs also *pivot* the lens when they succeed, so you land
where what you just did is visible: **Shift+S** in `unstaged` leaves you in
`staged`, and **Shift+U** in `staged` leaves you in `unstaged`. The hunk verbs
deliberately don't — pressing **s** down a file's hunks has to stay put — and
nothing pivots out of `all`, which is already showing both halves.

One case needs a particular lens. On a file that is both staged *and* modified
again, the hunks on screen are measured against a text the index does not hold,
so the verb that would write it declines and names the lens to use rather than
guessing which hunk you meant: **u** needs the `staged` lens, and **s** declines
only in the `staged` lens. **Shift+S** and **Shift+U** are unaffected.

Hunk rows carry no stage marker: staged-ness is a fact about a *file*, the lens
already says which hunks are left, and a per-hunk marker would be a second
answer that could disagree with both. Every file row — sidebar, header bar,
folded placeholder — carries its state from git's own XY pair:

| Marker | Colour | Means |
| --- | --- | --- |
| `●` | green (`Added`) | **staged** — the index differs from HEAD |
| `○` | yellow (`DiagnosticWarn`) | **unstaged** — the worktree differs from the index |
| `●○` | green + yellow | staged, then changed again |
| `●` | red (`DiagnosticError`) + bold, always last | **stale** — changed since you folded it |
| `● ●` | green, then red | staged *and* stale — same glyph, told apart by colour and position |

The first three markers appear on every file row; stale exists only under a
fold — a folded file's placeholder, its sidebar row, or a folded directory's
row — and clears when you unfold, because then you've seen it. Why the same
dot twice, and why bold: [the stale marker](docs/design.md#the-stale-marker).

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
      cycle_next = "<C-n>",  -- scroll to the next hunk (wraps)
      cycle_prev = "<C-p>",  -- scroll to the previous hunk (wraps)
      -- The file axis Ctrl+N/P used to walk, shipped unbound: `{}` is
      -- "disabled", so no map exists until you ask for one.
      cycle_file_next = {},  -- scroll to the next file's diff (wraps)
      cycle_file_prev = {},  -- scroll to the previous file's diff (wraps)
      refresh    = "r",      -- re-scan, splice in what changed, keep your place
      stage      = "s",      -- stage this hunk; this file on its header
      unstage    = "u",      -- unstage this hunk (never touches the worktree)
      stage_file   = "S",    -- stage this whole file, from anywhere in it
      unstage_file = "U",    -- unstage this whole file, from anywhere in it
      lens_next  = "<Tab>",  -- cycle the lens forward (all / unstaged / staged)
      lens_prev  = "<S-Tab>",-- and back
      sidebar    = "o",      -- toggle the file-tree sidebar
      close      = "q",      -- back out of a comparison, else close the canvas
      help       = "<leader>lh", -- show the keybind cheatsheet
    },
    sidebar = {
      select = { "<CR>", "za", "c", "<2-LeftMouse>" }, -- scroll here / fold a dir
      stage   = "s",         -- stage the row you're on: this hunk, or this file
      unstage = "u",         -- unstage the row you're on
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
    enabled = true,     -- treesitter syntax highlighting of hunk content
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
    -- The pinned header's breadcrumb: before the hunk (ascii `" -> "`), and
    -- inside it before the ordinal (ascii `" | "`). The surrounding spaces are
    -- part of the value — the file part of that row is a byte-for-byte mirror
    -- of the header it covers, so the separator owns every character between.
    crumb = " → ", crumb_sep = " · ",
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
| `cycle_next` / `cycle_prev` | `<C-n>` / `<C-p>` | hold **Ctrl** + **N** / **P** | Scroll to the next/previous **hunk**, wrapping — a folded file is one stop. Takes a count |
| `cycle_file_next` / `cycle_file_prev` | *(unbound)* | — | Scroll to the next/previous file's diff, wrapping. What Ctrl+N/P used to do; bind them if you want it back |
| `refresh` | `r` | **r** | Re-scan and splice in what changed, keeping your place |
| `stage` | `s` | **s** | Stage the hunk under the cursor; the whole file when on its header bar or its folded placeholder |
| `unstage` | `u` | **u** | The same, unstaging; never touches the worktree |
| `stage_file` / `unstage_file` | `S` / `U` | hold **Shift** + **s** / **u** | Stage/unstage the whole file from anywhere inside it |
| `lens_next` / `lens_prev` | `<Tab>` / `<S-Tab>` | **Tab** / hold **Shift** + **Tab** | Cycle the lens: all ⇄ unstaged ⇄ staged |
| `sidebar` | `o` | **o** | Toggle the file-tree sidebar (works even with `sidebar.enabled = false`) |
| `close` | `q` | **q** | Back out: leave a stacked comparison, else close the canvas and restore the previous buffer |
| `help` | `<leader>lh` | leader, then **l**, then **h** | Show the keybind cheatsheet |

| Sidebar | Default | How you press it | Action |
| --- | --- | --- | --- |
| `select` | `<CR>`, `za`, `c`, `<2-LeftMouse>` | **Enter**, **z** then **a**, just **c**, or **double-click** | Scroll the canvas to the file or hunk (without unfolding it), or fold the directory |
| `stage` / `unstage` | `s` / `u` | **s** / **u** | The row decides, as on the canvas: a hunk row takes that hunk, a file row the whole file. A directory row declines |
| `close` | `q` | **q** | Close the sidebar (canvas stays open) |
| `help` | `<leader>lh` | leader, then **l**, then **h** | Show the keybind cheatsheet |

| File buffer (during a jump) | Default | How you press it | Action |
| --- | --- | --- | --- |
| `back` | `<C-Space>` | hold **Ctrl** + **Space** | Return to the canvas at the same spot |

### Changed behaviour

**Ctrl+N and Ctrl+P now cycle by hunk, not by file.** They used to scroll a
file's diff at a time; they now stop at every hunk (a folded file still counting
as exactly one stop), which is the granularity the rest of the canvas already
worked at.

**s and u narrowed too.** They used to take the whole file wherever you pressed
them; they now take the hunk under the cursor, and the whole file only on a row
that names none — a file header bar, a folded placeholder, or a sidebar file
row. **Shift+S** and **Shift+U** are new keys rather than redefinitions, and
they are the whole-file verbs from anywhere.

The file-at-a-time behaviour is intact under new names — `cycle_file_next` and
`cycle_file_prev`, shipped unbound — so putting it back is one line:

```lua
require("canvasdiff").setup({
  keymaps = { canvas = {
    cycle_next = {}, cycle_prev = {},                      -- free the keys
    cycle_file_next = "<C-n>", cycle_file_prev = "<C-p>",  -- and take them
  } },
})
```

Freeing them first is worth the second line: two actions on one key is not an
error, it's whichever mapping installs last, and you don't want to depend on
that. Drop the first line and give the hunk cycle other keys if you want both.

Two things worth knowing before you rely on the defaults:

- **`q` costs macro-record on the canvas** — the usual scratch-buffer trade.
  `keymaps = { canvas = { close = "Q" } }` if you'd rather keep it. The other
  bare letters are free: the canvas is `nomodifiable`, so every editing key is
  already inert there.
- **Test Ctrl+Space in your terminal** before relying on it — it sends byte
  `0x00`, which most but not all terminals transmit:
  `:nnoremap <C-Space> <Cmd>echo "ok"<CR>`.

The reasoning behind all of this — why bare letters, why Tab, why exactly one
way back — is in [keymap philosophy](docs/design.md#keymap-philosophy).

Any function on `require("canvasdiff")` makes a global entry point the same
way the lazy-loading spec in [Installation](#installation) binds toggle,
compare and checkout — e.g. `cycle_lens(1)` for a from-anywhere lens key
(`:h canvasdiff-api` lists them all). CanvasDiff never replaces an existing
global mapping — an occupied key wins and
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
| `CanvasDiffFileBar` | derived bar elevation | the file header row and its pinned copy |
| `CanvasDiffFileHeader` | `Title` | the filename on the bar |
| `CanvasDiffHunkHeader` | `Comment` | `@@ … @@` hunk header rows |
| `CanvasDiffBinary` | `Comment` | binary-file notices |
| `CanvasDiffWinbar` / `CanvasDiffWinbarReadOnly` | `WinBar` / `Visual` | the top band / its read-only tint |
| `CanvasDiffStaged` / `CanvasDiffUnstaged` | `Added` / `DiagnosticWarn` | the stage markers |
| `CanvasDiffStale` / `CanvasDiffStaleEmphasis` | `DiagnosticError` / bold | the stale mark |
| `CanvasDiffSidebarDir` / `CanvasDiffSidebarActive` | `Directory` / `Visual` | sidebar directories / active row |
| `CanvasDiffSidebarHunk` | `Comment` | a sidebar hunk row, whole |
| `CanvasDiffHunkDel` | `CanvasDiffGhost` | a hunk label taken from a deleted line — struck, in the sidebar row *and* in the pinned header's crumb |
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
