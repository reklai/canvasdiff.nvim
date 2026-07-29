# Task 4 implementation report

## Outcome

- Added configurable `keymaps.global.compare = "<leader>lb"` with string/list
  normalization and `false`, `""`, or `{}` disable forms.
- The global callback is bound to the exact root `App` instance and opens its
  existing two-step branch/revision comparison picker.
- Global mapping reconciliation authenticates ownership with exact callback,
  description, and keymap metadata. Foreign collisions and later takeovers are
  preserved; repeated setup, disable, rebind, module reload, multiple App
  instances, and leader changes are covered.
- Added the global action to key metadata and to the cheatsheet's explicitly
  Global column.
- Updated README, help, and architecture documentation for stage cycling,
  branch comparison ranges/picker behavior, mapping configuration, collision
  policy, and lazy-loading visibility.

## TDD evidence

Initial focused red runs:

- `config_ setup is optional...`: failed because `keymaps.global` did not exist.
- `keys_compare...`: failed because no global compare metadata resolved.
- `cheatsheet_model labels...`: failed because compare was absent from help.
- Space-leader regression: failed because `<leader>` canonicalization left the
  old `<Space>lb` mapping installed after a leader change.
- First full suite: `804/808`; four existing notification-count tests exposed
  repeated module-reload collision warnings.

Focused green runs:

- Config: `13/13`
- Global mapping tests: `5/5`
- Key registry: `21/21` at the first green checkpoint
- Cheatsheet unit: `12/12`
- Cheatsheet integration: `7/7`
- Architecture: `30/30`
- Integration after diagnostic de-duplication: `374/374`

Authoritative verification:

```text
NVIM_LOG_FILE=/tmp/canvasdiff-task4-full-final.log make test
808/808 passed
```

`git diff --check` also passed.

## Self-review

- Replaced display-form lhs matching with `vim.keycode()` plus
  `nvim_get_keymap()`'s `lhsraw`/`lhsrawalt`; this handles the common Space
  leader as well as control and terminal keycodes.
- Stored Neovim's installed lhs separately for exact deletion.
- Collision-warning de-duplication is explicitly separate from ownership and
  grants no authority to remove or replace a mapping.
- No fixed lens-cycle behavior changed.

## Residual concern

A command-only lazy-loading declaration cannot expose a plugin-owned mapping
before the plugin itself loads. The README now makes that constraint explicit
and shows startup loading for immediate `<leader>lb` availability.

## Controller repair round 1

Independent review identified synchronous setup re-entry, partial API failure,
incomplete metadata authentication, and two help contradictions.

Red regressions reproduced all reported behaviors:

- same callback plus `nowait=true` was deleted as if still owned;
- `compare = { "gQi", "" }` threw after installing the first lhs;
- notification re-entry installed `gRb`, but a later disable left it orphaned;
- a write-then-throw setter propagated and lost ownership.

Repairs:

- The complete compare value is validated before mutation: type, dense-list
  shape, string/non-empty entries, termcode conversion, and canonical
  duplicates.
- Reconciliation now coalesces synchronous setup re-entry. Partial passes
  settle authenticated candidates, the latest configuration is replayed, and
  only final committed diagnostics are presented.
- Set/get/delete failures are contained. A conservative candidate ledger is
  retained and authenticated again before any later cleanup.
- Ownership snapshots and compares callback identity plus normalized
  `desc`, RHS, remap, silent, nowait, expr, script, and replace-keycodes
  behavior. Same-callback takeovers altering each exposed behavior are
  preserved.
- Help now says the default opens `all`, limits editability to
  worktree-backed lenses, and names staged/ranges as read-only.

Repair verification:

```text
keys-focused: 25/25 passed
architecture: 30/30 passed
NVIM_LOG_FILE=/tmp/canvasdiff-task4-fix-full.log make test
812/812 passed
```

Injected write-then-throw set, delete failure, and inspection failure all
recover on a later setup without deleting foreign mappings. `git diff --check`
passed. The documented command-only lazy-loading limitation remains the only
known residual concern.

## Controller repair round 2

