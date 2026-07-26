local canvas = require("galley.canvas")
local git = require("galley.git")
local model = require("galley.model")
local jump = require("galley.jump")
local config = require("galley.config")
local hl = require("galley.hl")
local collect = require("galley.collect")
local watch = require("galley.watch")
local sidebar = require("galley.sidebar")
local scrollbar = require("galley.scrollbar")
local virt = require("galley.virt")
local motions = require("galley.motions")
local statuscol = require("galley.statuscol")
local session = require("galley.session")
local util = require("galley.util")
local keys = require("galley.keys")
local fold = require("galley.fold")
local lens = require("galley.lens")

local M = {}

local EMPTY_MSG = "-- no changes --"

--- Is `st`'s canvas actually live and on screen right now? `state` outlives
--- M.close (the canvas buffer is cached and reopened), so a bare nil check
--- is not enough to tell an open canvas from a closed one.
---
--- Keys on state.win, which the scrollbar/hl/statuscolumn refresh on
--- BufWinEnter -- with all three disabled it can go stale, and multi-window
--- canvas display is a documented MVP limitation anyway. Note M.close
--- deliberately does NOT use this: it tests the CURRENT window instead, for
--- the reasons in its own docstring.
local function canvas_showing(st)
  return st.win and vim.api.nvim_win_is_valid(st.win)
    and vim.api.nvim_win_get_buf(st.win) == st.buf
end

-- The single live canvas excursion state, cached across close()/open() so
-- the canvas buffer content survives being hidden (canvas.lua itself keeps
-- the scratch buffer alive; this just remembers our bookkeeping around it:
-- the git root and the window's previous buffer).
local state = nil

--- Public setup: merge user options into the config module. Entirely
--- optional -- every code path below works fine against config.defaults
--- when setup() is never called.
function M.setup(opts)
  return config.setup(opts)
end

--- Show which lens the canvas is looking through, in a winbar on its own window.
---
--- Until now the only signal was a one-shot `vim.notify` on change, so once the
--- message faded there was nothing on screen telling you whether you were looking at
--- everything, at what you hadn't staged, or at what you had. For a canvas whose
--- whole premise is pivoting between those, that is the difference between a control
--- and a guessing game.
---
--- `""` clears it, which is what M.close wants -- a leftover winbar on a restored
--- window would claim the file you are editing is a diff canvas.
---
--- The text is a statusline expression, so `%` in a branch ref has to be escaped.
--- scrollbar.text_geometry accounts for the row this consumes; see the note there.
--- The path of the section under the canvas topline, or nil when the canvas is not on
--- screen (a jump excursion, or a closed window) or holds nothing.
---
--- Resolved from the topline rather than the cursor, matching the sidebar's active
--- row exactly, so the two never disagree about which file you are "in".
local function path_under_top(st)
  if not canvas_showing(st) or #st.sections == 0 then
    return nil
  end
  local top0 = vim.api.nvim_win_call(st.win, function()
    return vim.fn.line("w0") - 1
  end)
  local i = (canvas.locate(st, top0))
  return i and st.sections[i] and st.sections[i].path or nil
end

local function set_winbar(st, text)
  if not (st and st.win and vim.api.nvim_win_is_valid(st.win)) then
    return
  end
  if text == nil then
    -- The STICKY part, and the reason this is worth recomputing on scroll: a file
    -- header scrolls out of view as soon as you are a screen into its diff, and from
    -- then on nothing IN the canvas says which block you are reading. The sidebar
    -- knows, but peripherally and only if it is enabled. This keeps the answer on the
    -- canvas itself.
    local here = path_under_top(st)
    local file = here and ("  │  " .. here) or ""

    text = ("  galley: " .. lens.of(st).label .. file):gsub("%%", "%%%%")
  end
  -- Skipped when nothing changed, because this runs on every WinScrolled and writing
  -- 'winbar' forces a redraw of the window. Comparing the resolved string also covers
  -- the common case of scrolling WITHIN one file, where the text is identical and only
  -- path_under_top's work was wasted.
  if st.winbar_text == text then
    return
  end
  st.winbar_text = text
  pcall(vim.api.nvim_set_option_value, "winbar", text, { win = st.win, scope = "local" })
end

--- Stop every subsystem attached to `st` and persist its session -- everything
--- M.close does EXCEPT putting windows back, because by the time this runs the
--- window may already be gone.
---
--- That separation is the whole point: `:q` destroys the canvas window without
--- coming through M.close, and watch's only lifecycle hook is BufWipeout on the
--- canvas buffer -- which is `bufhidden = "hide"`, so `:q` hides it and the hook
--- never fires. Left unreached, watch keeps its fs_event handles armed and keeps
--- running a blocking `git status` plus a `git show` per changed file on every
--- write in the repo, splicing a buffer nobody can see.
---
--- Every step is idempotent and nil-safe, so calling this twice is fine.
local function teardown(st)
  if config.options.session.enabled then
    session.save(st)
  end
  pcall(vim.api.nvim_del_augroup_by_name, "galley.session")
  pcall(vim.api.nvim_del_augroup_by_name, "galley.close")
  -- Left armed, this keeps resolving sections against a torn-down state on every
  -- scroll in any window.
  pcall(vim.api.nvim_del_augroup_by_name, "galley.winbar")

  watch.stop()
  hl.detach(st)
  sidebar.close()
  scrollbar.close()
  virt.detach()
  statuscol.detach()
  -- Before restore_window hands the window back: a leftover winbar would claim
  -- whatever file lands there is a diff canvas.
  set_winbar(st, "")
end

local function show_empty_message(st)
  vim.api.nvim_set_option_value("modifiable", true, { buf = st.buf })
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { EMPTY_MSG })
  vim.api.nvim_set_option_value("modifiable", false, { buf = st.buf })
