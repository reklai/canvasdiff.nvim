-- The canvas winbar: breadcrumb text and the window-option bookkeeping that
-- applies and releases it.
--
-- Presentation only. App resolves WHICH path sits under a window's topline
-- (that is orchestration over live canvas state); this module owns everything
-- about how the answer is shown. Extracted from App.lua so the largest
-- stateful owner keeps orchestration and the ui domain keeps presentation.

local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")

local lens = diff.lens

local W = {}

--- The text is a statusline expression, so `%` in a branch ref or path has to
--- be escaped before Neovim evaluates it.
function W.escape(text)
  return tostring(text or ""):gsub("%%", "%%%%")
end

--- A coloured bar is a mode indicator, like macro-recording: the READ-ONLY
--- tint says "this comparison cannot be edited" in peripheral vision, before
--- the label is read. Groups are `default = true` so colourschemes win; the
--- read-only default was chosen by luminance measurement against the builtin
--- scheme and tokyonight-moon (numbers in the introducing commit), the same
--- method as CanvasDiffFileBar.
function W.ensure_hl_groups()
  vim.api.nvim_set_hl(0, "CanvasDiffWinbar", { link = "WinBar", default = true })
  vim.api.nvim_set_hl(0, "CanvasDiffWinbarReadOnly", { link = "Visual", default = true })
end

--- The breadcrumb: comparison on the left, the file under the topline after
--- it. `%<` truncates the path, never the comparison.
function W.text(st, path)
  local l = lens.of(st)
  local group = lens.is_range(l) and "CanvasDiffWinbarReadOnly" or "CanvasDiffWinbar"
  local out = "%#" .. group .. "#" .. W.escape(l.label)
  if not path then
    return out
  end
  return out .. " · %<" .. W.escape(canvas.format.escape_path(path))
end

--- Cached write. Runs on every WinScrolled, and writing 'winbar' forces a
--- window redraw, so identical text is skipped -- comparing the resolved
--- string also covers scrolling WITHIN one file, where only the path lookup's
--- work was wasted. The cache lives on the canvas state so a rebuilt state
--- starts clean.
function W.apply(st, win, text)
  if not (st and win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  st.winbar_text_by_win = st.winbar_text_by_win or {}
  if st.winbar_text_by_win[win] == text then
    local ok, actual = pcall(
      vim.api.nvim_get_option_value, "winbar", { win = win })
    if ok and actual == text then
      return
    end
  end
  W.ensure_hl_groups()
  st.winbar_text_by_win[win] = text
  pcall(vim.api.nvim_set_option_value, "winbar", text, { win = win, scope = "local" })
end

--- Release the option only while we still own the current value -- a leftover
--- winbar on a restored window would claim the file you are editing is a diff
--- canvas, but a value someone else wrote since is theirs to keep.
function W.clear(st, win)
  if not (st and win) then
    return
  end
  local owned_text = st.winbar_text_by_win and st.winbar_text_by_win[win] or nil
  if st.winbar_text_by_win then
    st.winbar_text_by_win[win] = nil
  end
  if not vim.api.nvim_win_is_valid(win) or owned_text == nil then
    return
  end
  local ok, actual = pcall(
    vim.api.nvim_get_option_value, "winbar", { win = win })
  if ok and actual == owned_text then
    pcall(vim.api.nvim_set_option_value, "winbar", "", { win = win, scope = "local" })
  end
end

return W
