# Contributing to CanvasDiff

CanvasDiff is organized around explicit owners and executable boundaries. A
change is ready when its owning module is clear, the smallest relevant lane is
green, and the repository-wide verification appropriate to the change has
been run.

## Before changing code

Read `docs/architecture.md`; cross-domain imports target only facades.

Follow the runtime entry path before choosing an edit point:

```text
plugin/canvasdiff.lua -> canvasdiff -> App -> Surface -> domain facade
```

The plugin registers the user command, the root API owns one `App`, `App`
sequences domain operations and selects a live `Surface`, and each `Surface`
owns one review's controller and teardown lifetime. A domain facade is its only
public cross-domain surface; modules inside that domain compose their concrete
owners directly.

Start from the task-oriented paths under “Where to start” in
`docs/architecture.md`. If a change moves a boundary, update
`test/architecture/rules.lua` and its executable contract in the same commit.
If it repairs a lifecycle or ownership invariant, add a focused fault or
integration test that would fail without the repair.

## Comments

Explain public contracts, ownership and lifetime, invariants, measured
behavior, reload behavior, or why a tempting simpler alternative is wrong. Do
not translate the next line of Lua into English. Keep load-bearing comments
beside the ordering, identity check, or bound they protect; do not narrate
aliases, loops, obvious branches, or every function.

## Verification

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

`FILTER` is a Lua pattern over test names and `SUITE` selects one intent
directory, so a focused replay is, for example:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-syntax.log \
  make test SUITE=fault FILTER='^hl_'
```

The publication gate runs the full suite plus the small-canvas regression,
million-row paging, chaos, and live acceptance lanes:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-verify.log \
  make verify OUT=/tmp/canvasdiff-verify
```

Run the full deterministic chaos campaign directly when changing ownership,
reentrancy, paging, compression, projection, or scheduling:

```sh
make bench-chaos OUT=/tmp/canvasdiff-chaos ACTIONS=10000
```

To replay an exact reported seed, copy its seed, action count, and `engine` or
`surface` harness into the worker command. The JSON output retains the failing
action and recent deterministic history:

```sh
NVIM_LOG_FILE=/tmp/canvasdiff-chaos-replay.log \
  nvim --headless --clean -n -i NONE \
  -l benchmark/chaos/worker.lua \
  /tmp/canvasdiff-chaos-replay.json SEED ACTIONS HARNESS
```

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
