local H = require("helpers")
local runtime = require("canvasdiff.runtime")

local T = {}

T["runtime_ facade exports exactly the two controller groups"] = function()
  local names = vim.tbl_keys(runtime)
  table.sort(names)
  H.eq(names, { "virtualizer", "watch" })
  H.eq(getmetatable(runtime), nil, "the runtime facade is a plain table")

  local virtualizer_names = vim.tbl_keys(runtime.virtualizer)
  table.sort(virtualizer_names)
  H.eq(virtualizer_names, { "apply", "attach", "detach" })
  H.eq(getmetatable(runtime.virtualizer), nil,
    "the virtualizer surface is a plain table")

  local watch_names = vim.tbl_keys(runtime.watch)
  table.sort(watch_names)
  H.eq(watch_names, { "reconcile", "start", "stop" })
  H.eq(getmetatable(runtime.watch), nil, "the watch surface is a plain table")

  for _, name in ipairs(virtualizer_names) do
    H.eq(type(runtime.virtualizer[name]), "function",
      "runtime.virtualizer." .. name .. " is callable")
  end
  for _, name in ipairs(watch_names) do
    H.eq(type(runtime.watch[name]), "function",
      "runtime.watch." .. name .. " is callable")
  end
end

T["runtime_ legacy watch module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.watch"] = nil
  local loaded = pcall(require, "canvasdiff.watch")
  assert(not loaded, "canvasdiff.watch must not remain as a forwarding module")
end

T["runtime_ legacy virt module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.virt"] = nil
  local loaded = pcall(require, "canvasdiff.virt")
  assert(not loaded, "canvasdiff.virt must not remain as a forwarding module")
end

T["runtime_ two Surfaces own and release independent controller leases"] = function()
  local Surface = require("canvasdiff.Surface")
  local root_a, root_b = H.tmpdir(), H.tmpdir()
  local buffers, windows, surfaces = {}, {}, {}

  local function make_state(root, col)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = col,
      width = 12,
      height = 4,
      style = "minimal",
    })
    buffers[#buffers + 1] = buf
    windows[#windows + 1] = win
    return {
      buf = buf,
      win = win,
      root = root,
      sections = {},
      collapsed = {},
    }
  end

  local ok, err = xpcall(function()
    local surface_a = Surface.new(make_state(root_a, 0))
    local surface_b = Surface.new(make_state(root_b, 14))
    surfaces = { surface_a, surface_b }
    surface_a.saved = true
    surface_b.saved = true

    local function install(surface)
      local generation = surface.generation
      surface.controllers.watch = runtime.watch.start(surface.state, {}, {
        alive = function() return surface:guard(generation) end,
      })
      surface.controllers.virt = runtime.virtualizer.attach(
        surface.state, { enabled = false }, {
          alive = function() return surface:guard(generation) end,
        })
    end

    install(surface_a)
    install(surface_b)
    local watch_a, watch_b =
      surface_a.controllers.watch, surface_b.controllers.watch
    local virt_a, virt_b =
      surface_a.controllers.virt, surface_b.controllers.virt

    assert(watch_a.group_name ~= watch_b.group_name)
    assert(virt_a.group_name ~= virt_b.group_name)
    assert(watch_a.aug ~= watch_b.aug)
    assert(virt_a.aug ~= virt_b.aug)

    H.eq(surface_a:dispose("test"), true)
    H.eq(surface_a.controllers.watch, nil,
      "Surface A unlinks its exact watch before teardown")
    H.eq(surface_a.controllers.virt, nil,
      "Surface A unlinks its exact virtualizer before teardown")
    H.eq(watch_a.disposed, true)
    H.eq(virt_a.disposed, true)
    H.eq(pcall(vim.api.nvim_get_autocmds, { group = watch_a.group_name }), false)
    H.eq(pcall(vim.api.nvim_get_autocmds, { group = virt_a.group_name }), false)

    H.eq(watch_b.disposed, false, "disposing A cannot retire B's watch")
    H.eq(virt_b.disposed, false, "disposing A cannot retire B's virtualizer")
    assert(pcall(vim.api.nvim_get_autocmds, { group = watch_b.group_name }))
    assert(pcall(vim.api.nvim_get_autocmds, { group = virt_b.group_name }))
    H.eq(runtime.virtualizer.apply(virt_b, { enabled = false }), false,
      "B remains independently usable")

    H.eq(surface_b:dispose("test"), true)
    H.eq(watch_b.disposed, true)
    H.eq(virt_b.disposed, true)
  end, debug.traceback)

  for _, surface in ipairs(surfaces) do
    pcall(function()
      surface.saved = true
      surface:dispose("cleanup")
    end)
  end
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(root_a, "rf")
  vim.fn.delete(root_b, "rf")
  assert(ok, err)
end

return T
