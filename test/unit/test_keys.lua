local H = require("helpers")
local input = require("canvasdiff.input")
local keys = input.keys
local config = require("canvasdiff.config")

local T = {}

local function defaults()
  return vim.deepcopy(config.defaults.keymaps)
end

local function find(entries, action)
  local out = {}
  for _, m in ipairs(entries) do
    if m.action == action then out[#out + 1] = m.lhs end
  end
  return out
end

T["input_ facade exports exactly the supported key and motion operations"] = function()
  local names = vim.tbl_keys(input)
  table.sort(names)
  H.eq(names, { "command", "jump", "keys", "motions" })

  local key_names = vim.tbl_keys(input.keys)
  table.sort(key_names)
  H.eq(key_names, { "collisions", "grouped", "list", "resolved" })
  for _, name in ipairs(key_names) do
    H.eq(type(input.keys[name]), "function", "input.keys." .. name .. " is callable")
  end

  local motion_names = vim.tbl_keys(input.motions)
  table.sort(motion_names)
  H.eq(motion_names, { "cycle_hunk", "goto_file", "goto_hunk", "hunk_stops" })
  for _, name in ipairs(motion_names) do
    H.eq(type(input.motions[name]), "function",
      "input.motions." .. name .. " is callable")
  end

  local jump_names = vim.tbl_keys(input.jump)
  table.sort(jump_names)
  H.eq(jump_names, {
    "back", "cancel", "enter", "last_buf", "locate", "store", "whereabouts",
  })
  for _, name in ipairs(jump_names) do
    H.eq(type(input.jump[name]), "function",
      "input.jump." .. name .. " is callable")
  end
end

T["input_ legacy keys module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.keys"] = nil
  local loaded = pcall(require, "canvasdiff.keys")
  assert(not loaded, "canvasdiff.keys must not remain as a forwarding module")
end

T["input_ legacy motions module path is deleted rather than shimmed"] = function()
  package.loaded["canvasdiff.motions"] = nil
  local loaded = pcall(require, "canvasdiff.motions")
  assert(not loaded, "canvasdiff.motions must not remain as a forwarding module")
end

-- --- K.list ------------------------------------------------------------

T["keys_list normalizes every accepted form"] = function()
  H.eq(keys.list("q"), { "q" }, "a bare string becomes a one-element list")
  H.eq(keys.list({ "a", "b" }), { "a", "b" }, "a list passes through")
  H.eq(keys.list(nil), {}, "nil disables")
  H.eq(keys.list(false), {}, "false disables")
  H.eq(keys.list(""), {}, "an empty string disables")
  H.eq(keys.list({}), {}, "an empty list disables")
end

T["keys_list returns a copy, never live config"] = function()
  local src = { "a", "b" }
  local got = keys.list(src)
  got[1] = "MUTATED"
  H.eq(src[1], "a", "mutating the result must not reach the caller's table")
end

-- --- K.resolved --------------------------------------------------------

T["keys_resolved expands a multi-key action to one entry per key"] = function()
  local got = keys.resolved("canvas", defaults())
  H.eq(find(got, "jump"), { "<CR>", "<2-LeftMouse>" })
  H.eq(find(got, "collapse"), { "za", "c" })
  H.eq(find(got, "close"), { "q" })
end

T["keys_resolved honors a user override and replaces the whole list"] = function()
  local km = defaults()
  km.canvas.collapse = "za" -- list -> string: `c` must be gone
  km.canvas.jump = { "<CR>", "o" }
  local got = keys.resolved("canvas", km)
  H.eq(find(got, "collapse"), { "za" }, "overriding with a string drops the alternate key")
  H.eq(find(got, "jump"), { "<CR>", "o" })
end

T["keys_resolved drops disabled actions entirely"] = function()
  local km = defaults()
  km.canvas.close = false
  km.canvas.refresh = {}
  local got = keys.resolved("canvas", km)
  H.eq(find(got, "close"), {}, "false installs nothing")
  H.eq(find(got, "refresh"), {}, "an empty list installs nothing")
end

T["keys_resolved every default resolves and carries a desc"] = function()
  for _, ctx in ipairs({ "canvas", "sidebar", "file" }) do
    local got = keys.resolved(ctx, defaults())
    assert(#got > 0, ctx .. " must resolve at least one binding")
    for _, m in ipairs(got) do
      assert(type(m.lhs) == "string" and m.lhs ~= "",
        ctx .. "." .. m.action .. " resolved to an empty lhs")
      assert(type(m.desc) == "string" and m.desc ~= "",
        ctx .. "." .. m.action .. " has no desc")
    end
  end
end

T["keys_resolved is empty for an unknown context"] = function()
  H.eq(keys.resolved("nope", defaults()), {})
  H.eq(keys.resolved("canvas", {}), {}, "missing sub-table is not an error")
end

-- --- K.grouped ---------------------------------------------------------

T["keys_grouped collapses a multi-key action into one row"] = function()
  local groups = keys.grouped({ "canvas" }, defaults())
  local collapse
  for _, g in ipairs(groups) do
    for _, item in ipairs(g.items) do
      if item.action == "collapse" then collapse = item end
    end
  end
  assert(collapse, "collapse must appear in the grouped view")
  H.eq(collapse.keys, { "za", "c" },
    "grouped shows one row carrying both keys, unlike resolved's two entries")
end

T["keys_grouped omits disabled actions and empty groups"] = function()
  local km = defaults()
  km.canvas.collapse = false
  km.canvas.review_next = false
  km.canvas.filter_unreviewed = false
  km.canvas.expand_context = false
  km.canvas.shrink_context = false
  km.canvas.peek_hunk = false
  km.canvas.lens_next = false
  km.canvas.lens_prev = false
  km.canvas.checkpoint = false
  km.canvas.sidebar = false
  local groups = keys.grouped({ "canvas" }, km)
  for _, g in ipairs(groups) do
    assert(g.name ~= "View",
      "disabling every action in View drops the group")
    for _, item in ipairs(g.items) do
      assert(item.action ~= "collapse", "a disabled action must not be listed")
    end
  end
end

T["keys_grouped follows group_order and spans contexts"] = function()
  local groups = keys.grouped({ "canvas", "file", "sidebar" }, defaults())
  local names = {}
  for _, g in ipairs(groups) do names[#names + 1] = g.name end
  H.eq(names, { "Navigate", "Jump", "View", "Canvas", "Sidebar" })

  -- `back` lives on the file buffer, not the canvas, but belongs in the Jump
  -- section of the cheatsheet alongside the jump that created the excursion.
  local jump_actions = {}
  for _, g in ipairs(groups) do
    if g.name == "Jump" then
      for _, item in ipairs(g.items) do jump_actions[#jump_actions + 1] = item.action end
    end
  end
  H.eq(jump_actions, { "jump", "back" })
end

-- --- K.collisions ------------------------------------------------------

T["keys_collisions reports a key claimed twice"] = function()
  local km = defaults()
  km.canvas.refresh = "q" -- already taken by close
  local got = keys.collisions("canvas", km)
  H.eq(#got, 1, "exactly one contested key")
  H.eq(got[1].lhs, "q")
  table.sort(got[1].actions)
  H.eq(got[1].actions, { "close", "refresh" })
end

T["keys_collisions is empty for the defaults"] = function()
  for _, ctx in ipairs({ "canvas", "sidebar", "file" }) do
    H.eq(keys.collisions(ctx, defaults()), {}, "shipped defaults must not collide in " .. ctx)
  end
end

T["keys_help resolves in both contexts and stays collision-free"] = function()
  H.eq(find(keys.resolved("canvas", defaults()), "help"), { "<leader>lh" })
  H.eq(find(keys.resolved("sidebar", defaults()), "help"), { "<leader>lh" })
  for _, ctx in ipairs({ "canvas", "sidebar", "file" }) do
    H.eq(keys.collisions(ctx, defaults()), {}, "help must not contest a key in " .. ctx)
  end
end

T["keys_stage_file capitals default to S and U on the canvas only"] = function()
  H.eq(find(keys.resolved("canvas", defaults()), "stage_file"), { "S" })
  H.eq(find(keys.resolved("canvas", defaults()), "unstage_file"), { "U" })
  -- The sidebar's s/u are already file-level, so it needs no capital twins.
  H.eq(find(keys.resolved("sidebar", defaults()), "stage_file"), {})
  H.eq(find(keys.resolved("sidebar", defaults()), "unstage_file"), {})

  local km = defaults()
  km.canvas.stage_file = "gS"
  km.canvas.unstage_file = false
  H.eq(find(keys.resolved("canvas", km), "stage_file"), { "gS" })
  H.eq(find(keys.resolved("canvas", km), "unstage_file"), {})
end

-- The one binding in this feature whose MEANING changed: Ctrl+N / Ctrl+P keep
-- their keys and their scroll-and-wrap mechanics, but their stops are hunks
-- now. The file axis they used to walk was retired entirely (see
-- REMOVED_ACTIONS in config: it shipped unbound as a migration path and
-- gathered no travelers); ]f/[f are the file motions.
T["keys_cycle Ctrl+N describes hunk stops"] = function()
  local km = defaults()
  H.eq(find(keys.resolved("canvas", km), "cycle_next"), { "<C-n>" })
  H.eq(find(keys.resolved("canvas", km), "cycle_prev"), { "<C-p>" })

  local desc = {}
  for _, m in ipairs(keys.resolved("canvas", km)) do desc[m.action] = m.desc end
  for _, action in ipairs({ "cycle_next", "cycle_prev" }) do
    assert(desc[action]:find("hunk", 1, true),
      action .. " must describe hunk stops, got: " .. desc[action])
    assert(desc[action]:find("folded", 1, true),
      action .. " must say what a folded file counts as, got: " .. desc[action])
  end
end

T["keys_stage defaults to s and unstage to u on canvas and sidebar, both configurable"] = function()
  H.eq(find(keys.resolved("canvas", defaults()), "stage"), { "s" })
  H.eq(find(keys.resolved("sidebar", defaults()), "stage"), { "s" })
  H.eq(find(keys.resolved("canvas", defaults()), "unstage"), { "u" })
  H.eq(find(keys.resolved("sidebar", defaults()), "unstage"), { "u" })
  local km = defaults()
  km.canvas.stage = "gs"
  km.sidebar.stage = false
  km.canvas.unstage = "gu"
  km.sidebar.unstage = false
  H.eq(find(keys.resolved("canvas", km), "stage"), { "gs" })
  H.eq(find(keys.resolved("sidebar", km), "stage"), {})
  H.eq(find(keys.resolved("canvas", km), "unstage"), { "gu" })
  H.eq(find(keys.resolved("sidebar", km), "unstage"), {})
end

-- --- installed maps ----------------------------------------------------

T["keys_install every canvas mapping is registered with a desc"] = function()
  local root = H.git_fixture({
    committed = { ["a.txt"] = "a1\n" },
    worktree = { ["a.txt"] = "A1\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.open()
  local buf = vim.api.nvim_get_current_buf()

  local installed = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    -- Normalized like `expected` below: keytrans notation drifts across
    -- Neovim versions (0.13 renders a raw backslash as <Bslash>), and only
    -- a comparison with both sides normalized survives that.
    installed[#installed + 1] = H.norm_lhs(m.lhs)
    assert(m.desc and m.desc ~= "",
      "every mapping needs a desc so it shows up in :map / which-key; missing on " .. m.lhs)
  end
  table.sort(installed)

  local expected = {}
  for _, m in ipairs(keys.resolved("canvas", config.options.keymaps)) do
    expected[#expected + 1] = H.norm_lhs(m.lhs)
  end
  -- The minimap scrollbar owns the mouse gesture keys on the canvas buffer
  -- (thumb drag / track jump; part of scrollbar.enabled, not of the keymaps
  -- registry). They are held to the same desc rule by the loop above.
  for _, lhs in ipairs({ "<LeftMouse>", "<LeftDrag>", "<LeftRelease>" }) do
    expected[#expected + 1] = H.norm_lhs(lhs)
  end
  table.sort(expected)

  fm.close()
  vim.api.nvim_set_current_dir(old_cwd)

  H.eq(installed, expected, "installed maps must be exactly what the registry resolves")
end

return T
