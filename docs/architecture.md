# CanvasDiff architecture

This is the contributor-facing map: which module may call which, who owns live
state, and which gate refuses a change that breaks either rule. Every claim
here has an executable counterpart under `test/architecture/`; where this file
and those tests disagree, the tests win and this file is wrong.

## Domains and facades

Code is grouped into domains. Each domain has exactly one facade — the flat
module named after it — and everything else in that domain is internal.

| Domain | Facade | Owns |
| --- | --- | --- |
| `appearance` | `canvasdiff.appearance` | Highlight names, derived defaults, explicit overrides, colorscheme recovery |
| `canvas` | `canvasdiff.canvas` | Buffer rendering, page storage, projection, scheduling |
| `config` | `canvasdiff.config` | Defaults, user options, glyphs |
| `diff` | `canvasdiff.diff` | The model: sections, hunks, anchors, folds, lenses, word diff |
| `input` | `canvasdiff.input` | Command grammar, key resolution, motions, jump excursions |
| `os` | `canvasdiff.os` | Raw process, filesystem and timer effects |
| `runtime` | `canvasdiff.runtime` | Watching the repository, virtualizing large canvases |
| `session` | `canvasdiff.session` | Persisting and restoring a review |
| `source` | `canvasdiff.source` | Git inspection, changeset collection, worktree reads |
| `ui` | `canvasdiff.ui` | Highlighting, sidebar, scrollbar, status column, notifications |

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

The process-wide compare and checkout keymaps follow the same identity rule.
Each desired and owned record carries its allowlisted action. Reconciliation
retains a mapping only when its effective lhs, action, callback, behavior, and
complete observable Neovim identity still match. Each `App` retains the exact
Lua callback and the complete stable `nvim_get_keymap()` identity for its own
global maps, including provenance such as `sid`, `lnum`, `scriptversion`, mode
bits and buffer scope. Canonical cross-action collisions are rejected before
mutation; an authenticated same-lhs action change replaces only CanvasDiff's
own prior callback. `setup()` removes or rebinds a mapping only when the
captured native getter still reports that callback and identity; the immediately
following comparison and delete use captured control primitives and native
functions, leaving no replaceable Lua wrapper between authentication and
mutation. An occupied lhs, a user/plugin takeover, another App, a
same-callback reinstall and a module reload are all foreign.
Configured `<leader>` notation is canonicalized at installation time, so a
later leader change can retire the old owned sequence without confusing it
with the newly requested one. Reconciliation prevalidates the complete list,
including Neovim's 50-byte post-termcode lhs limit, retains authenticated
candidates across API faults, and coalesces synchronous setup re-entry before
presenting diagnostics from the committed pass.

Those captured functions have one explicit trust boundary: Neovim's API table
must still contain its native functions when `canvasdiff.App` initializes
(including after a deliberate full module reload). Neovim's Lua execution is
single-threaded, so no mapping takeover can interleave between the captured,
non-reentrant native get and delete calls. Conversely, Neovim exposes no atomic
compare-and-delete mapping primitive, and a Lua wrapper installed before module
initialization can falsify the observation and mutate during deletion.
CanvasDiff cannot authenticate such a pre-compromised API namespace from Lua;
capturing the functions after initialization protects against later public
table replacement, not arbitrary code that crossed this bootstrap boundary.

## Git comparison and mutation boundaries

Named lenses (`all`, `unstaged`, `staged`) and bare refs can have a worktree or
index side. `A..B` and `A...B` resolve both sides to commits and are marked
read-only: two-dot compares tips, while three-dot replaces A with the merge
base. The interactive comparison picker projects repository metadata to local
branches only. Branch names are presentation; exact refs/heads/* identities
build the read-only range lens. Explicit typed ranges retain the broader Git
revision grammar.

Ref handling has one deliberately narrow boundary:

```text
ref metadata → role-based picker → exact full-ref Git operation
             → invalidated Surface → HEAD → WORKTREE recollection
```

Comparison is read-only. Checkout offers local branches only; tracking offers
non-symbolic remote-tracking refs only and creates a local tracking branch
without fetching. Before either mutation, the modified-buffer guard covers the
whole repository. Git remains the final authority for saved worktree changes
that an operation would overwrite. The mutation surface exposes no force,
stash, detached-HEAD, or deletion path.

Stage cycling is a file mutation, so `App` re-reads porcelain status for the
exact section identity before choosing a direction. Any unstaged state stages
the whole file; staged-only state resets that file from HEAD. Repository
mutations use literal pathspecs and rename-aware paths, while the buffer guard
rejects staging if any modified loaded buffer resolves to the same filesystem
identity. Successful mutation reconciles the lens and restores a content
anchor rather than trusting the pre-mutation row.

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
| `test/performance/` | A measured budget regressed |

```sh
make test                             # everything
make unit                             # one intent group
make fault
make test SUITE=fault FILTER='^hl_'   # a group, filtered by test name
```

`FILTER` is a Lua pattern matched against test names; `SUITE` selects a
directory. A test file must live in exactly one group, and no two groups may
claim the same filename — otherwise a reported failure does not say which file
it came from.

The supported branch lifecycle is: discover role-appropriate metadata; select
an exact full ref; block unsaved repository buffers; checkout a local branch or
create its local tracking branch; retire the old Surface; then recollect the
new `HEAD → WORKTREE` review. A visible review restores its semantic position;
a hidden one remains closed. Collection failure reports the new branch state
without reviving the retired Surface.

Always redirect Neovim's log outside the checkout when running the suite:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff.log make test
```

## Where to start

- Adding a user-facing command word: `lua/canvasdiff/input/command.lua`
  (grammar and plan), then `App:command` if the operation is new.
- Adding a mapping: declare its context/action/description in
  `lua/canvasdiff/input/keys.lua`, add its default under the matching
  `config.settings.keymaps` context, then wire the handler in `App` (global and
  canvas), `ui.sidebar` (sidebar), or `input.jump` (temporary file buffer).
- Adding a controller: model it on `lua/canvasdiff/ui/scrollbar.lua`, which is
  the smallest complete example of the lease contract, and wire it in
  `App:open` with `claim`/`alive`/`release`.
- Changing what a review renders: `lua/canvasdiff/diff/` builds the model,
  `lua/canvasdiff/canvas/` puts it on screen.
- Changing a boundary: `test/architecture/rules.lua` is the executable
  contract. Edit it in the same commit as the move it describes.
