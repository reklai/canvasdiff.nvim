# Ghostty-pattern architecture audit

Date: 2026-07-31

Reference checkout:
`/home/reklai/coding/personal/ts_js/ghostty` at
`15484b607eb5a518dedf1548247c923b8abaae7c` (the same checkout the
[scrollback study](2026-07-26-ghostty-scrollback-study.md) used). Every
ghostty claim below was read from that tree; every CanvasDiff claim cites a
file in this repository, and every line count was measured with `wc`/`grep`
at the commit this document lands in. The authoritative boundary map is
`docs/architecture.md`; where this audit and that file could disagree, the
executable rules in `test/architecture/` win over both.

## 1. Pattern map

Ghostty organizes a large Zig codebase into subsystem directories with
deliberate, checkable seams. CanvasDiff (49 Lua modules under
`lua/canvasdiff/`, measured with `find lua/canvasdiff -name "*.lua" | wc -l`)
uses the same disciplines at a smaller scale. Row by row:

| Ghostty discipline (verified in the checkout) | CanvasDiff counterpart | Verdict |
| --- | --- | --- |
| Subsystem directories: `src/font/`, `src/renderer/`, `src/terminal/`, `src/apprt/`, `src/input/`, `src/cli/`, `src/config/` (51 entries under `src/`, 28 of them flat `.zig` files) | Nine domains under `lua/canvasdiff/` (`canvas`, `config`, `diff`, `input`, `os`, `runtime`, `session`, `source`, `ui`) — the table in `docs/architecture.md` | MATCH |
| Directory + same-named root module as the subsystem's entry point: `src/apprt/` + `src/apprt.zig`, `src/renderer/` + `src/renderer.zig`, `src/input/` + `src/input.zig`, `src/config/` + `src/config.zig` | Exactly our facade rule: each domain directory has one flat module named after it (`lua/canvasdiff/canvas.lua`, `diff.lua`, `ui.lua`, ...), and rule 5 in `docs/architecture.md` forbids any other flat module | MATCH |
| `libghostty`'s deliberately small C API: `include/ghostty.h` is 1,209 lines fronting all of `src/` (`main_c.zig` is the implementation) | Facades are "the domain's exact public surface": `lua/canvasdiff/canvas.lua` exports 24 keys and `test/integration/test_canvas.lua` pins that list exactly, as the matching tests do for `source`, `runtime`, and `session` | MATCH |
| One owner per resource, explicit lifetimes: PascalCase stateful owners (`src/App.zig`, `src/Surface.zig`, `src/Command.zig`) with `init`/`deinit` pairs and allocator ownership | The lease system (`docs/architecture.md` "Ownership: leases"): `claim`/`alive`/`release`, invalidate-before-teardown (e.g. `lua/canvasdiff/runtime/virtualizer.lua:60-75` revokes identity before `del_augroup`/`close_timer`), and `R.stateful_paths` in `test/architecture/rules.lua` reserving PascalCase for the same kind of owner | MATCH |
| Cross-platform seam: multiple apprt implementations (`gtk`, `embedded`, `browser`, `none` under `src/apprt/`) behind one `Runtime` interface, chosen at comptime so a build has exactly one (`src/apprt.zig` header comment) | `lua/canvasdiff/os/` isolates process/fs/timer effects behind `canvasdiff.os`; there is one platform, but the seam serves the same purpose — no other domain touches raw effects, so faking them in `test/fault/` needs one interception point | MATCH (narrower: one implementation, same isolation) |
| Enforced boundaries, not documented ones: the comptime `Runtime` selection makes a boundary violation a build failure rather than a review comment | `test/architecture/` is 30 executable rules (`make architecture`: 30/30): direct-edges-only dependency graph, facade-only cross-domain requires, no flat modules, PascalCase allowlist, one-meaning-per-name | MATCH |
| Orchestrator size tolerance: `src/Surface.zig` is 6,044 lines and `src/App.zig` 605 — ghostty keeps the fat in the concrete owners, not the subsystems | `lua/canvasdiff/App.lua` is 3,031 lines (measured; see §2). The discipline in both codebases is the same: boundaries live at the subsystem/domain seam, and the composing owner is allowed to be large as long as it holds orchestration, not domain logic | MATCH — with the App.lua residue in §2 as the honest caveat |

