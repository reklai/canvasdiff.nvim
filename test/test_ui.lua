local H = require("helpers")
local ui = require("canvasdiff.ui")

local T = {}
local PREFIX = "CanvasDiff: "

--- Run `fn` with vim.notify captured; returns the recorded messages.
local function capture(fn)
  local real = vim.notify
  local msgs = {}
  vim.notify = function(msg, level)
    msgs[#msgs + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, err)
  return msgs
end

T["ui facade exports its curated presentation operations"] = function()
  local names = vim.tbl_keys(ui)
  table.sort(names)
  H.eq(names, { "err", "highlight", "notify", "scrollbar", "sidebar",
    "status_column", "warn" })
end

T["ui_sidebar legacy sidebar module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.sidebar"] = nil
  local loaded = pcall(require, "canvasdiff.sidebar")
  assert(not loaded, "canvasdiff.sidebar must not remain as a forwarding module")
end

T["ui_status_column legacy statuscol module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.statuscol"] = nil
  local loaded = pcall(require, "canvasdiff.statuscol")
  assert(not loaded, "canvasdiff.statuscol must not remain as a forwarding module")
end

-- The status column is drawn by a statusline expression that names the module
-- resolving it. If the module moves and the expression does not, every claimed
-- window silently renders nothing -- and no other test would notice, because
-- Neovim evaluates that string itself.
T["ui_status_column installs an expression that resolves back to its owner"] = function()
  local canvas = require("canvasdiff.canvas")
  local st = canvas.open({}, {})
  local lease = ui.status_column.attach(st, {
    windows = function() return { st.win } end,
  })
  local installed = vim.api.nvim_get_option_value(
    "statuscolumn", { win = st.win, scope = "local" })
  H.eq(ui.status_column.detach(lease), true)

  local module = installed:match("require'([^']+)'")
  assert(module, "the installed expression must name a module: " .. installed)
  local loaded, resolved = pcall(require, module)
  assert(loaded, "the expression's module must resolve: " .. tostring(resolved))
  assert(rawequal(resolved, ui.status_column),
    "the expression must resolve to the exact owner the UI facade exposes")
  assert(installed:find(".text()", 1, true),
    "and must call its entrypoint: " .. installed)
end

T["ui_highlight facade exposes the lease operations its owners call"] = function()
  for _, name in ipairs({
    "attach", "detach", "apply_now", "invalidate", "lang_for", "section_ts_marks",
  }) do
    H.eq(type(ui.highlight[name]), "function",
      "ui.highlight." .. name .. " is callable")
  end
end

T["ui_highlight legacy hl module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.hl"] = nil
  local loaded = pcall(require, "canvasdiff.hl")
  assert(not loaded, "canvasdiff.hl must not remain as a forwarding module")
end

T["ui_notify prefixes and defaults to INFO"] = function()
  local msgs = capture(function() ui.notify("hello") end)
  H.eq(#msgs, 1)
  H.eq(msgs[1].msg, "CanvasDiff: hello")
  H.eq(msgs[1].level, vim.log.levels.INFO)
end

T["ui_notify warn and err carry their levels"] = function()
  local msgs = capture(function()
    ui.warn("careful")
    ui.err("broken")
  end)
  H.eq(#msgs, 2)
  H.eq(msgs[1].msg, "CanvasDiff: careful")
  H.eq(msgs[1].level, vim.log.levels.WARN)
  H.eq(msgs[2].msg, "CanvasDiff: broken")
  H.eq(msgs[2].level, vim.log.levels.ERROR)
end

T["ui_notify an explicit level still wins"] = function()
  local msgs = capture(function() ui.notify("x", vim.log.levels.ERROR) end)
  H.eq(msgs[1].level, vim.log.levels.ERROR)
end

-- Regression: this site was the one inconsistency in the codebase -- it
-- notified without the plugin prefix, so the message read as if it came from
-- Neovim itself rather than from us.
T["ui_notify jump.back with no excursion is prefixed"] = function()
  local jump = require("canvasdiff.jump")
  -- jump.lua holds a module-level excursion singleton and the whole suite
  -- shares one Neovim process, so an earlier test can leave one live. back()
  -- nils it before doing any window work, so one guarded call always drains.
  pcall(jump.back)
  local msgs = capture(function() jump.back() end)
  H.eq(#msgs, 1, "exactly one notification")
  assert(msgs[1].msg:sub(1, #PREFIX) == PREFIX,
    "expected the CanvasDiff prefix, got: " .. msgs[1].msg)
  assert(msgs[1].msg:match("no active review excursion"),
    "and the review context, got: " .. msgs[1].msg)
end

return T
