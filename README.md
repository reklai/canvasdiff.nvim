# CanvasDiff

CanvasDiff proofs for your git diff — read the whole change as one continuous strip, fix it in place.

Every changed file's diff, concatenated into a single scrollable buffer. Jump into any hunk as a real, LSP-attached buffer and jump back to the exact spot. Status: pre-alpha MVP.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-name/canvasdiff.nvim", -- adjust to wherever this repo lives
  cmd = "CanvasDiff",
  opts = {}, -- optional; see Configuration below
}
```

`opts = {}` (or omitting `opts`/`config` entirely) is enough — the plugin
works with its defaults even if `setup()` is never called.

## Usage

Run `:CanvasDiff` in any window inside a git repository. It replaces the
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
- Edit the file as usual (saved or not), then press **Ctrl+Space** to jump back to
  the canvas. The diff for that file is regenerated from the file's current
  content (including unsaved edits) and the canvas view is restored to
  roughly where you left it.
- Press **q** to close the canvas. Closing is non-destructive: you land back on
  the buffer the canvas opened over, cursor and column intact. The two exits
  mean different things on purpose — `<CR>` is "I want to work on this file",
  `q` is "I'm done reading" — so a jump never changes where `q` puts you. If
  the buffer you came from was deleted meanwhile, it falls back to the file
  your review last touched, then to the alternate file, and only then to a
  blank one. `:CanvasDiff close` works from any window in the tab, not just the
  one showing the canvas.
- Press **r** to refresh: re-scan the repo and splice in whatever changed, without
  moving what you were reading. (`watch` already does this on save and focus — `r` is
  for when you want it now.)
- Press `<C-n>` / `<C-p>` to jump straight to the next/previous file's diff,
  wrapping around at either end. Focus stays in the canvas.

A file-tree sidebar opens automatically alongside the canvas (a fixed,
non-focused vsplit), listing every changed file in an indented directory
tree and tracking your scroll position with a highlighted active entry.
From the sidebar: **Enter**, **z** then **a**, **c**, or a double-click
scrolls the canvas to the file under the cursor — without unfolding it — or folds
that directory if you're on a directory row. If you're away in a file at the time, it
brings the canvas back first and then goes there. **q** closes just the sidebar
(the canvas stays open). Set `sidebar.enabled = false` to turn it off.

### Knowing where you are

The canvas is one long buffer holding every file's diff, so "which file am I in?" and
"where did that file end?" both have to stay answerable while you scroll.

**Each file's header row is a full-width tinted bar**, so a boundary registers in
peripheral vision instead of being one more line among diff lines:

```
████ src/canvas.lua  (3 hunks, +12 −4) ████████████████
  local M = {}
 -  return nil
 +  return M
