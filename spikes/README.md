# Spikes

## Spike: minimap click routing (mouse over the non-focusable float)

**Command:**
```bash
nvim --headless --clean -l spikes/2026-08-01-minimap-click-routing/spike.lua
```

**Verdict:** GO — the non-focusable float is mouse-transparent: the CANVAS
buffer's mappings receive press/drag/release, `getmousepos()` reports the
canvas window (`wincol == window width` over the bar; use `winrow - winbar`
for the bar row, never `line`), and drags keep firing off the float. Headless
synthesis works in-process via `nvim_input_mouse` + `getchar(0)` +
calling the mapping callback, and end-to-end via a child `--embed` nvim over
RPC (a `-l` process alone never dispatches queued mouse input). Full answers
in [2026-08-01-minimap-click-routing/README.md](2026-08-01-minimap-click-routing/README.md).

## Spike: treesitter string-parser highlight extraction

**Command:**
```bash
nvim --headless --clean -l spikes/ts_string_parser.lua
```

**Measured Results:**
- Parse time: 45.2ms (limit: 100ms) ✓
- Extract + mark 200 lines: 8.72ms (limit: 16ms) ✓
- Mark count: 3600 (limit: >200) ✓

**Verdict:** GO — Whole-file `vim.treesitter.get_string_parser` parsing + capture extraction into extmarks is fast enough to power diff highlighting. All thresholds met with comfortable margin.

## Spike: zero-motion splice above viewport

**Command:**
```bash
nvim --headless --clean -l spikes/splice_zero_motion.lua
```

**Observed Output:**
```
before first visible: line 500
after  first visible: line 500
col before/after: 3/3
SPIKE PASS
```

**Verdict:** GO — Replacing lines above the viewport (lines 100-200 → 150 new lines) and correcting topline in the same tick leaves visible text pixel-identical. Before/after first visible line is `line 500`, cursor column matches (3/3), and topline offset equals the splice delta (+49). Headless floating windows + winsaveview work as expected. Core splice invariant is viable.
