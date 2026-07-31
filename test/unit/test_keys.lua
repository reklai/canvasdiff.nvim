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
  H.eq(motion_names, { "cycle", "goto_file", "goto_hunk" })
  for _, name in ipairs(motion_names) do
    H.eq(type(input.motions[name]), "function",
      "input.motions." .. name .. " is callable")
  end

  local jump_names = vim.tbl_keys(input.jump)
  table.sort(jump_names)
  H.eq(jump_names, { "back", "cancel", "enter", "last_buf", "store" })
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
  for _, ctx in ipairs({ "global", "canvas", "sidebar", "file" }) do
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
  km.canvas.lens_next = false
  km.canvas.lens_prev = false
  km.canvas.sidebar = false
  local groups = keys.grouped({ "canvas" }, km)
  for _, g in ipairs(groups) do
    assert(g.name ~= "View",
      "View holds collapse, the two lens keys and the sidebar toggle;"
        .. " disabling all four drops the group")
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

T["keys_collisions reports global actions claiming the same key"] = function()
  local km = defaults()
  km.global.compare = "<leader>lx"
  km.global.checkout = "<leader>lx"
  local collision = keys.collisions("global", km)
  H.eq(collision[1].lhs, "<leader>lx")
  H.eq(collision[1].actions, { "compare", "checkout" })
end

T["keys_collisions is empty for the defaults"] = function()
  for _, ctx in ipairs({ "global", "canvas", "sidebar", "file" }) do
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

T["keys_global actions are described and independently configurable"] = function()
  local km = defaults()
  H.eq(find(keys.resolved("global", km), "compare"), { "<leader>lb" })
  H.eq(find(keys.resolved("global", km), "checkout"), { "<leader>lc" })

  local by_action = {}
  for _, mapping in ipairs(keys.resolved("global", km)) do
    by_action[mapping.action] = mapping
  end
  H.eq(by_action.compare.desc, "Compare two branches or revisions")
  H.eq(by_action.checkout.desc, "Checkout a local branch")
  H.eq(by_action.compare.group, "Global")
  H.eq(by_action.checkout.group, "Global")

  km.global.compare = { "gb", "gB" }
  km.global.checkout = false
  H.eq(find(keys.resolved("global", km), "compare"), { "gb", "gB" })
  H.eq(find(keys.resolved("global", km), "checkout"), {})
end

local function global_map(lhs)
  local target = vim.keycode(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap("n")) do
    if m.lhsraw == target or m.lhsrawalt == target then return m end
  end
end

local function delete_global(lhs)
  local map = global_map(lhs)
  if map then pcall(vim.keymap.del, "n", map.lhs) end
end

local function no_global_maps()
  return { compare = false, checkout = false }
end