end

--- Refresh the other live UI pieces after a direct canvas.set_collapsed
--- splice (mirrors what jump.back/M.refresh already do after their own
--- canvas splices): reapply lazy highlighting and sync sidebar/scrollbar.
local function sync_after_collapse(st)
  hl.apply_now(st)
  sidebar.refresh(st)
  scrollbar.update(st)
end

--- Set section i's collapse state on behalf of the USER (the <Tab>/za/<CR>
--- keymaps). set_collapsed's default intent records exactly that, which is what
--- stops the auto-virtualizer expanding it back on a later in-window pass and
--- stops session.save discarding it as module bookkeeping.
local function user_set_collapsed(st, i, collapsed)
  canvas.set_collapsed(st, i, collapsed)
  sync_after_collapse(st)
end

--- Index of the section under the canvas cursor, or nil.
local function section_under_cursor(st)
  return canvas.locate(st, vim.api.nvim_win_get_cursor(st.win)[1] - 1)
end

--- Clear every folded directory hiding section `i` (at `path`). Returns the
--- directories that were cleared, or nil when nothing was hiding it.
---
--- The whole chain has to go: with both "lua/" and "lua/mod/" folded, dropping
--- either alone leaves the file hidden and the keypress looks broken. That
--- brings back siblings as well, so it announces itself -- one keypress
--- reopening a directory should not be silent.
---
--- This is also the only way out of a fold when the sidebar is disabled: folds
--- restore onto state.folded regardless of the sidebar, so without it those
--- files would be permanently invisible.
local function reveal(st, i, path)
  local dirs = fold.folds_hiding(st.folded, path)
  if #dirs == 0 then
    return nil
  end
  for _, dir in ipairs(dirs) do
    st.folded[dir] = nil
  end
  -- Not just this row -- unfolding an ancestor un-hides the whole subtree. The
  -- OUTERMOST cleared fold spans every section any of them was hiding (they
  -- are all ancestors of one path, outermost first), so its subtree is exactly
  -- the affected set; a section some unrelated inner fold still hides stays
  -- hidden and its resplice no-ops.
  canvas.resync_visibility(st, fold.indices_under(st.sections, dirs[1]))
  -- Every resplice corrects the viewport, and the one whose section starts at
  -- the viewport top rewrites lnum too -- so the cursor must be put back on the
  -- file that was actually pressed. Without this, a <Tab> even one row below
  -- the viewport top lands the cursor on a different file, and the following
  -- <CR> / ]f / ]h all work from there.
  if canvas_showing(st) then
    local start0 = (canvas.section_rows(st, i))
    pcall(vim.api.nvim_win_set_cursor, st.win, { start0 + 1, 0 })
  end
  sync_after_collapse(st)
  util.notify("unfolded " .. table.concat(dirs, ", "))
  return dirs
end

