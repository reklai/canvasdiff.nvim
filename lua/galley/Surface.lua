local config = require("galley.config")
local hl = require("galley.hl")
local scrollbar = require("galley.scrollbar")
local session = require("galley.session")
local sidebar = require("galley.sidebar")
local statuscol = require("galley.statuscol")
local virt = require("galley.virt")
local watch = require("galley.watch")

local Surface = {}
Surface.__index = Surface

local next_id = 0
local next_generation = 0

local OWNED_GROUPS = {
  "galley.session",
  "galley.close",
  "galley.winbar",
}

function Surface.new(state, callbacks, ownership)
  next_id = next_id + 1
  next_generation = next_generation + 2
  ownership = ownership or {}
  local baseline_windows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    baseline_windows[win] = true
  end
  local self = setmetatable({
    id = next_id,
    generation = next_generation,
    phase = "active",
    saved = false,
    disposed = false,
    state = state,
    callbacks = callbacks or {},
    controllers = {},
    windows = {},
    landings = {},
    baseline_windows = baseline_windows,
  }, Surface)

  state.surface = self
  for _, win in ipairs(ownership.windows or {}) do
    if vim.api.nvim_win_is_valid(win) then
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

--- Every window currently displaying this Surface's one canvas buffer.
--- Remembering IDs lets WinClosed identify an owned window after Neovim has
--- already invalidated it; rescanning also adopts duplicate splits.
function Surface:canvas_windows()
  local out = {}
  local state = self.state
  if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return out
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == state.buf
        and (self.windows[win] or not self.baseline_windows[win]) then
      out[#out + 1] = win
      self.windows[win] = true
    end
  end

  local primary = state.win
  if #out > 0 and not (primary and vim.api.nvim_win_is_valid(primary)
      and vim.api.nvim_win_get_buf(primary) == state.buf) then
    state.win = out[1]
  end
  return out
end

--- Explicitly adopt an existing window that has just entered the canvas
--- buffer. This distinguishes a real post-open view from a lower-level/raw
--- view that happened to display the process-wide scratch buffer before this
--- Surface existed.
function Surface:adopt_window(win, landing)
  local state = self.state
  if not (win and state and state.buf and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_buf(win) == state.buf) then
    return false
  end
  self.windows[win] = true

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
  self.landings[win] = nil
  return true
end

function Surface:landing_buffer(win)
  return self.landings[win]
end

function Surface:capture_view(win)
  return session.capture(self.state, win)
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

  self:save()

  local errors = {}
  local function attempt(label, callback)
    local ok, err = pcall(callback)
    if not ok then
      errors[#errors + 1] = label .. ": " .. tostring(err)
    end
  end

  -- Producers first, then consumers. Each operation is attempted even when a
  -- sibling teardown is faulty; otherwise one extension error strands a
  -- half-dead Surface in the closing phase forever.
  attempt("watch.stop", function()
    local lease = self.controllers.watch
    if lease then
      watch.stop(lease)
    end
  end)
  attempt("virt.detach", function()
    local lease = self.controllers.virt
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
  attempt("sidebar.close", sidebar.close)
  attempt("scrollbar.close", scrollbar.close)
  attempt("statuscol.detach", function()
    local lease = self.controllers.statuscol
    if lease then
      statuscol.detach(lease)
    end
  end)

  for _, group in ipairs(OWNED_GROUPS) do
    -- A disabled feature legitimately has no group. Missing groups are not
    -- teardown faults, so keep the historical best-effort deletion semantics.
    pcall(vim.api.nvim_del_augroup_by_name, group)
  end

  local clear_winbar = self.callbacks.clear_winbar
  if clear_winbar then
    attempt("clear_winbar", function() clear_winbar(self) end)
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