local function capture_notifications(fn)
  local real = vim.notify
  local messages = {}
  vim.notify = function(message, level)
    messages[#messages + 1] = { message = message, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = real
  assert(ok, err)
  return messages
end

T["keys_global defaults route compare and checkout to the current App"] = function()
  delete_global("<leader>lb")
  delete_global("<leader>lc")
  package.loaded["canvasdiff"] = nil

  local App = require("canvasdiff.App")
  local real_compare, real_checkout = App.compare, App.checkout
  local calls = { compare = 0, checkout = 0 }
  App.compare = function(self)
    calls.compare = calls.compare + 1
    return self
  end
  App.checkout = function(self)
    calls.checkout = calls.checkout + 1
    return self
  end

  local fm = require("canvasdiff")
  assert(global_map("<leader>lb")).callback()
  assert(global_map("<leader>lc")).callback()
  H.eq(calls, { compare = 1, checkout = 1 })

  fm.setup({ keymaps = { global = no_global_maps() } })
  App.compare, App.checkout = real_compare, real_checkout
  delete_global("<leader>lb")
  delete_global("<leader>lc")
  config.setup({})
end

T["keys_global compare preserves a foreign collision and reports it"] = function()
  local lhs = "gZc"
  delete_global(lhs)
  local foreign_calls = 0
  local foreign = function() foreign_calls = foreign_calls + 1 end
  vim.keymap.set("n", lhs, foreign, { desc = "Foreign compare map" })

  local fm = require("canvasdiff")
  local messages = capture_notifications(function()
    fm.setup({ keymaps = { global = { compare = lhs, checkout = false } } })
  end)
  local installed = assert(global_map(lhs))
  assert(rawequal(installed.callback, foreign), "CanvasDiff must not replace a foreign callback")
  installed.callback()
  H.eq(foreign_calls, 1)
  assert(#messages == 1
      and messages[1].level == vim.log.levels.WARN
      and messages[1].message:find("CanvasDiff", 1, true)
      and messages[1].message:find(lhs, 1, true)
      and messages[1].message:find("already mapped", 1, true),
    "collision must produce one clear CanvasDiff warning: " .. vim.inspect(messages))

  fm.setup({ keymaps = { global = no_global_maps() } })
  assert(rawequal(assert(global_map(lhs)).callback, foreign),
    "disabling cannot delete a foreign collision")
  delete_global(lhs)
  config.setup({})
end

T["keys_global checkout preserves a foreign collision and reports it"] = function()
  local lhs = "gZd"
  delete_global(lhs)
  local foreign = function() end
  vim.keymap.set("n", lhs, foreign, { desc = "Foreign checkout map" })

  local fm = require("canvasdiff")
  local messages = capture_notifications(function()
    fm.setup({ keymaps = { global = { compare = false, checkout = lhs } } })
  end)
  assert(rawequal(assert(global_map(lhs)).callback, foreign),
    "CanvasDiff must not replace a foreign checkout callback")
  assert(#messages == 1
      and messages[1].level == vim.log.levels.WARN
      and messages[1].message:find(lhs, 1, true)
      and messages[1].message:find("already mapped", 1, true),
    "checkout collision must produce one clear warning: " .. vim.inspect(messages))

  fm.setup({ keymaps = { global = no_global_maps() } })
  assert(rawequal(assert(global_map(lhs)).callback, foreign),
    "disabling checkout cannot delete a foreign collision")
  delete_global(lhs)
  config.setup({})
end

T["keys_global actions rebind and disable independently"] = function()
  local compare_lhs, checkout_a, checkout_b = "gAa", "gAb", "gAc"
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { global = {
    compare = compare_lhs,
    checkout = { checkout_a, checkout_b },
  } } })
  assert(global_map(compare_lhs))
  assert(global_map(checkout_a))
  assert(global_map(checkout_b))

  fm.setup({ keymaps = { global = {
    compare = false,
    checkout = checkout_b,
  } } })
  H.eq(global_map(compare_lhs), nil)
  H.eq(global_map(checkout_a), nil)
  assert(global_map(checkout_b),
    "disabling compare cannot remove the retained checkout mapping")

  fm.setup({ keymaps = { global = no_global_maps() } })
end

T["keys_global changing an owned lhs action replaces its callback"] = function()
  local lhs = "gAd"
  local fm = require("canvasdiff")
  local App = require("canvasdiff.App")
  local real_compare, real_checkout = App.compare, App.checkout
  local calls = { compare = 0, checkout = 0 }
  App.compare = function() calls.compare = calls.compare + 1 end
  App.checkout = function() calls.checkout = calls.checkout + 1 end

  fm.setup({ keymaps = { global = {
    compare = lhs, checkout = false,
  } } })
  local compare_callback = assert(global_map(lhs)).callback
  compare_callback()

  fm.setup({ keymaps = { global = {
    compare = false, checkout = lhs,
  } } })
  local checkout_callback = assert(global_map(lhs)).callback
  assert(not rawequal(compare_callback, checkout_callback),
    "the old action callback cannot be retained")
  checkout_callback()
  H.eq(calls, { compare = 1, checkout = 1 })

  fm.setup({ keymaps = { global = no_global_maps() } })
  App.compare, App.checkout = real_compare, real_checkout
  delete_global(lhs)
  config.setup({})
end

T["keys_global post-initialization keytrans takeover survives an action swap"] = function()
  local lhs = "gAg"
  delete_global(lhs)
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { global = {
    compare = lhs, checkout = false,
  } } })

  local real_keytrans = vim.fn.keytrans
  local foreign = function() end
  vim.fn.keytrans = function(value)
    vim.keymap.set("n", lhs, foreign, { desc = "Keytrans takeover" })
    return real_keytrans(value)
  end
  local ok, err = pcall(function()
    capture_notifications(function()
      fm.setup({ keymaps = { global = {
        compare = false, checkout = lhs,
      } } })
    end)
  end)
  vim.fn.keytrans = real_keytrans
  assert(ok, err)

  assert(rawequal(assert(global_map(lhs)).callback, foreign),
    "a post-initialization foreign takeover must survive the action swap")
  fm.setup({ keymaps = { global = no_global_maps() } })
  assert(rawequal(assert(global_map(lhs)).callback, foreign),
    "foreign takeover remains outside CanvasDiff cleanup authority")
  delete_global(lhs)
  config.setup({})