--- Open the file under the cursor as a real buffer. Shared by the jump keymap and
--- the double-click mapping.
---
--- Deliberately fold-BLIND: pressing this on a folded file's placeholder opens the
--- file and leaves the fold exactly as it was, so coming back lands you on the
--- placeholder again. Two verbs with no exceptions -- this one goes to a file,
--- Tab/za folds one -- rather than one key whose meaning depends on state you
--- cannot see. (It used to expand a placeholder instead of opening it, which both
--- duplicated Tab and made Enter context-dependent.)
---
--- Safe only because jump.back guards on fold.hidden: returning into a folded
--- section lands on its placeholder instead of resolving a view against entries
--- that no longer map to rows.
local function open_under_cursor(st, cfg)
  jump.enter(st, { back_keys = keys.list(cfg.keymaps.file.back) })
end

--- Fold or unfold the section under the cursor: reveal it when a
--- folded directory is what's hiding it, otherwise flip its own collapse flag.
local function toggle_collapse_under_cursor(st)
  local i = section_under_cursor(st)
  if not i then
    return
  end
  local path = st.sections[i].path
  if reveal(st, i, path) then
    return
  end
  user_set_collapsed(st, i, not st.collapsed[path])
end

--- What each canvas action does. Keyed by `keys.specs` action names; an action
--- with no handler here simply installs no map, which is what lets a spec land
--- before the feature behind it does.
local function canvas_actions(st, cfg)
  return {
    jump       = function() open_under_cursor(st, cfg) end,
    collapse   = function() toggle_collapse_under_cursor(st) end,
    close      = function() M.close() end,
    refresh    = function() M.refresh() end,
    lens_next  = function() M.cycle_lens(1) end,
    lens_prev  = function() M.cycle_lens(-1) end,
    cycle_next = function() sidebar.cycle(st, 1) end,
    cycle_prev = function() sidebar.cycle(st, -1) end,
    next_file  = function() motions.goto_file(st, 1) end,
    prev_file  = function() motions.goto_file(st, -1) end,
    next_hunk  = function() motions.goto_hunk(st, 1) end,
    prev_hunk  = function() motions.goto_hunk(st, -1) end,
  }
end

local function set_canvas_keymaps(st)
  local cfg = config.options
  local acts = canvas_actions(st, cfg)
  for _, m in ipairs(keys.resolved("canvas", cfg.keymaps)) do
    local fn = acts[m.action]
    if fn then
      vim.keymap.set("n", m.lhs, fn,
        { buffer = st.buf, silent = true, noremap = true, desc = m.desc })
    end
  end
end

