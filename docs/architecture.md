# CanvasDiff architecture

This is the contributor-facing map: which module may call which, who owns live
state, and which gate refuses a change that breaks either rule. Every claim
here has an executable counterpart under `test/architecture/`; where this file
and those tests disagree, the tests win and this file is wrong.

## Before changing code

Follow the runtime entry path before choosing an edit point:

```text
plugin/canvasdiff.lua -> canvasdiff -> App -> Surface -> domain facade
```

The plugin registers the user command, the root API owns one `App`, `App`
sequences domain operations and selects a live `Surface`, and each `Surface`
owns one review's controller and teardown lifetime. A domain facade is its only
public cross-domain surface; modules inside that domain compose their concrete
owners directly.

Start from the task-oriented paths under “Where to start”. If a change moves a
boundary, update `test/architecture/rules.lua` and its executable contract in
the same commit. If it repairs a lifecycle or ownership invariant, add a
focused fault or integration test that would fail without the repair.

## Domains and facades

Code is grouped into domains. Each domain has exactly one facade — the flat
module named after it — and everything else in that domain is internal.

| Domain | Facade | Owns |
| --- | --- | --- |
| `appearance` | `canvasdiff.appearance` | Highlight names, derived defaults, explicit overrides, colorscheme recovery |
| `canvas` | `canvasdiff.canvas` | Buffer rendering, anchors, row formatting, section splicing |
| `config` | `canvasdiff.config` | Defaults, user options, glyphs |
| `diff` | `canvasdiff.diff` | The model: sections, hunks, anchors, folds, lenses, auto-collapse, line staging, word diff |
| `input` | `canvasdiff.input` | Command grammar, key resolution, motions, jump excursions |
| `os` | `canvasdiff.os` | Raw process, filesystem and timer effects |
| `runtime` | `canvasdiff.runtime` | Watching the repository, virtualizing large canvases |
| `session` | `canvasdiff.session` | Persisting and restoring a review |
| `source` | `canvasdiff.source` | Git inspection, lazy file-boundary collection, worktree reads |
| `ui` | `canvasdiff.ui` | Highlighting, sidebar, scrollbar, status column, hunk peek, notifications |

Above the domains sit three named layers:

- `plugin/canvasdiff.lua` — the user command. Imports the root facade only.
- `canvasdiff` (root) — the public Lua API. Owns one `App`.
- `canvasdiff.App` — composes domains into behavior. Owns `Surface`s.
- `canvasdiff.Surface` — one live review: its state, controllers and teardown.

### The rules

1. **Cross-domain calls go through the facade.** `require("canvasdiff.ui.sidebar")`
   from outside the UI domain is a violation, even though the path resolves.
   Transitive reachability grants nothing: the allowed edges in
   `test/architecture/rules.lua` are direct edges only.
2. **Inside a domain, owners compose directly.** `ui/sidebar.lua` requires
   `ui/notifications.lua`, not `canvasdiff.ui` — requiring the facade you are a
   member of is a cycle, not a boundary.
3. **The dependency graph is acyclic** across domains.
4. **Input never presents and never calls back into the application.** It
   returns outcomes — an operation to perform, an argument, an optional
   levelled diagnostic — and `App` executes and shows them. Both of the edges
   this replaces (`input -> ui`, `input -> canvasdiff`) would be cycles.
5. **No flat modules.** `lua/canvasdiff/*.lua` is facades only. A new flat
   module has no architectural owner and fails the scan by name.
6. **Peer controllers do not know about each other.** Watch, the virtualizer,
   the highlighter, the sidebar, the scrollbar and the status column all report
   through their owning `Surface`; none of them imports another.

### Appearance direction and reload

Appearance is a leaf domain. Rendering owners in `canvas` and `ui` choose
stable `CanvasDiff*` group names and call the `canvasdiff.appearance` facade;
appearance defines those names but has **no outgoing cross-domain edge**.
That direction keeps a renderer from becoming the owner of palette state and
keeps appearance from reaching back into a consumer to form a cycle.

The executable policy permits exactly these direct incoming edges:

| Scope | Direct consumers |
| --- | --- |
| Production | `app`, `health`, `canvas`, `ui` |
| Harnesses | `benchmark`, `testing` |

