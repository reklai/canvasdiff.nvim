local canvas = require("canvasdiff.canvas")
local config = require("canvasdiff.config")
local session = require("canvasdiff.session")
local input = require("canvasdiff.input")
local jump = input.jump
local ui = require("canvasdiff.ui")
local hl = ui.highlight
local scrollbar = ui.scrollbar
local sidebar = ui.sidebar
local statuscol = ui.status_column
local runtime = require("canvasdiff.runtime")
local virt = runtime.virtualizer
local watch = runtime.watch

local Surface = {}
Surface.__index = Surface

local next_id = 0
local next_generation = 0

-- Autocommand groups this Surface installs itself, rather than through a
-- controller lease. Their names carry the Surface id for the same reason every
-- controller group does: a fixed name means a second review's teardown deletes
-- the first review's event sources.
local OWNED_GROUP_KINDS = { "session", "close", "winbar" }

function Surface.new(state, callbacks, ownership)
  next_id = next_id + 1
  next_generation = next_generation + 2
  ownership = ownership or {}
  local baseline_windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    baseline_windows[win] = true
  end
  local groups = {}
  for _, kind in ipairs(OWNED_GROUP_KINDS) do
    groups[kind] = ("canvasdiff.%s.%d"):format(kind, next_id)
  end

  local self = setmetatable({
    id = next_id,
    generation = next_generation,
    groups = groups,
    phase = "active",
    saved = false,
    disposed = false,
    state = state,
    -- The index key App files this review under. Captured once: `state.buf`
    -- is released at disposal, but a late callback still has to be able to
    -- unregister the exact review it belonged to.
    canvas_buf = state and state.buf or nil,
    callbacks = callbacks or {},
    controllers = {},
    -- One review, one way back. Two concurrent reviews keep independent
    -- excursions rather than overwriting a shared module-global one.
    excursion = jump.store(),
    windows = {},
    -- Windows adopted from a single scan and not yet seen twice. See
    -- canvas_snapshot: one sighting is not proof a window is really a view of
    -- this review.
    provisional = {},
    landings = {},
    baseline_windows = baseline_windows,
  }, Surface)

  state.surface = self
  for _, win in ipairs(ownership.windows or {}) do
    if vim.api.nvim_win_is_valid(win) then
      -- Inherited from a predecessor that already proved these are its hosts.
      self.windows[win] = true
    end
  end
  for win, buf in pairs(ownership.landings or {}) do
    if vim.api.nvim_win_is_valid(win) then
      self.landings[win] = buf
    end
  end
  if state.win and vim.api.nvim_win_is_valid(state.win)
      and state.buf and vim.api.nvim_win_get_buf(state.win) == state.buf then
    self.windows[state.win] = true
    if self.landings[state.win] == nil and state.prev_buf ~= state.buf then
      self.landings[state.win] = state.prev_buf
    end
  end
  return self
end

function Surface:is_alive()
  return self.phase == "active" and not self.disposed
end

--- Confirm a provisionally adopted window once the event loop has turned.
---
--- Deferred rather than confirmed on a second synchronous sighting, because a
--- window being created beside a Canvas view stays on that Canvas across
--- several events -- WinNew, BufWinEnter, WinEnter, WinResized -- before
--- Neovim installs its real buffer. Only a turn of the loop separates "a real
--- duplicate view" from "a window that had not finished being made".
local function confirm_later(self, win)
  vim.schedule(function()
    if not (self:is_alive() and self.provisional[win]) then
      return
    end
    local buf = self.state and self.state.buf
    if buf and vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == buf then
      self.provisional[win] = nil
    end
  end)
end

--- Snapshot this Surface's valid hosts and Canvas windows without electing a
--- new scalar primary.
---
--- The scan adopts post-open duplicate Canvas splits into the Surface graph,
--- but deliberately does not write `state.win`. Controllers with per-window
--- state need a stable ownership snapshot, not a write to an unrelated
--- scalar merely because one of their callbacks happened to run.
---
--- Adoption is provisional until the event loop turns. A window being created
--- next to a Canvas view transiently displays that Canvas, and any unrelated
--- event in that moment -- a resize is enough -- scans it. Adopting outright
--- made the review claim a window it never had, so a `:CanvasDiff` there
--- replaced the review instead of starting a second one.
function Surface:canvas_snapshot()
  local canvas_windows = {}
  local state = self.state
  local buf = state and state.buf
  local valid_buf = buf ~= nil and vim.api.nvim_buf_is_valid(buf)

  for win in pairs(self.provisional) do
    local showing = valid_buf
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == buf
    if not showing then
      self.provisional[win] = nil
      self.windows[win] = nil
      self.landings[win] = nil
    end
  end

  if valid_buf then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win)
          and vim.api.nvim_win_get_buf(win) == buf
          and (self.windows[win] or not self.baseline_windows[win]) then
        canvas_windows[#canvas_windows + 1] = win
        if self.windows[win] == nil then
          self.windows[win] = true
          self.provisional[win] = true
          confirm_later(self, win)
        end
      end
    end
  end
  table.sort(canvas_windows)

  return {
    hosts = self:host_windows(),
    canvas = canvas_windows,
  }
end

--- Every window currently displaying this Surface's one canvas buffer.
--- Remembering IDs lets WinClosed identify an owned window after Neovim has
--- already invalidated it; rescanning also adopts duplicate splits. Historical
--- callers expect this method to repair the scalar primary when it disappears;
--- controllers that must remain read-only use canvas_snapshot() instead.
function Surface:canvas_windows()
  local out = self:canvas_snapshot().canvas
  local state = self.state
  if not state then
    return out
  end

  local primary = state.win
  if #out > 0 and not (primary and vim.api.nvim_win_is_valid(primary)
      and vim.api.nvim_win_get_buf(primary) == state.buf) then
    state.win = out[1]
  end
  return out
