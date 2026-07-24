-- `:Galley` argument grammar.
--
-- Split into a pure parser and an impure runner so the whole grammar is
-- table-testable with no windows and no git.
--
-- The surface is deliberately small: the canvas is modal, so once you are
-- inside it you press keys rather than typing `:`. Every word here earns its
-- place by being useful from OUTSIDE the canvas, or inside a user mapping.

local util = require("galley.util")

local C = {}

--- Words that name an action. Checked before revision parsing, so a branch
--- named "close" can never hijack the subcommand.
--- @type table<string, { action: string, base: string? }>
C.words = {
  open     = { action = "open" },
  close    = { action = "close" },
  toggle   = { action = "toggle" },
  refresh  = { action = "refresh" },
  -- States, not a flip: see init.set_base.
  unstaged = { action = "set_base", base = "index" },
  all      = { action = "set_base", base = "HEAD" },
}

--- Completion candidates, in the order they should be offered.
C.candidate_order = { "open", "close", "toggle", "refresh", "unstaged", "all" }

-- `git diff --staged` means index-vs-HEAD (the STAGED changes), which is the
-- exact opposite of base="index" (worktree-vs-index, the UNSTAGED changes) and
-- is content this plugin cannot render at all today. Aliasing them would bake
-- a contradiction with git's own vocabulary into the UI permanently, so these
-- are refused by name rather than quietly redirected.
local REFUSED_FLAGS = {
  ["--staged"] = true,
  ["--cached"] = true,
}

--- @class GalleyParse
--- @field action string  "toggle"|"open"|"close"|"refresh"|"set_base"|"rev"|"error"
--- @field base string|nil
--- @field rev string|nil
--- @field errors string[]

--- Parse `fargs`. Pure: no git, no vim state, no side effects.
--- @param fargs string[]|nil
--- @return GalleyParse
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
      errors = { ("%s means index vs HEAD (the staged changes), which galley cannot show yet."
        .. " Use 'unstaged' for worktree vs index, or 'all' for worktree vs HEAD"):format(arg) },
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
    return { action = word.action, base = word.base, errors = {} }
  end

  -- Anything else is treated as a revision spec. Not implemented yet, but
  -- parsed here so that adding range mode later needs no grammar change.
  return { action = "rev", rev = arg, errors = {} }
end

--- Execute a parse. Impure.
function C.run(parse)
  if parse.action == "error" then
    util.err(parse.errors[1])
    return
  end

  local fm = require("galley")

  if parse.action == "set_base" then
    fm.set_base(parse.base)
    return
  end

  if parse.action == "rev" then
    -- Deliberately does NOT fall through to a toggle: silently showing
    -- worktree-vs-HEAD when the user asked for `main...HEAD` would be worse
    -- than refusing, because the diff would look plausible and be wrong.
    if fm.open_rev then
      fm.open_rev(parse.rev)
    else
      util.warn(("revision mode is not implemented yet (got '%s')"):format(parse.rev))
    end
    return
  end

  fm[parse.action]()
end

--- Completion candidates for `arglead`. Pure.
---
--- Refs are deliberately NOT offered yet: completing branch names for a mode
--- that then reports "not implemented" is worse than not completing them.
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
