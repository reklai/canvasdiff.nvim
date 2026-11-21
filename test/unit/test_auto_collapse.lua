local H = require("helpers")
local diff = require("canvasdiff.diff")
local format = require("canvasdiff.canvas").format
local ac = diff.auto_collapse

local T = {}

T["auto_collapse_ match_glob handles basename and path globs case-insensitively"] = function()
  H.eq(ac.match_glob("package-lock.json", "*lock*"), true)
  H.eq(ac.match_glob("frontend/pnpm-lock.yaml", "*lock*"), true)
  H.eq(ac.match_glob("Cargo.LOCK", "*.lock"), true)
  H.eq(ac.match_glob("dist/app.min.js", "*.min.js"), true)
  H.eq(ac.match_glob("vendor/pkg/a.go", "vendor/*"), true)
  H.eq(ac.match_glob("src/vendor/a.go", "vendor/*"), false)
  H.eq(ac.match_glob("src/main.lua", "*lock*"), false)
  H.eq(ac.match_glob("a.txt", "?.txt"), true)
  H.eq(ac.match_glob("ab.txt", "?.txt"), false)
end

T["auto_collapse_ classify honors enabled, gitattributes, patterns, max_lines, and max_bytes"] = function()
  local opts = {
    enabled = true,
    max_lines = 500,
    max_bytes = 262144,
    patterns = { "*lock*", "*.min.js" },
    gitattributes = true,
  }

  H.eq(ac.classify("src/app.lua", { adds = 10, dels = 5, bytes = 400 }, nil, opts), nil)
  H.eq(ac.classify("package-lock.json", { adds = 2, dels = 1, bytes = 100 }, nil, opts), "generated")
  H.eq(ac.classify("src/gen.ts", { adds = 2, dels = 1 }, { generated = true }, opts), "generated")
  H.eq(ac.classify("src/nodiff.dat", { adds = 0, dels = 0 }, { no_diff = true }, opts), "generated")
  H.eq(ac.classify("src/big.lua", { adds = 300, dels = 201, bytes = 1000 }, nil, opts), "large")
  H.eq(ac.classify("src/huge.json", { adds = 1, dels = 0, bytes = 300000 }, nil, opts), "large")

  -- Threshold boundaries are strict (`>`), not `>=`.
  H.eq(ac.classify("src/edge.lua", { adds = 250, dels = 250, bytes = 262144 }, nil, opts), nil)

  -- Disabling rules suppresses classification.
  H.eq(ac.classify("package-lock.json", { adds = 5000, dels = 5000 }, { generated = true },
    vim.tbl_extend("force", opts, { enabled = false })), nil)
  H.eq(ac.classify("src/gen.ts", { adds = 1, dels = 1 }, { generated = true },
    vim.tbl_extend("force", opts, { gitattributes = false })), nil)
end

T["auto_collapse_ deferred_section formats honest summaries without fake hunk counts"] = function()
  local gen = diff.deferred_section("package-lock.json", "M", { adds = 420, dels = 110 }, {
    defer_reason = "generated",
  })
  H.eq(gen.deferred, true)
  H.eq(gen.nhunks, nil)
  H.eq(#gen.entries, 1)
  H.eq(format.summary(gen), "(generated, +420 −110)")

  local large = diff.deferred_section("huge.txt", "M", { adds = 1000, dels = 0 }, {
    defer_reason = "large",
  })
  H.eq(format.summary(large), "(large, +1000 −0)")

  local folded = diff.deferred_section("src/a.lua", "M", { adds = 4, dels = 2 }, {
    defer_reason = "folded",
  })
  H.eq(format.summary(folded), "(+4 −2)")

  local empty_deferred = diff.deferred_section("big.bin", "?", { adds = 0, dels = 0 }, {
    defer_reason = "large",
  })
  H.eq(format.summary(empty_deferred), "(large)")

  local bin = diff.deferred_section("img.png", "M", { adds = 0, dels = 0, binary = true }, {
    defer_reason = "generated",
  })
  H.eq(format.summary(bin), "(binary)")
end

return T
