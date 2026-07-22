# Spikes

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
