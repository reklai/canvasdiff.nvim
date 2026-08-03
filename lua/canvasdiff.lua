-- The public Lua API: everything `:h canvasdiff` documents enters here, and
-- nothing else in lua/canvasdiff/ is public surface (pre-alpha: this table
-- may still change; the internals definitely will). One process-wide App
-- instance owns every review; requiring this module is what installs the
-- global compare/checkout mappings, which is why lazy-loading setups must
-- own their trigger keys (see README "Lazy-loading correctly").
local App = require("canvasdiff.App")

local app = App.new()
app:sync_global_keymaps()

return {
  --- Merge `opts` into the configuration (see :h canvasdiff-setup). Entirely
  --- optional: every entry point works against the defaults when this is
  --- never called. Diagnostics are reported via vim.notify, not raised.
  --- @return table options the merged, active options
  setup = function(opts)
    return app:setup(opts)
  end,
  --- Open (or focus) the review canvas for the current window's repository.
  --- `opts.base` ("HEAD"|"index") overrides the saved session's base.
  --- Returns the review state, or nil plus a user-facing message when there
  --- is no repository or the collection failed.
  open = function(opts)
    return app:open(opts)
  end,
  --- Tear down the review shown in this tabpage: views, leases, session save.
  close = function()
    return app:close()
  end,
  --- close() if a canvas (or our sidebar) is showing in this tabpage,
  --- open() otherwise. Never errors.
  toggle = function()
    return app:toggle()
  end,
  --- Toggle the file-tree sidebar of the showing review. Warns instead of
  --- opening a review when none is showing.
  sidebar = function()
    return app:toggle_sidebar()
  end,
  --- Re-collect the diff and splice changes in place, keeping the same text
  --- under the cursor. For a buffer/state divergence, close() + open() is
  --- the recovery path, not this.
  refresh = function()
    return app:refresh()
  end,
  --- Point the canvas at a named lens ("all" | "unstaged" | "staged").
  --- Idempotent, and opens the canvas when none is showing: a command that
  --- names a state must always land on that state.
  set_lens = function(value)
    return app:set_lens(value)
  end,
  --- Step the lens cycle all → unstaged → staged by `delta` (default 1).
  --- Warns rather than opening when no canvas is showing.
  cycle_lens = function(delta)
    return app:cycle_lens(delta)
  end,
  --- Compare the worktree against `ref` (e.g. "main", "origin/main"). The
  --- new side stays the editable worktree.
  set_branch = function(ref)
    return app:set_branch(ref)
  end,
  --- Set the diff base: "HEAD" (the all lens) or "index" (unstaged).
  set_base = function(base)
    return app:set_base(base)
  end,
  --- Flip between the HEAD and index bases. Warns when nothing is showing.
  toggle_base = function()
    return app:toggle_base()
  end,
  --- Stage the file under the canvas cursor. Refused with a report -- not
  --- an error -- when a modified loaded buffer aliases the path, so unsaved
  --- text is never silently replaced.
  stage = function()
    return app:stage()
  end,
  --- Unstage the file under the canvas cursor. Never writes the worktree.
  unstage = function()
    return app:unstage()
  end,
  --- Return from a jump excursion into the live review's canvas. Returns
  --- true when a review was there to return to; with none, reports in the
  --- user's terms and returns false.
  jump_back = function(opts)
    return app:jump_back(nil, nil, type(opts) == "table" and opts.win or opts)
  end,
  --- Run one `:CanvasDiff` invocation from its raw arguments. Returns the
  --- parsed-and-executed command outcome; bad grammar reports and does not
  --- raise.
  command = function(fargs)
    return app:command(fargs)
  end,
  --- Completion candidates for `:CanvasDiff`, resolved from the command
  --- window's repository.
  command_complete = function(arglead)
    return app:command_complete(arglead)
  end,
  --- Pick a merge-base comparison from a branch list. Read-only: never
  --- changes refs or repository state.
  compare = function()
    return app:compare()
  end,
  --- Select and switch to one exact local branch. Refuses repositories with
  --- unsaved buffers; no force, stash, or detached-HEAD paths exist.
  checkout = function()
    return app:checkout()
  end,
  --- Create a local branch tracking one exact remote-tracking ref, then
  --- switch to it. Same refusals as checkout().
  track = function()
    return app:track()
  end,
  --- Point the canvas at a committed range ("main..topic" or an already
  --- normalized range lens). Committed ranges are read-only.
  set_range = function(spec)
    return app:set_range(spec)
  end,
}