████ src/sidebar.lua  (1 hunks, +2 −0) █████████████████
```

Folded files don't get one — a placeholder is already a visually distinct single row
(it opens with `▸`) and has no body to close off, and barring all of them would turn a
canvas of 200 auto-collapsed files into a solid block of colour. The group is
`CanvasDiffFileBar`, defaulting to `Folded` because that's the most visible group which
always carries a background — measured at +30 luminance against `Normal` under
tokyonight, where `CursorLine` manages +15 and `ColorColumn` is actually *darker*.
`CanvasDiffFileHeader` stays foreground-only so the two compose: the filename keeps
`Title`'s colour on the tinted row.

And once you're a screen deep and that header has scrolled off, two things say where
you are — always the same answer:

- **The winbar** names the file under the topline, next to the lens:
  `CanvasDiff: worktree vs HEAD │ src/canvas.lua`. It follows you as you scroll, so the
  answer is on the canvas itself rather than only off to the side.
- **The sidebar's highlighted row** tracks the same section — resolved from the
  topline, not the cursor, so the two can't disagree.

**Both follow you into a jump.** Open a file with **Enter** and the sidebar highlights
*that* file, because you're still somewhere in the changeset and the tree's job is to
say where. And selecting a different file in the tree while you're away brings the
canvas back and takes you there, rather than doing nothing.

A 1-column scrollbar minimap floats over the canvas's right edge, showing
file boundaries (─), add/del density per stretch of lines (│, colored), and
a highlighted thumb tracking your current viewport across the whole canvas.
Double-click a line in the canvas (`<2-LeftMouse>`) to jump into that file,
same as `<CR>`. It's purely visual and non-focusable — your mouse wheel still
works normally on the canvas window underneath it. satellite.nvim / nvim-scrollbar
still function on the canvas window, but they draw at the same right edge as
the built-in bar — disable one (`scrollbar = { enabled = false }`).

### Folding

Two places fold, and they fold different things — deliberately:

- **the sidebar folds directories** — **z** then **a**, or just **c**, on a
  directory row
- **the canvas folds files** — **z** then **a**, or just **c**, anywhere in a
  file's diff

(**Tab** and **Shift+Tab** are the lens axis on the canvas, not folding.)

They are not separate states. A directory folded in the tree is folded on the
canvas: every file under it renders as its one-row placeholder,
`▸ path  (N hunks, +adds −dels)`. Folding is never a hidden filter — you always
see what you put away.

Folding is for the canvas that keeps growing. Either you are done with a file, or
you are not looking at it right now; either way you want the room back.

**Folded files are still there to navigate to.** `]f`, `[f`, `Ctrl+N` and `Ctrl+P`
land on a folded file's placeholder like any other section, and `]h` / `[h` treat a
folded file as exactly one stop. You arrive on the placeholder, press **z** then **a** to
unfold, and carry on — which is what a closed fold means in Vim too: one line that
motions land on. Counts count folded files (`3]f` is three sections forward,
whatever state they are in).

**Enter never changes a fold.** Press it on a placeholder and it opens the file as a
real buffer, leaving the fold exactly as it was — so coming back with **Ctrl+Space**
lands you on the placeholder again. Two verbs, no exceptions: Enter goes to a file,
`za` folds one.

**z** then **a** (or **c**) on a placeholder that a *folded directory* is hiding unfolds that
directory instead — including a whole chain of nested folds — and says so, leaving
the cursor on the file you pressed. That is also the only way back out when
`sidebar.enabled = false`.

A fold lasts as long as the changes it covers. Fold `src/` and it stays folded
across restarts, and covers files that start changing there later — but once
nothing under `src/` is changed any more (you committed it, or reverted it), the
fold is forgotten. So finishing a directory and coming back to it next week
doesn't hide your new work behind a placeholder you don't remember setting.

### When something changes behind a fold

A fold never comes undone on its own. Edit a file you folded away — or let a
formatter, a `git stash`, an AI agent, or a save from another window do it — and it
stays folded. What it does instead is say so:

```
▸ src/a.txt  (3 hunks, +12 −4) ●
```

The `●` means *this changed since you folded it*, so what you decided about it may
no longer hold. It shows on the file's sidebar row too, and on a folded directory's
row when anything underneath it moved — a folded directory shows no rows for its
children, so that is the only place the signal can reach you. It clears as soon as
you unfold, because then you have seen it. A file that appears under a directory you
had already folded counts as changed for the same reason: you have never looked at
it.

This survives quitting, so a file edited while Neovim was closed is marked when you
come back. Each sidebar row also shows its stage state, straight from git's own XY
pair:

| Marker | Colour | Means |
| --- | --- | --- |
| `●` | **green** (`Added`) | **staged** — the index differs from HEAD |
| `○` | **yellow** (`DiagnosticWarn`) | **unstaged** — the worktree differs from the index |
| `●○` | green + yellow | staged, then changed again |
| `●` | **red** (`DiagnosticError`) + **bold** | **stale** — changed since you folded it |

Green, yellow, red, in that order: staged is done, unstaged is pending, stale wants
your attention.

Note the first and last are **the same character**, told apart by colour and by
position (stale is always last). A staged file that has since changed reads `● ●`:

```
▸ folded.txt  +3 −3 ● ●
                    │ └ stale, red
                    └── staged, green
