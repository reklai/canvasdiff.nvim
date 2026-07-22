# Finding Myself

Infinite-scroll git diff canvas for Neovim — review all your uncommitted changes in one scrollable view, jump into any hunk as a real buffer, jump back to the exact spot. Status: pre-alpha MVP.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-name/finding_myself", -- adjust to wherever this repo lives
  cmd = "FindingMyself",
  opts = {}, -- optional; see Configuration below
}
```

`opts = {}` (or omitting `opts`/`config` entirely) is enough — the plugin
works with its defaults even if `setup()` is never called.

## Usage

Run `:FindingMyself` in any window inside a git repository. It replaces the
current window's buffer with a single scrollable "canvas": every changed
file's diff, one after another, in alphabetical path order, each with a
`▎ path (+adds −dels)` header and unified-diff-style hunks (3 lines of
context by default -- configurable via `context`, see Configuration below).

- Move the cursor onto any line and press `<CR>` to jump into that file as a
  real `:edit` buffer, landing on the corresponding line (LSP/treesitter/
  autocmds all attach normally — it's not a preview).
- Edit the file as usual (saved or not), then press `<M-CR>` to jump back to
  the canvas. The diff for that file is regenerated from the file's current
  content (including unsaved edits) and the canvas view is restored to
  roughly where you left it.
- Press `q` to close the canvas and restore whatever buffer was in the
  window before.
- Press `R` to refresh the whole canvas: re-scan the repo for changed files
  and re-render everything from scratch.

`:FindingMyself` with no argument toggles the canvas (open if not showing,
close if showing). It also accepts an explicit subcommand, with completion:

```vim
:FindingMyself open
:FindingMyself close
:FindingMyself toggle
:FindingMyself refresh
```

If the current directory isn't inside a git repository, `:FindingMyself
open` notifies you and does nothing further (it never errors).

## Configuration

```lua
require("finding_myself").setup({
  keymaps = {
    jump = "<CR>",     -- jump into the file under the cursor
    back = "<M-CR>",   -- jump back to the canvas from an excursion
    close = "q",       -- close the canvas
    refresh = "R",      -- re-scan and re-render
  },
  context = 3,          -- unified-diff context lines around each hunk
})
```

Any subset of these can be overridden; unspecified keys keep their default.

| Keymap (canvas buffer only) | Default | Action |
| --- | --- | --- |
| `jump` | `<CR>` | Open the file under the cursor as a real buffer |
| `back` | `<M-CR>` | (set on the excursed file buffer) return to the canvas |
| `close` | `q` | Close the canvas, restore the previous buffer |
| `refresh` | `R` | Re-collect changed files and re-render the canvas |

## MVP scope

What's here today:

- One scrollable canvas per invocation, built from `git status` +
  `git show HEAD:<path>` + current worktree/buffer content.
- Line-tier highlighting only (`+`/`-`/context lines, file and hunk
  headers) — no syntax highlighting of the diffed code itself yet.
- Manual refresh (`R` / `:FindingMyself refresh`) — the canvas does not
  watch the filesystem or auto-update.
- Jump/back round-trip preserves your semantic position (same hunk/line)
  across edits, not just a raw line number.

## Roadmap

Rough order, each phase independently useful:

1. **Treesitter highlight tier** — real syntax highlighting of hunk content
   instead of plain diff-line coloring.
2. **Live watch / auto-refresh** — pick up filesystem and buffer changes
   without a manual `R`.
3. **Sidebar / file list** — a persistent index of changed files alongside
   the canvas for quick navigation.
4. **Scrollbar** — a visual indicator of where you are across all sections.
5. **Virtualization** — render only the visible window's worth of diff for
   large repos/diffs, instead of the whole canvas up front.
6. **Session persistence** — remember canvas state (open files, scroll
   position) across Neovim restarts.
