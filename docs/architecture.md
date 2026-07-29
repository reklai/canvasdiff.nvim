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

The process-wide compare keymap follows the same identity rule without becoming
a controller lease. Each `App` retains the exact Lua callback and the complete
stable `nvim_get_keymap()` identity for its own global maps, including behavior
and provenance such as `sid`, `lnum`, `scriptversion`, mode bits and buffer
scope. `setup()` removes or rebinds a mapping only when the captured native
getter still reports that callback and identity; the immediately following
delete also uses a captured native function, leaving no replaceable Lua wrapper
between authentication and mutation. An occupied lhs, a user/plugin takeover,
another App, a same-callback reinstall and a module reload are all foreign.
Configured `<leader>` notation is canonicalized at installation time, so a
later leader change can retire the old owned sequence without confusing it
with the newly requested one. Reconciliation prevalidates the complete list,
including Neovim's 50-byte post-termcode lhs limit, retains authenticated
candidates across API faults, and coalesces synchronous setup re-entry before
presenting diagnostics from the committed pass.

## Git comparison and mutation boundaries

Named lenses (`all`, `unstaged`, `staged`) and bare refs can have a worktree or
index side. `A..B` and `A...B` resolve both sides to commits and are marked
read-only: two-dot compares tips, while three-dot replaces A with the merge
base. The comparison picker only discovers refs and publishes one of those
lenses; it never checks out, fetches, or writes refs.

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