`app` supplies setup options, `health` audits them, and the `canvas` and `ui`
renderers repair groups at their render boundaries. `benchmark` and `testing`
exercise that same public facade; their harness access grants no additional
production edge.

The setup and reload path is deliberately singular:

```text
renderers choose group names -> canvasdiff.appearance defines them
App passes setup options      -> appearance manager applies them
ColorScheme                   -> one appearance callback
                              -> derived defaults -> explicit overrides
```

`App.new` passes `config.options.highlights`, and `App:setup` passes the merged
`options.highlights`, through the facade to the manager. The manager clears and
recreates one `ColorScheme` augroup callback, so repeated setup does not
accumulate reload handlers. On a colorscheme change that callback derives
defaults from the new palette first, then reapplies the accepted explicit user
overrides. Authorship snapshots let CanvasDiff replace its own stale defaults
while leaving a default definition taken over by a user or colorscheme
untouched; configured explicit overrides intentionally retain precedence.

## Ownership: leases

Every controller that holds live resources — timers, autocommand groups,
extmarks, windows, buffers, window-local options — hands its owner a **lease**.
The rules are uniform, and each one exists because its absence produced a real
defect:

- **A lease is authenticated by exact private identity.** Each owner module
  keeps a weak-keyed lookup table; membership in it is the proof. Public fields
  like `id` or `disposed` are copyable, so a shallow copy of a live lease must
  not be able to tear it down.
- **Authentication owns nothing.** Weak keys cannot keep a lease alive, and the
  registry's values never reference the key or the resources it holds.
- **No module-global selector picks a winner.** Two independent Surfaces hold
  two independent leases at the same time. Process-wide namespaces, monotonic
  IDs and non-owning lookup maps are fine; live state and cleanup authority are
  not.
- **`claim` / `alive` / `release`.** `claim` publishes the exact lease to its
  owner before the first resource exists, so a reentrant callback can dispose
  only this partial lease. `alive` is the owner's generation fence. `release`
  clears the owner's slot, and runs last — after every resource is gone.
- **Invalidate before teardown.** Closing a window, deleting a group or
  removing an extmark can run user code reentrantly. That code must observe a
  dead lease, so identity is revoked before the first external call.
- **Recheck identity after every callback that can reenter.** `alive`, timers,
  autocommands, codecs and Neovim API wrappers can all dispose or replace the
  owner mid-call; checking only before the call is not enough.

Where a resource is genuinely shared — one window's `statuscolumn`, one
buffer's extmark namespace — arbitration is per resource, not per module:
exactly one lease owns any one window or extmark ID at a time, and a lease that
loses one releases its own bookkeeping for it rather than restoring over the
new owner later.

## Git comparison and mutation boundaries

Named lenses (`all`, `unstaged`, `staged`), bare refs, and the per-worktree
checkpoint lens (`CHECKPOINT → WORKTREE`) have a worktree or index side.
`A..B` and `A...B` resolve both sides to commits and are marked read-only:
two-dot compares tips, while three-dot replaces A with the merge base. The
interactive comparison picker (`:CanvasDiff compare`) is read-only and never
mutates refs, branches, or the worktree.

Collection is lazy at file boundaries (`source/collect.lua`): one bounded
`git diff --numstat -z` and one `git check-attr -z --stdin` let generated,
lock, oversized, and already-folded files start as lightweight deferred
placeholders without reading their blobs or running `vim.text.diff`. Unfolding
materializes a section on demand into real Neovim buffer text via the canvas's
`on_materialize` hook.

Staging, unstaging, and discarding are pure line splices over blobs
(`diff/stage.lua`), never patches: `s`/`u`/`x` act on the current hunk in
normal mode, on exact selected lines in visual mode, or on the whole file on a
header (`S`/`U`/`X` from anywhere). Repository mutations use literal pathspecs
and rename-aware paths, and the buffer guard rejects staging when any modified
loaded buffer aliases the path. Discarding writes through a loaded buffer when
present so `u` in the real file undoes it cleanly.

## Tests

Tests are grouped by **intent**, because intent is what tells you how to read a
failure.

