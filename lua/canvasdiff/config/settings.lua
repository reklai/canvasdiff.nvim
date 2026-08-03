-- Owns CanvasDiff's live configuration state and validation.
local M = {}

--- Every glyph CanvasDiff draws, owned by configuration so applying an override
--- never requires config to depend upward on the canvas presentation domain.
---
--- Read live by formatters rather than snapshotted. `stale` is used for byte
--- arithmetic when placing its highlight span, so a cached value or length would
--- put the mark on the wrong columns after an override.
local DEFAULT_GLYPHS = {
  -- diff row prefixes
  ctx = " ",
  del = "-",
  add = "+",
  -- structure
  file = "▎",
  folded = "▸",
  open = "▾",
  minus = "−",
  -- the statuscolumn bar drawn beside add/del rows
  gutter = "▎",
  -- sidebar markers
  staged = "●",
  unstaged = "○",
  -- Appended to a row, so the leading space is part of the configured value.
  stale = " ●",
  -- Separates the pinned header's file identity from the hunk breadcrumb after
  -- it. Both spaces are part of the configured value: the file part must stay a
  -- byte-for-byte mirror of the header row it covers, so the separator owns
  -- every character between them.
  crumb = " → ",
  -- And inside the crumb, between the hunk's label and its ordinal. A second
  -- slot rather than part of `crumb`: they sit on either side of the `@@`
  -- marker, so one value could not produce both.
  crumb_sep = " · ",
  -- minimap
  scroll_file = "‒",
  scroll_bar = "❘",
}

M.glyphs = vim.deepcopy(DEFAULT_GLYPHS)

--- A glyph set that needs nothing beyond ASCII, for a restricted font, a Linux
--- framebuffer console, or anywhere the defaults render as boxes. Pass it as
--- `glyphs = "ascii"`.
---
--- Every character here is one cell wide under BOTH `ambiwidth` settings, which the
--- defaults are not: `● ○ ▎ −` are East Asian Ambiguous and double under
--- `ambiwidth=double`, so the marker column and the file-header gutter change width
--- for anyone with that set.
---
--- Note `stale = " !"` against `staged = "*"`. In the default set those two are the
--- SAME glyph (`●`) and only the highlight separates them; here they differ in the text
--- itself, so the ASCII set is the one place that distinction cannot be lost to a
--- colourscheme.
M.ASCII_GLYPHS = {
  ctx = " ", del = "-", add = "+",
  file = "|", folded = ">", open = "v", minus = "-", gutter = "|",
  staged = "*", unstaged = "o", stale = " !",
  crumb = " -> ", crumb_sep = " | ",
  scroll_file = "-", scroll_bar = "|",
}

local function reset_glyphs()
  for name, glyph in pairs(DEFAULT_GLYPHS) do
    M.glyphs[name] = glyph
  end
end

local function is_glyph(name)
  return DEFAULT_GLYPHS[name] ~= nil
end

-- `highlights` is an extension schema whose arbitrary native values belong to
-- appearance validation. Capture entries independently so one value Neovim's
-- deepcopy rejects cannot abort config or discard valid siblings.
local function capture_highlights(raw)
  if type(raw) ~= "table" then return raw end
  local captured = {}
  for name, spec in next, raw do
    local ok, copy = pcall(vim.deepcopy, spec)
    captured[name] = ok and copy or spec
  end
  return captured
end

