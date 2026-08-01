local canvas = require("canvasdiff.canvas")
local source = require("canvasdiff.source")
local config = require("canvasdiff.config")
local runtime = require("canvasdiff.runtime")
local input = require("canvasdiff.input")
local command = input.command
local jump = input.jump
local motions = input.motions
local virt = runtime.virtualizer
local watch = runtime.watch
local session = require("canvasdiff.session")
local ui = require("canvasdiff.ui")
local hl = ui.highlight
local scrollbar = ui.scrollbar
local sticky = ui.sticky_header
local sidebar = ui.sidebar
local statuscol = ui.status_column
local keys = input.keys
local diff = require("canvasdiff.diff")
local fold = diff.fold
local lens = diff.lens
local viewport = diff.anchor
local Surface = require("canvasdiff.Surface")

-- Capture the trusted Neovim global-map operations at module load. From this
-- point onward the final authenticate/delete pair does not pass through
-- replaceable Lua table fields, which could otherwise publish a foreign
-- takeover between the snapshot and the deletion it delegates.
local native_get_keymap = vim.api.nvim_get_keymap
local native_set_keymap = vim.api.nvim_set_keymap
local native_del_keymap = vim.api.nvim_del_keymap
local native_ipairs = ipairs
local native_next = next
local native_pcall = pcall
local native_rawget = rawget
local native_rawequal = rawequal
local native_type = type

local App = {}
App.__index = App

local EMPTY_MSG = "-- no changes --"
local STALE_COMPARE = {}
local buf_dir

local GLOBAL_ACTION_ORDER = { "compare", "checkout" }
local GLOBAL_ACTIONS = {
  compare = function(app) return app:compare() end,
  checkout = function(app) return app:checkout() end,
}

function App.new(opts)
  opts = opts or {}
  local effects = opts.global_keymap_effects or {
    get = native_get_keymap,
    set = function(mode, lhs, callback, map_opts)
      map_opts.callback = callback
      return native_set_keymap(mode, lhs, "", map_opts)
    end,
    del = native_del_keymap,
  }
  -- Reviews are indexed by their own canvas buffer, which is the only identity
  -- that cannot drift: windows move between tabs, a review may have none on
  -- screen for a while, and two reviews of the same repository are legal.
  return setmetatable({
    surfaces = {},
    opened = {},
    -- The lens each repository's review was showing when it was closed,
    -- keyed by root. Written by App:close, read by App:open between the
    -- explicit and session tiers: a mid-session reopen returns to the
    -- comparison you left, whether or not sessions are enabled. In-memory
    -- and per-App on purpose -- the session FILE remains the only carrier
    -- across instances.
    last_lens_by_root = {},
    compare_request = 0,
    ref_request = 0,
    global_maps = {},
    global_map_epoch = 0,
    global_map_syncing = false,
    global_map_pending = false,
    global_map_effects = effects,
  }, App)
end

--- Canonical raw form used by nvim_get_keymap(). Unlike keytrans(), this keeps
--- a Space leader as an actual space (the API's lhs is `" lb"`, not
--- `"<Space>lb"`). Unlike retaining the configured string, it freezes the
--- current <leader> expansion for reconciliation after mapleader changes.
local function global_lhs(lhs)
  return vim.keycode(lhs)
end

local function current_global_map(app, lhs)
  local ok, maps = native_pcall(app.global_map_effects.get, "n")
  if not ok then
    return nil, tostring(maps)
  end
  for _, map in native_ipairs(maps) do
    -- Control keys use lhsrawalt while printable and termcode sequences use
    -- lhsraw, so both are part of Neovim's observable canonical identity.
    if map.lhsraw == lhs or map.lhsrawalt == lhs then
      return map
    end
  end
end

local function map_flag(value)
  return value == true or (native_type(value) == "number" and value ~= 0)
end

local function map_behavior(map)
  local rhs = map.rhs
  if rhs == "" then rhs = nil end
  return {
    desc = map.desc,
    rhs = rhs,
    noremap = map_flag(map.noremap),
    silent = map_flag(map.silent),
    nowait = map_flag(map.nowait),
    expr = map_flag(map.expr),
    script = map_flag(map.script),
    replace_keycodes = map_flag(map.replace_keycodes),
  }
end

local MAP_FLAG_FIELDS = {
  abbr = true,
  expr = true,
  noremap = true,
  nowait = true,
  replace_keycodes = true,
  script = true,
  silent = true,
}

--- Complete stable observable identity from nvim_get_keymap(), excluding only
--- callback (compared by rawequal separately). Provenance fields such as
--- sid/lnum/scriptversion are intentional: reinstalling our callback from a
--- different call site is a foreign takeover, even with identical behavior.
local function map_identity(map)
  local out = {}
  local name, value = native_next(map)
  while name ~= nil do
    if name ~= "callback" then
      if MAP_FLAG_FIELDS[name] then
        out[name] = map_flag(value)
      elseif (name == "rhs" or name == "lhsrawalt") and value == "" then
        out[name] = nil
      else
        out[name] = value
      end
    end
    name, value = native_next(map, name)
  end
  return out
end

local function map_fields_equal(left, right)
  local name, value = native_next(left)
  while name ~= nil do
    if not native_rawequal(value, native_rawget(right, name)) then
      return false
    end
    name, value = native_next(left, name)
  end
  name = native_next(right)
  while name ~= nil do
    if native_rawget(left, name) == nil then
      return false
    end
    name = native_next(right, name)
  end
  return true
end

local function expected_record(lhs, request, callback)
  return {
    lhs = lhs,
    action = request.action,
    -- keytrans's display spelling is accepted by keymap.del for Space,
    -- control and terminal keycodes, even though it is not suitable for lookup.
    installed_lhs = vim.fn.keytrans(lhs),
    callback = callback,
    expected_behavior = {
      desc = request.desc,
      rhs = nil,
      noremap = true,
      silent = true,
      nowait = false,
      expr = false,
      script = false,
      replace_keycodes = false,
    },
  }
end

local function matches_expected_install(record, map)
  return map
    and native_rawequal(map.callback, record.callback)
    and map_fields_equal(map_behavior(map), record.expected_behavior)
end

--- Ownership is deliberately observable, not inferred from lhs or a
--- CanvasDiff-looking description. A user can replace our lhs at any time;
--- exact callback identity plus the complete stable keymap API identity is the
--- authority to remove it on the next setup.
local function owns_global_map(record, map)
  return record.identity
    and map
    and native_rawequal(map.callback, record.callback)
    and map_fields_equal(map_identity(map), record.identity)
end

local function record_from_map(record, map)
  return {
    lhs = record.lhs,
    action = record.action,
    installed_lhs = map.lhs or record.installed_lhs,
    callback = record.callback,
    identity = map_identity(map),
  }
end

