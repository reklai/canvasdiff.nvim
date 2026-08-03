-- Scene driver for the README media. Run from the repository root:
--   nvim --headless --clean -l media/shoot/shoot.lua <scene> <fixture> <out>
-- Scenes write SVG frames plus a manifest; run.sh rasterises and assembles.
local shoot_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
package.path = shoot_dir .. "/?.lua;" .. package.path
local rpc = require("rpc")
local render = require("render")

local scene_name, fixture, out = _G.arg[1], _G.arg[2], _G.arg[3]
assert(scene_name and fixture and out, "usage: shoot.lua <scene> <fixture> <out>")
vim.fn.mkdir(out, "p")

local repo = shoot_dir:gsub("/media/shoot$", "")
local tokyonight = vim.fn.expand("~/.local/share/nvim/lazy/tokyonight.nvim")

local manifest = assert(io.open(out .. "/manifest.txt", "w"))
local frame_index = 0

-- Every capture goes through here: still shots are one-frame manifests.
local function snap(client, name, delay_cs, opts)
  frame_index = frame_index + 1
  local file = ("%03d-%s.svg"):format(frame_index, name)
  render.write(client.grid, out .. "/" .. file, opts)
  manifest:write(("%d %s\n"):format(delay_cs or 100, file))
end

local function start(width, height, extra_setup, extra_rtp)
  -- Sessions (lens, folds, position) persist per repository; isolating the
  -- state dir keeps every shot deterministic across runs.
  local args = {
    "--embed", "-n", "--clean",
    "--cmd", "set rtp^=" .. repo,
    "--cmd", "set rtp+=" .. tokyonight,
  }
  for _, path in ipairs(extra_rtp or {}) do
    args[#args + 1] = "--cmd"
    args[#args + 1] = "set rtp+=" .. path
  end
  local client = rpc.spawn({
    args = args,
    cwd = fixture,
    env = {
      "PATH=" .. os.getenv("PATH"),
      "HOME=" .. os.getenv("HOME"),
      "XDG_STATE_HOME=" .. out .. "/xdg-state",
      "XDG_DATA_HOME=" .. out .. "/xdg-data",
      "XDG_CACHE_HOME=" .. out .. "/xdg-cache",
    },
    width = width,
    height = height,
  })
  client:lua(([[
    vim.o.termguicolors = true
    vim.cmd.colorscheme("tokyonight-moon")
    vim.o.laststatus = 0
    vim.opt.shortmess:append("I")
    require("canvasdiff").setup({})
    %s
  ]]):format(extra_setup or ""))
  return client
end

local function open_canvas(client, command)
  client:input(":" .. (command or "CanvasDiff") .. "<CR>")
  client:settle(1200)
end

-- Lens switches rebuild the canvas asynchronously; wait for the winbar to
-- name the expected lens instead of guessing a delay.
local function wait_winbar(client, pattern)
  local ok = vim.wait(5000, function()
    local winbar = client:lua([[return vim.wo.winbar]])
    return type(winbar) == "string" and winbar:find(pattern, 1, true) ~= nil
  end, 50)
  assert(ok, "winbar never matched: " .. pattern)
  client:settle(300)
end

local scenes = {}

-- The first thing a visitor sees: the whole changeset as one buffer, with
-- the sidebar, file bars, staged/unstaged dots and the minimap all visible.
function scenes.hero()
  local client = start(150, 40)
  open_canvas(client)
  client:lua([[vim.fn.search("history")]])
  client:input("zz")
  client:settle(400)
  snap(client, "hero", 100, { cursor = true, rows = { 1, 39 } })
  client:close()
end

-- The live loop: Enter into the real file, edit, save, jump back, and the
-- canvas already shows the new line.
function scenes.live()
  local client = start(120, 32)
  open_canvas(client)
  snap(client, "canvas", 160, { cursor = true, rows = { 1, 31 } })
  client:lua([[vim.fn.search("must be callable")]])
  client:input("zz")
  snap(client, "target", 120, { cursor = true, rows = { 1, 31 } })
  client:input("<CR>")
  client:settle(500)
  snap(client, "realfile", 140, { cursor = true, rows = { 1, 31 } })
  client:input("O")
  for char in ("-- reject junk early"):gmatch(".") do
    client:input(char)
    snap(client, "typing", 7, { cursor = true, rows = { 1, 31 } })
  end
  client:input("<Esc>")
  snap(client, "typed", 60, { cursor = true, rows = { 1, 31 } })
  client:input(":w<CR>")
  client:settle(700)
  snap(client, "saved", 140, { cursor = true, rows = { 1, 31 } })
  client:input("<C-Space>")
  client:settle(900)
  snap(client, "back", 400, { cursor = true, rows = { 1, 31 } })
  client:close()
end

-- Read-only revision comparison, no checkout.
function scenes.compare()
  local client = start(140, 34)
  open_canvas(client, "CanvasDiff main..feature/backoff")
  client:lua([[vim.fn.search("BACKOFF_BASE_MS")]])
  client:input("zz")
  client:settle(300)
  snap(client, "compare", 100, { cursor = true, rows = { 1, 33 } })
  client:close()
end

-- Sidebar: a folded directory as one summary row, then Enter jumping the
-- canvas to the selected hunk.
function scenes.sidebar()
  local client = start(140, 34)
  open_canvas(client)
  -- The sidebar is already open; move focus into it.
  client:input("<C-w>h")
  client:settle(200)
  client:lua([[vim.fn.search("lua/", "cw")]])
  client:input("za")
  client:settle(400)
  snap(client, "folded", 100, { cursor = true, rows = { 1, 33 } })
  client:input("za")
  client:settle(400)
  client:lua([[vim.fn.search("@@ 12")]])
  client:settle(200)
  client:input("<CR>")
  client:settle(500)
  snap(client, "jumped", 100, { cursor = true, rows = { 1, 33 } })
  client:close()
end

-- The three lenses, cropped to the strip that names them: winbar + first
-- file. Same review, different filters.
function scenes.lenses()
  local client = start(140, 36)
  open_canvas(client)
  wait_winbar(client, "HEAD → WORKTREE")
  snap(client, "all", 100, { rows = { 1, 14 } })
  client:input("<Tab>")
  wait_winbar(client, "INDEX → WORKTREE")
  snap(client, "unstaged", 100, { rows = { 1, 14 } })
  client:input("<Tab>")
  wait_winbar(client, "HEAD → INDEX")
  snap(client, "staged", 100, { rows = { 1, 14 } })
  client:close()
end

-- The cheatsheet and the two pickers.
function scenes.keys()
  -- The pickers go through vim.ui.select; telescope-ui-select stands in for
  -- the kind of picker a real config provides (plain inputlist otherwise).
  local lazy = vim.fn.expand("~/.local/share/nvim/lazy")
  local client = start(110, 32, [[
    require("telescope").setup({
      extensions = {
        ["ui-select"] = require("telescope.themes").get_dropdown({}),
      },
    })
    require("telescope").load_extension("ui-select")
  ]], {
    lazy .. "/plenary.nvim",
    lazy .. "/telescope.nvim",
    lazy .. "/telescope-ui-select.nvim",
  })
  open_canvas(client)
  client:input("\\lh")
  client:settle(400)
  snap(client, "cheatsheet", 100, { rows = { 1, 31 } })
  client:input("q")
  client:settle(200)
  client:input("\\lb")
  client:settle(400)
  snap(client, "compare-picker", 100, { rows = { 1, 31 } })
  client:input("<Esc>")
  client:settle(200)
  client:input("\\lc")
  client:settle(400)
  snap(client, "checkout", 100, { rows = { 1, 31 } })
  client:close()
end

assert(scenes[scene_name], "unknown scene: " .. scene_name)()
manifest:close()
print("scene " .. scene_name .. " done")