--- Directory of `buf`'s own file, or nil when it doesn't have one.
--- Restricted to ordinary file buffers, so scratch buffers, terminals and
--- URI-backed buffers (oil://, fugitive://, our own galley://) never
--- contribute a bogus path.
local function buf_dir(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local dir = vim.fn.fnamemodify(name, ":p:h")
  return vim.fn.isdirectory(dir) == 1 and dir or nil
end

--- Open the canvas in the current window for the git repo we're working in.
--- Not a repo ⇒ notify and return (never throws).
---
--- The repo is resolved from the cwd first, falling back to the current
--- buffer's own file. cwd wins because in Neovim the cwd IS the project, and
--- keeping it first means this changes nothing for anyone already working
--- that way. The fallback exists because `nvim path/to/repo/file.lua` from a
--- parent directory -- or hopping projects with a file picker -- otherwise
--- refuses to open at all, with a message that looks like the plugin is
--- broken rather than looking in the wrong place.
---
--- `opts.base` ("HEAD" | "index") overrides both the saved session's base and
--- the configured default, so a command naming a state can open straight into
--- it rather than opening and then re-rendering.
function M.open(opts)
  opts = opts or {}
  -- Invoked from inside our own sidebar (winfixbuf): the canvas can't be
  -- opened INTO that window. Redirect to the live canvas window if there is
  -- one; otherwise treat the sidebar as an appendage of an open canvas.
  if sidebar.is_sidebar_win(vim.api.nvim_get_current_win()) then
    if state and canvas_showing(state) then
      vim.api.nvim_set_current_win(state.win)
    else
      return
    end
  end

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  local cwd = vim.fn.getcwd()
  local root = git.root(cwd)
  if not root then
    local dir = buf_dir(prev_buf)
    root = dir and git.root(dir) or nil
  end
  if not root then
    util.warn("not inside a git repository (looked in " .. cwd .. ")")
    return
  end

  -- Load any saved session BEFORE collect, so a restored lens is honored from the
  -- very first collect.files call -- not just after the fact.
  --
  -- Precedence, most to least specific: an explicit lens from the caller; the older
  -- `base` string a command passed; the lens the session saved; the base an OLDER
  -- session saved (payloads predating lenses); the configured default.
  local sess = config.options.session.enabled and session.load(root) or nil
  local l = opts.lens
    or (opts.base and lens.from_base(opts.base))
    or (sess and lens.valid(sess.lens) and sess.lens)
    or (sess and sess.base and lens.from_base(sess.base))
    or lens.from_base(config.options.base)

  local sections = model.build(collect.files(root, l), config.options.context)

  local st = canvas.open(sections, {})
  st.root = root
  st.lens = l
  -- Kept alongside, for the session payload and for anything still speaking the
  -- older vocabulary. nil for `staged` and branch lenses, which it cannot express.
  st.base = lens.to_base(l)
  st.prev_buf = prev_buf
  state = st

  -- Before anything that can splice: a fold from the sidebar or a pass of the
  -- auto-virtualizer reshapes the canvas, and neither the highlight tier nor
  -- the minimap hears about it on its own. Wired unconditionally and on the
  -- state itself, so it is not a property of whichever of those two features
  -- happens to be enabled, and cannot outlive the canvas it describes.
  st.hooks = st.hooks or {}
  st.hooks.on_shape_change = sync_after_collapse
  -- Fired by sidebar.sync once it has resolved which section the topline is in --
  -- i.e. "the canvas viewport moved". WinScrolled alone is not enough: a PROGRAMMATIC
  -- move (sidebar select, jump.back, a motion) repositions the viewport without one,
  -- and the winbar would keep naming the file you were previously in.
  --
  -- Riding on the sidebar is sound rather than a dependency inversion, because the
  -- gap it closes only exists when the sidebar does -- selecting a row is the
  -- programmatic scroll. With the sidebar disabled there is nothing but interactive
  -- scrolling, which WinScrolled covers.
  st.hooks.on_locate = function()
    set_winbar(st)
  end

  set_winbar(st)

  if #sections == 0 then
    show_empty_message(st)
  end

  set_canvas_keymaps(st)

  if config.options.highlight.enabled then
    hl.attach(st, config.options.highlight)
  end

  if config.options.watch.enabled then
    watch.on_empty = function()
      show_empty_message(st)
    end
    watch.start(st, config.options.watch)
  end

  if config.options.sidebar.enabled then
    sidebar.open(st, config.options.sidebar)
  end

  if config.options.scrollbar.enabled then
    scrollbar.open(st, config.options.scrollbar)
  end

  -- Keep the winbar's sticky filename tracking the topline. Its own autocmd rather
  -- than a call inside sidebar.sync, because the winbar has to work when the sidebar
  -- is disabled -- it is the only in-canvas answer to "which file am I in" once the
  -- header has scrolled off.
  --
  -- Unconditional and grouped with the close hooks so teardown reaps it. set_winbar
  -- returns early when the resolved text has not changed, which is the common case
  -- while scrolling inside one file, so the redraw cost is paid only at boundaries.
  --
  -- (WinScrolled never fires headlessly -- see the harness notes -- so tests drive
  -- set_winbar or this callback by hand, as they already do for hl and the minimap.)
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = vim.api.nvim_create_augroup("galley.winbar", { clear = true }),
    callback = function()
      if state and canvas_showing(state) then
        set_winbar(state)
      end
    end,
  })

  if config.options.statuscolumn.enabled then
    statuscol.attach(st)
  end

  if config.options.session.enabled then
    local aug = vim.api.nvim_create_augroup("galley.session", { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = aug,
      callback = function()
        session.save(st)
      end,
    })
  end

  -- `:q` in the canvas window never reaches M.close, so hook the window's death
  -- and run the teardown from there. Without it the canvas is off screen while
  -- watch keeps reconciling it on every write and the session is never saved --
  -- losing whatever you had folded.
  --
  -- Deliberately NO `pattern`: hl, scrollbar and statuscol all re-point state.win
  -- on BufWinEnter without reinstalling their own autocmds, which is exactly how
  -- the `pattern = tostring(state.win)` hooks in sidebar and scrollbar go stale
  -- when the canvas moves windows. Reading state.win at fire time cannot.
  --
  -- Deferred and re-checked, because another window in this tabpage may still be
  -- showing the canvas -- and because doing window work from inside WinClosed is
  -- fragile (the same reason sidebar.lua schedules its own).
  local close_aug = vim.api.nvim_create_augroup("galley.close", { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = close_aug,
    callback = function(ev)
      if not (state and tonumber(ev.match) == state.win) then
        return
      end
      vim.schedule(function()
        if state and not canvas_showing(state) then
          teardown(state)
        end
      end)
    end,
  })

  -- Restore BEFORE the auto-virtualizer's first pass. A freshly-opened
  -- canvas sits at row 1, so a virt.apply here would auto-collapse whatever
  -- far section the saved view points at -- and restore's view step skips a
  -- collapsed target, silently reopening large changesets at section one.
  -- Restoring first also means the first apply classifies against the real
  -- viewport, so it leaves the section the user is looking at expanded.
  if sess then
    session.restore(st, sess)
    -- Restored collapses reshape the canvas after the sidebar and scrollbar
    -- were built from the fully-expanded one, and restoring the view doesn't
    -- necessarily scroll (it may already be at the top, or not be saved at
    -- all when the top section is the collapsed one) -- so nothing else
    -- brings them back in sync. Also fixes up the sidebar's active row, drawn
    -- from the pre-restore shape before the view step moved the viewport.
    sync_after_collapse(st)
  end

  if config.options.virt.enabled then
    -- attach applies immediately, and that first pass can already splice -- the
    -- on_shape_change hook is already in place from the top of this function.
    virt.attach(st, config.options.virt)
  end
