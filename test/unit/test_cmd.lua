local H = require("helpers")
local cmd = require("canvasdiff.input").command

local T = {}

-- --- pure parsing ------------------------------------------------------

T["cmd_parse bare invocation toggles"] = function()
  local p = cmd.parse({})
  H.eq(p.action, "toggle")
  H.eq(p.errors, {})
  H.eq(cmd.parse(nil).action, "toggle", "nil fargs behaves like none")
end

T["cmd_parse each word maps to its action"] = function()
  for word, want in pairs({
    open = "open", close = "close", toggle = "toggle", refresh = "refresh",
    compare = "compare", checkout = "checkout", track = "track",
    unstaged = "set_lens", all = "set_lens", staged = "set_lens",
  }) do
    H.eq(cmd.parse({ word }).action, want, "'" .. word .. "' should be " .. want)
  end
end

-- States rather than a flip: a toggle inside a user mapping is a coin flip,
-- while `:CanvasDiff unstaged` must always land unstaged.
T["cmd_parse each lens word names its lens"] = function()
  H.eq(cmd.parse({ "all" }).lens, "all", "worktree vs HEAD")
  H.eq(cmd.parse({ "unstaged" }).lens, "unstaged", "worktree vs index")
  -- The one the plugin could not express before lenses: index vs HEAD.
  H.eq(cmd.parse({ "staged" }).lens, "staged", "index vs HEAD")
end

