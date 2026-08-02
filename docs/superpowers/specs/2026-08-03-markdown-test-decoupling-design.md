# Markdown Test Decoupling Design

## Goal

Repository Markdown is editorial content, not an executable contract. Editing,
reorganizing, or deleting text in `README.md` or `docs/*.md` must not make the
test suite fail.

Neovim help remains contract-tested because `doc/canvasdiff.txt` is the
editor-facing help interface. Source code, Makefile targets, benchmark worker
interfaces, and architecture policy also remain directly tested.

## Changes

- Replace README-and-help documentation tests with help-only assertions for
  every public command, highlight group, and highlight precedence statement.
- Remove architecture assertions that parse `docs/architecture.md` for
  contributor commands or dependency-policy prose.
- Keep verification-target and chaos-worker argument checks, but assert them
  directly against `Makefile` and `benchmark/chaos/worker.lua`.
- Exclude repository Markdown files from the retired-identity file scan so
  neither their names nor contents participate in test outcomes.
- Rename integration helpers and test names that say “README” even though they
  exercise setup and highlight behavior without reading the README.
- Keep `.md` strings used as ordinary model filenames in unit/integration
  fixtures; they are data, not dependencies on repository documentation.

## Verification

- Run the focused architecture and integration lanes.
- Run the full deterministic test suite.
- Search the test tree to confirm no test opens or parses a repository Markdown
  document; fixture filenames ending in `.md` remain allowed.
- Confirm the pre-existing README and media work is unchanged by this task.
