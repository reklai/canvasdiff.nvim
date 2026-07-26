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
  -- Lenses. States, not flips: see the public facade's set_lens.
  unstaged = { action = "set_lens", lens = "unstaged" },
  all      = { action = "set_lens", lens = "all" },
  staged   = { action = "set_lens", lens = "staged" },
}

--- Completion candidates, in the order they should be offered.
C.candidate_order = { "open", "close", "toggle", "refresh", "all", "unstaged", "staged" }

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

  -- Anything else names a revision. A bare ref is a LENS -- "worktree vs main" --
  -- whose new side is still the worktree, so it stays editable and is supported. A
  -- RANGE (`main...HEAD`, `v1..v2`) puts a commit on both sides, which would make
  -- the canvas a read-only viewer and lose the reason to use it; that stays
  -- unimplemented, and the grammar keeps it distinguishable.
  if arg:find("%.%.") then
    return { action = "range", rev = arg, errors = {} }
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
    -- Deliberately plans NO call: silently showing worktree-vs-HEAD when the
    -- user asked for `main...HEAD` would be worse than refusing, because the
    -- diff would look plausible and be wrong.
    return {
      diagnostic = {
        level = "warn",
        message = ("commit ranges are not supported (got '%s'). A bare ref works:"
          .. " `:CanvasDiff main` shows your worktree against it"):format(parse.rev),
      },
    }
  end

  return { call = parse.action }
end

--- Completion candidates for `arglead`. Pure.
---
--- Bare refs are supported, but refs are deliberately NOT offered yet because
--- branch-name enumeration/completion has not been implemented. Fixed command
--- words remain complete and deterministic in the meantime.
function C.complete(arglead)
  local out = {}
  for _, c in ipairs(C.candidate_order) do
    if c:sub(1, #arglead) == arglead then
      out[#out + 1] = c
    end
  end
  return out
end

return C
