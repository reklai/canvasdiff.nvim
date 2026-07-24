local H = require("helpers")
local cmd = require("galley.cmd")

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
    unstaged = "set_base", all = "set_base",
  }) do
    H.eq(cmd.parse({ word }).action, want, "'" .. word .. "' should be " .. want)
  end
end

-- States rather than a flip: a toggle inside a user mapping is a coin flip,
-- while `:Galley unstaged` must always land unstaged.
T["cmd_parse unstaged and all carry explicit bases"] = function()
  H.eq(cmd.parse({ "unstaged" }).base, "index", "unstaged = worktree vs index")
  H.eq(cmd.parse({ "all" }).base, "HEAD", "all = worktree vs HEAD")
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
T["cmd_parse anything else parses as a revision"] = function()
  for _, rev in ipairs({ "HEAD~3", "main...HEAD", "v1.0..v2.0", "deadbeef" }) do
    local p = cmd.parse({ rev })
    H.eq(p.action, "rev", rev .. " should parse as a revision")
    H.eq(p.rev, rev)
  end
end

T["cmd_parse reserved words beat same-named branches"] = function()
  -- A branch literally named "close" must not hijack the subcommand.
  H.eq(cmd.parse({ "close" }).action, "close")
  H.eq(cmd.parse({ "close" }).rev, nil)
end

-- --- completion --------------------------------------------------------

T["cmd_complete filters by prefix and offers every word"] = function()
  H.eq(cmd.complete(""), { "open", "close", "toggle", "refresh", "unstaged", "all" })
  H.eq(cmd.complete("c"), { "close" })
  H.eq(cmd.complete("un"), { "unstaged" })
  H.eq(cmd.complete("zzz"), {})
end

T["cmd_complete offers no refs while revision mode is unimplemented"] = function()
  -- Completing branch names for a mode that then refuses is worse than not
  -- completing them; this pins that until open_rev exists.
  for _, c in ipairs(cmd.complete("")) do
    assert(cmd.words[c], "completion offered '" .. c .. "', which is not a known word")
  end
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

T["cmd_run a revision reports and opens nothing"] = function()
  local canvas = require("galley.canvas")
  local before = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if canvas.is_canvas_buf(b) then before = before + 1 end
  end

  local msgs = capture(function() cmd.run(cmd.parse({ "main...HEAD" })) end)

  H.eq(#msgs, 1, "exactly one notification")
  assert(msgs[1].msg:match("not implemented"), "got: " .. msgs[1].msg)
  assert(msgs[1].msg:match("main%.%.%.HEAD"), "should quote the revspec, got: " .. msgs[1].msg)

  local after = 0
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if canvas.is_canvas_buf(b) then after = after + 1 end
  end
  H.eq(after, before, "refusing must not create a canvas as a side effect")
end

T["cmd_run an error is reported at ERROR level"] = function()
  local msgs = capture(function() cmd.run(cmd.parse({ "--staged" })) end)
  H.eq(#msgs, 1)
  H.eq(msgs[1].level, vim.log.levels.ERROR)
end

return T