end

--- Adopt an existing window that has just entered the canvas buffer.
---
--- Provisional for the same reason snapshot adoption is: BufWinEnter also
--- fires for a window that is merely being CREATED beside a canvas view and
--- will hold a foreign buffer a moment later. See confirm_later.
function Surface:adopt_window(win, landing)
  local state = self.state
  if not (win and state and state.buf and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == state.buf) then
    return false
  end
  if self.windows[win] == nil then
    self.windows[win] = true
    self.provisional[win] = true
    confirm_later(self, win)
  end

  if self.landings[win] == nil then
    if landing == nil and self.baseline_windows[win] then
      pcall(function()
        landing = vim.api.nvim_win_call(win, function()
          return vim.fn.bufnr("#")
        end)
      end)
    end
    if landing ~= state.buf then
      self.landings[win] = landing
    end
  end
  return true
end

--- Transfer the logical hosts and their independent landing buffers to a
--- replacement Surface that will reuse the same process-wide canvas buffer.
function Surface:handoff()
  self:canvas_windows()
  local ownership = { windows = self:host_windows(), landings = {} }
  for _, win in ipairs(ownership.windows) do
    ownership.landings[win] = self.landings[win]
  end
  return ownership
end

--- Valid host windows still belonging to this review. A host may temporarily
--- show a real file during a jump excursion, so this is intentionally broader
--- than canvas_windows().
function Surface:host_windows(tabpage)
  local out = {}
  for win in pairs(self.windows) do
    if not vim.api.nvim_win_is_valid(win) then
      self.windows[win] = nil
    elseif not tabpage or vim.api.nvim_win_get_tabpage(win) == tabpage then
      out[#out + 1] = win
    end
  end
  table.sort(out)
  return out
end

function Surface:tab_canvas_windows(tabpage)
  local out = {}
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(self:canvas_windows()) do
    if vim.api.nvim_win_get_tabpage(win) == tabpage then
      out[#out + 1] = win
    end
  end
  return out
end

function Surface:is_showing(tabpage)
  if not self:is_alive() then
    return false
  end
  if tabpage then
    return #self:tab_canvas_windows(tabpage) > 0
  end
  return #self:canvas_windows() > 0
end

function Surface:owns_window(win)
  return win ~= nil and (
    self.windows[win]
    or (self.state and self.state.win == win)
  ) or false
end

function Surface:release_window(win)
  if not self:owns_window(win) then
    return false
  end
  self.windows[win] = nil
  self.provisional[win] = nil
  self.landings[win] = nil
  return true
end

function Surface:landing_buffer(win)
  return self.landings[win]
end

function Surface:capture_view(win)
  return session.capture(self.state, win)
end

--- Retire this source lifetime for a branch change and return only the
--- ownership and semantic view data a fresh Surface may inherit.
---
--- Disposal happens inside this operation so callers cannot accidentally
--- recollect repository state while the old controllers are still live.
function Surface:retire_for_ref_change(preferred_win, replacement_lens)
  if not self:is_alive() then
    return nil
  end
  local graph = self:canvas_snapshot()
  local capture_order = {}
  if preferred_win then
    capture_order[#capture_order + 1] = preferred_win
  end
  for _, win in ipairs(graph.canvas) do
    if win ~= preferred_win then
      capture_order[#capture_order + 1] = win
    end
  end
  for _, win in ipairs(capture_order) do
    local _, observed = self:capture_view(win)
    if observed then
      break
    end
  end
  local replacement = {
    canvas_buf = self.canvas_buf,
    ownership = self:handoff(),
    displaced = graph.canvas,
    session = vim.deepcopy(self.state and self.state.session_snapshot or nil),
  }
  if replacement_lens and self.state then
    self.state.lens = vim.deepcopy(replacement_lens)
    self.state.collapsed = {}
    self.state.folded = {}
    self.state.folded_seen = {}
  end
  self:dispose("branch_changed")
  return replacement
end

--- Run only work captured from this exact live generation.
function Surface:guard(generation, callback)
  if generation ~= self.generation or not self:is_alive() then
    return false
  end
  if callback then
    callback(self)
  end
  return true
end

function Surface:save()
  if self.saved or self.disposed or not config.options.session.enabled then
    return false
  end
  -- Flip the once gate before calling persistence code so a reentrant
  -- VimLeave/close path cannot write the same Surface twice.
  self.saved = true
  -- Prefer a live view, while preserving an earlier WinClosed snapshot when
  -- the terminal disposal is running after the window vanished.
  pcall(session.capture, self.state)
  pcall(session.save, self.state)
  return true
end

--- Tear down a Surface that was constructed but never published.
--- It has no user-visible lifetime to persist, so mark the save gate consumed
--- before routing through the same exact controller/canvas cleanup as dispose.
function Surface:abort(reason)
  if not self:is_alive() then
    return false
  end
  self.saved = true
  return self:dispose(reason or "aborted")
end

--- Terminal, exactly-once teardown for one review lifetime.
function Surface:dispose(reason)
  if not self:is_alive() then
    return false
  end

  -- Invalidate queued callbacks before the first teardown side effect. A
  -- callback already in vim.schedule can still run, but its captured
  -- generation can no longer pass guard().
  self.phase = "closing"
  self.generation = self.generation + 1
  self.reason = reason

  local errors = {}
  local function attempt(label, callback)
    local ok, err = pcall(callback)
    if not ok then
      errors[#errors + 1] = label .. ": " .. tostring(err)
    end
  end

  -- Saving is attempted, not assumed. It ran unprotected here once, and a
  -- session write that throws -- an unwritable state directory, a full disk --
  -- aborted disposal before a single augroup was deleted, stranding every
  -- controller on a review already marked closing. Losing a saved position is
  -- a bad outcome; leaving live callbacks behind is a worse one.
  attempt("session.save", function() self:save() end)

  -- Producers first, then consumers. Each operation is attempted even when a
  -- sibling teardown is faulty; otherwise one extension error strands a
  -- half-dead Surface in the closing phase forever.
  attempt("watch.stop", function()
    local lease = self.controllers.watch
    self.controllers.watch = nil
    if lease then
      watch.stop(lease)
    end
  end)
  attempt("virt.detach", function()
    local lease = self.controllers.virt
    self.controllers.virt = nil
    if lease then
      virt.detach(lease)
    end
  end)
  attempt("hl.detach", function()
    local lease = self.controllers.hl
    if lease then
      hl.detach(lease)
    end
  end)
  attempt("sidebar.close", function()
    local lease = self.controllers.sidebar
    if lease then
      sidebar.close(lease)
    end
  end)
  attempt("scrollbar.close", function()
    local lease = self.controllers.scrollbar
    self.controllers.scrollbar = nil
    if lease then
      scrollbar.close(lease)
    end
  end)
  attempt("statuscol.detach", function()
    local lease = self.controllers.statuscol
    if lease then
      statuscol.detach(lease)
    end
  end)

  for _, kind in ipairs(OWNED_GROUP_KINDS) do
    -- A disabled feature legitimately has no group. Missing groups are not
    -- teardown faults, so keep the historical best-effort deletion semantics.
    pcall(vim.api.nvim_del_augroup_by_name, self.groups[kind])
  end

  local clear_winbar = self.callbacks.clear_winbar
  if clear_winbar then
    attempt("clear_winbar", function() clear_winbar(self) end)
  end

  -- The way back belonged to this review. Releasing it here keeps a disposed
  -- Surface from retaining a file buffer and a whole canvas state graph.
  self.excursion = nil

  -- So did the canvas buffer. Reclaim it once the event loop turns: the
  -- explicit-close path restores each host window to its landing buffer AFTER
  -- disposal, and deleting the buffer synchronously would make Neovim pick a
  -- replacement for those windows first.
  -- The store and its projection, before the buffer they live on. A paged
  -- canvas owns both; an eager one owns neither, and `canvas.dispose` is
  -- harmless on it. Disposing the projection also deletes the skeleton
  -- buffer, which is why this runs before the deferred buffer reclamation
  -- below rather than after it.
  attempt("canvas.dispose", function()
    canvas.dispose(self.state)
  end)

  local canvas_buf = self.state and self.state.buf or nil
  if canvas_buf then
    vim.schedule(function()
      if not (vim.api.nvim_buf_is_valid(canvas_buf)
          and canvas.is_canvas_buf(canvas_buf)) then
        return
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        local ok, showing = pcall(vim.api.nvim_win_get_buf, win)
        if ok and showing == canvas_buf then
          return
        end
      end
      pcall(vim.api.nvim_buf_delete, canvas_buf, { force = true })
    end)
  end

  if self.state then
    self.state.hooks = nil
    if self.state.surface == self then
      self.state.surface = nil
    end
  end
  self.phase = "disposed"
  self.disposed = true
  self.errors = errors

  local on_dispose = self.callbacks.on_dispose
  self.callbacks = {}
  if on_dispose then
    attempt("on_dispose", function() on_dispose(self, reason) end)
  end
  return true
end

return Surface
