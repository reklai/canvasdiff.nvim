local H = require("helpers")

local T = {}

local function assert_retired_identity_absent(retired)
  local errors = {}
  local function inspect(label, names)
    for _, name in ipairs(names) do
      if type(name) == "string" and name:lower():find(retired, 1, true) then
        errors[#errors + 1] = ("%s still exposes retired identity: %s"):format(label, name)
      end
    end
  end

  inspect("module cache", vim.tbl_keys(package.loaded))
  inspect("namespace", vim.tbl_keys(vim.api.nvim_get_namespaces()))
  inspect("highlight", vim.fn.getcompletion("", "highlight"))
  inspect("command", vim.tbl_keys(vim.api.nvim_get_commands({ builtin = false })))

  local buffers = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    buffers[#buffers + 1] = vim.api.nvim_buf_get_name(buf)
  end
  inspect("buffer", buffers)

  local groups = {}
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
    groups[#groups + 1] = autocmd.group_name
  end
  inspect("autocmd group", groups)

  table.sort(errors)
  assert(#errors == 0, table.concat(errors, "\n"))
end

T["identity_ clean runtime exposes only CanvasDiff"] = function()
  local canonical = "canvasdiff"
  local retired = "gal" .. "ley"
  local retired_title = "Gal" .. "ley"
  local plugin = vim.fs.joinpath(
    H.project_root,
    "plugin",
    "canvasdiff.lua"
  )

  H.eq(package.loaded[retired], nil, "the retired root must not already be cached")
  H.eq(pcall(require, retired), false, "the retired root module must not resolve")
  H.eq(vim.fn.exists(":" .. retired_title), 0, "the retired command must not exist")
  H.eq(vim.g["loaded_" .. retired], nil, "the retired plugin guard must not exist")

  pcall(vim.api.nvim_del_user_command, "CanvasDiff")
  vim.g.loaded_canvasdiff = nil
  assert(loadfile(plugin))()
  H.eq(vim.fn.exists(":CanvasDiff"), 2, "the canonical command must exist")
  H.eq(vim.g.loaded_canvasdiff, true, "the canonical plugin guard must be set")

  -- A second source must take the guard path. Without it, recreating the
  -- command raises E174 and this assertion fails.
  local ok, err = pcall(function() assert(loadfile(plugin))() end)
  assert(ok, err)

  local loaded, facade = pcall(require, canonical)
  assert(loaded, facade)
  H.eq(type(facade), "table")
  assert_retired_identity_absent(retired)
end

return T