Independent review found three remaining ownership-boundary gaps:

- a 51-byte lhs later in a list passed local validation, so an earlier valid
  lhs was installed before Neovim rejected the long entry;
- a same-callback, same-behavior reinstall had different observable call-site
  provenance but was still deleted as owned;
- replaceable public Lua get/delete wrappers could run user code between the
  final ownership check and deletion.

Red regressions reproduced each issue: the valid prefix remained installed
after the long-lhs failure, a reinstall with a distinct `sid`/`lnum` was
removed, and the monkeypatched public getter was called three times.

Repairs:

- Complete-list validation now applies Neovim's 50-byte lhs limit after
  termcode expansion, before any mutation.
- Established ownership records snapshot every stable field returned by
  `nvim_get_keymap()` except the separately compared callback. This includes
  behavior, mode/buffer attributes and `sid`/`lnum`/`scriptversion`
  provenance, so even an otherwise identical foreign reinstall survives.
- Production reconciliation captures raw native get/set/delete functions at
  module load. The final authentication/delete pair cannot enter replaceable
  public Lua wrappers.
- `App.new()` accepts explicit keymap effects for fault testing. A second-entry
  write-then-throw, delete failure and inspection failure all retain a
  conservative authenticated ledger and recover on a later synchronization.

Repair verification:

```text
keys_global focused: 11/11 passed
architecture: 30/30 passed
NVIM_LOG_FILE=/tmp/canvasdiff-task4-r2-full.log make test
814/814 passed
```

`git diff --check` passed. The documented command-only lazy-loading limitation
remains the only known residual concern.

## Controller repair round 3

Independent re-review found that a throwing setter could still escalate a
tentative record. If the setter wrote CanvasDiff's callback, reinstalled that
same callback and behavior with foreign provenance, then threw,
`settle_global_ledger()` authenticated only the tentative behavior and promoted
the foreign identity. A later disable deleted it.

The exact regression failed before the repair because the foreign-provenance
mapping did not survive disable. The repair separates expected-install
matching from ownership:

- a tentative record has no deletion authority;
- only a successful set followed by a complete observed identity becomes an
  authoritative record;
- a throwing setter's observed mapping is never promoted;
- earlier successful list entries already carry full identities, so a later
  setter failure does not orphan those known-owned mappings.

The lifecycle review then found one post-load re-entry hook left in the final
comparison: replaceable `vim.deep_equal`. Its regression failed with one
wrapper call and deletion of the takeover. Global-map reconciliation now uses
captured `pcall`, iteration, type, raw-access and raw-equality primitives plus
an internal scalar-field comparator. The fix-only re-review returned
`ADDRESSED`; the independent requirements review and final whole-change review
both returned `PASS`.

### Pre-load API-wrapper disposition

No sound Lua-only protection exists for API functions replaced before
`canvasdiff.App` initializes. Neovim 0.11's documented global deletion
operation is `nvim_del_keymap(mode, lhs)` and provides no expected-identity
argument or atomic compare-and-delete primitive. Neovim Lua execution is
single-threaded, so no mapping mutation can interleave between the captured
non-reentrant native get, internal comparison and native delete calls under
the normal API boundary. But a pre-load wrapper can falsify observations and
mutate during deletion; any Lua bootstrap or hidden table is itself mutable
and cannot distinguish that compromise. The architecture documentation now
states this boundary explicitly, including deliberate full module reloads.

Repair verification:

```text
failed-set takeover regression: RED, then 1/1 passed
post-load comparison-wrapper regression: RED, then 1/1 passed
keys_global focused: 13/13 passed
architecture: 30/30 passed
NVIM_LOG_FILE=/tmp/canvasdiff-task4-r3-full.log make test
816/816 passed
```

`git diff --check` passed. No receipt or ledger file was edited. A setter that
throws after writing can leave that mapping present, but it is deliberately
non-authoritative and CanvasDiff will not delete it; previously authenticated
maps still recover normally. The command-only lazy-loading limitation remains
the only product-level residual, while arbitrary pre-load API replacement is
the documented runtime trust boundary.
