local canvas = require("finding_myself.canvas")

local M = {}

local AUGROUP = "finding_myself.statuscol"
local STATUSCOL_EXPR = "%!v:lua.require'finding_myself.statuscol'.text()"

-- Module singleton (mirrors scrollbar/sidebar's discipline): the one live
-- canvas state the statuscolumn is bound to, or nil when detached.
local live = nil

local function set_statuscolumn(win, value)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_set_option_value, "statuscolumn", value, { win = win, scope = "local" })
  end
end

local function canvas_showing(state)
  return state.win and vim.api.nvim_win_is_valid(state.win)
    and vim.api.nvim_win_get_buf(state.win) == state.buf
end

--- Core statuscolumn text for canvas buffer line `lnum` (1-based). "" unless
--- the window being DRAWN (`v:lua`-eval sets `g:statusline_winid` to it,
--- mirroring 'statusline') is showing the live canvas -- NOT whichever
--- window happens to be focused, so the column keeps rendering for the
--- canvas window while focus is elsewhere (e.g. the sidebar). pcall-guarded
--- so a stale/racing `live` (e.g. mid-splice) never surfaces an error into
--- the statusline.
function M.text_for(lnum)
  local ok, result = pcall(function()
    if not live then
      return ""
    end
    local win = vim.g.statusline_winid
    if not win or not vim.api.nvim_win_is_valid(win) then
      return ""
    end
    if vim.api.nvim_win_get_buf(win) ~= live.buf then
      return ""
    end
    local i, offset = canvas.locate(live, lnum - 1)
    if not i then
      return "     "
    end
    if live.collapsed and live.collapsed[live.sections[i].path] then
      return "     "
    end
    local entry = live.sections[i].entries[offset]
    if not entry then
      return "     "
    end
    if entry.kind == "file_hdr" or entry.kind == "hunk_hdr" then
      return "     "
    end
    if entry.new_lnum then
      return ("%4d "):format(entry.new_lnum)
    end
    if entry.kind == "del" then
      return "   · "
    end
    return "     "
  end)
  if not ok then
    return ""
  end
  return result
end

function M.text()
  return M.text_for(vim.v.lnum)
end

--- Attach the statuscolumn to `state`'s canvas window, tracking it across
--- BufWinEnter (re-show, re-track `state.win`) / BufWinLeave (clear the
--- option once the canvas has actually left the window) on `state.buf`.
--- Re-attaching (a fresh call with a different state) clears and reinstalls
--- the augroup, singleton-style.
function M.attach(state)
  live = state
  set_statuscolumn(state.win, STATUSCOL_EXPR)

  local aug = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = aug,
    buffer = state.buf,
    callback = function()
      if not live then
        return
      end
      live.win = vim.api.nvim_get_current_win()
      set_statuscolumn(live.win, STATUSCOL_EXPR)
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = aug,
    buffer = state.buf,
    callback = function()
      -- The window still transiently reports the OLD (canvas) buffer at
      -- this point in the event; defer so canvas_showing reads the buffer
      -- swap that actually landed (mirrors scrollbar.lua's BufWinLeave).
      vim.schedule(function()
        if live and live.win and vim.api.nvim_win_is_valid(live.win)
            and not canvas_showing(live) then
          set_statuscolumn(live.win, "")
        end
      end)
    end,
  })
end

--- Clear the statuscolumn from the live canvas window (if still valid),
--- tear down the augroup, and drop the singleton.
function M.detach()
  if live then
    set_statuscolumn(live.win, "")
  end
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  live = nil
end

return M
