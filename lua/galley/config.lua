local util = require("galley.util")

local M = {}

-- Keymaps are grouped by the buffer they live on, because the same key means
-- different things in different places: `q` closes the canvas but only the
-- sidebar when pressed there, and `<Tab>`/`za`/`<CR>` are each claimed twice.
-- A flat table would need sidebar_select_alt-style names to disambiguate.
--
-- Every value takes a single key or a list of them, so an action can own more
-- than one binding. A user override REPLACES the list rather than merging into
-- it (vim.tbl_deep_extend's behaviour for list-like tables), so
-- `collapse = "<Tab>"` really does drop `za`. `false` or `{}` disables.
M.defaults = {
  keymaps = {
    canvas = {
      jump       = { "<CR>", "<2-LeftMouse>" },
      collapse   = { "<Tab>", "za" },
      next_file  = "]f",
      prev_file  = "[f",
      next_hunk  = "]h",
      prev_hunk  = "[h",
      cycle_next = "<C-n>",
      cycle_prev = "<C-p>",
      refresh    = "R",
      base       = "B",
      close      = "q",
    },
    sidebar = {
      -- Double-click, not single: <LeftMouse> is how you position the cursor,
      -- and stealing it would make the tree impossible to browse.
      select = { "<CR>", "<Tab>", "za", "<2-LeftMouse>" },
      close  = "q",
    },
    -- Set on the real file's buffer for the duration of a jump, then removed.
    file = {
      back = "<M-CR>",
    },
  },
  context = 3,
  base = "HEAD",
  sidebar = {
    enabled = true,
    width = 32,
  },
  highlight = {
    enabled = true,
    margin = 100,
    debounce_ms = 30,
  },
  watch = {
    enabled = true,
    debounce_ms = 200,
  },
  scrollbar = {
    enabled = true,
  },
  statuscolumn = {
    enabled = true,
  },
  virt = {
    enabled = true,
    max_files = 200,
    max_lines = 100000,
    margin = 100,
    max_expanded = 20,
  },
  session = {
    enabled = true,
  },
}

M.options = vim.deepcopy(M.defaults)

-- The raw table the user passed to setup(), kept unmerged so :checkhealth can
-- diff it against the defaults and report keys that were silently swallowed --
-- tbl_deep_extend accepts `canvas.colapse` without complaint, and the only
-- symptom is a keymap that never appears.
M.user_opts = {}

-- Action names from the pre-1.0 flat keymaps table. Their presence as a
-- top-level string is an unambiguous legacy marker: in the current shape every
-- top-level value is a sub-table.
local LEGACY_ACTIONS = {
  "jump", "back", "close", "refresh", "cycle_next", "cycle_prev",
  "collapse", "next_file", "prev_file", "next_hunk", "prev_hunk",
}

--- Names from the old flat keymaps shape found at the top level, or nil.
local function legacy_keymaps(keymaps)
  if type(keymaps) ~= "table" then
    return nil
  end
  local found = {}
  for _, name in ipairs(LEGACY_ACTIONS) do
    if type(keymaps[name]) == "string" then
      found[#found + 1] = name
    end
  end
  return #found > 0 and found or nil
end

--- Merge `opts` into the current config (deep, `opts` wins). Never called ⇒
--- `M.options` stays at `M.defaults`.
---
--- Warns loudly on the old flat keymaps shape instead of silently ignoring it:
--- the sub-tables would simply never be found and every binding would fall
--- back to its default, which reads as "my config stopped working".
function M.setup(opts)
  opts = opts or {}
  local legacy = legacy_keymaps(opts.keymaps)
  if legacy then
    util.err(
      "keymaps are now grouped by context; found flat key(s): "
        .. table.concat(legacy, ", ")
        .. ". Use keymaps = { canvas = {...}, sidebar = {...}, file = { back = ... } }"
        .. " -- see :help galley-mappings"
    )
  end
  M.user_opts = vim.deepcopy(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  return M.options
end

return M
