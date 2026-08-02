local H = require("helpers")
local appearance = require("canvasdiff.appearance")

local T = {}

local function with_appearance(overrides, fn)
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  local ok, err = xpcall(function()
    local diagnostics = appearance.setup(overrides)
    fn(diagnostics)
  end, debug.traceback)
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

local GROUPS = {
  "CanvasDiffAdd", "CanvasDiffDel", "CanvasDiffGhost",
  "CanvasDiffPrefixAdd", "CanvasDiffPrefixDel",
  "CanvasDiffGutterAdd", "CanvasDiffGutterDel", "CanvasDiffFileBar",
  "CanvasDiffFileHeader", "CanvasDiffHunkHeader", "CanvasDiffBinary",
  "CanvasDiffWinbar", "CanvasDiffWinbarReadOnly",
  "CanvasDiffStaged", "CanvasDiffUnstaged", "CanvasDiffStale",
  "CanvasDiffStaleEmphasis", "CanvasDiffSidebarDir",
  "CanvasDiffSidebarActive", "CanvasDiffSidebarHunk",
  "CanvasDiffHunkDel", "CanvasDiffCrumb", "CanvasDiffScrollFile",
  "CanvasDiffScrollAdd", "CanvasDiffScrollDel",
  "CanvasDiffScrollChanged", "CanvasDiffScrollThumb",
}

T["appearance registry is the exact public highlight surface"] = function()
  local facade = vim.tbl_keys(appearance)
  table.sort(facade)
  H.eq(facade, { "audit", "ensure", "names", "setup" })
  H.eq(appearance.names(), GROUPS)
  local second = appearance.names()
  second[1] = "mutated"
  H.eq(appearance.names(), GROUPS, "callers receive a copy")
end

T["appearance colorscheme recovery defines every registered group"] = function()
  with_appearance({}, function()
    for _, name in ipairs(GROUPS) do
      vim.api.nvim_set_hl(0, name, {})
    end
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    for _, name in ipairs(GROUPS) do
      local value = vim.api.nvim_get_hl(0, { name = name, link = true })
      assert(next(value) ~= nil, name .. " was not defined")
    end
  end)
end

T["appearance ordinary ensure preserves an intentional foreign clear"] = function()
  with_appearance({}, function()
    appearance.ensure()
    vim.api.nvim_set_hl(0, "CanvasDiffWinbar", {})
    appearance.ensure()
    local value = vim.api.nvim_get_hl(0, {
      name = "CanvasDiffWinbar",
      link = true,
    })
    H.eq(value, {}, "an external empty definition owns the group")
  end)
end

T["appearance ensure preserves an identical explicit takeover during rederive"] = function()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = true })
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  local authored = vim.api.nvim_get_hl(0, {
    name = "CanvasDiffAdd",
    link = true,
  })
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", { bg = authored.bg })

  local ok, err = xpcall(function()
    local changed = vim.deepcopy(normal)
    changed.bg = authored.bg == 0x808080 and 0x101010 or 0x808080
    changed.default = nil
    vim.api.nvim_set_hl(0, "Normal", changed)
    -- A colourscheme clear removes manager defaults before the new palette is
    -- installed. Keep one manager-owned group on that path while the identical
    -- explicit takeover remains nonempty and foreign-owned.
    vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
    vim.api.nvim_exec_autocmds("ColorScheme", {})

    local add = vim.api.nvim_get_hl(0, {
      name = "CanvasDiffAdd",
      link = true,
    })
    local del = vim.api.nvim_get_hl(0, {
      name = "CanvasDiffDel",
      link = true,
    })
    H.eq(add.bg, authored.bg, "the identical explicit definition owns the group")
    assert(del.bg ~= authored.bg, "the manager-owned palette was rederived")
  end, debug.traceback)

  local restore = vim.deepcopy(normal)
  restore.default = nil
  restore.force = true
  vim.api.nvim_set_hl(0, "Normal", restore)
  vim.api.nvim_set_hl(0, "CanvasDiffAdd", {})
  vim.api.nvim_set_hl(0, "CanvasDiffDel", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance accepts native highlight fields"] = function()
  with_appearance({
    CanvasDiffFileBar = { fg = "#112233", bg = "#445566", bold = true },
  }, function(diagnostics)
    H.eq(diagnostics, {})
    local value = vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false })
    H.eq(value.fg, 0x112233)
    H.eq(value.bg, 0x445566)
    H.eq(value.bold, true)
  end)
end

