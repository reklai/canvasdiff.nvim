# Remove the Winbar Help Hint

Approved 2026-08-01. Removes the right-aligned `%=<help-key> help` tail the
canvas winbar gained in the read-only UX pass (commit `9f1be6e`). The user
decided against it; git history keeps the implementation if discoverability
becomes a real need at publication time. Everything else from that pass
stays: the `READ-ONLY  A → B` label, the winbar tint, the sidebar diffstat.

> **Supersedes in part**
> `2026-07-31-readonly-ux-and-architecture-audit-design.md` §4 item 1
> (the help-hint adoption). Item 2 (sidebar diffstat) and the recorded
> non-adoptions stand.

## Code

`lua/canvasdiff/ui/winbar.lua`:

- Delete `help_tail` and the tail concatenation.
- Revert `W.text(st, path, keymaps)` to `W.text(st, path)` — the third
  parameter existed only for the tail.
- Drop the requires only the tail needed: `canvasdiff.config` and
  `canvasdiff.input`. `canvasdiff.canvas` and `canvasdiff.diff` stay.
- The doc comment above `W.text` currently reads "`%<` truncates the path,
  never the comparison or the help tail" — it goes back to "`%<` truncates
  the path, never the comparison."

Two deferred minors in the audit's triage table dissolve with the feature
(the `W.text(st, path, {})` no-tail sharp edge; the literal `<leader>lh`
display). Mark both rows closed in
`docs/research/2026-07-31-ghostty-architecture-audit.md` with "feature
removed 2026-08-01" rather than deleting the rows.

## Tests

- `test/unit/test_winbar.lua`: delete the three tail tests (bound tail /
  disabled / multi-bound); strip the `%=<leader>lh help` suffix from the
  four remaining expectations.
- `test/integration/test_root.lua`: the winbar assertion loses the suffix —
  expected substring becomes
  `%#CanvasDiffWinbarReadOnly#READ-ONLY  main → topic · %<a.txt`.
- `test/e2e/test_e2e.lua`: both full-string winbar `H.eq` assertions lose
  the suffix.

## Docs

- `README.md`: remove the sentence "Its right edge names the cheatsheet key
  (`<leader>lh help` by default); rebinding or disabling `help` moves or
  removes the reminder." from the "Knowing where you are" canvas-winbar
  bullet.
- `doc/canvasdiff.txt`: remove the right-edge help-key sentence from the
  winbar paragraph (the one added by `959669a`).

## Verification

Full suite green (`NVIM_LOG_FILE=/tmp/canvasdiff.log make test`); a manual
`:CanvasDiff` open shows a winbar with no right-edge hint. One commit.
