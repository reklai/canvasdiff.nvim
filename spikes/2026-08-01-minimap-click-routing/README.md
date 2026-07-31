# Spike: mouse-click routing over the non-focusable minimap

Task 4 (thumb dragging) needs to know where its mouse mappings live and what a
press/drag/release over the 1-column `focusable = false` scrollbar float looks
like — and whether its integration tests can drive all of it headlessly.

**Command:**
```bash
nvim --headless --clean -l spikes/2026-08-01-minimap-click-routing/spike.lua
```

**Method:** a REAL canvas + REAL scrollbar float, opened through the plugin's
own open path (`require("canvasdiff").setup{} / .open()`) in a throwaway git
fixture, with logging `<LeftMouse>`/`<LeftDrag>`/`<LeftRelease>` mappings
registered on BOTH the canvas buffer and the scrollbar buffer. Two phases:
in-process (this `-l` script) and a child `nvim --headless --embed --clean`
driven over RPC, because those two turn out to have different powers (Q4).
Verified on NVIM v0.12.4. Result: **SPIKE PASS** (25/25 checks).

## The four answers

### Q1 — Which window receives `<LeftMouse>` over the float?

**The canvas, entirely. The float is mouse-transparent.** A `focusable = false`
float is skipped by mouse position resolution: the event resolves to the
canvas window beneath, and mapping dispatch uses the CURRENT buffer (the
canvas — focus never moves), so the canvas buffer's mapping fires. The
scrollbar buffer's mappings NEVER fired, for any event, in any scenario.
With no mapping at all, the default click also passes through: focus stays on
the canvas, the float is never focused (its cursor never moves), and the
canvas cursor jumps to the buffer line under the pointer.

**Task 4's mappings must live on the CANVAS buffer** (`n`-mode, buffer-local
`<LeftMouse>`/`<LeftDrag>`/`<LeftRelease>`). Mappings on the scrollbar buffer
are dead code.

### Q2 — What does `getmousepos()` report over the float?

The canvas window, never the float. Measured payload for a press on the
thumb's top row (canvas at screen col 34, width 47, one winbar row; float at
screen `{2, 80}`):

```
{ winid = <canvas win>, winrow = 2, wincol = 47,
  screenrow = 2, screencol = 80,
  line = 1, column = 27, coladd = 21 }
```

- `winid` = the CANVAS window id — the float's id appears nowhere.
- `wincol` = the canvas window's WIDTH (the float covers its last column), so
  "pointer is over the bar" is `pos.winid == canvas_win and pos.wincol ==
  nvim_win_get_width(canvas_win)`.
- `winrow` counts from the window top INCLUDING the winbar, so the 1-based bar
  row is `pos.winrow - getwininfo(canvas_win)[1].winbar`.
- `line`/`column` are canvas BUFFER coordinates under the pointer. **Do not use
  `line` for thumb math**: deletion ghosts are virtual lines, so screen rows
  and buffer lines diverge (measured: winrow 22 → line 19). Use `winrow`.

### Q3 — Do `<LeftDrag>` events keep firing? What does getmousepos say mid-drag?

Yes. Every synthesized drag step fired the canvas `<LeftDrag>` mapping: 3 rows
down the bar, 6 rows down, and even after the pointer left the float
horizontally into the canvas body (wincol dropped from 47 to 37 and kept
reporting the true pointer position). `getmousepos()` mid-drag tracks the live
pointer (`winrow` moved 2 → 5 → 8 exactly as synthesized). Focus stayed on the
canvas the whole time. Task 4 must therefore clamp: a drag that wanders off
the bar column still arrives, carrying real canvas coordinates.

### Q4 — Does `nvim_input_mouse` reproduce this headlessly?

**Yes for coordinates in-process; yes for everything in a child `--embed`.**
The sharp edge: a `-l` script (i.e. `test/run.lua`'s process) NEVER runs the
main input loop, so a queued mouse event is never dispatched to a mapping —
`nvim_feedkeys("", "x", ...)`, `vim.wait()`, and `:sleep` all fail to pump it
(all measured). Two working recipes:

**In-process (fits the existing test suite).** `getchar(0)` consumes the
queued event RAW (no mapping fires), which updates the position
`getmousepos()` reads; then invoke the mapping's callback directly:

```lua
vim.api.nvim_input_mouse("left", "press", "", 0, screenrow0, screencol0) -- 0-based screen coords, grid 0
vim.fn.getchar(0)      -- consume: getmousepos() now reports exactly this event
press_cb()             -- the <LeftMouse> callback from nvim_buf_get_keymap(canvas_buf, "n")
-- repeat per step: input_mouse("left","drag",...) ; getchar(0) ; drag_cb()
```

This exercises the handler with real position resolution (including float
transparency) but NOT Neovim's dispatch choice.

**Child embed (true end-to-end, proven by Phase B).** Spawn a child, set up the
plugin inside it, and drive mouse over RPC — the child's main loop dispatches
real mappings between requests:

```lua
local chan = vim.fn.jobstart(
  { vim.v.progpath, "--headless", "--embed", "--clean" }, { rpc = true })
vim.rpcrequest(chan, "nvim_exec_lua", setup_code, { repo_root })
vim.rpcrequest(chan, "nvim_input_mouse", "left", "press", "", 0, row0, col0)
-- poll vim.rpcrequest(chan, "nvim_exec_lua", "return <observable>", {}) with a deadline
```

Coordinate recipe for both: `vim.fn.win_screenpos(float_win)` gives the
float's 1-based `{row, col}`; bar row `r` is screen row `row + (r - 1)`;
subtract 1 from each for `nvim_input_mouse`'s 0-based grid arguments.

## Surprises worth keeping

- The float being INVISIBLE to `getmousepos()` (winid is the canvas, not the
  float) is the load-bearing surprise: bar-hit detection must be column math
  on the canvas window, not a `winid == float` comparison.
- The default (unmapped) click passes THROUGH the float and moves the canvas
  cursor — today's minimap is already silently click-through.
- `'mouse'` defaults to `"nvi"`, which includes normal mode: mappings fire
  without the plugin touching the option. A user with `mouse=` gets no events
  at all — the feature must degrade to simply inert.

## What headless synthesis could NOT prove

- **Real terminal delivery** (the residual manual check): synthesis enters
  below the TTY layer, so nothing here proves a real terminal's mouse protocol
  reports drag motion to Neovim, nor at what granularity/throttle. Manual
  check for Task 4: in a real terminal over the open canvas, press the thumb,
  drag vertically, and confirm the handler receives a `<LeftDrag>` stream
  (e.g. via `:messages` logging) and the release.
- Dispatch when focus is NOT on the canvas (e.g. sidebar focused, user clicks
  the minimap): by the measured dispatch rule the SIDEBAR buffer's mapping (or
  the default window-switch) would receive that press, not the canvas mapping.
  Not exercised; Task 4 should decide whether first-click-focuses-then-drag is
  acceptable.
- GUI/`ext_multigrid` clients: grid 0 was used; multigrid front-ends were not
  exercised.

**Verdict:** GO — map press/drag/release buffer-locally on the canvas buffer,
detect the bar with `wincol == win width`, convert `winrow - winbar` to a bar
row, and test in-process via the consume-then-call recipe (plus one
child-embed test if end-to-end dispatch coverage is wanted).
