# Hunk staging + two-level sidebar — design

Date: 2026-08-02. Status: approved scope, pre-plan.

## Goal

Give the canvas its missing review verb — staging a single hunk — and make the
sidebar answer "where am I?" at hunk depth. No mode, no hidden state: the
cursor decides granularity, capitals override to file scope.

## Decisions (from the brainstorm, in order)

1. **No mode toggle.** The "file mode vs hunk mode" concept was examined and
   rejected: a mode is invisible state whose failure direction is
   over-staging. The cursor is the mode — it is visible, persisted, and
   already what Enter and the sidebar select key off.
2. **Sidebar is a two-level tree** — directories → files → hunk rows — not a
   wholesale swap and not a current-file-only zoom of the whole panel.
   Hunk-row visibility mirrors the canvas fold state (spec-review decision,
   replacing an earlier active-file-only expansion rule): unfolded files
   show their hunks, folded files are one row, user folds only.
3. **Hunk folding is parked**, not designed-in. It carried the majority of the
   original cost (content-fingerprint identity, a fold-matching ladder,
   session schema v3, per-hunk stale marks, placeholder row math) for the
   weakest need: hunks are read linearly, so scroll position already is
   intra-file progress, and the two-level sidebar lets you jump past read
   hunks without hiding them. **Revisit if** big-file reviews prove painful in
   practice; the cheaper design at that point is likely a per-hunk "read"
   mark (validated by the hunk TUI's reviewed-hunk tracking), not folds.
   Cutting it also deletes the one breaking change the full design had
   (`za` inside a hunk would have folded the hunk).
4. **No per-hunk stage markers.** The lens is the existing answer to "what is
   staged?": sweep in the unstaged lens and a staged hunk vanishes from view,
   which is better feedback than a dot. File-level markers are unchanged and
   keep their job. If living with this proves wrong, per-hunk markers are
   purely additive later.
5. **Stage targets the index→worktree pair; unstage the HEAD→index pair** —
   whatever lens is showing (see Mechanics).
6. **Ctrl+N/P re-aim at hunks** (spec-review decision): with the sidebar
   showing the review at hunk depth, the cycle keys walk that itinerary —
   stops are hunks only, a folded file is one stop. This deliberately
   retires file-level cycling from the defaults; `]f`/`[f` and the sidebar
   remain the file axis, and the file-cycle actions stay bindable.
7. **The read-only band tint unifies** (spec-review decision): a range lens
   currently tints only the canvas half of the winbar
   (`CanvasDiffWinbarReadOnly`); the sidebar half now takes the same group
   under the same condition, so the band is one visual state edge to edge.
   Cosmetic-only; the groups and their defaults are unchanged. The README's
   "tints the canvas half" sentence updates with it.
8. **The pinned header becomes a breadcrumb** (spec-review decision):
   `file header → current hunk · n/total`. Rationale: "closing the sidebar
   loses nothing" is existing doctrine, and with the sidebar closed nothing
   on the canvas answers "which hunk am I on" once its `@@` row scrolls off
   — nor "how far through this file am I", which hunk-level cycling makes
   routine. The crumb restores both; the file part stays a verbatim mirror.

## UX

### Verbs

| Key | How you press it | Standing in a hunk | On a file header, folded placeholder, or sidebar file row |
| --- | --- | --- | --- |
| `s` / `u` | **s** / **u** | stage / unstage **this hunk** | stage / unstage **the file** (today's behavior, unchanged) |
| `S` / `U` | hold **Shift** + **s** / **u** | stage / unstage **the whole file**, from anywhere | same |

- Every verb keeps one meaning: act on what you're on. No existing binding
  changes meaning; `za`/`c` are untouched.
- A verb with nothing to do notifies and changes nothing: `hunk already
  staged`, `nothing staged here` — same discipline as file staging.
- Declines, each with a message: read-only ranges; binary files and renames
  (file-level staging still works — the message names **Shift+S**); a modified
  loaded buffer aliasing the path (unsaved text must never be silently
  replaced by disk content); the `staged` lens's new side is the index, so
  jump-related rules are unchanged.
- Git XY state is rechecked at press time, never trusted from the screen.

### Sidebar

- Tree levels: directories → files → hunk rows. File and directory rows keep
  today's markers.
- **Counts summarize what you can't see** (the canvas's own rule — hunk
  counts appear on its folded placeholders only): an unfolded file row stays
  `name  +N −N`; a folded file row becomes `▸ name  (x hunks, +N −N)` — the
  canvas placeholder's format verbatim, so a folded file is the same row in
  both views; an unfolded directory stays name-only; a folded directory
  gains `(x files, +N −N)`, aggregating what it hides — the row that already
  carries the stale signal for its subtree.
- A hunk row renders `@@ <new-side line>  <first changed line's text>  +a −d`,
  truncated to the sidebar width; a pure-deletion hunk shows its first
  removed (old-side) line, since it has no new-side text. No stage/stale
  markers on hunk rows (decision 4).
- **Hunk-row styling reuses the existing channels, no new hues.** Tree
  hierarchy is indentation plus emphasis: hunk rows render one step dimmer
  than file rows (`CanvasDiffSidebarHunk`, link `Comment` — the same
  de-emphasis the canvas's `@@` rows carry), counts render as they do on
  file rows. **A pure-deletion hunk's label is struck + dimmed**
  (`CanvasDiffSidebarHunkDel`, link `CanvasDiffGhost`): the label shows text
  that won't exist in the result, which is exactly the fact ghost styling
  already encodes on the canvas. Changed/addition hunks show new-side text
  and render unstruck. The rule: strikethrough iff the label text is
  old-side. The breadcrumb's crumb follows the same rule. Both groups
  `default = true`. Binary files contribute no hunk rows.
- **The tree mirrors the canvas: every unfolded file shows its hunk rows;
  a folded file is one row in both places.** This extends the existing
  doctrine — one fold state, two views — down a level, and it means the tree
  never reflows on its own: it changes only when you fold or unfold
  something. The fold-as-you-finish workflow is what keeps the tree short on
  big changesets, and tracking keeps the highlighted row in view meanwhile.
  Auto-virtualized (far-from-viewport) sections do NOT hide their hunk rows
  — that collapse is the plugin's bookkeeping, never marked, and the tree
  rippling with scroll would violate exactly that.
- Tracking: the highlighted row is the **hunk** under the canvas viewport
  (falling back to the file row on file headers and on folded files, whose
  file row is their only row). During a jump excursion the
  sidebar keeps today's behavior — the jumped file's row is highlighted; hunk
  tracking is canvas-scoped.
- From the sidebar, on a hunk row: **Enter** or **double-click** scrolls the
  canvas to that hunk (no unfolding, same contract as file select); **s** /
  **u** stage/unstage that hunk, identical semantics to the canvas verb.
  Directory and file rows behave exactly as today.

### Traversal

- **Ctrl+N / Ctrl+P cycle the review hunk by hunk** (hold **Ctrl** +
  **N** / **P**): each press scrolls the canvas to the next/previous hunk,
  crossing file boundaries, wrapping at either end, taking a count. The
  stops are **hunks only** — a file header is where hunks live, not a
  destination — and a **folded file is exactly one stop** (its placeholder),
  the same doctrine `]h` already follows. The sidebar walks in lockstep —
  the tree structure itself never changes with the cycle (it mirrors fold
  state alone), and the
  highlight is the hunk you landed on.
- `]h` / `[h` (tap **]** then **h** / **[** then **h**) remain the
  cursor-motion form: same stops, but the cursor moves and the ends clamp —
  clamping is what makes "I've seen every hunk" detectable, so the sweep
  (`]h`, read, `s`, repeat) keeps its finish line while Ctrl+N/P is the
  free-scrolling walk.
- Files remain reachable as their own axis by cursor motion — `]f` / `[f` —
  and through the sidebar (select a file row). File-level *cycling* is
  retired from the defaults but stays available: see the keymap spec below.

### The pinned header: a breadcrumb

- The pinned row becomes `<file header> → @@ <line>  <first changed line's
  text> · <n>/<total>` — the file part identical to today (bar tint, path,
  counts, markers), the crumb using the **same hunk label format as the
  sidebar rows**: one identity format for hunks everywhere.
- **The trailing ordinal (`· 3/5`) is the within-file progress answer** for
  a reader with the sidebar closed — the question Ctrl+N's hunk stops make
  routine. It lives in the crumb (which tracks scroll by design) and never
  in the file part (which must stay a verbatim mirror — the alternatives
  were surveyed and die on the band's never-varies contract, the mirror
  contract, or the statuscolumn's per-line scope). `n` is the current
  hunk's ordinal within the section, `total` the section's hunk count.
- **Current hunk** = the hunk whose header lies at or above the topline
  within the section the float covers. In a file's lead-in (no hunk header
  at/above the topline yet) the row is file-only.
- The crumb's label text is the elastic part: it truncates to fit the
  window; the file identity and the ordinal never do.
- Hide rules unchanged: the float still hides when the real header row is at
  the top of the window (the first `@@` is on screen then) and on folded
  placeholders. Geometry and click-through unchanged.
- The crumb renders in `CanvasDiffHunkHeader` over the bar tint — it reads
  as what it is. The separator is a new glyph `crumb = " → "`, `" -> "` in
  the ASCII set, configurable like every other glyph.
- Updates ride the existing topline-driven sticky-content path; headless
  tests drive the hook directly, as the sticky tests already do.

## Mechanics

### Staging writes the index by line splice, not by patch

The model already holds both sides' content, so no patch construction and no
`git apply` context fragility:

1. Resolve the target hunk on the **index→worktree pair**. In the `all` lens
   the on-screen hunk is HEAD→worktree, so the cursor's file line is mapped
   onto the unstaged pair and the overlapping unstaged hunk is the target; no
   overlap means `hunk already staged`.
2. Read the file's index content, splice the target hunk's worktree lines
   over its index-side range, `git hash-object -w` the result,
   `git update-index --cacheinfo` to point the index at it.
3. Unstage is the reverse splice on the HEAD→index pair.

EOL and encoding pass through untouched because the splice is byte-level on
lines the model already carries.

### The cursor-context resolver

One shared function — given a buffer and row: `{ scope = "hunk"|"file",
section, hunk }` — feeds `s`/`u` on the canvas and the sidebar. File headers,
folded placeholders, and sidebar file/directory rows resolve to file scope;
hunk headers and hunk body rows resolve to hunk scope. One home for the
decision, like `motions.step` is for stepping arithmetic.

### Keymap spec

- Two new actions in `input/keys.lua` `K.specs` — `stage_file` (**Shift+S**),
  `unstage_file` (**Shift+U**) — so the cheatsheet, helpfile section, and
  `desc`s pick them up automatically. Configurable and disableable like every
  other action; existing `stage`/`unstage` keep their keys and gain the
  context-sensitive resolution.
- `cycle_next` / `cycle_prev` keep their keys (**Ctrl+N** / **Ctrl+P**) and
  their mechanics (scroll, wrap, count) but their stops become hunks
  (decision 6). Their `desc`s change accordingly.
- Two new actions `cycle_file_next` / `cycle_file_prev` carry the old
  file-level cycling, **unbound by default** — one config line brings the
  previous behavior back on any key. The implementation is the existing
  section-cycle code; only the spec entries are new.

### Sidebar model

The tree model gains hunk children for the active file, keyed by section
index + hunk ordinal (display identity only — nothing is persisted about
hunks). Tracking and select resolve through the same context resolver. Two
new highlight groups, both `default = true` and documented in the README
groups table: `CanvasDiffSidebarHunk` (link `Comment`) and
`CanvasDiffSidebarHunkDel` (link `CanvasDiffGhost`, for pure-deletion hunk
labels — sidebar and crumb alike).

## Compatibility

- **No session schema change.** Nothing about hunks is persisted.
- **One deliberate behavior change:** Ctrl+N/Ctrl+P keep their keys but
  their stops change from files to hunks (decision 6). Everything else
  keeps its meaning; capitals are additions. The old behavior is one config
  line away (`cycle_file_next`/`cycle_file_prev`), and the change is called
  out in the README and helpfile, not slipped in.
- Read-only ranges, watch/refresh reconcile, virtualization, statuscolumn,
  scrollbar: untouched.
- **The pinned (sticky) header changes additively** — it gains the hunk
  crumb (decision 8) but keeps its geometry, hide rules, click-through, and
  file identity untouched; a config that never scrolls past a hunk header
  sees today's row exactly.

## Testing

- **Unit:** the sidebar winbar half under a range lens renders
  `CanvasDiffWinbarReadOnly` (decision 7), the working-lens case unchanged;
  context resolver over every row kind; index-splice construction
  asserted byte-exact against hand-written expected blobs (multi-hunk files,
  EOL edge, adjacent hunks); all-lens → unstaged-pair hunk mapping including
  the no-overlap (`already staged`) case; sidebar model with hunk children
  (fold-mirror visibility, truncation, the strikethrough-iff-old-side label
  rule); sticky content crumb — mid-hunk, exactly on a hunk header, the
  file lead-in (file-only row), a pure-deletion current hunk (struck
  crumb), the ordinal (`3/5` mid-file, `1/1` single-hunk, absent in the
  lead-in, surviving label truncation), and the unchanged hide rules.
- **Integration:** real-repo stage/unstage round-trips asserting git's XY
  *and* the index blob content (`git show :path`); staging from the sidebar
  hunk row; the aliasing-buffer refusal; binary/rename/range declines;
  sidebar tracking following `]h` across a file boundary; hunk cycling —
  wrap at both ends, a count, a folded file as exactly one stop; the tree
  mirroring fold state — hunk rows appear and disappear with `za`, never
  with scroll or virtualization; unstaged-lens sweep
  (staged hunk vanishes from view, position preserved for untouched files).
- **Fault:** chaos gains a stage-hunk action; the row-oracle invariants must
  hold across it; injected git failures leave the index byte-exact (the
  existing mixed-rename test's discipline, extended).
- **E2e:** the sweep — open unstaged lens, stage two hunks of a three-hunk
  file, watch them vanish, `Tab` to staged lens and find them, file marker
  flips as git says.
- **Architecture:** staging lives in the source/repository domain, the
  resolver with the diff model, sidebar model in ui — the dependency rules
  get their executable counterparts as usual.

## Non-goals

No mode. No hunk folding (parked, decision 3). No per-hunk stage or stale
markers (decision 4). No hunk staging on binaries, renames, or read-only
ranges. No word-level staging.