```

That's a deliberate trade to keep the marker column one cell per fact, and it's why
the red matters more than it looks. The choice is **luminance, not hue**: under
tokyonight-moon those two resolve to `#b3f6c0` and `#c53b53` — a luminance gap of 138,
so they read as a light dot against a dark dot. Red/green colour blindness confuses
hue while leaving brightness intact, so that gap survives it; the earlier amber gave a
gap of 23, which doesn't.

**The stale marker is also bold**, and that part doesn't depend on your colourscheme at
all. It has to be: measured, `CanvasDiffStaged` against `CanvasDiffStale` is 138 luminance apart
under tokyonight but only **23** under Neovim's builtin scheme, where `DiagnosticError`
resolves to a pale salmon rather than a dark red. Two pale pastels 23 apart is not a
distinction, and this is the one place where getting it wrong means reading the wrong
fact about a file. Bold composes over whatever colour is underneath, identically
everywhere — the same reasoning as the word-diff marks below.

The groups are `CanvasDiffStaged`, `CanvasDiffUnstaged`, `CanvasDiffStale` and
`CanvasDiffStaleEmphasis`, all `default = true`, so your colourscheme wins if it defines
them. If the two `●`s are still hard to tell apart, the most reliable fix is a different
*glyph*: `glyphs = { stale = " !" }`.

### Glyphs

Every glyph CanvasDiff draws is configurable through one table:

```lua
require("canvasdiff").setup({
  glyphs = {
    ctx = " ", del = "-", add = "+",   -- diff row prefixes
    file = "▎", folded = "▸", open = "▾", minus = "−",
    staged = "●", unstaged = "○", stale = " ●",
    scroll_file = "‒", scroll_bar = "❘",
  },
})
```

Override any subset; unnamed slots keep their defaults, and a misspelled name is
reported rather than silently ignored. `stale` carries its own leading space — that's
deliberate, since its byte length positions its own highlight span.

**`glyphs = "ascii"`** switches the lot to a set that needs no font beyond ASCII, for a
restricted font or a Linux framebuffer console:

```
| src/a.txt  (+2 -2)        v src/            minimap: - |
> src/b.txt  (+2 -2)          > a.txt  +2 -2 *
                                b.txt  +2 -2 o
```

Two things that set gets right which the defaults can't. Every character in it is **one
cell wide under both `ambiwidth` settings** — the defaults aren't, since `● ○ ▎ −` are
East Asian Ambiguous and double under `ambiwidth=double`, changing the width of the
marker column and the header gutter. And `staged = "*"` versus `stale = " !"` differ in
the **text**, so on the ASCII set that distinction can't be lost to a colourscheme at
all.

One thing the dots can't tell you: *which* kind of change. A rename and a newly added
file both render `●`, and a deletion looks like any other edit (the `+0 −N` diffstat is
the only hint). git's letters are still on the model if that turns out to matter.

For very large changesets (past `virt.max_files` files or `virt.max_lines`
fully-expanded canvas lines), the same collapse mechanism kicks in
automatically: sections far from your current viewport auto-collapse and
ones you scroll near auto-expand, keeping at most `virt.max_expanded`
sections rendered in full at once. Both thresholds describe the changeset
itself, so what is collapsed right now never changes whether virtualization
is on. Those are the plugin's own bookkeeping rather than folds you made, so they
are never persisted and never marked — you should not have to think about them.