-- Keymaps are grouped by the context they live in. `global` is process-wide;
-- the other contexts name the buffer that receives the mapping, because the
-- same key means different things in different places: `q` closes the canvas
-- but only the sidebar when pressed there, and `<Tab>`/`za`/`<CR>` are each
-- claimed twice.
-- A flat table would need sidebar_select_alt-style names to disambiguate.
--
-- Every value takes a single key or a list of them, so an action can own more
-- than one binding. A user override REPLACES the list rather than merging into
-- it (vim.tbl_deep_extend's behaviour for list-like tables), so
-- `collapse = "<Tab>"` really does drop `za`. `false` or `{}` disables.
M.defaults = {
  keymaps = {
    global = {
      -- Process-wide defaults. App installs each conservatively: an existing
      -- user/plugin mapping wins, and setup removes only authenticated ownership.
      compare = "<leader>lb",
      checkout = "<leader>lc",
    },
    canvas = {
      jump       = { "<CR>", "<2-LeftMouse>" },
      -- Vim's own fold key first, plus `c` for collapse -- the action you press
      -- most in a sweep, so it gets a single unshifted key.
      --
      -- `c` is free rather than merely convenient: it is a change operator, and
      -- the canvas is nofile + nomodifiable + undolevels=-1, so `cw` there fails
      -- with E21 and does nothing at all. Measured on the real buffer, not
      -- assumed. The same holds for the whole editing family (d s x p i a o r ~ J
      -- and their capitals), which is where to look if you want a different one.
      --
      -- Was Shift+Space, which needed a terminal speaking the kitty keyboard
      -- protocol: Space is the one key that cannot carry a modifier in classic
      -- terminal encoding, so elsewhere it arrived as a bare Space and merely
      -- moved the cursor right. That is NOT true of Shift+Tab or `R` below --
      -- those are an ordinary CSI Z and byte 0x52.
      collapse   = { "za", "c" },
      next_file  = "]f",
      prev_file  = "[f",
      next_hunk  = "]h",
      prev_hunk  = "[h",
      cycle_next = "<C-n>",
      cycle_prev = "<C-p>",
      -- The file-at-a-time scrolling the two keys above used to do. Unbound:
      -- `{}` means disabled, so no map installs until a user asks for one --
      -- `cycle_file_next = "<C-n>"` puts the old behaviour back on the old key.
      cycle_file_next = {},
      cycle_file_prev = {},
      -- Re-collects and splices in what changed, so the same TEXT stays under your
      -- cursor. Inert to take: `ra` is replace-char, which nomodifiable makes E21.
      --
      -- `R` is deliberately left FREE. It briefly held a hard-rebuild action, on the
      -- theory that a reconcile can only splice what it believes differs and so
      -- cannot repair a state/buffer divergence. True, but close() + open() repairs
      -- exactly that AND restores your position from the session file, which a bare
      -- render_all does not -- measured, both ways. A second verb that is strictly
      -- worse than two keys you already press is not an escape hatch, it is surface.
      refresh    = "r",
      -- Two explicit verbs, not a cycle: `s` only ever stages and `u` only
      -- ever unstages, so a keypress on a mixed file never picks a direction
      -- for you. A verb with nothing to do says so instead of acting. The
      -- cursor decides scope: on a hunk's own rows the verb takes that hunk,
      -- anywhere else in the file it takes the file.
      stage      = "s",
      unstage    = "u",
      -- The whole-file verbs from anywhere inside the file: the capitals of
      -- the hunk keys above. Free to take for the same reason `c` was: `S`
      -- (substitute line) and `U` (undo line) belong to the editing family,
      -- and this nofile + nomodifiable buffer refuses all of it with E21, so
      -- neither key does anything here today.
      stage_file   = "S",
      unstage_file = "U",
      -- Tab forward through the lenses, Shift+Tab back. One physical key for the
      -- whole "what am I looking at" axis, and a slip between the two lands on the
      -- other direction of the same action rather than on something unrelated.
      --
      -- Costs jumplist-forward on the canvas: in a terminal <Tab> and <C-i> are the
      -- same byte. Worth it -- you navigate the canvas by file and hunk, not by
      -- jumplist.
      lens_next  = "<Tab>",
      lens_prev  = "<S-Tab>",
      -- Brings the sidebar back after `q` (in the sidebar) closed it, and
      -- puts it away again. Inert to take, like the rest of the editing
      -- family above: `o` is open-line, which nomodifiable refuses with E21.
      sidebar    = "o",
      -- The convention in every scratch buffer, so it costs nothing to learn.
      -- It DOES cost macro recording on the canvas -- `q` is inert by the
      -- "does anything visible happen" test, but qa..q records fine on a
      -- read-only buffer. Accepted: macros are an editing tool, and this buffer
      -- cannot be edited.
      close      = "q",
      -- The canvas's leader-key default, accepted deliberately: a help binding
      -- exists for the user who does not know the other keys
      -- yet, so it must not shadow anything they might reach for (`?` is
      -- backward search, and search works fine in a read-only buffer).
      -- Like every default it is replaceable -- `help = "g?"` frees it.
      help       = "<leader>lh",
    },
    sidebar = {
      -- Double-click, not single: <LeftMouse> is how you position the cursor,
      -- and stealing it would make the tree impossible to browse.
      -- No <Tab> here: on the canvas Tab cycles the lens, and the same key must
      -- not fold in one window and change the comparison in the other.
      select = { "<CR>", "za", "c", "<2-LeftMouse>" },
      stage   = "s",
      unstage = "u",
      close  = "q",
      help   = "<leader>lh",
    },
    -- Set on the real file's buffer for the duration of a jump, then removed.
    --
    -- ONE key, and deliberately no second: if your terminal does not transmit it
    -- the jump loop has no exit, which is a loud failure rather than a subtly
    -- half-working one. Ctrl+Space sends byte 0x00, which most terminals do send.
    --
    -- Not Alt+Enter: tiling compositors commonly grab it. Not `q`, even though
    -- that closes the canvas -- this is a buffer you are actually editing, so
    -- macros and every other normal-mode key have to keep working. That
    -- asymmetry is the point of grouping keymaps by buffer.
    file = {
      back = "<C-Space>",
    },
  },
  context = 3,
  base = "HEAD",
  highlights = {}, -- exact CanvasDiff group -> native highlight spec; false resets
  -- Which default colour vocabulary the diff rows derive: "quiet" (neutral
  -- elevation, hue on the margin only), "classic" (DiffAdd/DiffDelete row
  -- washes), or "mono" (no hue anywhere). Colors only -- element toggles
  -- like statuscolumn and scrollbar are independent. The appearance manager
  -- validates the name; config just carries it.
  profile = "quiet",
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
  -- The page-backed canvas. Below `min_rows` the eager canvas is cheaper and
  -- simpler -- its text IS the buffer, so search, yank and every plugin that
  -- reads buffer lines work with no help from us. Above it the eager canvas
  -- stops being viable at all, because the text and one extmark per
  -- highlighted row both scale with the review.
  --
  -- The threshold is in canvas ROWS, not files: one enormous file is the case
  -- that hurts, and a hundred small ones is not.
  paged = {
    enabled = true,
    min_rows = 20000,
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

-- Actions that once existed and were removed or renamed, with the replacement
-- to suggest. An override for one merges cleanly into an unused corner of its
-- context table and simply never installs, so without a report the user's
-- binding vanishes without a trace -- the same failure mode as the flat shape
-- above. Adding the next removal is one line here.
local REMOVED_ACTIONS = {
  stage_cycle = 'bind "stage" and/or "unstage" instead',
}

--- One message per override of a removed action in any keymap context, or nil.
local function removed_keymaps(keymaps)
  if type(keymaps) ~= "table" then
    return nil
  end
  local found = {}
  for context, sub in pairs(keymaps) do
    if type(sub) == "table" then
      for action, hint in pairs(REMOVED_ACTIONS) do
        if sub[action] ~= nil then
          found[#found + 1] = ("keymaps.%s.%s was removed -- %s")
            :format(context, action, hint)
        end
      end
    end
  end
  table.sort(found)
  return #found > 0 and found or nil
end

-- Options that once existed and were removed, path -> replacement hint. Same
-- failure mode as REMOVED_ACTIONS: the override merges into an unused corner
-- of the options table and silently does nothing.
local REMOVED_OPTIONS = {
  ["highlight.diff"] = "the canvas now has one rendering; override the"
    .. ' CanvasDiff highlight groups instead -- see README "How diff rows'
    .. ' are coloured"',
}

--- One message per removed option present in `opts`, or nil.
local function removed_options(opts)
  local found = {}
  for path, hint in pairs(REMOVED_OPTIONS) do
    local node = opts
    for key in path:gmatch("[^.]+") do
      node = type(node) == "table" and node[key] or nil
    end
    if node ~= nil then
      found[#found + 1] = ("%s was removed -- %s"):format(path, hint)
    end
  end
  table.sort(found)
  return #found > 0 and found or nil
end

--- Walk the user's ORIGINAL setup() table against the defaults, collecting
--- dotted paths that exist nowhere in the schema. tbl_deep_extend accepts any
--- key without complaint, so `keymaps.canvas.colapse` merges into an unused
--- corner and silently does nothing -- this is the audit that finds it after
--- the fact (:checkhealth), the counterpart of setup()'s removed-option
--- report.
---
--- Removed options are skipped here (they are reported with their replacement
--- hints, not as typos), `glyphs` is skipped because setup() validates its
--- slots itself, and list-like values are never entered: a keymap list longer
--- than the default's is legitimate, not a set of unknown numeric keys.
local function unknown_paths(user, defaults, prefix, out)
  for key, value in pairs(user) do
    local path = prefix and (prefix .. "." .. tostring(key)) or tostring(key)
    if REMOVED_OPTIONS[path]
        or (prefix == nil and (key == "glyphs" or key == "highlights")) then
      -- reported elsewhere, with better words
    elseif defaults[key] == nil then
      out[#out + 1] = path
    elseif type(value) == "table" and type(defaults[key]) == "table"
        and not vim.islist(value) and not vim.islist(defaults[key]) then
      unknown_paths(value, defaults[key], path, out)
    end
  end
end

--- The configuration audit :checkhealth renders: dotted paths the schema does
--- not know, and removed options with their replacement hints. Reads the
--- captured user_opts, so it reflects what the user actually wrote even
--- though setup() stripped removed keys before merging.
function M.health()
  local unknown = {}
  if type(M.user_opts) == "table" then
    unknown_paths(M.user_opts, M.defaults, nil, unknown)
  end
  table.sort(unknown)
  return { unknown = unknown, removed = removed_options(M.user_opts) or {} }
end

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
  local raw_highlights = opts.highlights
  local merge_opts = {}
  for key, value in pairs(opts) do
    if key ~= "highlights" then merge_opts[key] = value end
  end
  local diagnostics = {}
  local function report(message)
    diagnostics[#diagnostics + 1] = message
  end
  local legacy = legacy_keymaps(opts.keymaps)
  if legacy then
    report(
      "keymaps are now grouped by context; found flat key(s): "
        .. table.concat(legacy, ", ")
        .. ". Use keymaps = { global = {...}, canvas = {...},"
        .. " sidebar = {...}, file = { back = ... } }"
        .. " -- see :help canvasdiff-mappings"
    )
  end
  for _, message in ipairs(removed_keymaps(opts.keymaps) or {}) do
    report(message)
  end
  for _, message in ipairs(removed_options(opts) or {}) do
    report(message)
  end
  -- user_opts is captured BEFORE the strip below, so :checkhealth still sees
  -- what the user actually wrote.
  M.user_opts = vim.deepcopy(merge_opts)
  if raw_highlights ~= nil then
    M.user_opts.highlights = capture_highlights(raw_highlights)
  end
  -- Strip the removed key so it never lands in M.options; deepcopy first
  -- because `opts` belongs to the caller.
  if type(merge_opts.highlight) == "table" then
    merge_opts.highlight = vim.deepcopy(merge_opts.highlight)
    merge_opts.highlight.diff = nil
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), merge_opts)
  if raw_highlights ~= nil then
    M.options.highlights = capture_highlights(raw_highlights)
  end

  -- Glyphs are live configuration state rather than part of M.options: formatting
  -- reads this exact table through the canvas facade. Reset first, or two setup()
  -- calls would layer their overrides on each other.
  --
  -- `glyphs = "ascii"` selects the preset above; a table overrides individual slots.
  -- Unknown slots are reported rather than ignored: `glyphs = { fyle = "|" }` would
  -- otherwise do nothing at all and look like CanvasDiff failing to honour the option,
  -- which is exactly the failure mode the legacy-keymaps check above exists for.
  reset_glyphs()
  local g = merge_opts.glyphs
  if g == "ascii" then
    g = M.ASCII_GLYPHS
  end
  if type(g) == "table" then
    local unknown = {}
    for name, value in pairs(g) do
      if not is_glyph(name) then
        unknown[#unknown + 1] = tostring(name)
      elseif type(value) ~= "string" then
        report(("glyphs.%s must be a string, got %s"):format(name, type(value)))
      else
        M.glyphs[name] = value
      end
    end
    if #unknown > 0 then
      table.sort(unknown)
      report("unknown glyph name(s): " .. table.concat(unknown, ", ")
        .. ". Valid names: " .. table.concat(vim.tbl_keys(M.ASCII_GLYPHS), ", "))
    end
  elseif g ~= nil then
    report('glyphs must be a table or the string "ascii", got ' .. type(g))
  end

  return M.options, diagnostics
end

return M