--- Keep the newest candidate for a canonical lhs. A failed setter may leave a
--- tentative record after an older stale record for the same sequence.
local function compact_candidates(candidates)
  local reversed, seen = {}, {}
  for index = #candidates, 1, -1 do
    local record = candidates[index]
    if not seen[record.lhs] then
      seen[record.lhs] = true
      reversed[#reversed + 1] = record
    end
  end
  local out = {}
  for index = #reversed, 1, -1 do
    out[#out + 1] = reversed[index]
  end
  return out
end

--- Refresh candidates against observable editor state. If inspection itself
--- fails, retaining the candidate is conservative: it still grants no future
--- mutation authority unless a later successful inspection authenticates it.
local function refresh_global_ledger(app, candidates)
  local out = {}
  for _, record in native_ipairs(compact_candidates(candidates)) do
    local map, err = current_global_map(app, record.lhs)
    if err then
      return compact_candidates(candidates), err
    end
    if owns_global_map(record, map) then
      out[#out + 1] = record_from_map(record, map)
    end
  end
  return out
end

-- Notification memory is not ownership: it grants no delete/replace
-- authority. It only prevents repeated setup calls and root-module reloads
-- from warning about the same still-live foreign callback over and over.
local warned_collision_callbacks = setmetatable({}, { __mode = "k" })
local warned_collision_mappings = {}

local function report_global_collision(collision)
  local request, lhs, occupied =
    collision.request, collision.lhs, collision.occupied
  local callback = occupied.callback
  if native_type(callback) == "function" then
    if warned_collision_callbacks[callback] then
      return
    end
    warned_collision_callbacks[callback] = true
  else
    local signature = table.concat({
      lhs,
      tostring(occupied.rhs),
      tostring(occupied.sid),
      tostring(occupied.lnum),
      tostring(occupied.desc),
    }, "\0")
    if warned_collision_mappings[signature] then
      return
    end
    warned_collision_mappings[signature] = true
  end
  ui.warn(("global mapping %s was not installed because %s is already mapped; "
    .. "the existing mapping was left unchanged")
    :format(request.configured_lhs, vim.fn.keytrans(lhs)))
end

local function validate_global_action(action, raw)
  if raw == nil or raw == false or raw == "" then
    return
  end
  if native_type(raw) ~= "string" and native_type(raw) ~= "table" then
    return ("global %s mapping must be a string or list, got %s")
      :format(action, native_type(raw))
  end
  if native_type(raw) == "table" then
    local max_index, count = 0, 0
    local index = native_next(raw)
    while index ~= nil do
      if native_type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
        return ("global %s mapping must be a dense list of lhs strings")
          :format(action)
      end
      max_index = math.max(max_index, index)
      count = count + 1
      index = native_next(raw, index)
    end
    if max_index ~= count then
      return ("global %s mapping must be a dense list of lhs strings")
        :format(action)
    end
  end
end

local function desired_global_maps()
  local global_config = config.options.keymaps.global or {}
  for _, action in native_ipairs(GLOBAL_ACTION_ORDER) do
    local err = validate_global_action(action, global_config[action])
    if err then return nil, nil, err end
  end

  local ok, resolved = native_pcall(keys.resolved, "global", config.options.keymaps)
  if not ok then
    return nil, nil, "could not resolve global mappings: " .. tostring(resolved)
  end
  local desired, order = {}, {}
  for index, mapping in native_ipairs(resolved) do
    if not GLOBAL_ACTIONS[mapping.action] then
      return nil, nil, ("unsupported global mapping action %s")
        :format(tostring(mapping.action))
    end
    if native_type(mapping.lhs) ~= "string" then
      return nil, nil, ("global %s mapping #%d must be a string, got %s")
        :format(mapping.action, index, native_type(mapping.lhs))
    end
    if mapping.lhs == "" then
      return nil, nil,
        ("global %s mapping list contains an empty lhs at position %d")
          :format(mapping.action, index)
    end
    local lhs_ok, lhs = native_pcall(global_lhs, mapping.lhs)
    if not lhs_ok or native_type(lhs) ~= "string" or lhs == "" then
      return nil, nil, ("invalid global %s lhs %q: %s")
        :format(mapping.action, mapping.lhs, tostring(lhs))
    end
    if #lhs > 50 then
      return nil, nil,
        ("global %s lhs %q exceeds Neovim's 50-byte maximum after termcode expansion")
          :format(mapping.action, mapping.lhs)
    end
    if desired[lhs] then
      return nil, nil,
        ("global mappings %s %q and %s %q resolve to the same lhs")
          :format(
            desired[lhs].action,
            desired[lhs].configured_lhs,
            mapping.action,
            mapping.lhs)
    end
    desired[lhs] = {
      action = mapping.action,
      configured_lhs = mapping.lhs,
      desc = mapping.desc,
    }
    order[#order + 1] = lhs
  end
  return desired, order
end

local function settle_global_ledger(app, candidates, diagnostic)
  local ledger, inspect_err = refresh_global_ledger(app, candidates)
  app.global_maps = ledger
  if inspect_err then
    return {
      {
        kind = "error",
        message = "could not verify global mapping ownership: " .. inspect_err,
      },
    }
  end
  return diagnostic and { diagnostic } or {}
end

--- One non-reentrant reconciliation pass. App:sync_global_keymaps coalesces
--- nested setup calls around it; a partial pass always settles its actual
--- candidates before the newest configuration is attempted.
local function reconcile_global_keymaps(app)
  local desired, desired_order, validation_error = desired_global_maps()
  if validation_error then
    return {
      { kind = "error", message = validation_error },
    }
  end

  local candidates = {}
  for _, record in native_ipairs(app.global_maps) do
    candidates[#candidates + 1] = record
  end

  local kept = {}
  for _, record in native_ipairs(app.global_maps) do
    local map, inspect_err = current_global_map(app, record.lhs)
    if inspect_err then
      return settle_global_ledger(app, candidates, {
        kind = "error",
        message = "could not inspect global mappings: " .. inspect_err,
      })
    end
    if app.global_map_pending then
      return settle_global_ledger(app, candidates)
    end
    local request = desired[record.lhs]
    if request
        and record.action == request.action
        and owns_global_map(record, map) then
      kept[record.lhs] = record_from_map(record, map)
    end
  end

  local collisions = {}
  -- Install before deleting prior owned maps: a failed rebind leaves the old
  -- entry usable and authenticated instead of publishing a half-transition.
  for _, lhs in native_ipairs(desired_order) do
    if not kept[lhs] then
      local request = desired[lhs]
      local dispatch = GLOBAL_ACTIONS[request.action]
      local callback = function()
        return dispatch(app)
      end
      -- Finish all replaceable Lua preparation before the final observable
      -- ownership snapshot that grants authority to the captured native set.
      local tentative = expected_record(lhs, request, callback)
      local occupied, inspect_err = current_global_map(app, lhs)
      if inspect_err then
        return settle_global_ledger(app, candidates, {
          kind = "error",
          message = "could not inspect global mappings: " .. inspect_err,
        })
      end
      if app.global_map_pending then
        return settle_global_ledger(app, candidates)
      end
      local prior_owned
      for _, record in native_ipairs(app.global_maps) do
        if record.lhs == lhs and owns_global_map(record, occupied) then
          prior_owned = record
          break
        end
      end

      if occupied and not prior_owned then
        collisions[#collisions + 1] = {
          kind = "collision",
          request = request,
          lhs = lhs,
          occupied = occupied,
        }
      else
        local set_ok, set_err = native_pcall(app.global_map_effects.set,
          "n", request.configured_lhs, callback, {
          desc = request.desc,
          noremap = true,
          silent = true,
        })
        if not set_ok then
          return settle_global_ledger(app, candidates, {
            kind = "error",
            message = ("could not install global mapping %s: %s")
              :format(request.configured_lhs, tostring(set_err)),
          })
        end
        local installed, verify_err = current_global_map(app, lhs)
        if verify_err then
          return settle_global_ledger(app, candidates, {
            kind = "error",
            message = ("could not verify installed global mapping %s: %s")
              :format(request.configured_lhs, verify_err),
          })
        end
        if not matches_expected_install(tentative, installed) then
          return settle_global_ledger(app, candidates, {
            kind = "error",
            message = ("could not authenticate installed global mapping %s")
              :format(request.configured_lhs),
          })
        end
        candidates[#candidates + 1] = record_from_map(tentative, installed)
        if app.global_map_pending then
          return settle_global_ledger(app, candidates)
        end
      end
    end
  end

  for _, record in native_ipairs(app.global_maps) do
    if not desired[record.lhs] then
      local map, inspect_err = current_global_map(app, record.lhs)
      if inspect_err then
        return settle_global_ledger(app, candidates, {
          kind = "error",
          message = "could not inspect global mappings: " .. inspect_err,
        })
      end
      if app.global_map_pending then
        return settle_global_ledger(app, candidates)
      end
      if owns_global_map(record, map) then
        local del_ok, del_err = native_pcall(
          app.global_map_effects.del, "n", record.installed_lhs)
        if not del_ok then
          return settle_global_ledger(app, candidates, {
            kind = "error",
            message = ("could not remove global mapping %s: %s")
              :format(record.installed_lhs, tostring(del_err)),
          })
        end
        if app.global_map_pending then
          return settle_global_ledger(app, candidates)
        end
      end
    end
  end

  local diagnostics = settle_global_ledger(app, candidates)
  for _, collision in native_ipairs(collisions) do
    diagnostics[#diagnostics + 1] = collision
  end
  return diagnostics
end

--- Reconcile the process-wide actions for this exact App instance.
---
--- Existing foreign maps always win. Records are per App, so a second instance
--- (including one created by a module reload) sees the first instance's
--- callback as foreign and cannot delete or replace it.
function App:sync_global_keymaps()
  self.global_map_epoch = self.global_map_epoch + 1
  if self.global_map_syncing then
    self.global_map_pending = true
    return
  end

  self.global_map_syncing = true
  local diagnostics, round
  repeat
    self.global_map_pending = false
    round = self.global_map_epoch
    local ok, result = native_pcall(reconcile_global_keymaps, self)
    diagnostics = ok and result or {
      {
        kind = "error",
        message = "global mapping reconciliation failed: " .. tostring(result),
      },
    }
  until not self.global_map_pending and round == self.global_map_epoch
  self.global_map_syncing = false

  -- Present only the final committed pass. Notifications can run arbitrary
  -- user code, including setup(); no ownership state is written afterwards.
  local report_epoch = self.global_map_epoch
  for _, diagnostic in native_ipairs(diagnostics) do
    if diagnostic.kind == "collision" then
      report_global_collision(diagnostic)
    else
      ui.err(diagnostic.message)
    end
    if self.global_map_epoch ~= report_epoch then
      break
    end
  end
end

--- Forget a review, whoever disposed it.
local function forget(app, surface)
  local buf = surface and surface.canvas_buf
  if buf and app.surfaces[buf] == surface then
    app.surfaces[buf] = nil
  end
  for index = #app.opened, 1, -1 do
    if app.opened[index] == surface then
      table.remove(app.opened, index)
    end
  end
end

--- Every live review, oldest first.
local function live_surfaces(app)
  local out = {}
  for _, surface in ipairs(app.opened) do
    if surface:is_alive() then
      out[#out + 1] = surface
    end
  end
  return out
end

--- The review a window belongs to: it shows that review's canvas, or the
--- review adopted it as a host, or it is that review's own sidebar.
local function surface_for_window(app, win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
  if ok then
    local owner = app.surfaces[buf]
    if owner and owner:is_alive() then
      return owner
    end
  end
  for _, surface in ipairs(live_surfaces(app)) do
    -- Refresh ownership first: a window that only ever showed this canvas
    -- transiently, while it was being created, is dropped here rather than
    -- answering for a review it never belonged to.
    surface:canvas_snapshot()
    if surface:owns_window(win) then
      return surface
    end
    local side = surface.controllers.sidebar
    if side and sidebar.is_sidebar_win(side, win) then
      return surface
    end
  end
  return nil
end

--- Which review a command acts on.
---
--- Context first: the window you are in answers it unambiguously, including
--- from that review's own sidebar. With no context, the most recently opened
--- live review is the only defensible default -- and with a single review, the
--- only one there is, which is why every existing single-review behavior is
--- unchanged.
local function active_surface(app, win)
  local contextual = surface_for_window(app, win or vim.api.nvim_get_current_win())
  if contextual then
    return contextual
  end
  local live = live_surfaces(app)
  return live[#live] or nil
end

--- Claim the next model-publication turn for one Surface. Unlike generation,
--- this advances for a newer user intent that keeps the same live owner.
local function claim_model_epoch(surface)
  surface.model_epoch = (surface.model_epoch or 0) + 1
  return surface.model_epoch
end

local pivot

--- Is one concrete window displaying this Canvas?
local canvas_showing = canvas.win_showing_canvas

--- Show a navigation outcome's diagnostic, and hand its result back.
---
--- Input reports what happened and in whose words; turning that into a message
--- is the owner's job, which is the whole reason input never imports UI.
local function present(outcome)
  local diagnostic = outcome and outcome.diagnostic
  if diagnostic then
    if diagnostic.level == "warn" then
      ui.warn(diagnostic.message)
    else
      ui.notify(diagnostic.message)
    end
  end
  return (outcome and outcome.ok) or false
end

--- Public setup: merge user options into the config module. Entirely
--- optional -- every code path below works fine against config.defaults
--- when setup() is never called.
function App:setup(opts)
  local options, diagnostics = config.setup(opts)
  for _, message in ipairs(diagnostics or {}) do
    ui.err(message)
  end
  self:sync_global_keymaps()
  return options
end

--- Run one `:CanvasDiff` invocation.
---
--- The grammar and its outcome are pure input-domain data; executing the
--- planned operation and showing its diagnostic are the owner's job. Keeping
--- the split here is what lets input stay free of both UI and a cycle back
--- through the root facade.
--- @param fargs string[]|nil
--- @return CanvasDiffCommand
function App:command(fargs)
  local outcome = command.plan(command.parse(fargs))
  local diagnostic = outcome.diagnostic
  if diagnostic then
    if diagnostic.level == "error" then
      ui.err(diagnostic.message)
    else
      ui.warn(diagnostic.message)
    end
  end
  if outcome.call then
    local operation = self[outcome.call]
    assert(type(operation) == "function",
      "command planned an operation this owner does not have: " .. outcome.call)
    operation(self, outcome.argument)
  end
  return outcome
end

--- Completion candidates for `:CanvasDiff`, resolved from the command window's
--- repository and routed through the owner so the plugin imports only the root
--- facade.
function App:command_complete(arglead)
  local win = vim.api.nvim_get_current_win()
  local surface = surface_for_window(self, win)
  local root = surface and surface.state.root or source.root(vim.fn.getcwd())
  if not root then
    local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
    local dir = ok and buf_dir(buf) or nil
    root = dir and source.root(dir) or nil
  end
  local branches = root and source.branches(root) or {}
  return command.complete(arglead, branches or {})
end

--- Return from a jump excursion into the owning review's canvas.
---
--- The excursion belongs to its Surface, so "which way back" is answered by
--- the review you left, not by a process-wide slot that a second review would
--- have overwritten. With no live review at all, the store is absent and the
--- outcome says so in the user's terms.
--- @return boolean returned
function App:jump_back(surface, generation, win)
  surface = surface or active_surface(self)
  if surface and generation and not surface:guard(generation) then
    return false
  end
  return present(jump.back(surface and surface.excursion or nil, { win = win }))
end

--- Show which lens the canvas is looking through, in a winbar on its own window.
---
--- Until now the only signal was a one-shot `vim.notify` on change, so once the
--- message faded there was nothing on screen telling you whether you were looking at
--- everything, at what you hadn't staged, or at what you had. For a canvas whose
--- whole premise is pivoting between those, that is the difference between a control
--- and a guessing game.
---
--- `""` clears it, which is what App:close wants -- a leftover winbar on a restored
--- window would claim the file you are editing is a diff canvas.
---
--- The text is the comparison label alone, scroll-invariant: which FILE sits
--- under the topline is the sticky header row's business (ui/sticky_header.lua,
--- which owns its own topline resolution), not the winbar's.
--- scrollbar.text_geometry accounts for the row this consumes; see the note there.
local function set_winbar(st, text, win)
  win = win or (st and st.win)
  if not (st and win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if text == nil then
    text = ui.winbar.text(st)
  end
  ui.winbar.apply(st, win, text)
end

local function clear_winbar(st, win)
  ui.winbar.clear(st, win)
end

local function refresh_winbars(surface)
  if not surface then
    return
  end
  local st = surface.state
  for _, win in ipairs(surface:canvas_snapshot().canvas) do
    set_winbar(st, nil, win)
  end
  -- The top band's file half rides along: every non-scroll path that makes
  -- the winbars re-read state (reconciles, pivots, restores) can also have
  -- changed what the pinned header row should say.
  local pin = surface.controllers.sticky
  if pin then
    sticky.update(pin)
  end
end

local function canvas_window_in_tab(surface, tab, preferred)
  if not surface then
    return nil
  end
  local fallback
  for _, win in ipairs(surface:canvas_snapshot().canvas) do
    if vim.api.nvim_win_get_tabpage(win) == tab then
      fallback = fallback or win
      if win == preferred then
        return win
      end
    end
  end
  return fallback
end

local function show_empty_message(st)
  vim.api.nvim_set_option_value("modifiable", true, { buf = st.buf })
  vim.api.nvim_buf_set_lines(st.buf, 0, -1, false, { EMPTY_MSG })
  vim.api.nvim_set_option_value("modifiable", false, { buf = st.buf })
end

--- Refresh the other live UI pieces after a direct canvas.set_collapsed
--- splice (mirrors what jump.back/App:refresh already do after their own
--- canvas splices): reapply lazy highlighting and sync sidebar/scrollbar.
local function sync_after_collapse(surface, st)
  local lease = surface and surface.controllers.hl
  if lease then
    hl.apply_now(lease)
  end
  local side = surface and surface.controllers.sidebar
  if side then
    sidebar.refresh(side)
  end
  local scroll = surface and surface.controllers.scrollbar
  if scroll then
    scrollbar.update(scroll, st)
  end
  -- A collapse reshapes the rows under the topline, so the section the
  -- pinned header names may have changed without any scroll event.
  local pin = surface and surface.controllers.sticky
  if pin then
    sticky.update(pin, st)
  end
end

--- Set section i's collapse state on behalf of the USER (the <Tab>/za/<CR>
--- keymaps). set_collapsed's default intent records exactly that, which is what
--- stops the auto-virtualizer expanding it back on a later in-window pass and
--- stops session.save discarding it as module bookkeeping.
local function user_set_collapsed(surface, st, i, collapsed, win)
  canvas.set_collapsed(st, i, collapsed, nil, win)
  sync_after_collapse(surface, st)
end

--- Index of the section under the canvas cursor, or nil.
local function section_under_cursor(st, win)
  if not canvas_showing(st, win) then
    return nil
  end
  return canvas.locate(st, vim.api.nvim_win_get_cursor(win)[1] - 1)
end

--- Clear every folded directory hiding section `i` (at `path`). Returns the
--- directories that were cleared, or nil when nothing was hiding it.
---
--- The whole chain has to go: with both "lua/" and "lua/mod/" folded, dropping
--- either alone leaves the file hidden and the keypress looks broken. That
--- brings back siblings as well, so it announces itself -- one keypress
--- reopening a directory should not be silent.
---
--- This is also the only way out of a fold when the sidebar is disabled: folds
--- restore onto state.folded regardless of the sidebar, so without it those
--- files would be permanently invisible.
local function reveal(surface, st, i, path, win)
  local dirs = fold.folds_hiding(st.folded, path)
  if #dirs == 0 then
    return nil
  end
  for _, dir in ipairs(dirs) do
    st.folded[dir] = nil
  end
  -- Not just this row -- unfolding an ancestor un-hides the whole subtree. The
  -- OUTERMOST cleared fold spans every section any of them was hiding (they
  -- are all ancestors of one path, outermost first), so its subtree is exactly
  -- the affected set; a section some unrelated inner fold still hides stays
  -- hidden and its resplice no-ops.
  canvas.resync_visibility(st, fold.indices_under(st.sections, dirs[1]), win)
  -- Every resplice corrects the viewport, and the one whose section starts at
  -- the viewport top rewrites lnum too -- so the cursor must be put back on the
  -- file that was actually pressed. Without this, a <Tab> even one row below
  -- the viewport top lands the cursor on a different file, and the following
  -- <CR> / ]f / ]h all work from there.
  if canvas_showing(st, win) then
    local start0 = (canvas.section_rows(st, i))
    pcall(vim.api.nvim_win_set_cursor, win, { start0 + 1, 0 })
  end
  sync_after_collapse(surface, st)
  ui.notify("unfolded " .. table.concat(dirs, ", "))
  return dirs
end

--- Open the file under the cursor as a real buffer. Shared by the jump keymap and
--- the double-click mapping.
---
--- Deliberately fold-BLIND: pressing this on a folded file's placeholder opens the
--- file and leaves the fold exactly as it was, so coming back lands you on the
--- placeholder again. Two verbs with no exceptions -- this one goes to a file,
--- Tab/za folds one -- rather than one key whose meaning depends on state you
--- cannot see. (It used to expand a placeholder instead of opening it, which both
--- duplicated Tab and made Enter context-dependent.)
---
--- Safe only because jump.back guards on fold.hidden: returning into a folded
--- section lands on its placeholder instead of resolving a view against entries
--- that no longer map to rows.
local function open_under_cursor(app, surface, generation, st, cfg, win)
  return present(jump.enter(surface.excursion, st, {
    win = win,
    back_keys = keys.list(cfg.keymaps.file.back),
    on_path = function(path, source_win)
      surface:guard(generation, function(owner)
        local lease = owner.controllers.sidebar
        if lease then
          sidebar.mark_path(lease, path, source_win)
        end
      end)
    end,
    on_return = function()
      app:jump_back(surface, generation)
    end,
  }))
end

--- Fold or unfold the section under the cursor: reveal it when a
--- folded directory is what's hiding it, otherwise flip its own collapse flag.
local function toggle_collapse_under_cursor(surface, st, win)
  local i = section_under_cursor(st, win)
  if not i then
    return
  end
  local path = st.sections[i].path
  if reveal(surface, st, i, path, win) then
    return
  end
  user_set_collapsed(surface, st, i, not st.collapsed[path], win)
end

--- What each canvas action does. Keyed by `keys.specs` action names; an action
--- with no handler here simply installs no map, which is what lets a spec land
--- before the feature behind it does.
local function owned_action(surface, generation, callback)
  return function()
    local win = vim.api.nvim_get_current_win()
    surface:guard(generation, function(owner)
      callback(owner, win)
    end)
  end
end

local function canvas_actions(app, surface, st, cfg)
  local generation = surface.generation
  local function after_motion(owner, win)
    local side = owner.controllers.sidebar
    if side then
      sidebar.sync(side, win)
    end
    set_winbar(st, nil, win)
  end
  return {
    jump       = owned_action(surface, generation,
      function(_, win) open_under_cursor(app, surface, generation, st, cfg, win) end),
    collapse   = owned_action(surface, generation,
      function(_, win) toggle_collapse_under_cursor(surface, st, win) end),
    close      = owned_action(surface, generation, function()
      app:back_out_or_close(surface)
    end),
    help       = owned_action(surface, generation, function() ui.cheatsheet.toggle() end),
    refresh    = owned_action(surface, generation, function() app:refresh() end),
    stage      = owned_action(surface, generation,
      function() app:stage(nil, surface, generation) end),
    unstage    = owned_action(surface, generation,
      function() app:unstage(nil, surface, generation) end),
    lens_next  = owned_action(surface, generation, function() app:cycle_lens(1) end),
    lens_prev  = owned_action(surface, generation, function() app:cycle_lens(-1) end),
    sidebar    = owned_action(surface, generation, function() app:toggle_sidebar() end),
    cycle_next = owned_action(surface, generation, function(owner, win)
      if motions.cycle(st, win, 1) then after_motion(owner, win) end
    end),
    cycle_prev = owned_action(surface, generation, function(owner, win)
      if motions.cycle(st, win, -1) then after_motion(owner, win) end
    end),
    next_file  = owned_action(surface, generation, function(owner, win)
      if motions.goto_file(st, 1, nil, win) then after_motion(owner, win) end
    end),
    prev_file  = owned_action(surface, generation, function(owner, win)
      if motions.goto_file(st, -1, nil, win) then after_motion(owner, win) end
    end),
    next_hunk  = owned_action(surface, generation, function(owner, win)
      if motions.goto_hunk(st, 1, nil, win) then after_motion(owner, win) end
    end),
    prev_hunk  = owned_action(surface, generation, function(owner, win)
      if motions.goto_hunk(st, -1, nil, win) then after_motion(owner, win) end
    end),
  }
end

local function set_canvas_keymaps(app, surface, st)
  local cfg = config.options
  local acts = canvas_actions(app, surface, st, cfg)
  for _, m in ipairs(keys.resolved("canvas", cfg.keymaps)) do
    local fn = acts[m.action]
    if fn then
      vim.keymap.set("n", m.lhs, fn,
        { buffer = st.buf, silent = true, noremap = true, desc = m.desc })
    end
  end
end

--- Directory of `buf`'s own file, or nil when it doesn't have one.
--- Restricted to ordinary file buffers, so scratch buffers, terminals and
--- URI-backed buffers (oil://, fugitive://, our own canvasdiff://) never
--- contribute a bogus path.
buf_dir = function(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  if vim.api.nvim_get_option_value("buftype", { buf = buf }) ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return nil
  end
  local dir = vim.fn.fnamemodify(name, ":p:h")
  return vim.fn.isdirectory(dir) == 1 and dir or nil
end

--- Open the file-tree sidebar for `surface`, claiming its one sidebar lease.
---
--- This is the ONLY open path: App:open drives it when `sidebar.enabled`, and
--- App:toggle_sidebar drives the same function on demand -- one lifecycle,
--- one set of lease/ownership rules, whichever way the sidebar appears.
local function open_sidebar(app, surface, st)
  local generation = surface.generation
  sidebar.open(st, config.options.sidebar, {
    claim = function(lease)
      if not surface:guard(generation)
          or surface.controllers.sidebar ~= nil then
        return false
      end
      surface.controllers.sidebar = lease
      return true
    end,
    alive = function(lease)
      return surface:guard(generation)
        and surface.controllers.sidebar == lease
    end,
    snapshot = function(lease)
      if not surface:guard(generation)
          or surface.controllers.sidebar ~= lease then
        return { hosts = {}, canvas = {} }
      end
      return surface:canvas_snapshot()
    end,
    on_shape_change = function(lease, changed_state, source_win)
      if surface.controllers.sidebar ~= lease then
        return
      end
      surface:guard(generation, function()
        sync_after_collapse(surface, changed_state)
        if source_win then
          set_winbar(changed_state, nil, source_win)
        else
          refresh_winbars(surface)
        end
      end)
    end,
    on_locate = function(lease, changed_state, canvas_win)
      if surface.controllers.sidebar ~= lease then
        return
      end
      surface:guard(generation, function(owner)
        owner:capture_view(canvas_win)
        -- The signal still carries the landed path, but the winbar no longer
        -- shows one -- with a scroll-invariant label the old "pin the winbar
        -- to where the locate landed" special case collapses to a plain
        -- refresh, and the sticky header row does the naming.
        set_winbar(changed_state, nil, canvas_win)
      end)
    end,
    on_return = function(lease, _, host_win)
      if surface.controllers.sidebar ~= lease then
        return false
      end
      local returned = false
      surface:guard(generation, function()
        returned = app:jump_back(surface, generation, host_win)
      end)
      return returned
    end,
    on_stage = function(lease, _, path, direction)
      if surface.controllers.sidebar ~= lease then
        return false
      end
      local changed = false
      surface:guard(generation, function()
        changed = app:stage_file(direction, path, surface, generation) or false
      end)
      return changed
    end,
    release = function(lease)
      if surface.controllers.sidebar ~= lease then
        return false
      end
      surface.controllers.sidebar = nil
      return true
    end,
  })
end

--- Open the canvas in the current window for the git repo we're working in.
--- Not a repo ⇒ notify and return (never throws).
---
--- The repo is resolved from the cwd first, falling back to the current
--- buffer's own file. cwd wins because in Neovim the cwd IS the project, and
--- keeping it first means this changes nothing for anyone already working
--- that way. The fallback exists because `nvim path/to/repo/file.lua` from a
--- parent directory -- or hopping projects with a file picker -- otherwise
--- refuses to open at all, with a message that looks like the plugin is
--- broken rather than looking in the wrong place.
---
--- `opts.base` ("HEAD" | "index") overrides both the saved session's base and
--- the configured default, so a command naming a state can open straight into
--- it rather than opening and then re-rendering.
function App:open(opts)
  opts = opts or {}
  -- Invoked from this Surface's own fixed sidebar: redirect only to a Canvas
  -- view in the same tab. An unrelated/stale sidebar-shaped window must not
  -- influence this App.
  local current = vim.api.nvim_get_current_win()
  local active = active_surface(self)
  local side = active and active.controllers.sidebar
  if side and sidebar.is_sidebar_win(side, current) then
    local canvas_win = canvas_window_in_tab(
      active, vim.api.nvim_win_get_tabpage(current))
    if canvas_win then
      vim.api.nvim_set_current_win(canvas_win)
    else
      return
    end
  end

  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)

  local cwd = vim.fn.getcwd()
  -- `_root` is an internal async handoff: a picker resolves its repository
  -- before yielding and must not silently follow a later cwd change.
  local root = opts._root or source.root(cwd)
  if not root then
    local dir = buf_dir(prev_buf)
    root = dir and source.root(dir) or nil
  end
  if not root then
    local err = "not inside a git repository (looked in " .. cwd .. ")"
    ui.warn(err)
    return nil, err
  end

  -- Load any saved session BEFORE collection, so a restored lens is honored
  -- from the very first source.files call -- not just after the fact.
  --
  -- Precedence, most to least specific: an explicit lens from the caller; the
  -- older `base` string a command passed; the lens this App last showed for
  -- this repository (recorded at close); the lens the session saved; the base
  -- an OLDER session saved (payloads predating lenses); the configured
  -- default. Memory outranks the file deliberately: mid-session, "the lens I
  -- just left" is what a reopen means, and the file only ever answers a fresh
  -- instance, which has no memory.
  local sess = opts._session
    or (config.options.session.enabled and session.load(root) or nil)
  local remembered = lens.normalize(self.last_lens_by_root[root])
  local l = opts.lens
    or (opts.base and lens.from_base(opts.base))
    or remembered
    or (sess and lens.valid(sess.lens) and sess.lens)
    or (sess and sess.base and lens.from_base(sess.base))
    or lens.from_base(config.options.base)
  -- A remembered or saved lens passed a SHAPE check only; whether its refs
  -- still resolve is decided by collection below. Remember where it came
  -- from, so a comparison over a since-deleted branch degrades to the default
  -- lens instead of failing the open -- same posture as the paged fallback: a
  -- recalled lens that cannot be collected is a reason to fall back, not to
  -- fail the review. An EXPLICIT lens still errors; that is typo feedback.
  -- Tier 5 -- an older session's `base` string -- counts as remembered too,
  -- so the flag means exactly "the lens was recalled, not requested". (A
  -- base only ever translates to a named lens, which always resolves, so
  -- the fallback below never actually fires for that tier.)
  local lens_remembered = opts.lens == nil and opts.base == nil
    and (remembered ~= nil
      or (sess ~= nil and (lens.valid(sess.lens) or sess.base ~= nil)))
    or false

  -- Transaction boundary: collection and model construction finish before
--- Choose the canvas the review actually needs.
---
--- Below the threshold the eager canvas is cheaper AND simpler: its text is
--- the buffer, so search, yank and every plugin that reads buffer lines work
--- with no help from us. Above it the eager canvas is not viable at all --
--- both its text and its one-extmark-per-highlighted-row scale with the
--- review -- so the paged canvas takes over.
---
--- The row count is exact rather than estimated: a section's entries ARE its
--- rendered rows, so this costs a walk over the model and no rendering.
local function open_canvas(sections)
  local settings = config.options.paged or {}
  if settings.enabled == false then
    return canvas.open(sections, {})
  end
  local rows = 0
  for _, section in ipairs(sections) do
    rows = rows + #(section.entries or {})
  end
  if rows < (settings.min_rows or 20000) then
    return canvas.open(sections, {})
  end
  -- A paged canvas that cannot be built is a reason to fall back, not a
  -- reason to fail the review: the eager one still renders it correctly, just
  -- expensively.
  local state = canvas.open_paged(sections, {})
  return state or canvas.open(sections, {})
end

local function discard_unpublished_canvas(st, win, restore_buf)
  if not st then
    return
  end
  if vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_buf_is_valid(restore_buf)
      and vim.api.nvim_win_get_buf(win) == st.buf then
    pcall(vim.api.nvim_win_set_buf, win, restore_buf)
  end
  canvas.dispose(st)
  if st.buf and vim.api.nvim_buf_is_valid(st.buf) then
    pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
  end
end

  -- canvas.open changes the current window or this App's state. In
  -- particular, an invalid/deleted branch ref is an error, not an empty old
  -- side and not an empty canvas.
  local sections, collect_err = source.sections(root, l, config.options.context)
  if opts._guard and not opts._guard() then
    return nil, STALE_COMPARE
  end
  if not sections and lens_remembered then
    local fallback = lens.from_base(config.options.base)
    if not lens.same(fallback, l) then
      -- Re-collect BEFORE announcing the fallback: "showing X" is a promise,
      -- and it must only be made once X actually collected. When the
      -- fallback fails too, the abort warning below is the only message.
      local saved_err = collect_err
      local fallback_sections
      fallback_sections, collect_err =
        source.sections(root, fallback, config.options.context)
      if opts._guard and not opts._guard() then
        return nil, STALE_COMPARE
      end
      if fallback_sections then
        ui.warn(("remembered comparison %s no longer resolves — showing %s (%s)")
          :format(l.label, fallback.label, saved_err))
        l = fallback
        sections = fallback_sections
      end
    end
  end
  if not sections then
    ui.warn(collect_err)
    return nil, collect_err
  end

  -- Collection is transactional: only a valid replacement may retire a review.
  --
  -- Deliberately the review owning THIS window, not the active one: opening
  -- from inside a review replaces that review in place and inherits its hosts,
  -- while opening from a window that belongs to no review starts a second one
  -- and leaves every other review alone.
  -- Retire any review whose last window has already gone. Its WinClosed
  -- recheck is queued but has not run, and leaving a hostless review live
  -- would let it answer for commands issued from windows it does not own.
  -- This sweep is a teardown path like any other, so it records the last-lens
  -- memory too: the queued recheck will find the surface disposed and no-op,
  -- meaning its own recording never runs for a review swept here.
  for _, surface in ipairs(live_surfaces(self)) do
    if #surface:canvas_windows() == 0 and #surface:host_windows() == 0 then
      if surface.state.root then
        self.last_lens_by_root[surface.state.root] = lens.of(surface.state)
      end
      surface:dispose("last_window")
    end
  end

  local previous = surface_for_window(self, win)
  local replacement = opts._replacement
  local ownership = replacement and replacement.ownership
    or (previous and previous:handoff() or nil)
  -- Which hosts were actually DISPLAYING the outgoing review. A replacement
  -- has a canvas buffer of its own now, so inheriting a window is no longer
  -- enough to keep showing the review in it -- the ones that were on the old
  -- canvas have to be moved onto the new one below, or a remote tab would sit
  -- on a retired buffer.
  local displaced = {}
  if replacement then
    for _, host in ipairs(replacement.displaced or {}) do
      displaced[#displaced + 1] = host
    end
  elseif previous then
    for _, host in ipairs(previous:canvas_windows()) do
      displaced[#displaced + 1] = host
    end
  end
  if opts._guard and not opts._guard() then
    return nil, STALE_COMPARE
  end

  local st = open_canvas(sections)
  if opts._guard and not opts._guard(st.buf) then
    discard_unpublished_canvas(st, win, prev_buf)
    return nil, STALE_COMPARE
  end

  if previous then
    -- A replacing open is a teardown path like the sweep above: the retired
    -- review's close never runs, so this is the only place its lens can
    -- reach the last-lens memory. Keyed by the RETIRED review's root -- on a
    -- cross-root replace the record must answer for the repository the old
    -- review was showing, not the one opening now, or a stale earlier entry
    -- (or, with sessions on, an older session file promoted over nothing)
    -- would answer that root's next reopen. Same-root this is harmless: the
    -- successor's own teardown overwrites it.
    if previous.state and previous.state.root then
      self.last_lens_by_root[previous.state.root] = lens.of(previous.state)
    end
    previous:dispose("replaced")
  end
  st.root = root
  session.activate(st)
  st.lens = l
  -- Kept alongside, for the session payload and for anything still speaking the
  -- older vocabulary. nil for `staged` and branch lenses, which it cannot express.
  st.base = lens.to_base(l)
  st.prev_buf = prev_buf

  local surface = Surface.new(st, {
    clear_winbar = function(owner)
      local seen = {}
      for _, owned_win in ipairs(owner:host_windows()) do
        clear_winbar(owner.state, owned_win)
        seen[owned_win] = true
      end
      if owner.state.win and not seen[owner.state.win] then
        clear_winbar(owner.state, owner.state.win)
      end
    end,
    on_dispose = function(owner)
      -- The overlay never survives the canvas (spec R4). Every teardown
      -- reason -- explicit close, `:q` on the last window, a replacing
      -- open -- funnels through here, so this is the one place that also
      -- catches the paths that never reach App:close (e.g. a `:q`-killed
      -- canvas going straight through WinClosed -> dispose("last_window")).
      ui.cheatsheet.close()
      -- Unregisters by exact identity, so a late callback from an older
      -- review can never evict its replacement from the index.
      forget(self, owner)
    end,
  }, ownership)
  if opts._guard and not opts._guard(st.buf) then
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_buf_is_valid(prev_buf)
        and vim.api.nvim_win_get_buf(win) == st.buf then
      pcall(vim.api.nvim_win_set_buf, win, prev_buf)
    end
    surface:abort("stale_compare")
    return nil, STALE_COMPARE
  end
  self.surfaces[st.buf] = surface
  self.opened[#self.opened + 1] = surface

  -- Move every inherited host that was showing the retired canvas onto this
  -- one. `canvas.show` rebinds the primary as a side effect, so the window the
  -- user actually invoked from is restored as primary afterwards.
  local primary = st.win
  for _, host in ipairs(displaced) do
    if host ~= primary and vim.api.nvim_win_is_valid(host)
        and surface:owns_window(host) then
      canvas.show(st, host)
    end
  end
  st.win = primary
  local generation = surface.generation

  -- A sidebar fold reshapes the canvas, and neither the highlight tier nor the
  -- minimap hears about it on its own. This canvas-local hook remains for that
  -- synchronous model operation; asynchronous controllers such as the
  -- virtualizer report through their exact Surface-owned leases below.
  st.hooks = st.hooks or {}
  st.hooks.on_shape_change = function(_, source_win)
    surface:guard(generation, function()
      sync_after_collapse(surface, st)
      if source_win then
        set_winbar(st, nil, source_win)
      else
        refresh_winbars(surface)
      end
    end)
  end

  set_winbar(st, nil, st.win)

  if #sections == 0 then
    show_empty_message(st)
  end

  set_canvas_keymaps(self, surface, st)

  -- Treesitter highlighting is deliberately NOT attached to a paged canvas.
  --
  -- It is viewport-bounded, but at SECTION granularity: a section that
  -- intersects the viewport is highlighted whole. That is right for an eager
  -- canvas, where a section is a file; on a paged canvas a single 24,000-row
  -- section produced 8,000 persistent extmarks -- marks that scale with the
  -- review, which is precisely what the paged canvas exists to prevent.
  --
  -- Making it row-granular means driving treesitter from the projection's
  -- decorator for visible rows only, which is a separate piece of work. Until
  -- then a large review keeps its diff tints, file bars and ghosts and loses
  -- syntax colour inside hunks -- a visible loss, chosen over silently
  -- reintroducing the structure the design forbids.
  if config.options.highlight.enabled and not st.paged then
    local hl_lease = hl.attach(st, config.options.highlight, {
      claim = function(lease)
        if not surface:guard(generation) or surface.controllers.hl ~= nil then
          return false
        end
        surface.controllers.hl = lease
        return true
      end,
      alive = function(lease)
        return surface:guard(generation) and surface.controllers.hl == lease
      end,
      release = function(lease)
        if surface.controllers.hl ~= lease then
          return false
        end
        surface.controllers.hl = nil
        return true
      end,
      windows = function()
        return surface:canvas_windows()
      end,
      side = function(section, which)
        -- Only reached for a section that has released its own copy. The UI
        -- domain cannot read the repository itself, so the owner answers.
        if not surface:guard(generation) or type(section) ~= "table" then
          return ""
        end
        if which == "new" then
          if section.new_rev then
            return source.show(st.root, section.new_rev, section.path) or ""
          end
          return source.worktree_text(st.root, section.path, section.status)
        end
        return source.show(st.root, section.old_rev or lens.of(st).old,
          section.old_path or section.path) or ""
      end,
    })
    if hl_lease then
      assert(surface.controllers.hl == hl_lease,
        "highlighter claim must publish its returned exact lease")
    end
  end

  if config.options.watch.enabled then
    surface.controllers.watch = watch.start(st, config.options.watch, {
      alive = function()
        return surface:guard(generation)
      end,
      begin = function()
        if not surface:guard(generation) then
          return nil
        end
        return {
          epoch = claim_model_epoch(surface),
          lens = lens.of(st),
        }
      end,
      current = function(publication)
        return surface:guard(generation)
          and publication ~= nil
          and surface.model_epoch == publication.epoch
          and lens.same(lens.of(st), publication.lens)
      end,
      publish = function(_, desired, publication)
        local function guard()
          return surface:guard(generation)
            and surface.model_epoch == publication.epoch
            and lens.same(lens.of(st), publication.lens)
        end
        local ok, err, full = pivot(
          surface, publication.lens, guard, desired)
        if not ok then
          if err == STALE_COMPARE then
            return false
          end
          return nil, err
        end
        return true, nil, full
      end,
      on_error = function(err)
        surface:guard(generation, function()
          ui.warn(err)
        end)
      end,
    })
  end

  if config.options.sidebar.enabled then
    open_sidebar(self, surface, st)
  end

  if config.options.scrollbar.enabled then
    local scroll_lease = scrollbar.open(st, config.options.scrollbar, {
      claim = function(lease)
        if not surface:guard(generation)
            or surface.controllers.scrollbar ~= nil then
          return false
        end
        surface.controllers.scrollbar = lease
        return true
      end,
      alive = function(lease)
        return surface:guard(generation)
          and surface.controllers.scrollbar == lease
      end,
      release = function(lease)
        if surface.controllers.scrollbar ~= lease then
          return false
        end
        surface.controllers.scrollbar = nil
        return true
      end,
    })
    if scroll_lease then
      assert(surface.controllers.scrollbar == scroll_lease,
        "scrollbar claim must publish its returned exact lease")
    end
  end

  -- The sticky file-header row is UNCONDITIONAL -- no config option. The top
  -- band and its file half are part of the one look, like the winbar: a
  -- canvas without it silently loses the answer to "which file am I in".
  local sticky_lease = sticky.open(st, {}, {
    claim = function(lease)
      if not surface:guard(generation)
          or surface.controllers.sticky ~= nil then
        return false
      end
      surface.controllers.sticky = lease
      return true
    end,
    alive = function(lease)
      return surface:guard(generation)
        and surface.controllers.sticky == lease
    end,
    release = function(lease)
      if surface.controllers.sticky ~= lease then
        return false
      end
      surface.controllers.sticky = nil
      return true
    end,
  })
  if sticky_lease then
    assert(surface.controllers.sticky == sticky_lease,
      "sticky claim must publish its returned exact lease")
  end

  -- The sticky filename now lives on the sticky header row
  -- (ui/sticky_header.lua), so the winbar text no longer varies with scroll --
  -- but this hook stays: its capture_view is load-bearing for session state,
  -- and it refreshes winbars on window changes. set_winbar skips identical
  -- text, which with a scroll-invariant label is every scroll, so the hook's
  -- winbar half costs a cache compare.
  --
  -- Unconditional and grouped with the close hooks so teardown reaps it.
  --
  -- (WinScrolled never fires headlessly -- see the harness notes -- so tests drive
  -- set_winbar or this callback by hand, as they already do for hl and the minimap.)
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized" }, {
    group = vim.api.nvim_create_augroup(surface.groups.winbar, { clear = true }),
    callback = function(ev)
      surface:guard(generation, function(owner)
        local event_win = tonumber(ev.match)
        if event_win and owner:owns_window(event_win) then
          owner:capture_view(event_win)
          if canvas_showing(st, event_win) then
            set_winbar(st, nil, event_win)
          end
        else
          refresh_winbars(owner)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinLeave" }, {
    group = surface.groups.winbar,
    buffer = st.buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      surface:guard(generation, function(owner)
        owner:canvas_snapshot()
        owner:capture_view(win)
        -- Activity defers the idle compactor: a user moving through the canvas
        -- must not be racing a background pass for the same pages.
        canvas.touch(owner.state)
      end)
    end,
  })

  if config.options.statuscolumn.enabled then
    local statuscol_lease = statuscol.attach(st, {
      claim = function(lease)
        if not surface:guard(generation) or surface.controllers.statuscol ~= nil then
          return false
        end
        surface.controllers.statuscol = lease
        return true
      end,
      alive = function(lease)
        return surface:guard(generation) and surface.controllers.statuscol == lease
      end,
      release = function(lease)
        if surface.controllers.statuscol ~= lease then
          return false
        end
        surface.controllers.statuscol = nil
        return true
      end,
      windows = function()
        return surface:canvas_windows()
      end,
    })
    if statuscol_lease then
      assert(surface.controllers.statuscol == statuscol_lease,
        "status-column claim must publish its returned exact lease")
    end
  end

  if config.options.session.enabled then
    local aug = vim.api.nvim_create_augroup(surface.groups.session, { clear = true })
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = aug,
      callback = function()
        surface:guard(generation, function(owner)
          owner:save()
        end)
      end,
    })
  end

  -- `:q` in the canvas window never reaches App:close, so hook the window's death
  -- and run the teardown from there. Without it the canvas is off screen while
  -- watch keeps reconciling it on every write and the session is never saved --
  -- losing whatever you had folded.
  --
  -- Deliberately NO `pattern`: BufWinEnter can move the Surface's primary host
  -- without reinstalling this hook. Binding the original scalar window is
  -- exactly how sidebar/scrollbar cleanup goes stale when the canvas moves.
  -- Reading the Surface's ownership at fire time cannot.
  --
  -- Deferred and re-checked, because another window in this tabpage may still be
  -- showing the canvas -- and because doing window work from inside WinClosed is
  -- fragile (the same reason sidebar.lua schedules its own).
  local close_aug = vim.api.nvim_create_augroup(surface.groups.close, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = close_aug,
    buffer = st.buf,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      surface:guard(generation, function(owner)
        owner:adopt_window(win)
        owner:capture_view(win)
        set_winbar(st, nil, win)
        local side_lease = owner.controllers.sidebar
        if side_lease then
          sidebar.reconcile(side_lease)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = close_aug,
    callback = function(ev)
      if not surface:guard(generation) then
        return
      end
      local closed = tonumber(ev.match)
      if not surface:owns_window(closed) then
        return
      end

      -- WinClosed fires while the closing window is still valid. Capture the
      -- semantic viewport now; the deferred disposal below runs after Neovim
      -- invalidates it and would otherwise persist folds but silently lose the
      -- user's position.
      surface:capture_view(closed)
      surface:release_window(closed)
      if st.winbar_text_by_win then
        st.winbar_text_by_win[closed] = nil
      end

      vim.schedule(function()
        surface:guard(generation, function(owner)
          -- Adopt an unregistered duplicate (plain :split emits no
          -- BufWinEnter), then decide from every still-valid host across tabs.
          owner:canvas_windows()
          if #owner:host_windows() == 0 then
            -- `:q` never reaches App:close, so the last-lens memory is
            -- recorded here as well: the rule is "the lens the review was
            -- showing when it closed", however it closed. Skipping this
            -- would leave an OLDER explicit-close record answering the
            -- next reopen.
            if owner.state.root then
              self.last_lens_by_root[owner.state.root] = lens.of(owner.state)
            end
            owner:dispose("last_window")
          else
            local side_lease = owner.controllers.sidebar
            if side_lease then
              sidebar.reconcile(side_lease)
            end
          end
        end)
      end)
    end,
  })

  -- Restore BEFORE the auto-virtualizer's first pass. A freshly-opened
  -- canvas sits at row 1, so a virt.apply here would auto-collapse whatever
  -- far section the saved view points at -- and restore's view step skips a
  -- collapsed target, silently reopening large changesets at section one.
  -- Restoring first also means the first apply classifies against the real
  -- viewport, so it leaves the section the user is looking at expanded.
  if sess then
    session.restore(st, sess)
    -- Restored collapses reshape the canvas after the sidebar and scrollbar
    -- were built from the fully-expanded one, and restoring the view doesn't
    -- necessarily scroll (it may already be at the top, or not be saved at
    -- all when the top section is the collapsed one) -- so nothing else
    -- brings them back in sync. Also fixes up the sidebar's active row, drawn
    -- from the pre-restore shape before the view step moved the viewport.
    sync_after_collapse(surface, st)
  end

  if config.options.virt.enabled then
    -- Attach applies immediately. Its owner callback is already generation-
    -- fenced even though the lease is not published on Surface until attach
    -- returns.
    surface.controllers.virt = virt.attach(st, config.options.virt, {
      alive = function()
        return surface:guard(generation)
      end,
      on_change = function(changed_state)
        surface:guard(generation, function()
          sync_after_collapse(surface, changed_state)
        end)
      end,
    })
  end
  surface:capture_view(st.win)
  return st
end

--- Is `buf` something we could sensibly leave a window sitting on?
local function restorable(buf, st)
  return buf
    and buf ~= st.buf
    and vim.api.nvim_buf_is_valid(buf)
    and vim.api.nvim_buf_is_loaded(buf)
end

--- Put `win` back on something useful now that the canvas is leaving it.
---
--- Preference order, most to least specific: the buffer this window had when
--- the canvas took it over; the last file an excursion landed in (if you were
--- reviewing, that's the file you most recently touched); the window's
--- alternate file; and only then a blank buffer. The chain exists because
--- landing on [No Name] reads as something having gone wrong, when in fact
--- nothing did -- the buffer we came from was simply deleted meanwhile.
local function restore_window(win, st, landing, visited)
  local candidates = {
    landing,
    visited,
    vim.api.nvim_win_call(win, function() return vim.fn.bufnr("#") end),
  }
  for _, buf in ipairs(candidates) do
    if restorable(buf, st) then
      vim.api.nvim_win_set_buf(win, buf)
      return
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("enew")
  end)
end

--- Take the canvas off screen and put every window it occupied back on
--- something useful. The canvas buffer itself is left alone -- canvas.lua
--- keeps it cached/hidden, which is what makes reopening cheap.
---
--- Acts on every window in this tabpage showing the canvas, not just the
--- current one. Restricting it to the current window meant `:CanvasDiff close`
--- from a neighbouring split was a silent no-op that read as the plugin being
--- broken. Surface records a landing per host, so views in different tabs
--- return to their own buffers rather than inheriting another window's history.
---
--- No canvas on screen ⇒ nothing to restore, but the teardown still runs. It used
--- to return early here, which meant that after a `:q` had taken the window there
--- was no longer any way to reach the teardown at all.
---
--- The status-column lease observes each buffer leave and restores that
--- window's prior local option; final disposal also restores every touched
--- host before this method swaps its buffer.
function App:close()
  -- The overlay never survives the canvas (spec R4). toggle() closes through
  -- here too, so one hook covers both paths.
  ui.cheatsheet.close()

  local surface = active_surface(self)
  if not surface then
    return
  end

  -- One Surface may have views in several tabs. `close` retains the historical
  -- tab-local command policy: retire the hosts in this workspace, but keep the
  -- review alive when another tab still owns a view of the same canvas.
  local st = surface.state
  -- Remember the comparison this review is showing, so a reopen returns to
  -- it (the in-memory tier of App:open's precedence chain). lens.of returns
  -- a normalized COPY, never the live table: the state graph dies with the
  -- Surface, and a later pivot in a still-alive review must not mutate the
  -- record. Ranges are remembered too -- a dead ref degrades at open, same
  -- as a saved one.
  local function remember_lens()
    if st.root then
      self.last_lens_by_root[st.root] = lens.of(st)
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  surface:canvas_windows()
  local hosts = surface:host_windows(tab)
  if #hosts == 0 then
    -- The final host may already have vanished and queued its deferred
    -- WinClosed recheck. An explicit close in that gap still owns teardown.
    if #surface:host_windows() == 0 then
      remember_lens()
      surface:dispose("explicit")
    end
    return
  end
  remember_lens()
  local wins = surface:tab_canvas_windows(tab)
  local landings = {}
  for _, win in ipairs(wins) do
    landings[win] = surface:landing_buffer(win)
    surface:capture_view(win)
  end
  -- Resolved before disposal, which releases this review's excursion store.
  local visited = jump.last_buf(surface.excursion)
  for _, win in ipairs(hosts) do
    clear_winbar(st, win)
  end

  for _, win in ipairs(hosts) do
    surface:release_window(win)
  end

  local final = #surface:host_windows() == 0
  if final then
    -- dispose() clears self.surface through an identity-checked callback, so
    -- retain the exact state and window list locally through restoration.
    surface:dispose("explicit")
  end

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == st.buf then
      restore_window(win, st, landings[win], visited)
    end
  end

  if not final then
    surface:canvas_windows()
    local side = surface.controllers.sidebar
    if side then
      sidebar.reconcile(side)
    end
  end
end

--- Toggle: if the canvas is on screen anywhere in this tabpage, take it off;
--- otherwise open it here.
---
--- Keyed on this tabpage: a neighbouring split closes the local views, while
--- a review living only in another tab is shown here without rebuilding it.
---
--- Being focused inside our own sidebar counts as "the canvas is open": close
--- it, or just close the sidebar if the canvas it was attached to is already
--- gone. Never errors.
function App:toggle()
  local surface = active_surface(self)
  local tab = vim.api.nvim_get_current_tabpage()
  local showing = surface and canvas_window_in_tab(surface, tab) ~= nil
  local current = vim.api.nvim_get_current_win()
  local side = surface and surface.controllers.sidebar

  if side and sidebar.is_sidebar_win(side, current) then
    if #surface:host_windows(tab) > 0 then
      self:close()
    else
      sidebar.reconcile(side)
    end
    return
  end

  if showing then
    self:close()
  elseif surface then
    local win = vim.api.nvim_get_current_win()
    local landing = vim.api.nvim_win_get_buf(win)
    if canvas.show(surface.state, win) then
      surface:adopt_window(win, landing)
      surface:capture_view(win)
      set_winbar(surface.state, nil, win)
      local side_lease = surface.controllers.sidebar
      if side_lease then
        sidebar.reconcile(side_lease)
      end
    end
  else
    -- Hand back what was opened, the way `open` does. A caller that toggles
    -- has no other way to learn whether it opened or closed a review.
    return self:open()
  end
end

--- Toggle the file-tree sidebar of the showing review.
---
--- Both directions reuse the sidebar's one lifecycle: OFF is the exact
--- terminal close Surface disposal drives (sidebar.close retires the lease
--- and releases the controller slot), ON is the exact open App:open runs when
--- `sidebar.enabled` -- deliberately WITHOUT that config check here, because
--- the flag governs auto-open only. A lease that is alive but has no view in
--- this tab (`q` dismissed it, or its window was :closed by hand) is retired
--- through the same close path first, so the reopen claims a fresh lease with
--- no dismissal state left over.
---
--- Warns rather than opening a review when nothing is showing, for the same
--- reason cycle_lens does: a toggle that opens a canvas would make a slip of
--- the key an expensive surprise.
function App:toggle_sidebar()
  local surface = active_surface(self)
  if not (surface and surface:is_showing()) then
    ui.warn("no live diff canvas")
    return
  end
  local lease = surface.controllers.sidebar
  if lease then
    local was_open = sidebar.is_open(
      lease, vim.api.nvim_get_current_tabpage())
    sidebar.close(lease)
    if was_open then
      return
    end
  end
  open_sidebar(self, surface, surface.state)
end

--- `:CanvasDiff sidebar` plans the call `sidebar`, matching the facade's
--- export; the verb itself is named toggle_sidebar, for what it does.
App.sidebar = App.toggle_sidebar

--- Re-collect against whatever the state is now pointed at and splice the
--- difference in, rather than rebuilding the buffer.
---
--- This is what makes the canvas *dynamic* instead of merely re-renderable.
--- render_all recreates every anchor, rewrites every line and restores no view, so
--- anything routed through it throws away where you were looking.
--- reconcile_sections leaves every section whose content is unchanged completely
--- untouched, and most files look identical through two lenses, so a pivot typically
--- splices nothing and moves nothing at all.
---
--- Shared by the lens pivot, App:refresh and watch -- they are one operation ("go and
--- see what is true now"), differing only in what prompted it.
local function capture_pivot(surface, st)
  local views = {}
  for _, win in ipairs(surface:canvas_snapshot().canvas) do
    local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
    if ok then
      views[win] = view
    end
  end
  local sections = {}
  for index, section in ipairs(st.sections or {}) do
    sections[index] = section
  end
  return {
    lens = st.lens,
    base = st.base,
    sections = sections,
    collapsed = vim.deepcopy(st.collapsed or {}),
    folded = vim.deepcopy(st.folded or {}),
    folded_seen = vim.deepcopy(st.folded_seen or {}),
    rendered_hidden = vim.deepcopy(st.rendered_hidden or {}),
    views = views,
  }
end

local function rollback_pivot(surface, st, snapshot, transaction)
  while true do
    st.lens = snapshot.lens
    st.base = snapshot.base
    st.collapsed = vim.deepcopy(snapshot.collapsed)
    st.folded = vim.deepcopy(snapshot.folded)
    st.folded_seen = vim.deepcopy(snapshot.folded_seen)
    st.rendered_hidden = vim.deepcopy(snapshot.rendered_hidden)
    local sections = {}
    for index, section in ipairs(snapshot.sections) do
      sections[index] = section
    end
    canvas.render_all(st, sections)
    if #snapshot.sections == 0 then
      show_empty_message(st)
    end

    -- Restoration itself renders and restores window state, both re-entrant
    -- editor boundaries. If a newer nested picker commits there, restart from
    -- its checkpoint instead of resuming the obsolete snapshot over it.
    local checkpoint = surface.compare_checkpoint
    if checkpoint and checkpoint.transaction > transaction then
      snapshot = checkpoint.snapshot
      transaction = checkpoint.transaction
    else
      st.folded_seen = vim.deepcopy(snapshot.folded_seen)
      st.rendered_hidden = vim.deepcopy(snapshot.rendered_hidden)
      local superseded
      for win, view in pairs(snapshot.views) do
        if canvas_showing(st, win) then
          pcall(vim.api.nvim_win_call, win, function()
            vim.fn.winrestview(view)
          end)
        end
        checkpoint = surface.compare_checkpoint
        if checkpoint and checkpoint.transaction > transaction then
          snapshot = checkpoint.snapshot
          transaction = checkpoint.transaction
          superseded = true
          break
        end
      end
      if not superseded then
        return
      end
    end
  end
end

pivot = function(surface, target_lens, guard, collected, publish)
  local st = surface and surface.state
  if not (st and st.buf and vim.api.nvim_buf_is_valid(st.buf)) then
    return nil, "no valid diff canvas"
  end

  -- Captured before anything below mutates the state: st.lens is provisionally
  -- overwritten mid-transaction, and the return-lens record at the commit point
  -- needs the comparison this pivot LEFT, not the one it installed.
  local prior_lens = lens.of(st)
  local next_lens = target_lens or lens.of(st)
  local desired, err = collected, nil
  if desired == nil then
    desired, err = source.sections(st.root, next_lens, config.options.context)
  end
  if guard and not guard() then
    return nil, STALE_COMPARE
  end
  if not desired then
    return nil, err
  end

  if guard and not guard() then
    return nil, STALE_COMPARE
  end

  local transaction
  if guard and target_lens then
    surface.compare_epoch = (surface.compare_epoch or 0) + 1
    transaction = surface.compare_epoch
    surface.compare_depth = (surface.compare_depth or 0) + 1
  end
  local snapshot = transaction and capture_pivot(surface, st) or nil
  local function finish(ok, err)
    if transaction then
      surface.compare_depth = surface.compare_depth - 1
      if surface.compare_depth == 0 then
        surface.compare_checkpoint = nil
      end
    end
    return ok, err
  end
  local function rollback()
    if snapshot then
      local restore = snapshot
      local restore_transaction = transaction
      local checkpoint = surface.compare_checkpoint
      if checkpoint and checkpoint.transaction > transaction then
        restore = checkpoint.snapshot
        restore_transaction = checkpoint.transaction
      end
      rollback_pivot(surface, st, restore, restore_transaction)
      snapshot = nil
      -- Reconciliation publishes more than section text. A failed excursion
      -- presentation can occur after peer winbars and controllers observed the
      -- provisional lens, so restore those consumers from the same checkpoint
      -- before the transaction returns.
      refresh_winbars(surface)
      sync_after_collapse(surface, st)
      local lease = surface.controllers.virt
      if lease then
        virt.apply(lease, config.options.virt)
      end
    end
  end
  local function stale()
    if not (guard and not guard()) then
      return false
    end
    rollback()
    return true
  end
  if stale() then
    return finish(nil, STALE_COMPARE)
  end

  -- Fold rendering and folded_seen are lens-dependent, so reconciliation must
  -- see the candidate lens. The snapshot above makes this publication
  -- provisional until every re-entrant boundary below has retained ownership.
  if target_lens then
    st.lens = target_lens
    st.base = lens.to_base(target_lens)
  end

  local full = canvas.reconcile_sections(st, desired)
  if stale() then
    return finish(nil, STALE_COMPARE)
  end

  if full and #desired == 0 then
    show_empty_message(st)
    if stale() then
      return finish(nil, STALE_COMPARE)
    end
  end
  refresh_winbars(surface)
  if stale() then
    return finish(nil, STALE_COMPARE)
  end
  sync_after_collapse(surface, st)
  if stale() then
    return finish(nil, STALE_COMPARE)
  end
  local lease = surface.controllers.virt
  if lease then
    virt.apply(lease, config.options.virt)
    if stale() then
      return finish(nil, STALE_COMPARE)
    end
  end
  if publish then
    local called, published, publish_err = pcall(publish)
    if not called or not published then
      rollback()
      return finish(nil, called
        and (publish_err or "could not publish comparison")
        or tostring(published))
    end
    if stale() then
      return finish(nil, STALE_COMPARE)
    end
  end
  if transaction and surface.compare_depth > 1 then
    local committed = capture_pivot(surface, st)
    if stale() then
      return finish(nil, STALE_COMPARE)
    end
    local checkpoint = surface.compare_checkpoint
    if not checkpoint or transaction > checkpoint.transaction then
      surface.compare_checkpoint = {
        transaction = transaction,
        snapshot = committed,
      }
    end
  end
  -- Where <Tab> goes when it leaves a comparison. Recorded at the single
  -- commit point every lens change funnels through, so no caller can forget
  -- it: entering a range remembers the lens you were looking through, leaving
  -- one forgets it. Range→range keeps the ORIGINAL — the comparison you came
  -- from is where "back" goes, however many ranges you visited meanwhile.
  -- In-memory only: a restored session exits to the default, as before.
  -- Reached only on success — every failed or stale path returned above, so a
  -- pivot that rolled back leaves the record exactly as it found it.
  if lens.is_range(next_lens) then
    if not lens.is_range(prior_lens) then
      st.return_lens = prior_lens
    end
  else
    st.return_lens = nil
  end
  local ok, finish_err = finish(true)
  return ok, finish_err, full and true or false
end

--- Re-collect and splice in whatever changed: the manual version of the pass
--- `watch` runs on save and focus, for when you don't trust what is on screen.
---
--- NON-DESTRUCTIVE, and that is the point of it being on a bare `r`. This used to
--- call render_all, which recreated every anchor, rewrote every line and restored
--- no view -- so the key you pressed to make the canvas trustworthy was also the
--- key that lost your place in it. Refreshing is the most ordinary thing you can
--- ask of a diff view; it has no business violating the invariant the rest of the
--- plugin is built to hold.
---
--- There is deliberately no companion "hard rebuild" action. A reconcile only
--- splices what it BELIEVES differs, so a state/buffer divergence survives any
--- number of refreshes -- but close() + open() already recovers from exactly that,
--- and it RESTORES your position through the session file, which a bare render_all
--- does not. A rebuild verb was written, measured against close+open, found
--- strictly worse on every axis, and deleted. Don't add it back without measuring:
--- test_e2e's "refresh cannot repair a divergent buffer, close+open can" pins both
--- halves of that result.
function App:refresh()
  local surface = active_surface(self)
  if not surface then
    return
  end
  local generation = surface.generation
  local model_epoch = claim_model_epoch(surface)
  local function guard()
    return self.surfaces[surface.state.buf] == surface
      and surface:guard(generation)
      and surface.model_epoch == model_epoch
  end
  local ok, err = pivot(surface, lens.of(surface.state), guard)
  if not ok then
    if err == STALE_COMPARE then
      return nil
    end
    ui.warn(err)
    return nil, err
  end
  return true
end

local function section_by_exact_path(st, path)
  for i, section in ipairs(st.sections or {}) do
    if section.path == path then
      return i, section
    end
  end
end

local function section_by_restore_path(st, path)
  for i, section in ipairs(st.sections or {}) do
    if section.path == path or section.old_path == path then
      return i, section
    end
  end
end

local function status_identity_key(file)
  return table.concat({
    tostring(file.path or ""),
    tostring(file.old_path or ""),
    tostring(file.staged or ""),
    tostring(file.unstaged or ""),
    tostring(file.status or ""),
  }, "\0")
end

-- Porcelain can report two records with the same current path, notably a
-- staged deletion plus a recreated untracked source. Keep action routing on
-- the exact selected section path, then use that section's visible lens and XY
-- metadata to choose deterministically between same-path records.
local function action_file(files, cached, current_lens)
  local best, best_rank, best_key
  for _, candidate in ipairs(files or {}) do
    if candidate.path == cached.path then
      local rank = 0
      if current_lens.id == "staged" and candidate.staged then
        rank = rank + 16
      elseif current_lens.id == "unstaged" and candidate.unstaged then
        rank = rank + 16
      end
      if candidate.staged == cached.staged then rank = rank + 4 end
      if candidate.unstaged == cached.unstaged then rank = rank + 2 end
      if candidate.old_path == cached.old_path then rank = rank + 1 end
      local key = status_identity_key(candidate)
      if not best_rank or rank > best_rank
          or (rank == best_rank and key < best_key) then
        best, best_rank, best_key = candidate, rank, key
      end
    end
  end
  return best
end

-- Git may rewrite one logical identity after a stage mutation: for example,
-- staging the deleted destination of an indexed old->new rename leaves a
-- staged deletion at old. Prefer the stable destination when it survives,
-- then its historical source, and break otherwise-equivalent matches by
-- Git's already-sorted path identity. This is intentionally post-mutation
-- only; action preflight remains exact-section-path.
local function post_mutation_file(files, before)
  local best, best_rank, best_key
  for _, candidate in ipairs(files or {}) do
    local rank = 0
    if candidate.path == before.path then
      rank = 4
    elseif before.old_path and candidate.path == before.old_path then
      rank = 3
    elseif candidate.old_path == before.path then
      rank = 2
    elseif before.old_path and candidate.old_path == before.old_path then
      rank = 1
    end
    local key = status_identity_key(candidate)
    if rank > 0 and (not best_rank or rank > best_rank
        or (rank == best_rank and key < best_key)) then
      best, best_rank, best_key = candidate, rank, key
    end
  end
  return best
end

local function capture_file_positions(surface, st, file)
  local positions = {}
  for _, win in ipairs(surface:canvas_snapshot().canvas) do
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local section_i = canvas.locate(st, cursor[1] - 1)
      local section = section_i and st.sections[section_i]
      if section and (section.path == file.path
          or section.path == file.old_path
          or section.old_path == file.path
          or section.old_path == file.old_path) then
        local start0 = canvas.section_rows(st, section_i)
        local offset = math.max(1, cursor[1] - start0)
        local entry = section.entries and section.entries[offset] or nil
        positions[win] = {
          path = file.path,
          old_path = file.old_path,
          offset = offset,
          anchor = entry and {
            new_lnum = entry.new_lnum,
            content = entry.content,
          } or nil,
          col = cursor[2],
        }
      end
    end
  end
  return positions
end

local function restore_file_positions(st, positions)
  for win, position in pairs(positions or {}) do
    if canvas_showing(st, win) then
      local section_i = section_by_restore_path(st, position.path)
      if not section_i and position.old_path then
        section_i = section_by_restore_path(st, position.old_path)
      end
      if section_i then
        local start0, end0 = canvas.section_rows(st, section_i)
        local section = st.sections[section_i]
        local offset = position.anchor
          and viewport.resolve(position.anchor, section.entries or {})
          or position.offset
        offset = math.max(1, offset or 1)
        local row = math.min(start0 + offset - 1, math.max(start0, end0 - 1))
        pcall(vim.api.nvim_win_set_cursor, win, { row + 1, position.col })
      end
    end
  end
end

local function stage_refresh_failure(message)
  local err = "index changed, but refresh failed: " .. tostring(message)
  ui.warn(err)
  return nil, err
end

--- Stage or unstage the file under the canvas cursor.
---
--- `direction` is "stage" or "unstage". The old auto-cycle decided this from
--- the file's XY state; two explicit verbs mean a keypress never surprises by
--- picking the other direction on a mixed file. A verb with nothing to do
--- reports itself as information and returns false without touching Git.
---
--- Git is the irreversible boundary: all ownership checks happen before it,
--- and every failure after it says explicitly that the index already changed.
--- `path`/`owned_surface`/`generation` are owner-only routing arguments used
--- by the sidebar callback; the public root calls this with no arguments.
function App:stage_file(direction, path, owned_surface, generation)
  assert(direction == "stage" or direction == "unstage",
    "stage_file: direction must be 'stage' or 'unstage', got " .. tostring(direction))
  local surface = owned_surface or active_surface(self)
  if not (surface and surface:is_alive()) then
    local err = "no live diff canvas"
    ui.warn(err)
    return nil, err
  end
  generation = generation or surface.generation
  local st = surface.state
  local current_lens = lens.of(st)
  if lens.is_range(current_lens) then
    local err = "READ-ONLY comparison — staging needs a worktree lens (press Tab)"
    ui.warn(err)
    return nil, err
  end

  surface.stage_epoch = (surface.stage_epoch or 0) + 1
  local transaction = surface.stage_epoch
  local model_epoch = claim_model_epoch(surface)
  local function guard()
    return self.surfaces[st.buf] == surface
      and surface:guard(generation)
      and surface.stage_epoch == transaction
      and surface.model_epoch == model_epoch
  end
  if not guard() then
    local err = "stage action was superseded before Git ran"
    ui.warn(err)
    return nil, err
  end

  local section_i, cached_file
  if path then
    section_i, cached_file = section_by_exact_path(st, path)
  else
    local win = vim.api.nvim_get_current_win()
    section_i = section_under_cursor(st, win)
    cached_file = section_i and st.sections[section_i]
  end
  if not cached_file then
    local err = path and (path .. " has no changes any more")
      or "no file under the cursor"
    ui.warn(err)
    return nil, err
  end

  local files, status_err = source.changed_files(st.root)
  if not guard() then
    local err = "stage action was superseded during status preflight"
    ui.warn(err)
    return nil, err
  end
  if not files then
    ui.warn(status_err)
    return nil, status_err
  end
  local file = action_file(files, cached_file, current_lens)
  if not file then
    local err = cached_file.path .. " has no changes any more"
    ui.warn(err)
    return nil, err
  end
  if not file.staged and not file.unstaged then
    local err = file.path .. " has no stage status"
    ui.warn(err)
    return nil, err
  end

  if direction == "stage" and not file.unstaged then
    ui.notify("already staged")
    return false
  end
  if direction == "unstage" and not file.staged then
    ui.notify("nothing staged")
    return false
  end

  local action = direction
  if action == "stage" and source.buffer_modified(st.root, file) then
    local err = "cannot stage " .. file.path .. ": its loaded buffer has unsaved changes"
    ui.warn(err)
    return nil, err
  end

  local positions = capture_file_positions(surface, st, cached_file)
  local changed, mutation_err, index_changed = source[action](st.root, file)
  if not changed then
    if index_changed then
      local err = "index changed, but " .. action .. " failed: " .. tostring(mutation_err)
      ui.warn(err)
      return nil, err
    end
    ui.warn(mutation_err)
    return nil, mutation_err
  end
  if not guard() then
    return stage_refresh_failure("the owning review changed during Git")
  end

  local files, status_err = source.changed_files(st.root)
  if not files then
    return stage_refresh_failure(status_err)
  end
  if not guard() then
    return stage_refresh_failure("the owning review changed during status refresh")
  end
  local remains = post_mutation_file(files, file)
  if not remains then
    local reconciled, reconcile_err = pivot(surface, current_lens, guard)
    if not reconciled then
      if reconcile_err == STALE_COMPARE then
        reconcile_err = "the owning review changed during clean reconcile"
      end
      return stage_refresh_failure(reconcile_err)
    end
    if not guard() then
      return stage_refresh_failure("the owning review changed after clean reconcile")
    end
    ui.notify(file.path .. " is clean")
    return true
  end

  local target_lens = current_lens
  if action == "stage" and current_lens.id == "unstaged" then
    target_lens = lens.get("staged")
  elseif action == "unstage" and current_lens.id == "staged" then
    target_lens = lens.get("unstaged")
  end
  local reconciled, reconcile_err = pivot(surface, target_lens, guard)
  if not reconciled then
    if reconcile_err == STALE_COMPARE then
      reconcile_err = "the owning review changed during reconcile"
    end
    return stage_refresh_failure(reconcile_err)
  end
  if not guard() then
    return stage_refresh_failure("the owning review changed after reconcile")
  end
  restore_file_positions(st, positions)
  ui.notify((action == "stage" and "staged " or "unstaged ") .. file.path)
  return true
end

--- Stage the file under the canvas cursor (or `path`).
function App:stage(path, owned_surface, generation)
  return self:stage_file("stage", path, owned_surface, generation)
end

--- Unstage the file under the canvas cursor (or `path`). Never writes disk.
function App:unstage(path, owned_surface, generation)
  return self:stage_file("unstage", path, owned_surface, generation)
end

--- Point the canvas at a different comparison, opening it if it isn't showing.
---
--- Idempotent, which is the whole point: commands get put inside user mappings, and
--- `:CanvasDiff unstaged` must always land unstaged. A toggle in a mapping is a coin
--- flip. Opening rather than warning is likewise the only sensible reading of a
--- command that names a state.
function App:set_lens(l)
  if not lens.valid(l) then
    local err = "not a lens"
    ui.warn(err)
    return nil, err
  end
  local surface = active_surface(self)
  if not (surface and surface:is_showing()) then
    local opened, err = self:open({ lens = l })
    if not opened then
      return nil, err
    end
    return true
  end
  local generation = surface.generation
  local model_epoch = claim_model_epoch(surface)
  local function guard()
    return self.surfaces[surface.state.buf] == surface
      and surface:guard(generation)
      and surface.model_epoch == model_epoch
  end
  if lens.same(lens.of(surface.state), l) then
    return true
  end

  local ok, err = pivot(surface, l, guard)
  if not ok then
    if err == STALE_COMPARE then
      return nil
    end
    ui.warn(err)
    return nil, err
  end
  ui.notify("showing " .. l.label)
  return true
end

local function set_owned_lens(app, surface, l, guard, on_commit, publish)
  local generation = surface.generation
  local model_epoch = claim_model_epoch(surface)
  local function owned_guard()
    return (not guard or guard())
      and app.surfaces[surface.state.buf] == surface
      and surface:guard(generation)
      and surface.model_epoch == model_epoch
  end
  if not owned_guard() then
    return nil
  end
  if lens.same(lens.of(surface.state), l)
      and not ((surface.compare_depth or 0) > 0) then
    if publish then
      local called, published, publish_err = pcall(publish)
      if not called or not published then
        local err = called
          and (publish_err or "could not publish comparison")
          or tostring(published)
        if err ~= STALE_COMPARE then
          ui.warn(err)
        end
        return nil, err
      end
      if not owned_guard() then
        return nil
      end
    end
    if on_commit then
      on_commit()
    end
    return true
  end
  local ok, err = pivot(surface, l, owned_guard, nil, publish)
  if not ok then
    if err == STALE_COMPARE then
      return nil
    end
    ui.warn(err)
    return nil, err
  end
  if not owned_guard() then
    return nil
  end
  if on_commit then
    on_commit()
  end
  ui.notify("showing " .. l.label)
  return true
end

--- Step through the three named lenses: all → unstaged → staged → all.
---
--- This is what the `base` keymap runs, and it is the gesture the canvas is built
--- around -- one key to ask "what am I actually looking at" from three angles.
--- Warns rather than opening: a keypress on no canvas is a mistake, not a request.
function App:cycle_lens(delta)
  local surface = active_surface(self)
  if not (surface and surface:is_showing()) then
    ui.warn("no live diff canvas")
    return
  end
  local current = lens.of(surface.state)
  -- Leaving a comparison goes back to the lens you entered it from; the
  -- cycle only ever steps between the three named lenses. A return lens
  -- that no longer pivots for a REPORTED reason (its branch was deleted
  -- meanwhile) is cleared, so the next press takes the default exit instead
  -- of failing forever. A transient refusal -- a stale-compare bounce or a
  -- git hiccup that set_lens reports with no error -- keeps the target, so
  -- one bad press does not permanently downgrade <Tab>.
  if lens.is_range(current) then
    local back = surface.state.return_lens
    if back and lens.valid(back) then
      local ok, err = self:set_lens(back)
      if ok then
        return ok
      end
      if err ~= nil then
        surface.state.return_lens = nil
      end
      return
    end
  end
  return self:set_lens(lens.step(current, delta or 1))
end

--- The canvas q: back out of the thing you are in. A comparison stacked on a
--- working view this session pops back to that view (same landing as <Tab>,
--- same clear-on-real-error rule); anything else closes the review. Only the
--- KEY behaves this way -- :CanvasDiff close and App:close stay pure close,
--- so scripts that say close get close.
function App:back_out_or_close(surface)
  surface = surface or active_surface(self)
  local st = surface and surface.state
  if st and lens.is_range(lens.of(st)) then
    local back = st.return_lens
    if back and lens.valid(back) then
      local ok, err = self:set_lens(back)
      if ok then
        return ok
      end
      if err ~= nil then
        st.return_lens = nil
      end
      return
    end
  end
  return self:close()
end

--- Compare the worktree against an arbitrary ref, e.g. `main` or `origin/main`.
--- The new side stays the worktree, so this is still somewhere you can work.
function App:set_branch(ref)
  local l = lens.branch(ref)
  if not l then
    local err = "no ref given"
    ui.warn(err)
    return nil, err
  end
  return self:set_lens(l)
end

--- Point the canvas at a committed range. Public callers may pass the direct
--- command spelling or an already-normalized range lens.
function App:set_range(spec)
  local l = spec
  if type(spec) == "string" then
    local parsed = command.parse({ spec })
    if parsed.action == "range" then
      l = lens.range(parsed.left, parsed.right, parsed.operator)
    end
  end
  if not lens.is_range(l) then
    local err = "not a commit range"
    ui.warn(err)
    return nil, err
  end
  return self:set_lens(l)
end

local function sorted_copy(items)
  local out = vim.list_slice(items)
  table.sort(out, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.ref < b.ref
  end)
  return out
end

local function base_choices(branches)
  local main
  local master
  local remaining = {}
  for _, item in ipairs(branches) do
    if item.ref == "refs/heads/main" then
      main = item
    elseif item.ref == "refs/heads/master" then
      master = item
    else
      remaining[#remaining + 1] = item
    end
  end
  remaining = sorted_copy(remaining)
  local out = {}
  if main then
    out[#out + 1] = main
  end
  if master then
    out[#out + 1] = master
  end
  vim.list_extend(out, remaining)
  return out
end

local function comparison_choices(branches)
  local current
  local remaining = {}
  for _, item in ipairs(branches) do
    if item.current then
      current = item
    else
      remaining[#remaining + 1] = item
    end
  end
  remaining = sorted_copy(remaining)
  local out = {}
  if current then
    out[#out + 1] = current
  end
  vim.list_extend(out, remaining)
  return out
end

local function format_branch(item)
  return source.format_ref(item)
end

local function window_cwd(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  local ok, cwd = pcall(vim.fn.getcwd,
    vim.api.nvim_win_get_number(win),
    vim.api.nvim_tabpage_get_number(tab))
  return ok and vim.fs.normalize(cwd) or nil
end

local function ref_origin_alive(app, request)
  if app.ref_request ~= request.token
      or not vim.api.nvim_win_is_valid(request.win)
      or vim.api.nvim_win_get_buf(request.win) ~= request.buf
      or window_cwd(request.win) ~= request.cwd then
    return false
  end
  local owner = surface_for_window(app, request.win)
  if not request.surface then
    return owner == nil
  end
  if owner ~= request.surface
      or request.surface.state.root ~= request.root
      or not request.surface:guard(request.generation)
      or request.surface:is_showing() ~= request.visible then
    return false
  end
  if request.origin == "sidebar" then
    local side = request.surface.controllers.sidebar
    return side ~= nil
      and sidebar.is_sidebar_win(side, request.win)
      and sidebar.canvas_win(side, request.win) == request.host_win
      and canvas_showing(request.surface.state, request.host_win)
  end
  if request.origin == "canvas" then
    return request.host_win == request.win
      and canvas_showing(request.surface.state, request.win)
  end
  if request.visible then
    return request.host_win ~= nil
      and canvas_showing(request.surface.state, request.host_win)
  end
  return true
end

local function begin_ref_request(app, kind)
  -- Mutation requests and comparisons are distinct monotonic domains, but a
  -- new mutation invalidates both: no older picker may cross the Git boundary
  -- after the user has expressed a newer ref intent.
  app.ref_request = app.ref_request + 1
  app.compare_request = app.compare_request + 1
  local request = {
    token = app.ref_request,
    kind = kind,
    win = vim.api.nvim_get_current_win(),
  }
  request.buf = vim.api.nvim_win_get_buf(request.win)
  request.cwd = window_cwd(request.win)
  request.surface = surface_for_window(app, request.win)
  request.generation = request.surface and request.surface.generation or nil
  request.visible = request.surface and request.surface:is_showing() or false
  if request.surface then
    local side = request.surface.controllers.sidebar
    if side and sidebar.is_sidebar_win(side, request.win) then
      request.origin = "sidebar"
      request.host_win = sidebar.canvas_win(side, request.win)
    elseif canvas_showing(request.surface.state, request.win) then
      request.origin = "canvas"
      request.host_win = request.win
    else
      request.origin = "excursion"
      request.host_win = request.surface:canvas_windows()[1]
    end
    request.root = request.surface.state.root
  else
    local dir = buf_dir(request.buf)
    request.root = dir and source.root(dir) or nil
    if not request.root then
      request.root = request.cwd and source.root(request.cwd) or nil
    end
  end
  return request
end

local function branch_refresh_failure(message)
  local err = "branch changed, but Canvas refresh failed: " .. tostring(message)
  ui.warn(err)
  return nil, err
end

local function leave_retired_canvas(host, replacement)
  if not (host and vim.api.nvim_win_is_valid(host)
      and replacement and replacement.canvas_buf
      and vim.api.nvim_win_get_buf(host) == replacement.canvas_buf) then
    return
  end
  local landing = replacement.ownership
    and replacement.ownership.landings
    and replacement.ownership.landings[host] or nil
  if landing and vim.api.nvim_buf_is_valid(landing)
      and vim.api.nvim_buf_is_loaded(landing) then
    pcall(vim.api.nvim_win_set_buf, host, landing)
    return
  end
  pcall(vim.api.nvim_win_call, host, function() vim.cmd("enew") end)
end

local function rebuild_after_ref_change(app, request)
  if not request.surface then
    return true
  end
  if not request.surface:guard(request.generation) then
    return branch_refresh_failure("originating Canvas is no longer live")
  end

  -- The ownership operation invalidates the old generation and disposes every
  -- controller/store before App:open can recollect against the new HEAD.
  local replacement = request.surface:retire_for_ref_change(
    request.host_win, lens.get("all"))
  if not replacement then
    return branch_refresh_failure("could not retire the originating Canvas")
  end
  -- The retire above is a teardown path too, so it must land in the
  -- last-lens memory -- but NOT as lens.of(the retired state):
  -- retire_for_ref_change overwrites state.lens with the replacement lens
  -- BEFORE disposing, so the pre-checkout lens is already gone here. That
  -- replacement lens is also the correct record: the checkout deliberately
  -- resets the review to `all` and invalidates the session file, so when the
  -- reopen below fails (or the review is not visible), a stale memory entry
  -- would otherwise decide the next open and resurrect the pre-checkout
  -- comparison over that deliberate reset.
  if request.root then
    app.last_lens_by_root[request.root] = lens.get("all")
  end
  if not request.visible then
    return true
  end
  local host = request.host_win
  if not (host and vim.api.nvim_win_is_valid(host)) then
    return branch_refresh_failure("originating Canvas window is no longer valid")
  end

  local opened, open_err
  local called, call_err = pcall(vim.api.nvim_win_call, host, function()
    opened, open_err = app:open({
      _root = request.root,
      _replacement = replacement,
      _session = replacement.session,
      lens = lens.get("all"),
    })
  end)
  if not called then
    leave_retired_canvas(host, replacement)
    return branch_refresh_failure(call_err)
  end
  if not opened then
    leave_retired_canvas(host, replacement)
    return branch_refresh_failure(open_err or "could not reopen Canvas")
  end
  return true
end

local function choose_ref(app, kind)
  local request = begin_ref_request(app, kind)
  if not ref_origin_alive(app, request) then
    return
  end
  if not request.root then
    local err = "not inside a git repository"
    ui.warn(err)
    return nil, err
  end

  local branches, inspect_err = source.branches(request.root)
  if not ref_origin_alive(app, request) then
    return
  end
  if not branches then
    ui.warn(inspect_err)
    return nil, inspect_err
  end
  local choices = kind == "checkout"
    and source.local_branches(branches)
    or source.remote_tracking_branches(branches)
  if #choices == 0 then
    local err = kind == "checkout"
      and "no local branches found"
      or "no remote-tracking branches found"
    ui.warn(err)
    return nil, err
  end

  local result, result_err
  vim.ui.select(choices, {
    prompt = kind == "checkout"
      and "CanvasDiff switch local branch:"
      or "CanvasDiff create tracking branch:",
    kind = kind == "checkout"
      and "canvasdiff_branch_checkout"
      or "canvasdiff_branch_track",
    format_item = format_branch,
  }, function(selected)
    if not selected or not ref_origin_alive(app, request) then
      return
    end
    local offered = false
    for _, item in ipairs(choices) do
      if item == selected then
        offered = true
        break
      end
    end
    if not offered then
      return
    end
    local local_name
    if kind == "track" then
      local_name, result_err = source.tracking_branch_name(selected)
      if not local_name then
        ui.warn(result_err)
        return
      end
    end
    if kind == "checkout" then
      local live_ref = source.current_branch(request.root)
      if not ref_origin_alive(app, request) then
        return
      end
      if live_ref == selected.ref then
        result, result_err = true, nil
        return
      end
    end
    local modified = source.modified_buffer_in_root(request.root)
    if not ref_origin_alive(app, request) then
      return
    end
    if modified then
      result_err = "cannot switch branches: modified buffer " .. modified
      ui.warn(result_err)
      return
    end
    -- Last ownership check before the irreversible Git boundary.
    if not ref_origin_alive(app, request) then
      return
    end

    local changed, mutation_warning
    if kind == "checkout" then
      changed, mutation_warning =
        source.switch_branch(request.root, selected.ref)
    else
      changed, mutation_warning = source.track_branch(
        request.root, local_name, selected.ref)
    end
    if not changed then
      result_err = mutation_warning
      ui.warn(result_err)
      return
    end
    if mutation_warning then
      ui.warn(mutation_warning)
    end
    session.invalidate(request.root)
    local rebuilt, rebuild_err = rebuild_after_ref_change(app, request)
    if not rebuilt then
      result, result_err = nil, rebuild_err
      return
    end
    result, result_err = true, mutation_warning
  end)
  return result, result_err
end

--- Select and switch to one exact local branch.
function App:checkout()
  return choose_ref(self, "checkout")
end

--- Create a local branch that tracks one exact remote-tracking ref.
function App:track()
  return choose_ref(self, "track")
end

local function compare_origin_alive(app, request, unpublished_buf)
  if app.compare_request ~= request.token
      or not vim.api.nvim_win_is_valid(request.win) then
    return false
  end
  local owner = surface_for_window(app, request.win)
  if request.surface then
    if owner ~= request.surface
        or not request.surface:guard(request.generation) then
      return false
    end
    if request.origin == "sidebar" then
      local side = request.surface.controllers.sidebar
      return side ~= nil
        and sidebar.is_sidebar_win(side, request.win)
        and sidebar.canvas_win(side, request.win) == request.host_win
        and canvas_showing(request.surface.state, request.host_win)
    end
    return true
  end
  return owner == nil
    and (
      vim.api.nvim_win_get_buf(request.win) == request.buf
      or vim.api.nvim_win_get_buf(request.win) == unpublished_buf
    )
end

--- Pick a merge-base comparison without changing refs or repository state.
--- Every callback is fenced by both a monotonic request and the exact
--- Surface/window identity that issued it.
function App:compare()
  -- Invalidate before any repository or editor call: injected adapters and UI
  -- callbacks may reenter, and "newer" begins when this request is invoked.
  self.ref_request = self.ref_request + 1
  self.compare_request = self.compare_request + 1
  local token = self.compare_request
  local win = vim.api.nvim_get_current_win()
  local request = {
    token = token,
    win = win,
    buf = vim.api.nvim_win_get_buf(win),
  }
  local surface = surface_for_window(self, win)
  if self.compare_request ~= token then
    return
  end
  request.surface = surface
  request.generation = surface and surface.generation or nil
  if surface then
    local side = surface.controllers.sidebar
    if side and sidebar.is_sidebar_win(side, win) then
      request.origin = "sidebar"
      request.host_win = sidebar.canvas_win(side, win)
    elseif canvas_showing(surface.state, win) then
      request.origin = "canvas"
      request.host_win = win
    else
      request.origin = "excursion"
      request.host_win = win
    end
  end

  local root = surface and surface.state.root or source.root(vim.fn.getcwd())
  if not compare_origin_alive(self, request) then
    return
  end
  if not root then
    local dir = buf_dir(request.buf)
    root = dir and source.root(dir) or nil
    if not compare_origin_alive(self, request) then
      return
    end
  end
  if not root then
    ui.warn("not inside a git repository")
    return
  end
  request.root = root

  local branches, err = source.branches(root)
  if not compare_origin_alive(self, request) then
    return
  end
  if not branches then
    ui.warn(err)
    return nil, err
  end
  local local_branches = source.local_branches(branches)
  local bases = base_choices(local_branches)
  if #bases == 0 then
    local no_branches = "no local branches found"
    ui.warn(no_branches)
    return nil, no_branches
  end
  local comparisons = comparison_choices(local_branches)

  vim.ui.select(bases, {
    prompt = "CanvasDiff compare from branch:",
    kind = "canvasdiff_branch_base",
    format_item = format_branch,
  }, function(base)
    if not base or not compare_origin_alive(self, request) then
      return
    end
    -- The base never reappears in the second list: A...A is empty by
    -- construction, and vim.ui.select cannot gray an item out, so omission
    -- is the only way to make the mistake inexpressible.
    local targets = {}
    for _, item in ipairs(comparisons) do
      if item.ref ~= base.ref then
        targets[#targets + 1] = item
      end
    end
    if #targets == 0 then
      ui.warn("no other local branch to compare " .. base.name .. " against")
      return
    end
    vim.ui.select(targets, {
      -- The prompt carries step one's choice: by the second list the first
      -- pick is off screen, and "to branch:" made the user hold it in their
      -- head. Same arrow vocabulary as the winbar label the pick becomes;
      -- the bare name, not format_branch's "[checked out]" decoration --
      -- that is picker-item metadata, not part of the comparison.
      prompt = ("CanvasDiff compare: %s → ?"):format(base.name),
      kind = "canvasdiff_branch_compare",
      format_item = format_branch,
    }, function(other)
      if not other or not compare_origin_alive(self, request) then
        return
      end
      vim.api.nvim_win_call(request.win, function()
        if compare_origin_alive(self, request) then
          local target = lens.range(base.ref, other.ref, "...")
          local guard = function(unpublished_buf)
            return compare_origin_alive(self, request, unpublished_buf)
          end
          if request.surface then
            local publish
            if request.origin == "excursion"
                and not canvas_showing(request.surface.state, request.host_win) then
              publish = function()
                local host = request.host_win
                local st = request.surface.state
                local landing = vim.api.nvim_win_get_buf(host)
                local primary = st.win
                local winbar = vim.api.nvim_get_option_value("winbar", { win = host })
                local function restore()
                  st.win = primary
                  if vim.api.nvim_win_is_valid(host)
                      and vim.api.nvim_buf_is_valid(landing)
                      and vim.api.nvim_win_get_buf(host) == st.buf then
                    pcall(vim.api.nvim_win_set_buf, host, landing)
                    pcall(vim.api.nvim_set_option_value,
                      "winbar", winbar, { win = host })
                  end
                end
                local ok, published = pcall(function()
                  if not canvas.show(st, host) then
                    error("could not show comparison in its originating window", 0)
                  end
                  if not guard() then
                    error(STALE_COMPARE, 0)
                  end
                  request.surface:adopt_window(host, landing)
                  request.surface:capture_view(host)
                  set_winbar(st, nil, host)
                  local side_lease = request.surface.controllers.sidebar
                  if side_lease then
                    sidebar.reconcile(side_lease)
                  end
                  return true
                end)
                if not ok or not published then
                  restore()
                  return nil, ok
                    and "could not publish comparison"
                    or tostring(published)
                end
                return true
              end
            end
            local changed = set_owned_lens(
              self, request.surface, target, guard, function()
                jump.cancel(request.surface.excursion)
              end, publish)
          else
            self:open({
              lens = target,
              _root = request.root,
              _guard = guard,
            })
          end
        end
      end)
    end)
  end)
end

--- Set the diff base to "HEAD" or "index" -- the older two-value vocabulary, which
--- `:CanvasDiff all` / `:CanvasDiff unstaged` still speak.
function App:set_base(base)
  return self:set_lens(lens.from_base(base))
end

--- Flip between "worktree vs HEAD" and "worktree vs index" (unstaged-only review).
---
--- Kept as the exact two-value flip for user mappings that want precisely that; the
--- `B` key runs App:cycle_lens, which also reaches the staged view. Warns rather than
--- opening, for the same reason cycle_lens does.
function App:toggle_base()
  local surface = active_surface(self)
  if not (surface and surface:is_showing()) then
    ui.warn("no live diff canvas")
    return
  end
  return self:set_base(
    lens.to_base(lens.of(surface.state)) == "index" and "HEAD" or "index")
end

return App
