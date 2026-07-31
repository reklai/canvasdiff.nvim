-- Session payload encoding, persistence, and semantic viewport restoration.
-- Consumers enter through canvasdiff.session; this owner keeps representation
-- and storage details inside the session domain.
local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")
local system = require("canvasdiff.os")
local viewport = diff.anchor
local fold = diff.fold
local lens = diff.lens

local M = {}

local VERSION = 2

local win_showing_canvas = canvas.win_showing_canvas

local function index_of_path(state, path)
  for i, sec in ipairs(state.sections) do
    if sec.path == path then
      return i
    end
  end
end

--- Capture the semantic viewport and cursor while `win` is still a valid
--- canvas view. WinClosed callbacks run before Neovim invalidates the closing
--- window, whereas the lifecycle teardown is deliberately deferred; keeping
--- this small snapshot lets the later save retain the user's exact place.
---
--- The second return value says whether a live canvas view was observed.
--- An uninspectable window leaves the last good snapshot alone; an observed
--- placeholder deliberately clears it, because a stale earlier position must
--- not masquerade as the user's current (unrepresentable) view.
function M.capture(state, win)
  win = win or (state and state.win)
  if not (state and state.buf and win and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == state.buf) then
    return nil, false
  end

  local snapshot
  local ok = pcall(function()
    local top0 = vim.api.nvim_win_call(win, function()
      return vim.fn.line("w0") - 1
    end)
    local i, top_offset = canvas.locate(state, top0)
    if not (i and state.sections[i]
        and not fold.hidden(state, state.sections[i].path)) then
      return
    end

    local sec = state.sections[i]
    local view = viewport.capture_from_entries(sec.entries, top_offset)
    view.path = sec.path
    snapshot = { view = view }

    -- A folded placeholder has no stable entry offset. This is the same
    -- refusal save() historically made: restoring a fabricated file-header
    -- cursor is worse than falling back to the captured topline.
    local cursor_row0 = vim.api.nvim_win_get_cursor(win)[1] - 1
    local ci, cursor_offset = canvas.locate(state, cursor_row0)
    if ci and state.sections[ci]
        and not fold.hidden(state, state.sections[ci].path) then
      local centry = state.sections[ci].entries[cursor_offset]
      snapshot.cursor = {
        path = state.sections[ci].path,
        new_lnum = centry and centry.new_lnum or nil,
        content = centry and centry.content or nil,
      }
    end
  end)

  if not ok then
    return nil, false
  end
  state.session_snapshot = snapshot
  return snapshot, true
end

--- Where a root's session file lives on disk.
function M.path_for(root)
  return vim.fn.stdpath("state") .. "/canvasdiff/" .. vim.fn.sha256(root) .. ".json"
end