T["appearance diagnoses unknown malformed and manager fields"] = function()
  local diagnostics = appearance.audit({
    CanvasDiffFyleBar = { bg = "#000000" },
    CanvasDiffGhost = "Comment",
    CanvasDiffFileBar = { default = true },
    CanvasDiffAdd = { force = true },
  })
  local text = table.concat(diagnostics, "\n")
  assert(text:find("CanvasDiffFyleBar", 1, true))
  assert(text:find("must be a table or false", 1, true))
  assert(text:find("default", 1, true))
  assert(text:find("force", 1, true))
  H.eq(appearance.audit("Comment"), {
    "highlights must be a table, got string",
  })
end

T["appearance validation raw-traverses highlight containers"] = function()
  local raw = {
    CanvasDiffFileBar = { bg = "#112233" },
  }
  local real_pairs = _G.pairs
  _G.pairs = function(value)
    if rawequal(value, raw) then error("hostile pairs") end
    return real_pairs(value)
  end
  local ok, diagnostics = pcall(appearance.audit, raw)
  _G.pairs = real_pairs
  H.eq(ok, true, tostring(diagnostics))
  H.eq(diagnostics, {})

  with_appearance(raw, function(diagnostics)
    H.eq(diagnostics, {})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
  end)
end

T["appearance audit diagnoses invalid native fields without global mutation"] = function()
  with_appearance({ CanvasDiffFileBar = { bg = "#123456" } }, function()
    local before = vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true })
    local diagnostics = appearance.audit({
      CanvasDiffFileBar = { bg = "definitely-not-a-colour" },
    })
    assert(table.concat(diagnostics, "\n"):find("is invalid", 1, true),
      vim.inspect(diagnostics))
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true }), before)
  end)
end

T["appearance setup applies valid siblings while diagnosing invalid ones"] = function()
  with_appearance({
    CanvasDiffFileBar = { bg = "#112233" },
    CanvasDiffGhost = "Comment",
    CanvasDiffFyleBar = { bg = "#abcdef" },
  }, function(diagnostics)
    H.eq(#diagnostics, 2)
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
  end)
end

T["appearance replacement releases only its own old override"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
    appearance.setup({})
    assert(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg ~= 0x112233)

    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#abcdef" })
    appearance.setup({})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0xabcdef)
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance omission restores the foreign definition displaced by override"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {
      fg = "#102030", bg = "#abcdef", sp = "#fedcba",
      bold = true, undercurl = true, ctermfg = 123,
    })
    local foreign = vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true })
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    appearance.setup({})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true }), foreign)
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance ensure retains a direct takeover beneath an active override"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {
      fg = "#102030", bg = "#abcdef", bold = true,
    })
    local foreign = vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true })

    appearance.ensure()
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233,
      "the configured override remains highest precedence")
    appearance.setup({})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true }), foreign)
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance false restores the foreign definition displaced by override"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#abcdef" })
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    appearance.setup({ CanvasDiffFileBar = false })
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0xabcdef)
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance colorscheme refreshes the underlay hidden by an override"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#abcdef" })
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })

    -- A colorscheme installs its definitions before the ColorScheme event.
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#445566" })
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)

    appearance.setup({})
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x445566)
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance omission preserves an identical explicit override takeover"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#112233" })
    appearance.setup({})
    local value = vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = true })
    H.eq(value.bg, 0x112233)
    assert(value.default ~= true,
      "an identical explicit definition retains foreign provenance")
  end, debug.traceback)
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

T["appearance isolates a throwing deepcopy and applies its valid sibling"] = function()
  local thread = coroutine.create(function() end)
  with_appearance({
    CanvasDiffFileBar = { bg = "#112233" },
    CanvasDiffGhost = { fg = thread },
  }, function(diagnostics)
    H.eq(#diagnostics, 1, vim.inspect(diagnostics))
    assert(diagnostics[1]:find("CanvasDiffGhost", 1, true), diagnostics[1])
    assert(diagnostics[1]:find("is invalid", 1, true), diagnostics[1])
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
  end)
end

T["appearance false releases an owned override to the current default"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
    local diagnostics = appearance.setup({ CanvasDiffFileBar = false })
    H.eq(diagnostics, {})
    assert(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg ~= 0x112233)
  end, debug.traceback)
  appearance.setup({})
  assert(ok, err)
end

T["appearance explicitly supplied override replaces a foreign definition"] = function()
  appearance.setup({})
  local ok, err = xpcall(function()
    vim.api.nvim_set_hl(0, "CanvasDiffFileBar", { bg = "#abcdef" })
    appearance.setup({ CanvasDiffFileBar = { bg = "#112233" } })
    H.eq(vim.api.nvim_get_hl(0,
      { name = "CanvasDiffFileBar", link = false }).bg, 0x112233)
  end, debug.traceback)
  appearance.setup({})
  vim.api.nvim_set_hl(0, "CanvasDiffFileBar", {})
  appearance.setup({})
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  assert(ok, err)
end

return T
