local H = require("helpers")
local fold = require("galley.fold")

local T = {}

local function sections(...)
  local out = {}
  for _, path in ipairs({ ... }) do
    out[#out + 1] = { path = path, entries = {} }
  end
  return out
end

-- --- F.hides -----------------------------------------------------------

T["fold_hides matches a folded ancestor at any depth"] = function()
  H.eq(fold.hides({ ["lua/"] = true }, "lua/x.lua"), true, "immediate parent")
  H.eq(fold.hides({ ["lua/"] = true }, "lua/mod/deep/x.lua"), true, "distant ancestor")
  H.eq(fold.hides({ ["lua/mod/"] = true }, "lua/mod/x.lua"), true, "nested key")
  H.eq(fold.hides({ ["lua/mod/"] = true }, "lua/x.lua"), false, "not under it")
  H.eq(fold.hides({ ["b/"] = true }, "a/x.lua"), false, "unrelated dir")
end

-- The trailing slash on fold keys is the whole reason this works. Without it
-- "lua/mod" would prefix-match "lua/modules/x.lua" and folding one directory
-- would silently hide its string-prefix siblings.
T["fold_hides does not match a string-prefix sibling directory"] = function()
  local folded = { ["lua/mod/"] = true }
  H.eq(fold.hides(folded, "lua/modules/x.lua"), false, "modules/ is not mod/")
  H.eq(fold.hides(folded, "lua/mod2/x.lua"), false, "mod2/ is not mod/")
  H.eq(fold.hides(folded, "lua/mod/x.lua"), true, "the real child still matches")
  H.eq(fold.hides({ ["ab/"] = true }, "abc/x.lua"), false, "abc/ is not ab/")
end

T["fold_hides is false for a root-level file and nil-safe"] = function()
  H.eq(fold.hides({ ["lua/"] = true }, "README.md"), false, "no ancestor to fold")
  H.eq(fold.hides(nil, "lua/x.lua"), false, "nil folded set")
  H.eq(fold.hides({}, "lua/x.lua"), false, "empty folded set")
  H.eq(fold.hides({ ["lua/"] = true }, nil), false, "nil path")
end

-- --- F.folds_hiding ----------------------------------------------------

T["fold_folds_hiding returns every ancestor, outermost first"] = function()
  local folded = { ["lua/"] = true, ["lua/mod/"] = true }
  H.eq(fold.folds_hiding(folded, "lua/mod/x.lua"), { "lua/", "lua/mod/" },
    "both ancestors, shallowest first -- revealing must clear the whole chain")
  H.eq(fold.folds_hiding({ ["lua/mod/"] = true }, "lua/mod/deep/x.lua"), { "lua/mod/" },
    "only the folded one, not every ancestor")
  H.eq(fold.folds_hiding({}, "lua/x.lua"), {}, "nothing hides it")
  H.eq(fold.folds_hiding(nil, "lua/x.lua"), {}, "nil-safe")
end

-- --- F.hidden ----------------------------------------------------------

T["fold_hidden is the OR of collapsed and folded"] = function()
  local function st(collapsed, folded)
    return { collapsed = collapsed, folded = folded }
  end
  local p = "lua/x.lua"
  H.eq(fold.hidden(st({}, {}), p), false, "neither")
  H.eq(fold.hidden(st({ [p] = true }, {}), p), true, "collapsed outright")
  H.eq(fold.hidden(st({}, { ["lua/"] = true }), p), true, "folded ancestor")
  H.eq(fold.hidden(st({ [p] = true }, { ["lua/"] = true }), p), true, "both")
end

T["fold_hidden is nil-safe on state and its tables"] = function()
  H.eq(fold.hidden(nil, "lua/x.lua"), false, "nil state")
  H.eq(fold.hidden({}, "lua/x.lua"), false, "state without either table")
  H.eq(fold.hidden({ collapsed = { ["lua/x.lua"] = true } }, "lua/x.lua"), true,
    "collapsed without folded")
  H.eq(fold.hidden({ folded = { ["lua/"] = true } }, "lua/x.lua"), true,
    "folded without collapsed")
end

-- --- F.hidden_set ------------------------------------------------------

T["fold_hidden_set covers both axes over plain tables"] = function()
  local secs = sections("a/one.txt", "a/two.txt", "b/three.txt", "root.md")
  H.eq(fold.hidden_set(secs, { ["root.md"] = true }, { ["a/"] = true }), {
    ["a/one.txt"] = true,
    ["a/two.txt"] = true,
    ["root.md"] = true,
  }, "folded dir plus a collapsed file")
  H.eq(fold.hidden_set(secs, nil, nil), {}, "nil-safe, nothing hidden")
  H.eq(fold.hidden_set(nil, nil, nil), {}, "nil sections")
end

-- --- F.indices_under ---------------------------------------------------

T["fold_indices_under is ascending and contiguous"] = function()
  local secs = sections("a/one.txt", "a/two.txt", "b/three.txt", "root.md")
  H.eq(fold.indices_under(secs, "a/"), { 1, 2 }, "both files under a/")
  H.eq(fold.indices_under(secs, "b/"), { 3 }, "single file")
  H.eq(fold.indices_under(secs, "z/"), {}, "no match")
  H.eq(fold.indices_under(secs, ""), {}, "empty dir never matches everything")
  H.eq(fold.indices_under(secs, nil), {}, "nil-safe")
end

T["fold_indices_under respects the directory boundary"] = function()
  local secs = sections("lua/mod/x.lua", "lua/modules/y.lua")
  H.eq(fold.indices_under(secs, "lua/mod/"), { 1 },
    "modules/ must not be swept up with mod/")
  H.eq(fold.indices_under(secs, "lua/"), { 1, 2 }, "the shared parent takes both")
end

return T