A statuscolumn shows each visible line's number in the file it belongs to
(not the canvas buffer's own line number) — blank for headers and
placeholders, `·` for pure deletions.

## Commands

`:CanvasDiff` with no argument toggles the canvas — that's the one you'll use.
The rest exist so you can drive it from your own mappings and scripts:

```vim
:CanvasDiff             " toggle the canvas
:CanvasDiff open        " open it
:CanvasDiff close       " close it
:CanvasDiff refresh     " re-scan and splice in what changed, keeping your place
:CanvasDiff all         " everything: worktree vs HEAD   (the default)
:CanvasDiff unstaged    " what you haven't staged: worktree vs index
:CanvasDiff staged      " what you have staged: index vs HEAD
```

All of them complete with `<Tab>`.

### The lens

The canvas always compares two sides, and the **lens** is which pair:

| lens | old side | new side | equivalent to |
| --- | --- | --- | --- |
| `all` | `HEAD` | your worktree | `git diff HEAD` |
| `unstaged` | the index | your worktree | plain `git diff` |
| `staged` | `HEAD` | the index | `git diff --staged` |

`B` cycles through the three; the commands **set** one, so they're safe in a
mapping — `:CanvasDiff unstaged` always lands unstaged, which a toggle can't
promise. Any of them will open the canvas if it isn't showing, and the current
lens is always named in the canvas's winbar.

Pivoting is non-destructive: a file that looks identical through two lenses
isn't re-rendered at all, so your scroll position and cursor stay exactly where
they were. Only the files that genuinely differ get re-spliced.

Two things follow from the sides. In the `staged` lens the new side is the
index, which isn't a file — so `<CR>` declines rather than dropping you into a
buffer whose content isn't what you're looking at; unstage it to edit it. And a
file that is staged *and* then modified again appears in both the `staged` and
`unstaged` lenses, which is git's own way of saying "you said you were done
with this, then changed it".

> `--staged` as a *flag* is still not accepted, because `:CanvasDiff staged` is the
> spelling, and `--cached` means the same thing in git. The flag form reported
> an error before `staged` existed; it now points at the word.

A bare revision such as `:CanvasDiff main` is a supported branch lens: it
shows the editable worktree against that ref. A commit range such as
`:CanvasDiff main...HEAD` would put commits on both sides and make the canvas
read-only, so ranges are rejected with a message that points back to the
supported bare-ref form.

If the current directory isn't inside a git repository, `:CanvasDiff open`
notifies you and does nothing further (it never errors).

The canvas remembers, per repository, which files you folded, which
directories you folded, and roughly where you were scrolled/where
your cursor was — restored the next time you open the canvas there, even
across a Neovim restart. It's saved when you close the canvas and again on
Neovim exit, to a small JSON file under `stdpath("state") ..
"/canvasdiff/"`, keyed by the repo root. Nothing here is a raw line
number: the saved position is content-based (which line, near what text), so
it still lands close to the right spot even if the file changed since you
last looked. Set `session.enabled = false` to turn this off entirely.

## Configuration

```lua
require("canvasdiff").setup({
  -- Grouped by the buffer each key lives on, because the same key means
  -- different things in different places (`q` closes the canvas, but only the
  -- sidebar when pressed there). Every value takes one key or a list of them.
  keymaps = {
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
      lens_next  = "<Tab>",  -- cycle the lens forward (all / unstaged / staged)
      lens_prev  = "<S-Tab>",-- and back
      close      = "q",      -- close the canvas
      help       = "<leader>lh", -- show the keybind cheatsheet
    },
    sidebar = {
      select = { "<CR>", "za", "c", "<2-LeftMouse>" }, -- scroll here / fold a dir
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
})
```

Any subset of these can be overridden; unspecified keys keep their default.

### Keymaps

**Every** binding the plugin installs is listed above and can be changed — there
are no hidden ones. Each value takes a single key or a list of keys:

```lua
keymaps = { canvas  = { collapse = "za" } }            -- one key: drops `c`
keymaps = { canvas  = { jump = { "<CR>", "o" } } }    -- a different pair
keymaps = { canvas  = { close = false } }             -- disable it
keymaps = { sidebar = { close = {} } }                -- also disables
```

An override **replaces** the list rather than merging into it, so
`collapse = "za"` really does remove `c`.

Notation is Vim's, so here is what each one means physically. **Chords** are held
together; **sequences** are tapped one after the other, like typing two letters (you
have about a second between taps).

| Canvas | Default | How you press it | Action |
| --- | --- | --- | --- |
| `jump` | `<CR>`, `<2-LeftMouse>` | **Enter**, or **double-click** | Open the file under the cursor as a real buffer. Never changes its fold |
| `collapse` | `za`, `c` | tap **z** then **a**, or just **c** | Fold or unfold this file — unfolds the directory when that is what's hiding it |
| `next_file` / `prev_file` | `]f` / `[f` | tap **]** then **f** / **[** then **f** | Cursor to the next/previous file's diff start, clamping. Lands on folded files too; takes a count |
| `next_hunk` / `prev_hunk` | `]h` / `[h` | tap **]** then **h** / **[** then **h** | Cursor to the next/previous hunk header, clamping. A folded file counts as one stop; takes a count |
| `cycle_next` / `cycle_prev` | `<C-n>` / `<C-p>` | hold **Ctrl** + **N** / **P** | Scroll to the next/previous file's diff, wrapping. Lands on folded files too; takes a count |
| `refresh` | `r` | **r** | Re-scan the repo and splice in what changed — **keeps the same text under your cursor** |
| `lens_next` / `lens_prev` | `<Tab>` / `<S-Tab>` | **Tab** / hold **Shift** + **Tab** | Cycle the lens forward / back: all ⇄ unstaged ⇄ staged |
| `close` | `q` | **q** | Close the canvas, restore the previous buffer |

| Sidebar | Default | How you press it | Action |
| --- | --- | --- | --- |
| `select` | `<CR>`, `za`, `c`, `<2-LeftMouse>` | **Enter**, **z** then **a**, just **c**, or **double-click** | Scroll the canvas to the file (without unfolding it), or fold the directory — which folds its files on the canvas too |
| `close` | `q` | **q** | Close the sidebar (canvas stays open) |

| File buffer (during a jump) | Default | How you press it | Action |
| --- | --- | --- | --- |
| `back` | `<C-Space>` | hold **Ctrl** + **Space** | Return to the canvas at the same spot |

**Tab and Shift+Tab are the lens axis** — forward and back through all / unstaged /
staged. One physical key for the whole "what am I looking at" question, and a slip
between the two lands on the other direction of the same action. It costs
jumplist-forward on the canvas (in a terminal `<Tab>` and `<C-i>` are the same byte),
which is a fair trade: you navigate the canvas by file and hunk, not by jumplist.

**Folding is `za` and `c`**, in both windows. `za` is Vim's own fold key; `c` is the
one-key version, because folding is what you press most in a sweep.

Single bare letters look reckless until you notice the canvas and the sidebar are
`nofile`, `nomodifiable`, `undolevels=-1` buffers. **Every editing key is already
inert there** — `c`, `d`, `s`, `x`, `p`, `i`, `a`, `o`, `r`, `~`, `J` and their
capitals all fail with `E21: Cannot make changes`. Mapping one costs you nothing,
which is why `c` and `q` are safe while `f`, `w`, `y`, `v`, `/` and `n` are not:
those still work on read-only text, and the plugin leaves them alone.

The one real cost is **`q`, which is also macro-record**. You give that up on the
canvas. Every plugin that closes a scratch buffer with `q` makes the same trade, and
macros are an editing tool in a buffer that cannot be edited — but it is a cost, not
a freebie. `keymaps = { canvas = { close = "Q" } }` if you'd rather keep it.

**`r` refreshes** — re-scans the repo and splices in only what changed. It's the
manual version of the pass `watch` already runs on save and focus, for when you don't
trust what's on screen.

What it guarantees is *what stays fixed*, not "it doesn't scroll". Add three lines to
a file that sorts above where you're reading and `r` moves your row number down by
exactly three, so the **same line of text** stays under your cursor. That's the
invariant the whole plugin is built on: content changing outside the viewport never
moves what you're reading.

Its honest limit: the reconcile compares CanvasDiff's model against git, not against the
buffer. If those ever diverge — only reachable through a bug in CanvasDiff itself, since
`nomodifiable` blocks the buffer API too — refreshing can't fix it, because the
comparison keeps concluding there's nothing to do. **The recovery is to close and
reopen** (`q`, then whatever you bound the toggle to). That rebuilds from scratch
*and* restores your folds and position from the session file.

> There's deliberately no `R`-for-rebuild key. One was written for exactly this gap,
> then measured against close+open on a corrupted buffer: refresh didn't repair it,
> rebuild repaired it but lost your position, close+open repaired it *and* kept your
> position. Strictly dominated by two keys you already press, so it was deleted.
> `R` is free.

**Ctrl+Space is the only way back** from a jump, deliberately — no second key. It
sends byte `0x00`, which most terminals do transmit. If yours doesn't, the jump loop
has no exit, so test it before relying on it:
`:nnoremap <C-Space> <Cmd>echo "ok"<CR>`. Alt+Enter is not a default because tiling
compositors commonly intercept it, and `q` is not one *here* even though it closes the
canvas — this is a real file you are editing, so macros and every other normal-mode key
have to keep working. That asymmetry is the whole reason keymaps are grouped by buffer.

### Suggested global mappings

The plugin installs **nothing** outside its own buffers — your leader namespace is
yours. If you want the canvas and its lenses reachable from anywhere, this is the
block to copy (lazy.nvim; adjust the prefixes to taste). With which-key installed,
**Space l** becomes a self-documenting menu.

```lua
keys = {
  { "<leader><leader>", function() require("canvasdiff").toggle() end,
    desc = "CanvasDiff: toggle canvas" },
  { "<leader>ll", function() require("canvasdiff").cycle_lens(1) end,
    desc = "CanvasDiff: cycle the lens" },
},
```

Assuming leader is **Space**: **Space Space** toggles the canvas, **Space l l**
cycles the lens — the same thing Shift+Tab does on the canvas, reachable from
anywhere. (`:CanvasDiff all` / `unstaged` / `staged` still set a lens directly, and each
opens the canvas if it isn't showing.)

Leader mappings have no terminal-encoding problem at all — they are ordinary
keypresses — which is why they suit the global entry points, while the canvas keeps
bare single keys for the actions you press dozens of times in a sweep.

> Don't hang the lens keys off the toggle (`<leader><leader>a` and friends). If both
> `<leader><leader>` and `<leader><leader>a` exist, Vim has to wait a full
> `timeoutlen` after the second Space to see whether another key is coming, and the
> toggle feels broken. A separate prefix costs nothing and avoids that entirely.

Every mapping is registered with a `desc`, so they show up in `:map`,
which-key.nvim and telescope keymaps without extra configuration.

Diff content is highlighted lazily: only sections within `margin` rows of
the current viewport get real treesitter syntax highlighting (using
whatever parser/highlight query you already have for that filetype) plus
word-level diff emphasis, applied/evicted as you scroll (debounced by
`debounce_ms`).

### The result view: deletions are ghosts

The canvas shows each file **as it will be**, not as a patch. Removed lines are drawn
as *virtual* lines above the row that replaced them, rather than as rows of their own:

```
▎ a.lua  (+1 −1)
@@ -1,6 +1,6 @@
 one
 two
      -three          ← virtual, CanvasDiffGhost
+THREE                ← a real row, and really line 3 of a.lua
 four
```

The point isn't the ~13% of rows this saves. It's that **every remaining row maps 1:1
to a real file line**, which fixes a thing that was quietly wrong: `jump.enter`
resolves a target line by walking *forward* off any row that has no line number of its
own, so pressing `<CR>` on a deleted row used to land you somewhere you hadn't pointed
at. On this repo's own changeset that was 897 of 6999 rows. Now `<CR>` always opens the
line under your cursor, and the statuscolumn shows a real number on every row instead
of `·` for the ones that don't exist.

Two deliberate limits:

- **A wholly deleted file keeps its deletions as real rows.** A result view of a file
  with no new side is *empty*, and ghosting would turn its entire content into virtual
  text you can't yank, search, or put a cursor on — when those lines are all it has to
  show. The rule is: the result view applies when there is a result.
- **Word-diff marks only the new side now.** Extmarks can't be placed inside virtual
  text, so the ghost renders whole and the `+` line carries the intra-line detail —
  the half that says what the code became.

`CanvasDiffGhost` is its own group (defaulting to `CanvasDiffDel`) so you can dim the ghosts
without touching anything else, which is usually what you want once deletions read as
context for the line that replaced them rather than something to study on their own.

### How diff rows are coloured

Four overridable groups, all `default = true` so your colourscheme wins:

| Group | Default | Marks |
| --- | --- | --- |
| `CanvasDiffAdd` | `DiffAdd` | an added row's background |
| `CanvasDiffDel` | `DiffDelete` | a removed row's background |
| `CanvasDiffWordAdd` | **bold + underline** | the changed span within an added line |
| `CanvasDiffWordDel` | **bold + underline** | the changed span within a removed line |

Two deliberate choices behind that, both arrived at by measurement:

**Row tints stop at end-of-text.** They used to set `hl_eol`, which fills the rest of
the *screen line* — so a three-character edit painted colour to the right edge of a
200-column window, and the coloured area scaled with your window rather than with the
change. It also muddied code: on a tinted row, `@comment` sat at only 47 luminance
delta against the fill where every other syntax group had 103–153.

**Word-diff emphasises by attribute, never by a competing background.** This mark sits
*inside* a row tint, so a background here has to out-contrast one that already claimed
most of the range — and which wins is pure colourscheme luck. Linked to `DiffText` it
cleared an added row by just **9** luminance under tokyonight while the row itself
cleared `Normal` by 27, so the strongest signal was "this line is involved" and the
weakest was "this is the token that changed" — backwards, since the second is the only
one you can't already read off the `+`/`-`. Switching the link to `Search` fixed that
under tokyonight (+39) and *reversed it* under Neovim's builtin scheme (19, versus
`DiffText`'s 28). Bold + underline sidesteps the contest entirely: attributes compose
over whatever is underneath, identically under every colourscheme, and an underline
states the exact extent where a background only says "somewhere in here".

The `+`/`-` prefixes stay regardless — they're the only **shape**-based channel, so
they're what survives red/green colour blindness and a monochrome terminal.

To quieten the row tints, which is the usual want once you notice how much screen they
cover:

```lua
vim.api.nvim_set_hl(0, "CanvasDiffAdd", { link = "CursorLine" })
vim.api.nvim_set_hl(0, "CanvasDiffDel", { link = "CursorLine" })
```

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
  Configuration above), plus manual refresh (`R` / `:CanvasDiff
  refresh`) for a full re-scan on demand.
- Jump/back round-trip preserves your semantic position (same hunk/line)
  across edits, not just a raw line number.
- A persistent file-tree sidebar (directory folding, scroll-synced active
  entry, `<CR>`-to-scroll) plus `<C-n>`/`<C-p>` section cycling, both live
  updated as the canvas reconciles.
- A scrollbar minimap (file boundaries, add/del density, viewport thumb)
  overlaid on the canvas, plus double-click-to-jump.
- Folding at two scopes: **z** then **a** (or just **c**) folds a file on the canvas,
  folding a directory puts everything under it away, and both look the same
  in the canvas, the tree, and every file motion.
- Tier-1 auto-virtualization that collapses far-from-viewport sections once a
  changeset crosses configurable file/line thresholds, so huge diffs stay
  responsive — kept distinct from the folds you made yourself.
- `]f [f ]h [h` file/hunk motions and a statuscolumn showing each line's
  number in the file it belongs to.
- A **lens** you pivot with one key — all changes, only what you haven't
  staged, or only what you have — where pivoting preserves your place because
  files identical across two lenses are never re-rendered. Each file's row says
  which kind of change it is, so "staged, then changed again" is visible.
- Session persistence: which files and directories you folded, and
  semantic scroll/cursor position are remembered per repo across restarts.

## Contributing

[`docs/architecture.md`](docs/architecture.md) is the map: which module may
call which, who owns live state, and which gate refuses a change that breaks
either rule. Tests are grouped by intent, and every boundary rule has an
executable counterpart:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff.log make test   # everything
make unit                                     # one intent group
make architecture                             # the boundary rules alone
```