--- Persist `state`'s base/collapsed/folds and (when the canvas is actually
--- showing) a semantic view/cursor anchor to disk. Entirely pcall-guarded --
--- session persistence must never break closing the canvas.
function M.save(state)
  local ok, err = pcall(function()
    if not state or not state.root then
      return
    end

    -- `lens` is the truth; `base` is written alongside as a courtesy to readers
    -- that only know the older two-value vocabulary, and is nil for the `staged`
    -- and branch lenses it cannot express. Version 2 is the CanvasDiff identity
    -- boundary: copied version-1 payloads are intentionally rejected rather than
    -- being mistaken for state created under this package.
    local l = lens.of(state)
    local data = { version = VERSION, base = lens.to_base(l), lens = l }

    -- Auto-collapsed (virt) paths are module intent, not user intent -- never
    -- persist them as if the user had collapsed them. state.collapsed records
    -- which is which, so this is a straight filter.
    local collapsed = {}
    for path, intent in pairs(state.collapsed or {}) do
      if intent == "user" then
        collapsed[#collapsed + 1] = path
      end
    end
    table.sort(collapsed)
    data.collapsed = collapsed

    -- Read straight off `state`, so folds persist whether or not the sidebar
    -- happens to be open at quit time.
    local folds = {}
    for dir in pairs(state.folded or {}) do
      folds[#folds + 1] = dir
    end
    table.sort(folds)
    data.folds = folds

    -- What each folded file looked like when it went away. Folds persist, so
    -- this has to as well, or reopening would silently declare everything fresh --
    -- and a shut editor is exactly when files change behind your back. Sorted, like
    -- the arrays above, so the on-disk payload diffs cleanly.
    --
    -- `fp = false` (arrived sight-unseen) is preserved as JSON `false`; vim.json
    -- keeps the distinction from a hash string, which is all fold.stale needs. The
    -- lens id rides along because a fingerprint is only comparable within the lens
    -- that captured it.
    local seen = {}
    for path, e in pairs(state.folded_seen or {}) do
      seen[#seen + 1] = { path = path, lens = e.lens, fp = e.fp }
    end
    table.sort(seen, function(a, b) return a.path < b.path end)
    data.folded_seen = seen

    local position, observed = M.capture(state)
    if not observed then
      position = state.session_snapshot
    end
    if position then
      data.view = position.view
      data.cursor = position.cursor
    end

    local path = M.path_for(state.root)
    system.write_file(path, vim.json.encode(data))
  end)
  return ok, ok and nil or tostring(err)
end

--- Load a previously saved session for `root`, or nil when there is none /
--- it can't be decoded / it's from an incompatible version.
function M.load(root)
  local path = M.path_for(root)
  local content = system.read_file(path)
  if not content or content == "" then
    return nil
  end

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or data.version ~= VERSION then
    return nil
  end
  if data.lens ~= nil then
    data.lens = lens.normalize(data.lens)
  end
  return data
end

--- Reapply a loaded session onto a freshly-opened `state`. Each of the three
--- sub-steps (collapse, folds, view) is independently pcall-guarded, so a
--- failure resolving one never prevents the others from applying.
function M.restore(state, data)
  if not state or not data then
    return
  end

  -- Folds FIRST: everything below derives visibility from state.folded, and
  -- the collapse loop's own splices resolve their rendered form through it.
  pcall(function()
    local set = {}
    for _, dir in ipairs(data.folds or {}) do
      set[dir] = true
    end
    -- Pruned on the way in as well as on the way out: a payload written before
    -- the directory's last change was committed would otherwise reintroduce a
    -- fold over files that only appear in it now.
    state.folded = fold.prune(state.sections, set)
  end)

  -- A restored collapse is the user's own -- set_collapsed's default intent --
  -- so the virtualizer will neither expand it back on a later pass nor discard
  -- it from the next save.
  pcall(function()
    for _, path in ipairs(data.collapsed or {}) do
      local idx = index_of_path(state, path)
      if idx then
        canvas.set_collapsed(state, idx, true)
      end
    end
  end)

  -- One pass over every section, because assigning state.folded above changed
  -- what they should render as without splicing anything. The caller
  -- (App:open) owns the single follow-up sync of the other UI pieces.
  pcall(function()
    canvas.resync_visibility(state)
  end)

  -- AFTER the collapse and fold steps, and the ordering is load-bearing -- do not
  -- move it above them. Restoring those goes through resplice, which records a
  -- fingerprint of whatever each file looks like NOW. If the file changed while
  -- Neovim was shut, those resplices have just recorded the new content as "what
  -- you saw", losing the staleness at the exact moment it matters most. The saved
  -- fingerprints have to land last and overwrite them.
  --
  -- Filtered to paths still folded, so a payload whose folds have since been
  -- pruned doesn't leave fingerprints behind for visible files.
  pcall(function()
    for _, e in ipairs(data.folded_seen or {}) do
      if e.path and fold.user_folded(state, e.path) then
        state.folded_seen[e.path] = { lens = e.lens, fp = e.fp }
      end
    end
  end)

  pcall(function()
    local v = data.view
    if not v or not v.path then
      return
    end
    local idx = index_of_path(state, v.path)
    if not idx then
      return
    end
    -- A folded section is just its placeholder row -- its entries don't
    -- map to buffer rows, so there is nothing to resolve. save() never
    -- records a view onto one, so this only fires on a stale or hand-written
    -- payload whose collapse/fold set covers its own view path.
    -- (App:open runs this restore BEFORE attaching the auto-virtualizer,
    -- precisely so virt can't collapse the target first.)
    if fold.hidden(state, v.path) then
      return
    end

    local sec = state.sections[idx]
    local resolved = viewport.resolve(v, sec.entries)
    if not resolved then
      return
    end
    local start_row = (canvas.section_rows(state, idx))
    local topline = math.max(1, start_row + resolved - (v.screen_offset or 0))
    local lnum = topline

    local c = data.cursor
    if c and c.path then
      local cidx = index_of_path(state, c.path)
      if cidx and not fold.hidden(state, c.path) then
        local csec = state.sections[cidx]
        local cresolved = viewport.resolve(c, csec.entries)
        if cresolved then
          local cstart = (canvas.section_rows(state, cidx))
          lnum = math.max(1, cstart + cresolved)
        end
      end
    end

    if win_showing_canvas(state) then
      vim.api.nvim_win_call(state.win, function()
        vim.fn.winrestview({ topline = topline, lnum = lnum })
      end)
    end
  end)
end

return M
