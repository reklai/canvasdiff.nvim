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
  H.eq(names, { "err", "notify", "scrollbar", "warn" })
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