T["cmd_parse too many arguments is a named error"] = function()
  local p = cmd.parse({ "close", "extra" })
  H.eq(p.action, "error")
  H.eq(#p.errors, 1)
  assert(p.errors[1]:match("at most one"), "got: " .. p.errors[1])
  assert(p.errors[1]:match("extra"), "should quote what was passed, got: " .. p.errors[1])
end

-- git's `--staged` is index-vs-HEAD, the exact opposite of base="index".
-- Aliasing them would show the wrong content under git's own word.
T["cmd_parse --staged is refused, never aliased to unstaged"] = function()
  for _, flag in ipairs({ "--staged", "--cached" }) do
    local p = cmd.parse({ flag })
    H.eq(p.action, "error", flag .. " must not resolve to an action")
    assert(p.errors[1]:match("unstaged"),
      "must point at the word that does work, got: " .. p.errors[1])
    assert(p.errors[1]:match("index vs HEAD"),
      "and explain what it actually means, got: " .. p.errors[1])
  end
end

T["cmd_parse an unknown flag lists the real words"] = function()
  local p = cmd.parse({ "--bogus" })
  H.eq(p.action, "error")
  assert(p.errors[1]:match("unknown flag"), "got: " .. p.errors[1])
  assert(p.errors[1]:match("unstaged"), "should list valid words, got: " .. p.errors[1])
end

-- The grammar reserves revision specs now so that adding range mode later is
-- not a breaking change to the command surface.
-- A bare ref is a supported lens (worktree vs that ref, still editable). A range
-- puts a commit on BOTH sides, so the grammar keeps the editable and read-only
-- comparisons distinct.
T["cmd_parse distinguishes bare refs from two and three dot ranges"] = function()
  for _, ref in ipairs({ "HEAD~3", "main", "deadbeef", "origin/main" }) do
    local p = cmd.parse({ ref })
    H.eq(p.action, "rev", ref .. " should parse as a bare ref")
    H.eq(p.rev, ref)
  end
  for _, range in ipairs({
    { "main...HEAD", "main", "HEAD", "..." },
    { "v1.0..v2.0", "v1.0", "v2.0", ".." },
  }) do
    local p = cmd.parse({ range[1] })
    H.eq(p.action, "range", range[1] .. " should parse as a range")
    H.eq({ p.left, p.right, p.operator }, { range[2], range[3], range[4] })
  end
end

T["cmd_parse omitted range endpoints mean HEAD"] = function()
  for _, case in ipairs({
    { "..topic", "HEAD", "topic", ".." },
    { "main..", "main", "HEAD", ".." },
    { "...topic", "HEAD", "topic", "..." },
    { "main...", "main", "HEAD", "..." },
    { "..", "HEAD", "HEAD", ".." },
    { "...", "HEAD", "HEAD", "..." },
  }) do
    local p = cmd.parse({ case[1] })
    H.eq(p.action, "range", case[1])
    H.eq({ p.left, p.right, p.operator }, { case[2], case[3], case[4] }, case[1])
  end
end

T["cmd_parse reserved words beat same-named branches"] = function()
  -- A branch literally named after an action must not hijack the subcommand.
  for _, word in ipairs({ "close", "checkout", "track", "sidebar" }) do
    H.eq(cmd.parse({ word }).action, word)
    H.eq(cmd.parse({ word }).rev, nil)
  end
end

-- --- completion --------------------------------------------------------

T["cmd_complete filters by prefix and offers every word"] = function()
  H.eq(cmd.complete("", {}), {
    "open", "close", "toggle", "refresh", "sidebar", "compare", "checkout",
    "track", "all", "unstaged", "staged",
  })
  H.eq(cmd.complete("c", {}), { "close", "compare", "checkout" })
  H.eq(cmd.complete("t", {}), { "toggle", "track" })
  H.eq(cmd.complete("un"), { "unstaged" })
  H.eq(cmd.complete("s"), { "sidebar", "staged" })
  H.eq(cmd.complete("zzz"), {})
  H.eq(cmd.complete("re"), { "refresh" })
end

T["cmd_complete offers branch names and preserves a range prefix"] = function()
  local refs = {
    { ref = "refs/heads/main", name = "main", kind = "local", current = true },
    { ref = "refs/remotes/origin/main", name = "origin/main", kind = "remote" },
    { ref = "refs/remotes/origin/topic", name = "origin/topic", kind = "remote" },
  }
  H.eq(cmd.complete("ma", refs), { "main" })
  H.eq(cmd.complete("origin/", refs), { "origin/main", "origin/topic" })
  H.eq(cmd.complete("main..ori", refs), {
    "main..origin/main", "main..origin/topic",
  })
  H.eq(cmd.complete("...ori", refs), {
    "...origin/main", "...origin/topic",
  })
end

-- --- running -----------------------------------------------------------

local function capture(fn)
  local real = vim.notify
  local msgs = {}
  vim.notify = function(msg, level) msgs[#msgs + 1] = { msg = msg, level = level } end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, err)
  return msgs
end

T["cmd_run an error is reported at ERROR level"] = function()
  local msgs = capture(function()
    require("canvasdiff").command({ "--staged" })
  end)
  H.eq(#msgs, 1)
  H.eq(msgs[1].level, vim.log.levels.ERROR)
end

-- --- planning ----------------------------------------------------------
--
-- The grammar produces data, not effects. Input neither presents messages nor
-- calls back into the application: doing either would put a cycle in the
-- domain graph and make the whole grammar untestable without a window.

T["cmd_plan every action names an operation the root facade exposes"] = function()
  local root = require("canvasdiff")
  for _, word in ipairs(cmd.candidate_order) do
    local outcome = cmd.plan(cmd.parse({ word }))
    assert(outcome.call, "'" .. word .. "' must plan an operation")
    H.eq(type(root[outcome.call]), "function",
      "'" .. word .. "' planned " .. outcome.call .. ", which the facade lacks")
    H.eq(outcome.diagnostic, nil, "a known word needs no diagnostic")
  end
  H.eq(cmd.plan(cmd.parse({})).call, "toggle", "a bare invocation toggles")
end

T["cmd_plan a lens word resolves its lens rather than passing a name"] = function()
  local outcome = cmd.plan(cmd.parse({ "staged" }))
  H.eq(outcome.call, "set_lens")
  H.eq(outcome.argument, require("canvasdiff.diff").lens.get("staged"))
end

T["cmd_plan checkout and track retain their reserved operation names"] = function()
  H.eq(cmd.plan(cmd.parse({ "checkout" })), { call = "checkout" })
  H.eq(cmd.plan(cmd.parse({ "track" })), { call = "track" })
end

T["cmd_plan a bare ref becomes a branch change"] = function()
  local outcome = cmd.plan(cmd.parse({ "main" }))
  H.eq(outcome.call, "set_branch")
  H.eq(outcome.argument, "main")
end

T["cmd_plan ranges construct committed lenses with normalized endpoints"] = function()
  local two = cmd.plan(cmd.parse({ "main.." }))
  H.eq(two.call, "set_range")
  H.eq(two.argument, require("canvasdiff.diff").lens.range("main", "HEAD", ".."))

  local three = cmd.plan(cmd.parse({ "...topic" }))
  H.eq(three.call, "set_range")
  H.eq(three.argument, require("canvasdiff.diff").lens.range("HEAD", "topic", "..."))
end

T["cmd_plan refusals carry a level and plan no operation"] = function()
  local refused = cmd.plan(cmd.parse({ "--cached" }))
  H.eq(refused.call, nil)
  H.eq(refused.diagnostic.level, "error")
  assert(refused.diagnostic.message:match("staged"), refused.diagnostic.message)
end

T["cmd_plan the input domain reaches neither UI nor the root facade"] = function()
  local source = assert(io.open(
    vim.fs.joinpath(H.project_root, "lua/canvasdiff/input/command.lua"), "rb"))
  local text = source:read("*a")
  source:close()
  assert(not text:find('require("canvasdiff.ui")', 1, true),
    "input must not present its own messages")
  assert(not text:find('require("canvasdiff")', 1, true),
    "input must not call back into the application")
end

return T
