# CanvasDiff design notes

The README says how to use CanvasDiff; this file says why it looks and behaves
the way it does. Nothing here is required reading — it exists so that every
"why is it like this?" has a written answer, and so that future changes argue
with measurements rather than with taste. Module boundaries and state
ownership live separately in [architecture.md](architecture.md).

## How diff rows are coloured

One rendering, three channels — each carrying exactly one fact:

- **Elevation says "changed".** Every added row's background — and a wholly
  deleted file's rows — is `Normal`'s background moved **4% toward the luminance
  pole** (white on a dark scheme, black on a light one). Hueless on purpose:
  colourschemes tune `DiffAdd`/`DiffDelete` for a two-pane vimdiff, where a
  whole-window wash is the point; on a canvas most of the screen *is* changed
  rows, so a hued wash would spend the strongest visual channel on the least
  interesting fact.
- **Dimming says "removed".** Ghost deletion lines — and a wholly deleted file's
  rows, the only real `-` rows left — render with `Normal`'s foreground moved
  **30% toward its background**.
- **The margin hue says which direction.** The green/red lives *only* on the
  one-cell `+`/`-` prefix and the statuscolumn bar: `DiffAdd`/`DiffDelete`'s
  **foreground**, or a fixed `#2ea043`/`#db4444` when those groups carry none
  (background-only diff groups are the common case). Never their background —
  bg-tuned colours read as mud when used as a foreground.

Every value is derived from the live colourscheme when the canvas draws, and each
factor is measured, not felt:

- **4% (the elevation)** is budgeted by what the old derived tints already spent:
  the worst probed syntax token's (`@comment` as the dim extreme,
  `Function`/`String` as bright ones) contrast loss on a tinted row was 22.8%
  under the builtin dark scheme and 14.7% under tokyonight-moon, and 0.04 is the
  largest of the 0.03–0.10 candidates whose worst loss fits both budgets (6.6%
  builtin, 12.0% moon — 0.05 already overshoots moon's by a hair). It lands about
  +9 luma from `Normal` under both schemes.
- **16% (the file bar, `CanvasDiffFileBar`)** is the smallest of the measured
  candidates whose bar clears the elevation by at least 10 luma under both
  schemes (builtin +37.1 against the field's +9.0; moon +34.8 against +8.9)
  *and* stays at least 8 luma from both `CursorLine`'s and `Visual`'s
  backgrounds, so a file boundary never reads as just another cursor line — 0.12
  lands 3.9 from builtin's `CursorLine`, 0.14 lands 4.5 from moon's `Visual`. A
  15% `Title`-fg tint on the bar was measured and rejected: builtin's `Title` is
  near-neutral, so tinting just lightens the bar into `Visual`'s band (gap 5.9),
  and under moon it collapses the stale marker's contrast on the bar from 23.3
  to 11.6.
- **30% (the ghost dim)** is the largest candidate whose dimmed foreground keeps
  at least `@comment`'s luma delta against `Normal`'s background — a deletion
  must never read dimmer than a comment. The builtin scheme is the binding one
  (`@comment` at 135.9; the ghost reads 143.1 at 0.30 but 133.1 at 0.35);
  moon's `@comment` sits at 74.1, where every candidate clears.

A transparent scheme gives `Normal` no background at all, so there is nothing to
elevate from; a fixed near-Normal pair (`#2c2c2c` dark, `#e4e4e4` light) keeps the
field visible rather than invisible.

Two more deliberate choices, both arrived at by measurement:

**The elevation stops at end-of-text.** Row backgrounds used to set `hl_eol`, which
fills the rest of the *screen line* — so a three-character edit painted colour to
the right edge of a 200-column window, and the coloured area scaled with your
window rather than with the change. It also muddied code: on a tinted row,
`@comment` sat at only 47 luminance delta against the fill where every other
syntax group had 103–153.

**Word-diff emphasises by attribute, never by a competing background.** This mark sits
*inside* the row's elevation, so a background here has to out-contrast one that already
claimed most of the range — and which wins is pure colourscheme luck. Linked to `DiffText` it
cleared an added row by just **9** luminance under tokyonight while the row itself
cleared `Normal` by 27, so the strongest signal was "this line is involved" and the
weakest was "this is the token that changed" — backwards, since the second is the only
one you can't already read off the `+`/`-`. Switching the link to `Search` fixed that
under tokyonight (+39) and *reversed it* under Neovim's builtin scheme (19, versus
`DiffText`'s 28). Bold + underline sidesteps the contest entirely: attributes compose
over whatever is underneath, identically under every colourscheme, and an underline
states the exact extent where a background only says "somewhere in here".

The `+`/`-` prefixes stay regardless — they're the only **shape**-based channel, so
they're what survives red/green colour blindness and a monochrome terminal, which
is why the margin hue rides *on* them rather than replacing them.

`CanvasDiffDel` carries *both* the elevation and the dimmed foreground because real
`-` rows exist only for a wholly deleted file — every other deletion renders as a
ghost — and those rows must read as removed content under a red margin, not as
live code.

There used to be a `highlight.diff` option choosing between three loudnesses; it
was removed with the modes themselves, and a leftover `highlight.diff = ...` in a
config now gets one diagnostic from `setup()` and is otherwise ignored — override
the groups instead.

## The file bar and the pinned header

**Each file's header row is a full-width tinted bar**, so a boundary registers in
peripheral vision instead of being one more line among diff lines. Folded files
don't get a bar — a placeholder is already a visually distinct single row
(it opens with `▸`) and has no body to close off, and barring all of them would turn a
canvas of 200 auto-collapsed files into a solid block of colour. The group is
`CanvasDiffFileBar`, and its default is derived rather than linked: `Normal`'s
background moved 16% toward the luminance pole — the same derivation as the
changed-row elevation, pushed further, so a file boundary reads *above* the field it
interrupts and never as just another cursor line (measurements above).
`CanvasDiffFileHeader` stays foreground-only so the two compose: the filename keeps
`Title`'s colour on the tinted row, and the marker colours sit over both.

**The winbar is one continuous band** across the canvas and the sidebar. The
canvas half names the comparison — `HEAD → WORKTREE` — and never varies with
scroll, so the band is something you check, not something that flickers.

Where you are is the **pinned header's** job: a one-row float directly
under the band showing the current file's own header row — the same bar tint,
counts and stage marks as the row it mirrors, kept current by the same
reconcile. It *covers* the first canvas row rather than pushing anything down,
so showing and hiding it never reflows the canvas or moves your view, and clicks
fall through to the row beneath it. It hides itself while the real header row is
at the top of the window — a copy over the original would double it — and on a
folded placeholder, whose single row already is the header.

Once the topline is *inside* a hunk the row continues into a **breadcrumb**:

```
▎ src/canvas.lua  (+12 −4) → @@ 88  render(state) · 3/5
```

Three decisions are packed into that.

The file part stays a **byte-for-byte mirror** of the header row it covers, and
the crumb is appended after it. That is why the separators are glyphs with their
spaces baked in (`crumb`, `crumb_sep`) rather than padding the drawer adds: the
stage-mark highlight spans are measured by walking in from the end of the file
part, so a single character of drift between the mirror and the original puts
the markers on the wrong bytes.

The hunk is named by **the same formatter the sidebar's tree rows use**. A hunk
that answered to two names would read as two hunks, and the whole reason the
sidebar is closable is that the canvas keeps saying everything it said.

The **ordinal** (`3/5`) is the part that could not be read off the screen. Which
file you are in is one glance at the tree; how much of it is left is not, and a
crumb that named the hunk without ranking it would be an identifier where a
progress reading was wanted. So the ordinal is what a narrow window keeps: the
label is cut to fit around it, and when even a label-less crumb would not fit,
the crumb is dropped whole rather than drawn with its right edge — the ordinal —
past the window. A crumb clipped at the ordinal is worse than no crumb, because
it silently answers the one question the row was added to answer.

## Ghost deletions: the result view

The canvas shows each file **as it will be**, not as a patch. Removed lines are drawn
as *virtual* lines above the row that replaced them, rather than as rows of their own.

The point isn't the ~13% of rows this saves. It's that **every remaining row maps 1:1
to a real file line**, which fixes a thing that was quietly wrong: `jump.enter`
resolves a target line by walking *forward* off any row that has no line number of its
own, so pressing Enter on a deleted row used to land you somewhere you hadn't pointed
at. On this repo's own changeset that was 897 of 6999 rows. Now Enter always opens the
line under your cursor, and the statuscolumn shows a real number on every row instead
of `·` for the ones that don't exist.

Two deliberate limits:

- **A wholly deleted file keeps its deletions as real rows.** A result view of a file
  with no new side is *empty*, and ghosting would turn its entire content into virtual
  text you can't yank, search, or put a cursor on — when those lines are all it has to
  show. The rule is: the result view applies when there is a result.
- **Word-diff marks only the new side.** Extmarks can't be placed inside virtual
  text, so the ghost renders whole and the `+` line carries the intra-line detail —
  the half that says what the code became.

`CanvasDiffGhost`'s default is the dimming plus a strikethrough: dimmed because
deletions read as context for the line that replaced them rather than something to
study on their own; struck because the dim floor deliberately parks ghosts at comment
brightness, which makes a deleted block and a comment block luminance twins — the
strike is what tells them apart at a glance, before you read a character, and it
survives colour blindness where the margin's red does not.

## The stale marker

A staged file's `●` and the stale `●` are **the same character**, told apart by
colour and by position (stale is always last). That's a deliberate trade to keep
the marker column one cell per fact, and it's why the red matters more than it
looks. The choice is **luminance, not hue**: under tokyonight-moon those two
resolve to `#b3f6c0` and `#c53b53` — a luminance gap of 138, so they read as a
light dot against a dark dot. Red/green colour blindness confuses hue while
leaving brightness intact, so that gap survives it; the earlier amber gave a gap
of 23, which doesn't.

**The stale marker is also bold**, and that part doesn't depend on your colourscheme at
all. It has to be: measured, `CanvasDiffStaged` against `CanvasDiffStale` is 138 luminance apart
under tokyonight but only **23** under Neovim's builtin scheme, where `DiagnosticError`
resolves to a pale salmon rather than a dark red. Two pale pastels 23 apart is not a
distinction, and this is the one place where getting it wrong means reading the wrong
fact about a file. Bold composes over whatever colour is underneath, identically
everywhere — the same reasoning as the word-diff marks.

If the two `●`s are still hard to tell apart, the most reliable fix is a different
*glyph*: `glyphs = { stale = " !" }`.

One thing the dots can't tell you: *which* kind of change. A rename and a newly added
file both render `●`, and a deletion looks like any other edit (the `+0 −N` diffstat is
the only hint). git's letters are still on the model if that turns out to matter.

## Glyphs and ambiwidth

Two things the `glyphs = "ascii"` set gets right which the defaults can't. Every
character in it is **one cell wide under both `ambiwidth` settings** — the
defaults aren't, since `● ○ ▎ −` are East Asian Ambiguous and double under
`ambiwidth=double`, changing the width of the marker column and the header
gutter. And `staged = "*"` versus `stale = " !"` differ in the **text**, so on
the ASCII set that distinction can't be lost to a colourscheme at all.

`stale` carries its own leading space — that's deliberate, since its byte length
positions its own highlight span.

## Keymap philosophy

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

**Tab and Shift+Tab are the lens axis.** One physical key for the whole "what am
I looking at" question, and a slip between the two lands on the other direction
of the same action. It costs jumplist-forward on the canvas (in a terminal
`<Tab>` and `<C-i>` are the same byte), which is a fair trade: you navigate the
canvas by file and hunk, not by jumplist.

**Ctrl+Space is the only way back** from a jump, deliberately — no second key. It
sends byte `0x00`, which most terminals do transmit. If yours doesn't, the jump loop
has no exit, so test it before relying on it:
`:nnoremap <C-Space> <Cmd>echo "ok"<CR>`. Alt+Enter is not a default because tiling
compositors commonly intercept it, and `q` is not one *here* even though it closes the
canvas — this is a real file you are editing, so macros and every other normal-mode key
have to keep working. That asymmetry is the whole reason keymaps are grouped by buffer.

Leader mappings have no terminal-encoding problem at all — they are ordinary
keypresses — which is why they suit the global entry points (`<leader>lb`,
`<leader>lc`), while the canvas keeps bare single keys for the actions you press
dozens of times in a sweep.

Don't hang lens keys off a toggle mapping (`<leader><leader>` plus
`<leader><leader>a` and friends): if both exist, Vim has to wait a full
`timeoutlen` after the toggle to see whether another key is coming, and the
toggle feels broken. A separate prefix costs nothing and avoids that entirely.

**Enter never changes a fold.** Press it on a placeholder and it opens the file as a
real buffer, leaving the fold exactly as it was — so coming back with Ctrl+Space
lands you on the placeholder again. Two verbs, no exceptions: Enter goes to a file,
`za` folds one.

## Refresh, and why there is no rebuild key

What `r` guarantees is *what stays fixed*, not "it doesn't scroll". Add three lines to
a file that sorts above where you're reading and `r` moves your row number down by
exactly three, so the **same line of text** stays under your cursor. That's the
invariant the whole plugin is built on: content changing outside the viewport never
moves what you're reading.

Its honest limit: the reconcile compares CanvasDiff's model against git, not against the
buffer. If those ever diverge — only reachable through a bug in CanvasDiff itself, since
`nomodifiable` blocks the buffer API too — refreshing can't fix it, because the
comparison keeps concluding there's nothing to do. **The recovery is to close and
reopen** (`q`, then the toggle). That rebuilds from scratch *and* restores your
folds and position from the session file.

There's deliberately no `R`-for-rebuild key. One was written for exactly this gap,
then measured against close+open on a corrupted buffer: refresh didn't repair it,
rebuild repaired it but lost your position, close+open repaired it *and* kept your
position. Strictly dominated by two keys you already press, so it was deleted.
`R` is free.

## Watching without recursive inotify

The canvas auto-refreshes on `:write`, on regaining focus, and on file changes
made outside Neovim, debounced so a burst of changes settles into a single
reconcile. Because Linux `inotify` has no recursive watch, external-change
detection watches the repo root and `.git` non-recursively plus the parent
directories of files currently shown on the canvas; a change to a file in some
other, not-yet-watched subdirectory is picked up the next time you save or
refocus Neovim (or with a manual `r`) rather than instantly. The watcher keeps
running while the canvas is merely hidden (so it's already fresh when you return
to it) and only stops when the canvas is closed with `q` or its buffer is wiped.

## Folds outlive sessions, not changes

A fold lasts as long as the changes it covers. Fold `src/` and it stays folded
across restarts, and covers files that start changing there later — but once
nothing under `src/` is changed any more (you committed it, or reverted it), the
fold is forgotten. So finishing a directory and coming back to it next week
doesn't hide your new work behind a placeholder you don't remember setting.

A fold never comes undone on its own, either. Edit a file you folded away — or
let a formatter, a `git stash`, an AI agent, or a save from another window do it
— and it stays folded; the stale `●` says so instead. It clears as soon as you
unfold, because then you have seen it. A file that appears under a directory you
had already folded counts as changed for the same reason: you have never looked
at it. This survives quitting, so a file edited while Neovim was closed is
marked when you come back.

Nothing in the session file is a raw line number: the saved position is
content-based (which line, near what text), so it still lands close to the right
spot even if the file changed since you last looked.