end

T["keys_global rejects cross-action effective collisions before mutation"] = function()
  local old_leader = vim.g.mapleader
  vim.g.mapleader = " "
  local old_compare, old_checkout = "gAe", "gAf"
  local collided = "<Space>lx"
  local fm = require("canvasdiff")

  fm.setup({ keymaps = { global = {
    compare = old_compare, checkout = old_checkout,
  } } })
  local messages = capture_notifications(function()
    fm.setup({ keymaps = { global = {
      compare = "<leader>lx", checkout = collided,
    } } })
  end)
  assert(global_map(old_compare) and global_map(old_checkout),
    "invalid desired state cannot remove the prior valid state")
  H.eq(global_map(collided), nil)
  assert(messages[1].level == vim.log.levels.ERROR)
  assert(messages[1].message:find("same lhs", 1, true))

  fm.setup({ keymaps = { global = no_global_maps() } })
  vim.g.mapleader = old_leader
end

T["keys_global compare rebinds and disables only mappings it still owns"] = function()
  local first, second = "gZa", "gZb"
  delete_global(first)
  delete_global(second)
  local fm = require("canvasdiff")

  fm.setup({ keymaps = { global = { compare = first, checkout = false } } })
  local original = assert(global_map(first))
  fm.setup({ keymaps = { global = { compare = first, checkout = false } } })
  assert(rawequal(assert(global_map(first)).callback, original.callback),
    "repeated setup is idempotent")

  fm.setup({ keymaps = { global = { compare = { first, second }, checkout = false } } })
  assert(global_map(first) and global_map(second),
    "the list form installs every configured global lhs")
  fm.setup({ keymaps = { global = { compare = second, checkout = false } } })
  H.eq(global_map(first), nil, "rebind removes the old owned map")
  assert(global_map(second), "rebind installs the new map")

  fm.setup({ keymaps = { global = { compare = "", checkout = false } } })
  H.eq(global_map(second), nil, "an empty string disables the owned map")
  fm.setup({ keymaps = { global = { compare = {}, checkout = false } } })
  H.eq(global_map(second), nil, "an empty list remains disabled")
  delete_global(first)
  delete_global(second)
  config.setup({})
end

T["keys_global compare preserves a mapping that takes over its lhs"] = function()
  local first, second = "gZx", "gZy"
  delete_global(first)
  delete_global(second)
  local fm = require("canvasdiff")
  fm.setup({ keymaps = { global = { compare = first, checkout = false } } })

  local foreign = function() end
  vim.keymap.set("n", first, foreign, { desc = "Took over CanvasDiff lhs" })
  fm.setup({ keymaps = { global = { compare = second, checkout = false } } })
  assert(rawequal(assert(global_map(first)).callback, foreign),
    "rebind cannot remove a map whose callback/metadata no longer prove ownership")
  assert(global_map(second), "the newly requested free lhs still installs")

  vim.keymap.set("n", second, foreign, { desc = "Also took over" })
  fm.setup({ keymaps = { global = no_global_maps() } })
  assert(rawequal(assert(global_map(second)).callback, foreign),
    "disable cannot remove a taken-over map")
  delete_global(first)
  delete_global(second)
  config.setup({})
end

T["keys_global compare preserves same-callback takeovers with changed behavior metadata"] = function()
  local fm = require("canvasdiff")
  local cases = {
    { lhs = "gQn", opts = { nowait = true }, field = "nowait" },
    {
      lhs = "gQe",
      opts = { expr = true, replace_keycodes = false },
      field = "expr",
    },
    { lhs = "gQs", opts = { script = true }, field = "script" },
    {
      lhs = "gQr",
      opts = { expr = true, replace_keycodes = true },
      field = "replace_keycodes",
    },
  }
  for _, case in ipairs(cases) do
    delete_global(case.lhs)
    fm.setup({ keymaps = { global = { compare = case.lhs, checkout = false } } })
    local installed = assert(global_map(case.lhs))
    local opts = {
      desc = installed.desc,
      noremap = true,
      silent = true,
    }
    for name, value in pairs(case.opts) do opts[name] = value end
    vim.keymap.set("n", case.lhs, installed.callback, opts)
    local takeover = assert(global_map(case.lhs))
    assert(rawequal(takeover.callback, installed.callback),
      "the takeover deliberately retains the callback identity")

    fm.setup({ keymaps = { global = no_global_maps() } })
    assert(global_map(case.lhs),
      ("changed %s metadata must make the map foreign"):format(case.field))
    delete_global(case.lhs)
  end
  config.setup({})