Honest outcome, stated plainly: **mostly MATCH.** That is not surprising —
`docs/architecture.md` was written after studying ghostty, and the July 26
scrollback study already imported its PageList design into
`lua/canvasdiff/canvas/PageList.lua`. The value of this pass is not
discovering divergence; it is (a) confirming the executable rules still
enforce what the prose claims, and (b) the residue list in §2. No row earned
ADOPT: the one candidate — pinning facade surfaces the way `ghostty.h` pins
the C API — already exists as the facade-key tests.

## 2. Debt found and what this pass did

`lua/canvasdiff/App.lua` was 3,077 lines before this branch
(`git show 8c6d540^:lua/canvasdiff/App.lua | wc -l`), with presentation mixed
into orchestration. Two subtractions landed on this branch:

- **The worked exemplar — winbar extraction** (commit `8c6d540`): breadcrumb
  text, highlight groups, and window-option bookkeeping moved to
  `lua/canvasdiff/ui/winbar.lua` (103 lines), exported as `ui.winbar`, unit
  tested in `test/unit/test_winbar.lua`. App kept only the orchestration half
  (which path sits under a window's topline). App.lua: 3,077 → 3,035.
- **This pass — `canvas_showing` dedup** (§4, item 2): six private copies of
  "is this window showing the canvas buffer" collapsed into one exported
  `canvas.win_showing_canvas`. App.lua: 3,035 → 3,031.

The remaining App.lua concerns worth the winbar treatment later, measured and
ranked:

1. **Picker presentation for compare/checkout** — the largest share.
   `choose_ref` (App.lua:2708-2818, 111 lines), `App:compare`
   (App.lua:2860-3008, 149 lines), plus `format_branch` (App.lua:2553-2555):
   263 lines, 8.7% of the file. Honest caveat from reading them: only ~22 of
   those lines are presentation proper (the `vim.ui.select` prompt/kind/
   format_item tables and `format_branch`); the bulk is liveness guarding
   (`ref_origin_alive`, `compare_origin_alive`) and surface republication,
   which is genuinely App's job. The extraction win is real but smaller than
   the raw spans suggest — a `ui.picker` module would own prompt vocabulary
   and item formatting, not the guards.
2. **Notification phrasing** — 44 `ui.notify`/`ui.warn` call sites in App.lua
   (`grep -c 'ui\.\(warn\|notify\)('`). Each is one line, but the message
   vocabulary (breadcrumb terms, "press Tab" escape hatches) is composed
   inline at each site. A messages table in the ui domain would make the
   vocabulary reviewable in one place. Medium value, low urgency.
3. **Empty-message presentation** — `show_empty_message` (App.lua:813-817,
   5 lines) plus the `EMPTY_MSG` constant (App.lua:41). Six lines, 0.2% of
   the file. Worth moving only when something else opens the same seam.

Why none blocks today: all three already speak through the `ui` facade or
write only canvas-buffer text; no architecture rule is violated, `make
architecture` is 30/30, and ghostty itself demonstrates (Surface.zig at 6,044
lines) that a large composing owner is acceptable while the subsystem seams
hold. These are ranked candidates for the next natural touch, not defects.

## 3. The mode seam contract

This is the "lego" section: what a new comparison mode (PR, single commit)
must plug into, and what it must not touch. The seam already exists and
carried the `A..B` / `A...B` range modes; a new mode is three additions:

1. **A lens identity** in `lua/canvasdiff/diff/lens.lua`:
   - a shape predicate like `range_shape` (lens.lua:46-52) — the lens is a
     validated value object, and `L.valid` (lens.lua:73-75) is what protects
     every reader from a hand-edited session payload;
   - a `label_for` branch (lens.lua:77-91) — the on-screen vocabulary,
     including the `READ-ONLY` prefix when the mode has no editable side;
   - an `L.editable` answer (lens.lua:167-169) — for PR/commit modes this is
     `false` by construction, since neither side is the worktree.
   A constructor in the style of `L.range` (lens.lua:111-123) normalizes and
   labels the identity in one place.
2. **A collector branch** in `lua/canvasdiff/source/collect.lua`:
   `plan_files` (collect.lua:67-96) is where a lens's sides become concrete
   revs — the existing range branch resolves commits and, for `...`, the
   merge base, then diffs the resolved pair. A PR mode is exactly this shape
   (resolve the PR head and its base, diff them); a commit mode is
   `commit^..commit`. `file_stream` (collect.lua:247-258) already threads
   `is_range` through to per-file reads.
3. **Nothing else.** Every other consumer reads the lens through the facade
   (`diff.lua:36-42` exports `lens.of` / `lens.editable` / `lens.is_range`):
   - winbar text and tint: `lua/canvasdiff/ui/winbar.lua:51-52` branches on
     `lens.is_range`, not on a mode id;
   - edit refusal: `lua/canvasdiff/input/jump.lua:115-122` gates on
     `lens.editable` and phrases the way out;
   - staging refusal: App.lua:2234-2238, same predicates;
   - session round-trip: `lua/canvasdiff/session/codec.lua:99` persists the
     lens itself, and `L.valid` re-guards it on restore;
   - fold bookkeeping: `lua/canvasdiff/canvas/Canvas.lua:815,918` and
     `lua/canvasdiff/ui/sidebar.lua:595` key per-lens fold state on
     `lens.of(state).id`, which a new identity gets for free.

What a new mode must NOT do:

- **No new state fields read outside the lens.** If the mode needs to carry
  data (a PR number, a base ref), it lives on the lens identity and rides
  `L.normalize`/`L.valid`/the session codec like every existing field. A
  parallel `state.pr_info` would bypass the validation seam and the session
  round-trip at once.
- **No UI branching on mode id.** Consumers branch on capability predicates
  (`is_range`, `editable`), never on `l.id == "pr:..."`. If a new mode needs
  a distinction no predicate expresses, the predicate is added to `lens.lua`
  — one file — instead of teaching the winbar, sidebar, jump, and App each to
  recognize the id string.
- **No collector logic outside `source/collect.lua`.** Side resolution is the
  collector's monopoly; the lens stores what the user asked for (lens.lua's
  `L.range` keeps the requested refs precisely so the identity stays stable
  and serializable while `...` resolution happens at collection time).