| Directory | A failure here means |
| --- | --- |
| `test/unit/` | A logic bug, in code that needs no window and no repository |
| `test/integration/` | A wiring bug between real components |
| `test/e2e/` | A user-visible journey broke |
| `test/fault/` | An invariant was lost under injected faults, reentrancy or concurrency |
| `test/architecture/` | A boundary rule above was violated |

`FILTER` is a Lua pattern matched against test names; `SUITE` selects a
directory. A test file must live in exactly one group, and no two groups may
claim the same filename — otherwise a reported failure does not say which file
it came from.

### Verification workflow

Always direct Neovim logs outside the checkout. Use the focused lane that owns
the change, then widen verification in proportion to its reach:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-unit.log make unit
NVIM_LOG_FILE=/tmp/canvasdiff-integration.log make integration
NVIM_LOG_FILE=/tmp/canvasdiff-e2e.log make e2e
NVIM_LOG_FILE=/tmp/canvasdiff-fault.log make fault
NVIM_LOG_FILE=/tmp/canvasdiff-architecture.log make architecture
NVIM_LOG_FILE=/tmp/canvasdiff-test.log make test
```

A focused replay can combine `SUITE` and `FILTER`:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-syntax.log \
  make test SUITE=fault FILTER='^hl_'
```

The publication gate runs the full suite plus the small-canvas regression,
chaos, and live acceptance lanes:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-verify.log \
  make verify OUT=/tmp/canvasdiff-verify
```

Run the deterministic surface chaos campaign directly when changing ownership
or reentrancy:

```sh
make bench-chaos OUT=/tmp/canvasdiff-chaos ACTIONS=1000
```

To replay an exact reported seed, pass its seed, action count, and `surface`
harness to the worker:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-chaos-replay.log \
  nvim --headless --clean -n -i NONE \
  -l benchmark/chaos/worker.lua \
  /tmp/canvasdiff-chaos-replay.json SEED ACTIONS surface
```

## Where to start

- Adding a user-facing command word: `lua/canvasdiff/input/command.lua`
  (grammar and plan), then `App:command` if the operation is new.
- Adding a mapping: declare its context/action/description in
  `lua/canvasdiff/input/keys.lua`, add its default under the matching
  `config.settings.keymaps` context, then wire the handler in `App` (canvas),
  `ui.sidebar` (sidebar), or `input.jump` (temporary file buffer).
- Adding a controller: model it on `lua/canvasdiff/ui/scrollbar.lua`, which is
  the smallest complete example of the lease contract, and wire it in
  `App:open` with `claim`/`alive`/`release`.
- Changing what a review renders: `lua/canvasdiff/diff/` builds the model,
  `lua/canvasdiff/canvas/` puts it on screen.
- Changing a boundary: `test/architecture/rules.lua` is the executable
  contract. Edit it in the same commit as the move it describes.

## Comments

Explain public contracts, ownership and lifetime, invariants, measured
behavior, reload behavior, or why a tempting simpler alternative is wrong. Do
not translate the next line of Lua into English. Keep load-bearing comments
beside the ordering, identity check, or bound they protect; do not narrate
aliases, loops, obvious branches, or every function.

Comments here are load-bearing, so maintaining them is part of the change,
not a courtesy:

- When a change touches a measured constant or invalidates a stated
  invariant, re-read the neighboring comment block in the same commit and
  update whatever it made false. A stale measurement is worse than no
  comment: readers here trust the numbers literally.
- Changes to measured constants argue with measurements, not taste. The
  existing comment states the experiment that chose the value; a replacement
  value brings a replacement experiment (see docs/design.md for the
  vocabulary those experiments use).
- Every exported symbol on a domain facade carries its contract -- what it
  takes, what it returns, and its failure mode -- verified against the
  implementation, never inferred from the name.

## Repository guardrails

- Keep production Lua under its owning domain. Do not add a new flat
  `lua/canvasdiff/*.lua` module or broaden the empty legacy ledger.
- Add or change cross-domain dependencies only through facades, and keep the
  domain graph acyclic.
- Put benchmark JSON and Neovim logs outside the checkout; the Make targets'
  `OUT` default already points under `/tmp`.
- Preserve unrelated tracked and untracked work. Inspect `git status` and
  `git diff`, then stage explicit paths rather than the whole checkout.
- Run `git diff --check` before committing. Do not weaken a fault,
  architecture, or performance gate merely to make a change pass.