end

T["keys_global compare validates a complete list before mutating any lhs"] = function()
  local fm = require("canvasdiff")
  local lhs = "gQi"
  delete_global(lhs)
  fm.setup({ keymaps = { global = no_global_maps() } })
  local cases = {
    { value = { lhs, "" }, fragment = "empty" },
    { value = { lhs, 42 }, fragment = "string" },
    { value = { lhs, lhs }, fragment = "same lhs" },
    { value = { lhs, string.rep("x", 51) }, fragment = "maximum" },
    { value = 42, fragment = "string or list" },
    { value = { named = lhs }, fragment = "dense list" },
  }
  for _, case in ipairs(cases) do
    local messages = capture_notifications(function()
      fm.setup({ keymaps = { global = {
        compare = case.value, checkout = false,
      } } })
    end)
    H.eq(global_map(lhs), nil,
      "an invalid complete value cannot leave an earlier list entry installed")
    assert(#messages == 1
        and messages[1].level == vim.log.levels.ERROR
        and messages[1].message:find(case.fragment, 1, true),
      "the validation error must be presented: " .. vim.inspect(messages))
  end
  fm.setup({ keymaps = { global = no_global_maps() } })
  delete_global(lhs)
  config.setup({})
end

T["keys_global compare preserves a same-callback same-behavior foreign reinstall"] = function()
  local fm = require("canvasdiff")
  local lhs = "gVp"
  delete_global(lhs)
  fm.setup({ keymaps = { global = { compare = lhs, checkout = false } } })
  local installed = assert(global_map(lhs))

  vim.keymap.set("n", lhs, installed.callback, {
    desc = installed.desc,
    noremap = true,
    silent = true,
  })
  local takeover = assert(global_map(lhs))
  assert(rawequal(takeover.callback, installed.callback))
  assert(takeover.lnum ~= installed.lnum or takeover.sid ~= installed.sid,
    "the foreign call site must have distinct observable provenance")

  fm.setup({ keymaps = { global = no_global_maps() } })
  local survived = assert(global_map(lhs),
    "same callback and behavior do not erase foreign call-site provenance")
  assert(rawequal(survived.callback, installed.callback))
  delete_global(lhs)
  config.setup({})
end

T["keys_global compare deletion bypasses reentrant public get and delete wrappers"] = function()
  local fm = require("canvasdiff")
  local get_lhs, del_lhs = "gVg", "gVd"
  delete_global(get_lhs)
  delete_global(del_lhs)

  fm.setup({ keymaps = { global = { compare = get_lhs, checkout = false } } })
  local real_get = vim.api.nvim_get_keymap
  local stale = real_get("n")
  local get_calls = 0
  local get_foreign = function() end
  vim.api.nvim_get_keymap = function(mode)
    get_calls = get_calls + 1
    if get_calls == 2 then
      vim.keymap.set("n", get_lhs, get_foreign, { desc = "Stale-get takeover" })
      return stale
    end
    return real_get(mode)
  end
  local get_ok, get_err = pcall(function()
    fm.setup({ keymaps = { global = no_global_maps() } })
  end)
  vim.api.nvim_get_keymap = real_get
  assert(get_ok, get_err)
  H.eq(get_calls, 0,
    "production authentication must use the captured native getter, not a Lua wrapper")
  H.eq(global_map(get_lhs), nil, "the original owned mapping is removed")

  fm.setup({ keymaps = { global = { compare = del_lhs, checkout = false } } })
  local real_del = vim.keymap.del
  local del_calls = 0
  local del_foreign = function() end
  vim.keymap.del = function(mode, target, opts)
    del_calls = del_calls + 1
    vim.keymap.set("n", del_lhs, del_foreign, { desc = "Delete takeover" })
    return real_del(mode, target, opts)
  end
  local del_ok, del_err = pcall(function()
    fm.setup({ keymaps = { global = no_global_maps() } })
  end)
  vim.keymap.del = real_del
  assert(del_ok, del_err)
  H.eq(del_calls, 0,
    "no reentrant Lua delete wrapper may run after final authentication")
  H.eq(global_map(del_lhs), nil, "the original owned mapping is removed")

  delete_global(get_lhs)
  delete_global(del_lhs)
  config.setup({})
end

