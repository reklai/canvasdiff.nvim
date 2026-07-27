# Cheatsheet overlay — design

Date: 2026-07-28
Status: approved in conversation, pending spec review

## Purpose

The plugin is deliberately opinionated: few options, plain buffer-local keys,
one way to use the surface. Opinionated software has to teach its own verbs.
The cheatsheet is a centered floating window that lists every keybind the
plugin installs, so a user who is lost inside the canvas or sidebar can see
the full vocabulary without leaving Neovim or installing which-key.

`keys.lua` was built anticipating this ("consumed … later by the `?`
cheatsheet"): `K.specs` carries display descriptions, and `K.resolved` /
`K.grouped` already produce override-aware views of the keymap config. The
overlay is a renderer over that existing data; it introduces no new source of
keybind truth.

## Requirements

- **R1 — binding.** A new `help` action, default `<leader>lh`, bound
  buffer-locally on the canvas and the sidebar. Not bound on the real file
  buffer during a jump excursion (that context keeps its one-key rule).
- **R2 — reflects the user's config, always.** The overlay renders from the
  resolved `config.keymaps` at open time — never from the shipped defaults.
  A user override REPLACES the default list (existing semantics), and the
  overlay shows exactly the replacement. Multi-key actions render on one row
  (`za c`). Disabled actions (`false` / `{}` / `""`) are omitted entirely.
  This holds for every action including `help` itself.
- **R3 — layout: three columns, `Global | Sidebar | Canvas`.**
  - **Global** — actions available in more than one context with identical
    keys. Computed, not hardcoded: an action bound in both canvas and sidebar
    whose resolved key lists are equal is global (defaults: `help`, `close`).
    The file-context `back` binding also lives here, since it applies outside
    the plugin's own windows.
  - **Sidebar** — sidebar-only actions (default: `select`), plus any shared
    action whose keys the user has diverged between contexts (a diverged
    action leaves Global and appears in both the Sidebar and Canvas columns
    with its per-context keys).
  - **Canvas** — everything else: jump, collapse, file/hunk motions, cycle,
    lenses, refresh. Within this column, rows keep the existing `K.specs`
    group sub-headers (Navigate / Jump / View / Canvas) since it is the
    largest column; Global and Sidebar columns are flat lists.
- **R4 — closing.** `q`, `<Esc>`, or the help binding again close the
  overlay (buffer-local on the overlay buffer). Closing the canvas closes
  the overlay with it. The overlay never survives its parent surface.
- **R5 — sizing.** Width and height fit the content, clamped to the editor
  size. If the editor is too narrow for three columns side by side, the
  columns stack vertically in the same order. If height is clamped, the
  window scrolls normally (no pagination logic).

## Architecture

- **New module `lua/canvasdiff/ui/cheatsheet.lua`.** Owns: building the
  column model from `keys.lua` data + `config.keymaps`, rendering lines,
  and the floating window lifecycle (open / close / toggle). Exposes
  `toggle()` (the handler target) and `close()` (for the canvas-close path).
  Pure-data model building is a separate function from rendering so tests
  can assert the column assignment without a UI.
- **`keys.lua` change:** two new `K.specs` entries —
  `{ ctx = "canvas", action = "help", group = "Canvas", desc = "Show keybind cheatsheet" }`
  and the sidebar equivalent. No structural change to the module.
- **`config/settings.lua` change:** `help = "<leader>lh"` added to the
  `canvas` and `sidebar` default sub-tables, with a comment noting the
  leader-namespace trade-off (accepted: every default is user-replaceable,
  and `<leader>lh` shadows nothing the plugin owns).
- **Wiring:** the `help` handler joins the existing handler tables in
  `App.lua` (canvas) and `sidebar.open` (sidebar), installed through the
  same `K.resolved` path as every other key. The canvas close path calls
  `cheatsheet.close()`.
- **Overlay buffer:** scratch (`nofile`, `bufhidden=wipe`, `nomodifiable`),
  floating window centered relative to the editor, rounded border, title
  "canvasdiff". No filetype, no treesitter, no extmark machinery beyond
  simple highlights (column headers and key columns via existing highlight
  groups where sensible).

## Error handling

The overlay has no external state: no git, no file IO, no timers. The only
failure classes are degenerate configs (everything disabled → columns may be
empty; render whatever remains, and if literally no actions are bound the
overlay still opens showing its own close keys) and tiny terminals (R5
stacking + normal window scrolling).

## Testing

Headless tests alongside the existing suite, mindful of documented headless
constraints (no reliance on autocmd events that do not fire under test;
prefer calling `toggle()`/`close()` directly):

1. Overlay opens from the canvas and contains a known default key row.
2. An overridden binding (e.g. `refresh = "R"`) is displayed, and the
   default it replaced is absent.
3. A disabled action is omitted.
4. Column model: `close` with identical keys in both contexts is Global;
   after diverging sidebar `close`, it appears per-context instead.
5. `q` closes the overlay; closing the canvas closes the overlay.
6. `help` action itself is listed, with the user's key when overridden.

## Out of scope

- No binding on the jump-excursion file buffer.
- No pagination, search, or filtering inside the overlay.
- No which-key integration (the `desc=` fields already serve which-key
  users independently).
- No generated-helpfile work (the `:help` docs remain a separate concern).
