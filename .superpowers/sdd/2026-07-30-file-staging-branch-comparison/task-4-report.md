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