T["keys_global compare deletion bypasses reentrant public comparison wrappers"] = function()
  local fm = require("canvasdiff")
  local lhs = "gVe"
  delete_global(lhs)
  fm.setup({ keymaps = { global = { compare = lhs, checkout = false } } })

  local real_deep_equal = vim.deep_equal
  local comparison_calls = 0
  local foreign = function() end
  vim.deep_equal = function()
    comparison_calls = comparison_calls + 1
    vim.keymap.set("n", lhs, foreign, { desc = "Comparison takeover" })
    return true
  end
  local ok, err = pcall(function()
    fm.setup({ keymaps = { global = no_global_maps() } })
  end)
  vim.deep_equal = real_deep_equal
  assert(ok, err)
  H.eq(comparison_calls, 0,
    "final ownership comparison must not call a replaceable Vim wrapper")
  H.eq(global_map(lhs), nil, "the original owned mapping is removed")

  delete_global(lhs)
  config.setup({})
end

T["keys_global compare coalesces notification reentry so the newest setup owns the result"] = function()
  local fm = require("canvasdiff")
  local collision_lhs, newest_lhs = "gRa", "gRb"
  delete_global(collision_lhs)
  delete_global(newest_lhs)
  fm.setup({ keymaps = { global = no_global_maps() } })
  local foreign = function() end
  vim.keymap.set("n", collision_lhs, foreign, { desc = "Foreign reentry trigger" })

  local real_notify = vim.notify
  local reentered = false
  vim.notify = function(message)
    if not reentered and tostring(message):find(collision_lhs, 1, true) then
      reentered = true
      fm.setup({ keymaps = { global = {
        compare = newest_lhs, checkout = false,
      } } })
    end
  end
  local ok, err = pcall(function()
    fm.setup({ keymaps = { global = {
      compare = collision_lhs, checkout = false,
    } } })
  end)
  vim.notify = real_notify
  assert(ok, err)
  assert(reentered, "the collision notification must exercise synchronous setup reentry")
  assert(rawequal(assert(global_map(collision_lhs)).callback, foreign))
  assert(global_map(newest_lhs), "the reentrant newest setup installs its map")

  fm.setup({ keymaps = { global = no_global_maps() } })
  H.eq(global_map(newest_lhs), nil,
    "the newest map remains in the ownership ledger and is removable")
  delete_global(collision_lhs)
  delete_global(newest_lhs)
  config.setup({})
end

T["keys_global compare recovers known ownership across set and delete failures"] = function()
  local App = require("canvasdiff.App")
  local set_lhs, later_set_lhs = "gRf", "gRh"
  local del_lhs, get_lhs = "gRd", "gRg"
  delete_global(set_lhs)
  delete_global(later_set_lhs)
  delete_global(del_lhs)
  delete_global(get_lhs)

  local native_get = vim.api.nvim_get_keymap
  local native_set = vim.api.nvim_set_keymap
  local native_del = vim.api.nvim_del_keymap
  local fail_set_lhs, fail_del, fail_get = nil, false, false
  local app = App.new({
    global_keymap_effects = {
      get = function(mode)
        if fail_get then error("injected keymap inspection failure") end
        return native_get(mode)
      end,
      set = function(mode, lhs, callback, opts)
        local native_opts = vim.deepcopy(opts)
        native_opts.callback = callback
        native_set(mode, lhs, "", native_opts)
        if lhs == fail_set_lhs then error("injected write-then-throw") end
      end,
      del = function(mode, lhs)
        if fail_del then error("injected delete failure") end
        return native_del(mode, lhs)
      end,
    },
  })

  config.setup({
    keymaps = { global = {
      compare = { set_lhs, later_set_lhs }, checkout = false,
    } },
  })
  fail_set_lhs = later_set_lhs
  capture_notifications(function()
    app:sync_global_keymaps()
  end)
  fail_set_lhs = nil
  assert(global_map(set_lhs), "the earlier setter succeeded before the later failure")
  assert(global_map(later_set_lhs), "the injected later setter wrote before it failed")
  config.setup({ keymaps = { global = no_global_maps() } })
  app:sync_global_keymaps()
  H.eq(global_map(set_lhs), nil, "the earlier set remains authenticated for cleanup")
  assert(global_map(later_set_lhs),
    "a throwing later setter cannot confer cleanup authority")

  config.setup({ keymaps = { global = {
    compare = del_lhs, checkout = false,
  } } })
  app:sync_global_keymaps()
  assert(global_map(del_lhs))
  config.setup({ keymaps = { global = no_global_maps() } })
  fail_del = true
  capture_notifications(function()
    app:sync_global_keymaps()
  end)
  fail_del = false
  assert(global_map(del_lhs), "a failed delete leaves the map and ledger intact")
  app:sync_global_keymaps()
  H.eq(global_map(del_lhs), nil, "a later setup retries cleanup")

  config.setup({ keymaps = { global = {
    compare = get_lhs, checkout = false,
  } } })
  app:sync_global_keymaps()
  assert(global_map(get_lhs))
  config.setup({ keymaps = { global = no_global_maps() } })
  fail_get = true
  capture_notifications(function()
    app:sync_global_keymaps()
  end)
  fail_get = false
  assert(global_map(get_lhs), "an inspection failure performs no unauthenticated delete")
  app:sync_global_keymaps()
  H.eq(global_map(get_lhs), nil, "the candidate ledger survives for a later cleanup")

  delete_global(set_lhs)
  delete_global(later_set_lhs)
  delete_global(del_lhs)
  delete_global(get_lhs)
  config.setup({})
