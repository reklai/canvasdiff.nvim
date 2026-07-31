# Stage Verbs, q Back-Out, Sidebar Toggle

Approved 2026-08-01. Three keymap-facing changes decided together:
`s`/`u` become plain stage/unstage verbs, `q` on the canvas backs out of a
stacked comparison before closing, and the sidebar becomes reopenable
(`o` on the canvas, `:CanvasDiff sidebar`, `.sidebar()` API). `q` on the
sidebar stays exactly what it is.

## 1. `s` = stage, `u` = unstage (canvas AND sidebar)

Replaces today's `s` stage-cycle. Pre-alpha: the `stage_cycle` action is
removed cleanly — no alias; a user override naming it gets the existing
misspelled-name report.

- `s` stages the file under the cursor: every unstaged change moves to the
  index. When the file has nothing unstaged, notify `already staged` (info
  level) and change nothing.
- `u` unstages the file: the index entry returns to HEAD's content without
  touching the worktree. When the index already matches HEAD for that file,
  notify `nothing staged` and change nothing.
- Both keys exist in BOTH contexts (canvas + sidebar), same defaults.
- All current `toggle_stage` guards keep working unchanged for both verbs:
  refusal while a modified loaded buffer aliases the path, refusal on ranges
  (READ-ONLY vocabulary), XY-state-from-git-not-screen, and the lens
  retargeting on success (staging from `unstaged` pivots the view the same
  way the cycle did).
- Implementation shape: `App:toggle_stage` gains an explicit direction
  (internally `stage_file(action, path, ...)` or a `direction` parameter —
  implementer's choice), with the two thin entries the action tables and the
  sidebar's callback bind to. The auto-direction "cycle" decision
  (`file.unstaged and "stage" or "unstage"`) is deleted, not kept as a
  hidden third mode.
- Action names in `input/keys.lua`: `stage` (desc: `Stage this file's
  changes`) and `unstage` (desc: `Unstage this file`), groups as today.
  Config defaults: `stage = "s"`, `unstage = "u"` in both `keymaps.canvas`
  and `keymaps.sidebar`; `stage_cycle` removed from `config/settings.lua`
  defaults and its valid-action list.

## 2. `q` on the canvas backs out of a stacked comparison

The rule: **q backs out of the thing you're in.** The comparison state is
visible (READ-ONLY tinted winbar), and `state.return_lens` already records
whether a comparison was stacked on a working view this session.

- `q` (the canvas `close` action) when the current lens is a range AND
  `state.return_lens` is set and valid: pivot back to `return_lens` —
  identical landing to `<Tab>`, including the `showing …` notification and
  the same clear-on-real-error rule `cycle_lens` uses. Pressing `q` again
  then closes the review.
- `q` in a comparison with NO recorded return lens (opened directly via
  `:CanvasDiff a..b`, or session-restored): closes the review, as today —
  nothing was stacked, so out means out.
- `q` in any editable lens: closes the review, unchanged.
- `q` on the sidebar: unchanged (closes the sidebar). `:q` everywhere:
  unchanged (Vim's window-close).
- `:CanvasDiff close` and `App:close()` API are NOT modified — the back-out
  lives in the canvas key action only, so scripts that say close still get
  close.
- Key desc (`input/keys.lua` canvas `close`): `Back out: leave a stacked
  comparison, else close the canvas`.

## 3. Sidebar toggle

Today `q` on the sidebar is a one-way door (verified: no command, no API, no
key reopens it; only a full canvas close+reopen).

- New canvas action `sidebar`, default key `o` (in the `nomodifiable`-inert
  set, so binding it costs nothing), desc: `Toggle the sidebar`. Canvas
  context only — the sidebar needs no key to toggle itself; its `q` already
  closes it.
- New subcommand `:CanvasDiff sidebar`: toggles the sidebar for the showing
  canvas; warns `no live diff canvas` (existing vocabulary) when none is
  showing. Tab-completes with the other subcommands.
- New API `require("canvasdiff").sidebar()` — same behavior as the command.
- Toggling ON when `sidebar.enabled = false` in config still works — the
  config flag controls auto-open at canvas open, not availability. Toggling
  respects all existing sidebar ownership/lease rules (reuse the existing
  open/close paths; no new lifecycle).

## Docs

README + vimdoc, one pass: the canvas/sidebar keymap tables gain `u` and
`o` rows and the new `s`/`u` descriptions; the `q` rows and the
"two exits mean different things" paragraph get the back-out rule; the
Commands block gains `:CanvasDiff sidebar`; the sidebar section's "q closes
just the sidebar" sentence gains "press o (or `:CanvasDiff sidebar`) to
bring it back". Cheatsheet needs no code change (renders from the registry)
— verify layout with the new rows.

## Tests

- s/u: happy paths both contexts; notify no-ops (`already staged`,
  `nothing staged`); range refusal unchanged; the unsaved-buffer guard
  fires for both verbs.
- q back-out: stacked comparison → q pops to the recorded lens, q again
  closes; direct-opened range → q closes immediately; editable lens → q
  closes; `:CanvasDiff close` still closes even in a stacked comparison.
- Sidebar toggle: o closes when open, reopens when closed (same canvas,
  no full reopen); `:CanvasDiff sidebar` from a non-canvas window in the
  tab; API call with no canvas warns; sidebar reopened via `o` when
  `sidebar.enabled = false`.
- Chaos harness: the `stage_cycle` action follows the API split (becomes
  `stage` + `unstage` actions); add a `sidebar_toggle` action. Short
  campaign green.

## Verification

Full suite green; manual smoke: s/u on a mixed file, q-q out of a stacked
comparison, o o on the sidebar.
