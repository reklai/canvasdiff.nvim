-- `:CanvasDiff` argument grammar.
--
-- Split into a pure parser and an impure runner so the whole grammar is
-- table-testable with no windows and no git.
--
-- The surface is deliberately small: the canvas is modal, so once you are
-- inside it you press keys rather than typing `:`. Every word here earns its
-- place by being useful from OUTSIDE the canvas, or inside a user mapping.

local lens = require("canvasdiff.diff").lens

local C = {}

--- Words that name an action. Checked before revision parsing, so a branch
--- named "close" can never hijack the subcommand.
--- @type table<string, { action: string, lens: string? }>
C.words = {
  open     = { action = "open" },
  close    = { action = "close" },
  toggle   = { action = "toggle" },
  refresh  = { action = "refresh" },
  compare  = { action = "compare" },
  -- Lenses. States, not flips: see the public facade's set_lens.
  unstaged = { action = "set_lens", lens = "unstaged" },
  all      = { action = "set_lens", lens = "all" },
  staged   = { action = "set_lens", lens = "staged" },
}

--- Completion candidates, in the order they should be offered.
C.candidate_order = {
  "open", "close", "toggle", "refresh", "compare", "all", "unstaged", "staged",
}

-- `git diff --staged` (and its `--cached` synonym) means index-vs-HEAD, which the
-- `staged` lens now renders -- but the flag spelling stays refused rather than
-- aliased, because `--staged` is one keystroke from `unstaged` and they mean OPPOSITE
-- things. Quietly accepting it would make a typo silently show the complement of what
-- was asked for. Refused by name, pointing at the word that works.
local REFUSED_FLAGS = {
  ["--staged"] = true,
  ["--cached"] = true,
}

--- @class CanvasDiffParse
--- @field action string  "toggle"|"open"|"close"|"refresh"|"set_lens"|"rev"|"range"|"error"
--- @field base string|nil
--- @field lens string|nil  named lens id, set only when action is "set_lens"
--- @field rev string|nil
--- @field errors string[]

--- Parse `fargs`. Pure: no git, no vim state, no side effects.
--- @param fargs string[]|nil
--- @return CanvasDiffParse
function C.parse(fargs)
  fargs = fargs or {}

  if #fargs == 0 then
    return { action = "toggle", errors = {} }
  end

  if #fargs > 1 then
    return {
      action = "error",
      errors = { ("expected at most one argument, got %d (%s)")
        :format(#fargs, table.concat(fargs, " ")) },
    }
  end

  local arg = fargs[1]

  if REFUSED_FLAGS[arg] then
    return {
      action = "error",
      errors = { ("%s means index vs HEAD — say 'staged' instead."
        .. " ('unstaged' is worktree vs index, the opposite.)"):format(arg) },
    }
  end

  if arg:sub(1, 1) == "-" then
    return {
      action = "error",
      errors = { ("unknown flag '%s' (try: %s)"):format(arg, table.concat(C.candidate_order, ", ")) },
    }
  end

  local word = C.words[arg]
  if word then
    return { action = word.action, lens = word.lens, errors = {} }
  end

  -- Anything else names a revision. A bare ref is "worktree vs ref". A range
  -- puts commits on both sides and is read-only. Three dots must be recognized
  -- before two; an omitted side has Git's usual HEAD meaning.
  local operator, at
  at = arg:find("...", 1, true)
  if at then
    operator = "..."
  else
    at = arg:find("..", 1, true)
    if at then
      operator = ".."
    end
  end
  if operator then
    local left = arg:sub(1, at - 1)
    local right = arg:sub(at + #operator)
    return {
      action = "range",
      rev = arg,
      left = left ~= "" and left or "HEAD",
      right = right ~= "" and right or "HEAD",
      operator = operator,
      errors = {},
    }
  end
  return { action = "rev", rev = arg, errors = {} }
end

--- @class CanvasDiffCommand
--- @field call string|nil       operation the owner should perform
--- @field argument any|nil      that operation's single argument
--- @field diagnostic { level: "error"|"warn", message: string }|nil

--- Turn a parse into what the owner should DO, without doing any of it.
---
--- Input never presents messages and never calls back into the application:
--- both would make the domain graph cyclic, and neither is testable without a
--- window. The owner executes the call and shows the diagnostic.
--- @param parse CanvasDiffParse
--- @return CanvasDiffCommand
function C.plan(parse)
  if parse.action == "error" then
    return { diagnostic = { level = "error", message = parse.errors[1] } }
  end

  if parse.action == "set_lens" then
    return { call = "set_lens", argument = lens.get(parse.lens) }
  end

  if parse.action == "rev" then
    return { call = "set_branch", argument = parse.rev }
  end

  if parse.action == "range" then
    return {
      call = "set_range",
      argument = lens.range(parse.left, parse.right, parse.operator),
    }
  end

  return { call = parse.action }
end

--- Completion candidates for `arglead`. Pure; repository inspection belongs
--- to the App owner, which passes branch metadata in.
function C.complete(arglead, refs)
  local out = {}
  local seen = {}
  local operator, at
  at = arglead:find("...", 1, true)
  if at then
    operator = "..."
  else
    at = arglead:find("..", 1, true)
    if at then
      operator = ".."
    end
  end
  local prefix = ""
  local lead = arglead
  if operator then
    prefix = arglead:sub(1, at + #operator - 1)
    lead = arglead:sub(at + #operator)
  else
    for _, c in ipairs(C.candidate_order) do
      if c:sub(1, #lead) == lead then
        out[#out + 1] = c
        seen[c] = true
      end
    end
  end
  for _, branch in ipairs(refs or {}) do
    local name = type(branch) == "table" and branch.name or branch
    if type(name) == "string" and name:sub(1, #lead) == lead then
      local candidate = prefix .. name
      if not seen[candidate] then
        out[#out + 1] = candidate
        seen[candidate] = true
      end
    end
  end
  return out
end

return C