This is the same shape as ghostty's apprt seam: many implementations, one
interface, and consumers that cannot tell which one they got.

## 4. Deferred-minors triage

Two pools, one decision each. Pool A is the post-merge follow-up pool
(`.superpowers/sdd/progress.md:103` in the main checkout); pool B is this
branch's per-task `minor (deferred)` ledger
(`.superpowers/sdd/2026-07-31-readonly-ux-and-architecture-audit/progress.md`).

| # | Item (pool) | Decision | Evidence / promotion trigger |
| --- | --- | --- | --- |
| 1 | statuscol `locate` per line, O(sections) (A) | DEFERRED | `lua/canvasdiff/ui/status_column.lua:700` calls `canvas.locate` per drawn line. Promote when a 1000+-file changeset shows measured statuscolumn redraw lag (`test/performance/` has the harness). |
| 2 | `canvas_showing` duplicated; export `canvas.win_showing_canvas` (A) | **DONE-NOW** (this commit) | Measured six private definitions of the same check: App.lua, `input/motions.lua`, `runtime/virtualizer.lua`, `session/codec.lua`, `ui/scrollbar.lua`, plus the canonical local in `canvas/Canvas.lua`. All were semantically identical (the one-argument variants equal the two-argument variant with `win = nil`). Now one exported `canvas.win_showing_canvas` (Canvas.lua) with the facade key pinned in `test/integration/test_canvas.lua`; the five consumers alias it. All five consumers already had the facade edge (`test/architecture/rules.lua` allows app/input/ui/runtime/session → canvas), so no boundary moved. |
| 3 | `VimLeavePre` closure style (A) | DEFERRED | App.lua:1545. Style-only; collapse when that autocmd is next edited. |
| 4 | virtualizer uv timer never closed (A) | **ALREADY RESOLVED** | Current code closes it: created at `runtime/virtualizer.lua:286`, closed at :291 on the failure path and via `close_timer` in the release path (:75), after identity revocation. The pool entry predates that fix; no work remains. |
| 5 | `jump.back` skips `virt.apply` (A) | DEFERRED | App.lua:733 presents `jump.back` without the `virt.apply` the refresh paths run (App.lua:1962, :2006). Partially deliberate — the comment at App.lua:1625 records that applying with the view at row 1 auto-collapses the far end. Promote on a report of a huge canvas staying fully expanded after returning from an excursion. |
| 6 | stale `collapsed` keys on full rebuild (A) | DEFERRED | `state.collapsed` (Canvas.lua:477) is keyed by path; `replace_section` clears a deleted section's key (Canvas.lua:728-729) but a full `render_all` with a new section list does not sweep keys for departed paths. Bounded by changeset path count. Promote if a departed-and-returned path visibly resurrects the wrong collapse intent. |
| 7 | `test_motions_statuscol.lua` cleanups (A) | **OBSOLETE** | The named file no longer exists (`find test -name "*statuscol*"` returns nothing; the statuscolumn suite now lives at `test/fault/test_status_column.lua`). The cited lines went with it. |
| 8 | `tick_of` unbounded (A) | DEFERRED | `runtime/virtualizer.lua:182-204`: grows one key per distinct section path per producer lifetime, reset on attach (:82) and release. Bounded by changeset size in practice. Promote if profiling a long-lived watch session on a huge repo shows real growth. |
| 9 | cursor-above-w0 restore edge (A) | DEFERRED | `session/codec.lua:273` `winrestview` can override the restored topline when the saved cursor sat above w0. Promote when the wrong-topline restore reproduces in use. |
| 10 | fault fixtures emit `CanvasDiff:` notify lines (B, T1) | DEFERRED | Suite hygiene only; output noise, no assertion touched. Promote if the noise ever obscures a real failure line. |
| 11 | `lens.lua` mid-line `--` used as an em-dash (B, T1) | DEFERRED | Cosmetic; fix on next lens.lua edit. |
| 12 | `set_winbar` validity-checks the window twice (B, T2) | DEFERRED | App delegate and `W.apply` (`ui/winbar.lua`) each check; collapse when either side is next touched. |
| 13 | cached winbar keeps cleared hl groups after `:colorscheme` (B, T3) | DEFERRED | `ensure_hl_groups` runs only on the write path; a `ColorScheme` autocmd would close it. Promote on a user report of a blank/untinted bar after a mid-session colorscheme change. |
| 14 | README:294-295 lowercase "(read-only)" vs `READ-ONLY` (B, T4) | **RATIFIED — no change** | Ruling this audit was asked to make: `READ-ONLY` (upper) is on-screen mode vocabulary — the winbar label (`lens.lua:86`), the staging refusal (App.lua:2236), the jump refusal (`jump.lua:119`). Lowercase "read-only" is ordinary English prose. README:294-295 are prose comments in the command table, so lowercase governs there; README:101 correctly uses both registers in one sentence. |
| 15 | `jump.lua` param shadows module-local `source` (B, T4) | DEFERRED | `input/jump.lua:221` (`target_win(state, requested, source)`). Rename to `source_win` on next edit of that function. |
| 16 | `doc/canvasdiff.txt` lacks entries for the new hl groups/label (B, T4) | DEFERRED to branch final review | The branch ledger already assigns this check to the final whole-branch review; it is a docs completeness gate, not code debt. |
| 17 | `W.text(st, path, {})` yields no tail rather than the config default (B, T5) | CLOSED | Feature removed 2026-08-01 (help tail deleted); moot. |
| 18 | winbar shows literal `<leader>lh`, not the resolved leader (B, T5) | CLOSED | Feature removed 2026-08-01 (help tail deleted); moot. |
| 19 | ASCII glyph variant of the sidebar title untested (B, T6) | DEFERRED | Live-glyph chain verified by reading; promote to a one-line ascii-mode assertion next time sidebar tests are edited. |

Net effect of this pass: one item landed (2), two closed as already-resolved
or obsolete (4, 7), one ratified as no-change (14), fifteen remain deferred —
each now with a named file and a concrete promotion trigger instead of a
one-line pool entry.