end

T["keys_global compare never promotes a failed setter's foreign takeover"] = function()
  local App = require("canvasdiff.App")
  local owned_lhs, takeover_lhs = "gRt", "gRu"
  delete_global(owned_lhs)
  delete_global(takeover_lhs)

  local native_get = vim.api.nvim_get_keymap
  local native_set = vim.api.nvim_set_keymap
  local native_del = vim.api.nvim_del_keymap
  local first_install, callback
  local app = App.new({
    global_keymap_effects = {
      get = native_get,
      set = function(mode, lhs, installed_callback, opts)
        local native_opts = vim.deepcopy(opts)
        native_opts.callback = installed_callback
        native_set(mode, lhs, "", native_opts)
        if lhs == takeover_lhs then
          first_install = assert(global_map(lhs))
          callback = installed_callback
          vim.keymap.set(mode, lhs, installed_callback, opts)
          error("injected foreign takeover after write")
        end
      end,
      del = native_del,
    },
  })

  config.setup({
    keymaps = { global = {
      compare = { owned_lhs, takeover_lhs }, checkout = false,
    } },
  })
  capture_notifications(function()
    app:sync_global_keymaps()
  end)
  assert(global_map(owned_lhs), "the earlier successful mapping is known-owned")
  local takeover = assert(global_map(takeover_lhs))
  assert(rawequal(takeover.callback, callback),
    "the takeover deliberately reuses CanvasDiff's callback")
  assert(takeover.lnum ~= first_install.lnum or takeover.sid ~= first_install.sid,
    "the takeover must have different observable provenance")

  config.setup({ keymaps = { global = no_global_maps() } })
  app:sync_global_keymaps()
  H.eq(global_map(owned_lhs), nil,
    "a later setter failure must not orphan an earlier known-owned mapping")
  assert(global_map(takeover_lhs),
    "a failed setter never grants deletion authority over the observed identity")

  delete_global(owned_lhs)
  delete_global(takeover_lhs)
  config.setup({})
end

T["keys_global compare expands leader at each setup without crossing App ownership"] = function()
  local old_leader = vim.g.mapleader
  vim.g.mapleader = " "
  delete_global("<Space>lb")
  delete_global(",lb")

  local fm = require("canvasdiff")
  fm.setup({ keymaps = { global = {
    compare = "<leader>lb", checkout = false,
  } } })
  assert(global_map("<Space>lb"), "a Space leader is resolved when installed")
  vim.g.mapleader = ","
  fm.setup({ keymaps = { global = {
    compare = "<leader>lb", checkout = false,
  } } })
  H.eq(global_map("<Space>lb"), nil, "leader change removes the prior owned expansion")
  assert(global_map(",lb"), "leader change installs the current expansion")

  package.loaded["canvasdiff"] = nil
  local other
  local messages = capture_notifications(function()
    other = require("canvasdiff")
    other.setup({ keymaps = { global = {
      compare = "<leader>lb", checkout = false,
    } } })
  end)
  H.eq(#messages, 1,
    "a second App diagnoses the foreign owner once, not on every reconciliation")
  assert(global_map(",lb"), "a second App never replaces the first App's map")

  delete_global("<Space>lb")
  delete_global(",lb")
  vim.g.mapleader = old_leader
  other.setup({ keymaps = { global = no_global_maps() } })
  config.setup({})
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
    installed[#installed + 1] = m.lhs
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