end

--- Windows in the CURRENT tabpage showing the canvas buffer.
---
--- Tabpage-scoped on purpose: tabs are separate workspaces, so closing here
--- must not reach into a canvas someone left open in another one.
local function canvas_wins(st)
  local out = {}
  if not (st and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then
    return out
  end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == st.buf then
      out[#out + 1] = w
    end
  end
  return out
end

--- Is `buf` something we could sensibly leave a window sitting on?
local function restorable(buf, st)
  return buf
    and buf ~= st.buf
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
end

--- Put `win` back on something useful now that the canvas is leaving it.
---
--- Preference order, most to least specific: the buffer this window had when
--- the canvas took it over; the last file an excursion landed in (if you were
--- reviewing, that's the file you most recently touched); the window's
--- alternate file; and only then a blank buffer. The chain exists because
--- landing on [No Name] reads as something having gone wrong, when in fact
--- nothing did -- the buffer we came from was simply deleted meanwhile.
local function restore_window(win, st)
  local candidates = {
    (win == st.win) and st.prev_buf or nil,
    jump.last_buf(),
    vim.api.nvim_win_call(win, function() return vim.fn.bufnr("#") end),
  }
  for _, buf in ipairs(candidates) do
    if restorable(buf, st) then
      vim.api.nvim_win_set_buf(win, buf)
      return
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("enew")
  end)
end

--- Take the canvas off screen and put every window it occupied back on
--- something useful. The canvas buffer itself is left alone -- canvas.lua
--- keeps it cached/hidden, which is what makes reopening cheap.
---
--- Acts on every window in this tabpage showing the canvas, not just the
--- current one. Restricting it to the current window meant `:Galley close`
--- from a neighbouring split was a silent no-op that read as the plugin being
--- broken. `state` is still a single module-level singleton, so only the one
--- window it remembers a `prev_buf` for gets that buffer back; the others go
--- through the same fallback chain rather than being handed another window's
--- history.
---
--- No canvas on screen ⇒ nothing to restore, but the teardown still runs. It used
--- to return early here, which meant that after a `:q` had taken the window there
--- was no longer any way to reach the teardown at all.
---
--- A stale 'statuscolumn' left on a restored window is harmless: statuscol's
--- text function returns "" as soon as the window isn't showing the canvas.
function M.close()
  if not state then
    return
  end

  local wins = canvas_wins(state)
  teardown(state)

  for _, win in ipairs(wins) do
    restore_window(win, state)
  end
end

--- Toggle: if the canvas is on screen anywhere in this tabpage, take it off;
--- otherwise open it here.
---
--- Keyed on "is it showing at all", not "is it showing in THIS window".
--- Toggling from a neighbouring split used to fall through to open() and put
--- a second view of the same canvas on screen, so the key that is supposed to
--- dismiss it added another one instead.
---
--- Being focused inside our own sidebar counts as "the canvas is open": close
--- it, or just close the sidebar if the canvas it was attached to is already
--- gone. Never errors.
function M.toggle()
  local showing = state and #canvas_wins(state) > 0

  if sidebar.is_sidebar_win(vim.api.nvim_get_current_win()) then
    if showing then
      M.close()
    else
      sidebar.close()
    end
    return
  end

  if showing then
    M.close()
  else
    M.open()
  end
end

--- Re-collect against whatever the state is now pointed at and splice the
--- difference in, rather than rebuilding the buffer.
---
--- This is what makes the canvas *dynamic* instead of merely re-renderable.
--- render_all recreates every anchor, rewrites every line and restores no view, so
--- anything routed through it throws away where you were looking.
--- reconcile_sections leaves every section whose content is unchanged completely
--- untouched, and most files look identical through two lenses, so a pivot typically
--- splices nothing and moves nothing at all.
---
--- Shared by the lens pivot, M.refresh and watch -- they are one operation ("go and
--- see what is true now"), differing only in what prompted it.
local function pivot(st)
  if not (st and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then
    return
  end
  local desired = model.build(collect.files(st.root, lens.of(st)), config.options.context)
  local full = canvas.reconcile_sections(st, desired)
  if full and #desired == 0 then
    show_empty_message(st)
  end
  set_winbar(st)
  sync_after_collapse(st)
  virt.apply(st, config.options.virt)
end

--- Re-collect and splice in whatever changed: the manual version of the pass
--- `watch` runs on save and focus, for when you don't trust what is on screen.
---
--- NON-DESTRUCTIVE, and that is the point of it being on a bare `r`. This used to
--- call render_all, which recreated every anchor, rewrote every line and restored
--- no view -- so the key you pressed to make the canvas trustworthy was also the
--- key that lost your place in it. Refreshing is the most ordinary thing you can
--- ask of a diff view; it has no business violating the invariant the rest of the
--- plugin is built to hold.
---
--- There is deliberately no companion "hard rebuild" action. A reconcile only
--- splices what it BELIEVES differs, so a state/buffer divergence survives any
--- number of refreshes -- but close() + open() already recovers from exactly that,
--- and it RESTORES your position through the session file, which a bare render_all
--- does not. A rebuild verb was written, measured against close+open, found
--- strictly worse on every axis, and deleted. Don't add it back without measuring:
--- test_e2e's "refresh cannot repair a divergent buffer, close+open can" pins both
--- halves of that result.
function M.refresh()
  if not state then
    return
  end
  pivot(state)
end

--- Point the canvas at a different comparison, opening it if it isn't showing.
---
--- Idempotent, which is the whole point: commands get put inside user mappings, and
--- `:Galley unstaged` must always land unstaged. A toggle in a mapping is a coin
--- flip. Opening rather than warning is likewise the only sensible reading of a
--- command that names a state.
function M.set_lens(l)
  if not lens.valid(l) then
    util.warn("not a lens")
    return
  end
  if not (state and canvas_showing(state)) then
    M.open({ lens = l })
    return
  end
  if lens.same(lens.of(state), l) then
    return
  end
  state.lens = l
  state.base = lens.to_base(l)
  pivot(state)
  util.notify("showing " .. l.label)
end

--- Step through the three named lenses: all → unstaged → staged → all.
---
--- This is what the `base` keymap runs, and it is the gesture the canvas is built
--- around -- one key to ask "what am I actually looking at" from three angles.
--- Warns rather than opening: a keypress on no canvas is a mistake, not a request.
function M.cycle_lens(delta)
  if not (state and canvas_showing(state)) then
    util.warn("no live diff canvas")
    return
  end
  M.set_lens(lens.step(lens.of(state), delta or 1))
end

--- Compare the worktree against an arbitrary ref, e.g. `main` or `origin/main`.
--- The new side stays the worktree, so this is still somewhere you can work.
function M.set_branch(ref)
  local l = lens.branch(ref)
  if not l then
    util.warn("no ref given")
    return
  end
  M.set_lens(l)
end

--- Set the diff base to "HEAD" or "index" -- the older two-value vocabulary, which
--- `:Galley all` / `:Galley unstaged` still speak.
function M.set_base(base)
  M.set_lens(lens.from_base(base))
end

--- Flip between "worktree vs HEAD" and "worktree vs index" (unstaged-only review).
---
--- Kept as the exact two-value flip for user mappings that want precisely that; the
--- `B` key runs M.cycle_lens, which also reaches the staged view. Warns rather than
--- opening, for the same reason cycle_lens does.
function M.toggle_base()
  if not (state and canvas_showing(state)) then
    util.warn("no live diff canvas")
    return
  end
  M.set_base(lens.to_base(lens.of(state)) == "index" and "HEAD" or "index")
end

return M
