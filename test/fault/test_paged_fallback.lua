local H = require("helpers")
local canvas = require("canvasdiff.canvas")

local T = {}

-- The paged->eager fallback is deliberate UX (a review must open even when
-- the paged store refuses), but it must be LOUD: it pays the eager cost on a
-- review sized for paging, and a silent fallback makes every field failure
-- of the paged engine look like nothing happened -- the paged path would rot
-- unexercised while its users quietly pay for it.
T["paged_fallback a failed paged build opens eagerly and says so"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\n" },
    worktree = { ["a.txt"] = "A1\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  local real_open_paged = canvas.open_paged
  local real_notify = vim.notify
  local messages = {}
  vim.notify = function(msg, level)
    messages[#messages + 1] = { msg = tostring(msg), level = level }
  end
  canvas.open_paged = function()
    return nil, "injected store refusal"
  end

  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  local ok, err = xpcall(function()
    -- min_rows = 1 routes even this one-file review through the paged path.
    fm.setup({ paged = { min_rows = 1 } })
    fm.open()
    local buf = vim.api.nvim_get_current_buf()
    assert(canvas.is_canvas_buf(buf),
      "the review must still open, on the eager canvas")

    local reported
    for _, message in ipairs(messages) do
      if message.msg:find("paged canvas unavailable", 1, true)
          and message.msg:find("injected store refusal", 1, true) then
        reported = message
      end
    end
    assert(reported, "the fallback must name itself and its reason: "
      .. vim.inspect(messages))
    H.eq(reported.level, vim.log.levels.WARN,
      "a fallback is a warning -- the review still opened")
  end, debug.traceback)

  pcall(function() fm.close() end)
  fm.setup({})
  canvas.open_paged = real_open_paged
  vim.notify = real_notify
  vim.api.nvim_set_current_dir(old_cwd)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

return T
