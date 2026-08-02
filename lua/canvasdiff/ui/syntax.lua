local M = {}

local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")
local fold = diff.fold

local TS_NS = vim.api.nvim_create_namespace("canvasdiff.canvas.ts")

local CACHE_CAP = 20
local next_id = 0
-- Supplying extmark IDs before placement lets a lease publish ownership before
-- the Neovim call that creates the mark. That matters under fault injection:
-- if set_extmark reentrantly disposes this lease, teardown already knows the
-- exact ID it must remove. IDs never repeat within this module, so a delayed
-- old cleanup cannot hit an ID recycled by a concurrent or later lease.
local next_extmark_id = 0

-- Lookup-only authentication. Weak keys cannot keep a lease alive and, unlike
-- trusting a handful of public table fields, cannot be copied onto a forged
-- shell. Nothing here decides which highlighter is "the" live one: independent
-- Surfaces hold independent leases simultaneously, and every live resource
-- stays reachable only from the lease that owns it.
local LEASE_AUTH = setmetatable({}, { __mode = "k" })

local function exact(lease)
  return type(lease) == "table"
    and LEASE_AUTH[lease] == true
    and not lease.disposed
end

--- Add the owner's generation fence to exact lease authentication. Both checks
--- around `alive` are load-bearing: owner code may dispose this exact lease
--- reentrantly before the callback returns.
local function active(lease)
  if not exact(lease) then
    return false
  end
  local alive = lease.callbacks and lease.callbacks.alive
  if not alive then
    return true
  end
  local ok, result = pcall(alive, lease)
  return ok and result and exact(lease) or false
end

-- Whole-file parse cache, keyed by section path. This state belongs to one
-- highlighter lease; the no-lease analysis helper gets an ephemeral store and
-- therefore cannot retain a source string or syntax tree globally.
local function ephemeral_cache()
  return { cache = {}, cache_n = 0, cache_tick = 0 }
end

local function evict_lru(owner)
  local worst, worst_tick
  for p, e in pairs(owner.cache) do
    if not worst_tick or e.tick < worst_tick then
      worst, worst_tick = p, e.tick
    end
  end
  if worst then
    owner.cache[worst] = nil
    owner.cache_n = owner.cache_n - 1
  end
end

local function cache_entry(owner, path)
  local e = owner.cache[path]
  if not e then
    if owner.cache_n >= CACHE_CAP then
      evict_lru(owner)
    end
    e = {}
    owner.cache[path] = e
    owner.cache_n = owner.cache_n + 1
  end
  owner.cache_tick = owner.cache_tick + 1
  e.tick = owner.cache_tick
  return e
end

--- Drop one exact lease's cached trees for `path` (its content changed).
function M.invalidate(lease, path)
  if not exact(lease) then
    return false
  end
  if lease.cache[path] then
    lease.cache[path] = nil
    lease.cache_n = lease.cache_n - 1
  end
  return true
end

--- Test-only: current number of cached paths in one exact lease.
function M._cache_size(lease)
  return exact(lease) and lease.cache_n or 0
end

--- Treesitter language for a repo-relative path, or nil when the filetype is
--- unknown, no parser is installed, or the language has no highlights query.
function M.lang_for(path)
  local ft = vim.filetype.match({ filename = path })
  if not ft or ft == "" then
    return nil
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.language.add, lang) then
    return nil
  end
  local ok, query = pcall(vim.treesitter.query.get, lang, "highlights")
  if not ok or not query then
    return nil
  end
  return lang
end

--- Parse (or reuse) the tree for one side of a cached path. `src` identity is
--- the invalidation check: a replaced section arrives with a fresh string.
local function side_tree(entry, side, src, lang)
  local src_key, tree_key = side .. "_src", side .. "_tree"
  if entry[src_key] ~= src then
    if src == "" then
      entry[src_key] = src
      entry[tree_key] = nil
    else
      local parser = vim.treesitter.get_string_parser(src, lang)
      local tree = parser:parse(true)[1]
      -- Publish the source key only after parsing succeeds, so a transient
      -- parser failure cannot poison this cache entry into a permanent nil.
      entry[src_key] = src
      entry[tree_key] = tree
    end
  end
  return entry[tree_key]
end

--- Treesitter highlight marks for one section, as pure data:
--- { row = 0-based section-relative, col, end_col (byte, incl. the 1-byte
--- rendered prefix), group = "@<capture>.<lang>", priority = 110 }.
--- ctx/add rows are colored from new_text, del rows from old_text; header
--- rows get nothing. Multi-row captures are clipped per displayed row.
function M.section_ts_marks(section, lease)
  if lease and not active(lease) then
    return {}
  end
  local lang = M.lang_for(section.path)
  if not lang then
    return {}
  end
  if lease and not active(lease) then
    return {}
  end
  local query = vim.treesitter.query.get(lang, "highlights")
  if lease and not active(lease) then
    return {}
  end
  local owner = lease or ephemeral_cache()
  local entry = cache_entry(owner, section.path)

  local marks = {}

  --- One side's raw file text.
  ---
  --- A section may have released its copies (bounded ingestion), so fall back
  --- to the owner. Input for a parse only -- the UI domain must not read the
  --- repository itself, and a side that cannot be produced simply yields no
  --- treesitter marks rather than a wrong or partial highlight.
  local function side_text(side)
    local retained = (side == "new") and section.new_text or section.old_text
    if retained ~= nil then
      return retained
    end
    local provide = lease and lease.callbacks and lease.callbacks.side
    if not provide then
      return ""
    end
    local ok, text = pcall(provide, section, side)
    if not ok or type(text) ~= "string" then
      return ""
    end
    return text
  end

  local function side_marks(side)
    local src = side_text(side)
    if src == "" then
      return
    end

    -- source lnum (1-based) -> section-relative 0-based row
    local rows, lo, hi = {}, nil, nil
    for i, e in ipairs(section.entries) do
      local lnum
      if side == "new" then
        lnum = (e.kind == "ctx" or e.kind == "add") and e.new_lnum or nil
      else
        lnum = (e.kind == "del") and e.old_lnum or nil
      end
      if lnum then
        rows[lnum] = i - 1
        lo = math.min(lo or lnum, lnum)
        hi = math.max(hi or lnum, lnum)
      end
    end
    if not lo then
      return
    end

    local tree = side_tree(entry, side, src, lang)
    if not tree then
      return
    end
    if lease and not active(lease) then
      return
    end

    local src_lines
    for id, node in query:iter_captures(tree:root(), src, lo - 1, hi) do
      local sr, sc, er, ec = node:range()
      for r = math.max(sr, lo - 1), math.min(er, hi - 1) do
        local brow = rows[r + 1]
        if brow then
          local scol = (r == sr) and sc or 0
          local ecol
          if r == er then
            ecol = ec
          else
            src_lines = src_lines or vim.split(src, "\n", { plain = true })
            ecol = #(src_lines[r + 1] or "")
          end
          if ecol > scol then
            marks[#marks + 1] = {
              row = brow,
              col = scol + 1,
              end_col = ecol + 1,
              group = "@" .. query.captures[id] .. "." .. lang,
              priority = 110,
            }
          end
        end
      end
    end
  end

  side_marks("new")
  if lease and not active(lease) then
    return {}
  end
  side_marks("old")
  if lease and not active(lease) then
    return {}
  end
  return marks
end

local function close_timer(timer)
  if not timer then
    return
  end
  pcall(function()
    timer:stop()
  end)
  local ok, closing = pcall(function()
    return timer:is_closing()
  end)
  if not ok or not closing then
    pcall(function()
      timer:close()
    end)
  end
end

local function try_delete_extmark(buf, id)
  local ok = pcall(vim.api.nvim_buf_del_extmark, buf, TS_NS, id)
  -- Neovim returns false when the exact ID is already absent. That is still a
  -- completed cleanup; only a thrown call leaves ownership unresolved.
  return ok
end

-- Terminal teardown and a post-replacement late-write rollback have no later
-- exact owner to retry through, so absorb one transient failure locally.
local function retry_delete_extmark(buf, id)
  for _ = 1, 2 do
    if try_delete_extmark(buf, id) then
      return true
    end
  end
  return false
end

local function owned_ids(lease)
  local out, seen = {}, {}
  local function collect(ids)
    for _, id in ipairs(ids or {}) do
      if not seen[id] then
        seen[id] = true
        out[#out + 1] = id
      end
    end
  end
  for _, ids in pairs(lease.ids_by_path) do
    collect(ids)
  end
  for ids in pairs(lease.pending) do
    collect(ids)
  end
  for ids in pairs(lease.deleting) do
    collect(ids)
  end
  return out
end

-- Highlighter hook records live on the canvas state's own hooks table under
-- this private key. Keeping the chain there rather than in a module-global
-- registry means no process-wide table retains a state, a wrapper, or an
-- owner callback, and a lease can still be spliced out of the middle of the
-- chain when leases are torn down out of installation order.
local HOOK_CHAIN = {}

--- Remove one record from one hook slot's chain.
---
--- Restoring only works when this record still holds the slot. Otherwise a
--- later lease captured this wrapper as its own predecessor, so hand that peer
--- our predecessor instead: the consumer's original hook stays reachable and
--- no wrapper of ours remains referenced from anywhere.
local function unlink_hook(record, slot, wrapper_key, prior_key)
  local hooks_table = record.table
  if rawget(hooks_table, slot) == record[wrapper_key] then
    rawset(hooks_table, slot, record[prior_key])
    return true
  end
  for _, peer in ipairs(rawget(hooks_table, HOOK_CHAIN) or {}) do
    if peer ~= record and peer[prior_key] == record[wrapper_key] then
      peer[prior_key] = record[prior_key]
      return true
    end
  end
  -- A consumer replaced the slot outright after attach. Its replacement is
  -- not ours to undo.
  return false
end

local function release_hooks(hooks)
  if not (hooks and hooks.table) then
    return
  end
  unlink_hook(hooks, "on_render_all", "render_wrapper", "prior_render")
  unlink_hook(hooks, "on_section_replaced", "replace_wrapper", "prior_replace")

  local chain = rawget(hooks.table, HOOK_CHAIN)
  if chain then
    for i, peer in ipairs(chain) do
      if peer == hooks then
        table.remove(chain, i)
        break
      end
    end
    if #chain == 0 then
      rawset(hooks.table, HOOK_CHAIN, nil)
    end
  end

  -- A caller may retain either wrapper after detach. Empty its captured hook
  -- graph so that stale closure retains neither the state table nor earlier
  -- owner callbacks. Unlinking already handed our predecessor to whoever still
  -- needed it, so no live chain can reach these fields.
  hooks.table = nil
  hooks.prior_render = nil
  hooks.prior_replace = nil
  hooks.render_wrapper = nil
  hooks.replace_wrapper = nil
end

--- Exact, idempotent teardown for one highlighter lease. Invalidate and
--- release the retained graph before any Neovim/uv operation can run user
--- fault-injection code.
function M.detach(expected)
  local lease = expected
  if not exact(lease) then
    return false
  end

  LEASE_AUTH[lease] = nil
  lease.disposed = true

  local state = lease.state
  local buf = state and state.buf
  local aug = lease.aug
  local group_name = lease.group_name
  local autocmd_ids = lease.autocmd_ids
  local timer = lease.timer
  local hooks = lease.hooks
  local release = lease.callbacks and lease.callbacks.release
  local claimed = lease.claimed
  local ids = owned_ids(lease)

  lease.state = nil
  lease.opts = nil
  lease.callbacks = {}
  lease.aug = nil
  lease.group_name = nil
  lease.timer = nil
  lease.hooks = nil
  lease.ids_by_path = {}
  lease.pending = {}
  lease.deleting = {}
  lease.cache = {}
  lease.cache_n = 0
  lease.cache_tick = 0
  lease.epoch = 0
  lease.autocmd_ids = {}

  -- Restore only the hook slots this exact lease still owns. A consumer that
  -- replaced either slot after attach keeps its replacement untouched.
  release_hooks(hooks)
  local group_deleted = false
  if aug then
    group_deleted = pcall(vim.api.nvim_del_augroup_by_id, aug)
  end
  if not group_deleted and group_name then
    group_deleted = pcall(vim.api.nvim_del_augroup_by_name, group_name)
  end
  -- Normally group deletion owns this cleanup. Exact IDs are the fallback for
  -- a fault-injected group deletion, so no producer survives a partial detach.
  if not group_deleted then
    for _, autocmd_id in ipairs(autocmd_ids or {}) do
      pcall(vim.api.nvim_del_autocmd, autocmd_id)
    end
  end
  if buf and vim.api.nvim_buf_is_valid(buf) then
    for _, id in ipairs(ids) do
      retry_delete_extmark(buf, id)
    end
  end
  close_timer(timer)

  -- Last, so the owner's slot is only cleared once every resource this lease
  -- held has actually been released.
  if release and claimed then
    local ok, err = pcall(release, lease)
    if not ok then
      error(err, 0)
    end
  end
  return true
end

-- Move an ID list out of ordinary bookkeeping before deletion. If any delete
-- call reentrantly replaces the lease, detach still finds the whole list in
-- `deleting` and completes exact cleanup.
local function delete_ids(lease, ids)
  lease.deleting[ids] = true
  local deleted_all = true
  for _, id in ipairs(ids) do
    if not active(lease) then
      return false
    end
    if not try_delete_extmark(lease.state.buf, id) then
      deleted_all = false
    end
    if not active(lease) then
      return false
    end
  end
  if deleted_all then
    lease.deleting[ids] = nil
  end
  return deleted_all
end

local function del_path_marks(lease, path)
  if not active(lease) then
    return false
  end
  local ids = lease.ids_by_path[path]
  if not ids then
    return true
  end
  lease.ids_by_path[path] = nil
  if delete_ids(lease, ids) then
    return true
  end
  if exact(lease) then
    -- Keep the path association as well as the deletion transaction. A retry
    -- must not mistake this section for unapplied and add a duplicate tier.
    lease.ids_by_path[path] = ids
  end
  return false
end

local function del_all_marks(lease)
  if not active(lease) then
    return false
  end
  local paths = {}
  for path in pairs(lease.ids_by_path) do
    paths[#paths + 1] = path
  end
  -- Publish ownership one path at a time. If one deletion fails, that list is
  -- retained in `deleting` and every unprocessed list remains in ids_by_path;
  -- no external failure can strand the tail outside both graphs.
  for _, path in ipairs(paths) do
    if lease.ids_by_path[path] and not del_path_marks(lease, path) then
      return false
    end
  end
  return true
end

local STALE = {}

local function reserve_extmark_id(lease, ids)
  while active(lease) do
    next_extmark_id = next_extmark_id + 1
    local id = next_extmark_id
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id,
      lease.state.buf, TS_NS, id, {})
    if not ok then
      error(pos, 0)
    end
    if not active(lease) then
      error(STALE, 0)
    end
    if #pos == 0 then
      ids[#ids + 1] = id
      return id
    end
  end
  error(STALE, 0)
end

local function rollback_pending(lease, buf, ids)
  -- Always reconcile the reserved globally-unique IDs, even after replacement.
  -- A set_extmark wrapper can attach B *before* performing A's real write:
  -- A's detach sees an absent reserved ID, then the outer call lands it late.
  -- These IDs can never belong to B, so stale post-return deletion is exact.
  local deleted_all = true
  local was_exact = exact(lease)
  for _, id in ipairs(ids) do
    local deleted
    if was_exact then
      deleted = try_delete_extmark(buf, id)
    else
      deleted = retry_delete_extmark(buf, id)
    end
    if not deleted then
      deleted_all = false
    end
  end
  if exact(lease) and deleted_all then
    lease.pending[ids] = nil
  end
end

--- Place one section transactionally. The provisional ID list is published
--- before the first set_extmark call, so errors and reentrant replacement can
--- remove every mark without ever clearing another producer's namespace.
local function apply_section(lease, i, epoch)
  if not active(lease) then
    return false
  end
  local state = lease.state
  local buf = state.buf
  local sec = state.sections[i]
  local srow = (canvas.section_rows(state, i))
  if not active(lease) or lease.epoch ~= epoch or not (sec and srow) then
    return false
  end

  local ts_marks = M.section_ts_marks(sec, lease)
  if not active(lease) or lease.epoch ~= epoch then
    return false
  end

  local ids = {}
  lease.pending[ids] = true
  local ok, err = pcall(function()
    local function place(list)
      for _, mark in ipairs(list) do
        if not active(lease) or lease.epoch ~= epoch then
          error(STALE, 0)
        end
        local id = reserve_extmark_id(lease, ids)
        if not active(lease) or lease.epoch ~= epoch then
          error(STALE, 0)
        end
        vim.api.nvim_buf_set_extmark(buf, TS_NS, srow + mark.row, mark.col, {
          id = id,
          end_row = srow + mark.row,
          end_col = mark.end_col,
          hl_group = mark.group,
          priority = mark.priority,
          strict = false,
        })
        if not active(lease) or lease.epoch ~= epoch then
          error(STALE, 0)
        end
      end
    end
    place(ts_marks)
  end)
  if not ok then
    rollback_pending(lease, buf, ids)
    if err == STALE or not exact(lease) then
      return false
    end
    error(err, 0)
  end
  if not active(lease) or lease.epoch ~= epoch then
    rollback_pending(lease, buf, ids)
    return false
  end
  lease.pending[ids] = nil
  lease.ids_by_path[sec.path] = ids
  return true
end

local function default_windows(state)
  local out = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win)
        and vim.api.nvim_win_get_buf(win) == state.buf then
      out[#out + 1] = win
    end
  end
  return out
end

--- Resolve every currently owned Canvas viewport. Failure, replacement, or
--- an empty result all mean "preserve what is already applied"; eviction
--- without an observed viewport would turn a temporary hidden state into data
--- loss and needless reparsing.
local function viewport_ranges(lease)
  if not active(lease) then
    return nil
  end
  local get_windows = lease.callbacks.windows
  local windows
  if get_windows then
    -- Direct apply/attach is synchronous owner code. A broken owner callback
    -- must remain observable instead of looking like a legitimate hidden
    -- Canvas and silently preserving stale coverage.
    windows = get_windows()
  else
    windows = default_windows(lease.state)
  end
  if not active(lease) or type(windows) ~= "table" then
    return nil
  end

  local ranges, seen = {}, {}
  for _, win in ipairs(windows) do
    if type(win) == "number" and not seen[win] then
      seen[win] = true
      local valid = vim.api.nvim_win_is_valid(win)
      if not active(lease) then
        return nil
      end
      if valid then
        local showing_ok, showing = pcall(vim.api.nvim_win_get_buf, win)
        if not active(lease) then
          return nil
        end
        if showing_ok and showing == lease.state.buf then
          local view_ok, info = pcall(vim.api.nvim_win_call, win, function()
            return {
              top0 = vim.fn.line("w0") - 1,
              bot0 = vim.fn.line("w$") - 1,
            }
          end)
          if not active(lease) then
            return nil
          end
          if view_ok then
            local margin = lease.margin
            ranges[#ranges + 1] = {
              apply_lo = info.top0 - margin,
              apply_hi = info.bot0 + margin,
              retain_lo = info.top0 - 2 * margin,
              retain_hi = info.bot0 + 2 * margin,
            }
          end
        end
      end
    end
  end
  return #ranges > 0 and ranges or nil
end

local function intersects(ranges, srow, erow, lo_key, hi_key)
  for _, range in ipairs(ranges) do
    if srow <= range[hi_key] and erow > range[lo_key] then
      return true
    end
  end
  return false
end

--- Synchronously apply marks for the union of all Canvas viewports±margin and
--- evict only sections outside every viewport's 2x retain margin.
function M.apply_now(lease)
  if not active(lease) then
    return false
  end
  local epoch = lease.epoch
  local ranges = viewport_ranges(lease)
  if not ranges or not active(lease) or lease.epoch ~= epoch then
    return false
  end

  local state = lease.state
  for i, sec in ipairs(state.sections) do
    if not active(lease) or lease.epoch ~= epoch then
      return false
    end
    local srow, erow = canvas.section_rows(state, i)
    if not active(lease) or lease.epoch ~= epoch then
      return false
    end
    -- Nil anchors are a stale state/buffer pairing; preserving is the only
    -- safe action because its recorded IDs may now alias no real section.
    if srow and erow then
      local hidden = fold.hidden(state, sec.path)
      local should_apply = not hidden
        and intersects(ranges, srow, erow, "apply_lo", "apply_hi")
      local should_retain = not hidden
        and intersects(ranges, srow, erow, "retain_lo", "retain_hi")
      local has = lease.ids_by_path[sec.path] ~= nil
      if should_apply and not has then
        apply_section(lease, i, epoch)
      elseif has and not should_retain then
        if not del_path_marks(lease, sec.path) then
          return false
        end
      end
    end
  end
  return active(lease)
end

local function debounce(lease)
  if not active(lease) then
    return
  end
  local timer = lease.timer
  pcall(function()
    timer:stop()
  end)
  if not active(lease) then
    return
  end
  local scheduled = vim.schedule_wrap(function()
    if active(lease) then
      M.apply_now(lease)
    end
  end)
  if not active(lease) then
    return
  end
  pcall(function()
    timer:start(lease.debounce_ms, 0, function()
      if active(lease) then
        scheduled()
      end
    end)
  end)
end

local function defer_apply(lease)
  if not active(lease) then
    return
  end
  vim.schedule(function()
    if active(lease) then
      M.apply_now(lease)
    end
  end)
end

local function install_hooks(lease)
  local state = lease.state
  state.hooks = state.hooks or {}
  local hooks = {
    table = state.hooks,
    prior_render = rawget(state.hooks, "on_render_all"),
    prior_replace = rawget(state.hooks, "on_section_replaced"),
  }

  -- Both wrappers read their predecessor from the record rather than from a
  -- captured upvalue, so an out-of-order teardown can rewire the chain under
  -- a wrapper that is already installed.
  hooks.render_wrapper = function(...)
    if not active(lease) then
      -- Fenced off or already unlinked. Either way the consumer's own hook is
      -- not ours to swallow; detach clears `prior_render` once nothing can
      -- still reach this wrapper.
      local prior = hooks.prior_render
      return prior and prior(...)
    end
    lease.epoch = lease.epoch + 1
    lease.cache = {}
    lease.cache_n = 0
    lease.cache_tick = 0
    del_all_marks(lease)
    local prior = hooks.prior_render
    if prior then
      return prior(...)
    end
  end
  hooks.replace_wrapper = function(path, ...)
    if not active(lease) then
      local prior = hooks.prior_replace
      return prior and prior(path, ...)
    end
    lease.epoch = lease.epoch + 1
    del_path_marks(lease, path)
    if active(lease) then
      M.invalidate(lease, path)
    end
    local prior = hooks.prior_replace
    if prior then
      return prior(path, ...)
    end
  end

  lease.hooks = hooks
  local chain = rawget(hooks.table, HOOK_CHAIN)
  if not chain then
    chain = {}
    rawset(hooks.table, HOOK_CHAIN, chain)
  end
  chain[#chain + 1] = hooks
  rawset(hooks.table, "on_render_all", hooks.render_wrapper)
  rawset(hooks.table, "on_section_replaced", hooks.replace_wrapper)
end

--- Attach one exact highlighter lease. All retained syntax trees, mark IDs,
--- hooks, event sources, and owner callbacks belong to the returned object.
---
--- Attaching never disturbs another lease: two independent reviews highlight
--- concurrently, and only their own owners may dispose them. `claim`, `alive`,
--- and `release` let the owner publish and fence the exact identity before any
--- resource exists.
function M.attach(state, opts, callbacks)
  next_id = next_id + 1
  opts = opts or {}
  local lease = {
    id = next_id,
    group_name = "canvasdiff.syntax." .. next_id,
    claimed = false,
    state = state,
    opts = opts,
    callbacks = callbacks or {},
    margin = opts.margin or 100,
    debounce_ms = opts.debounce_ms or 30,
    ids_by_path = {},
    pending = {},
    deleting = {},
    cache = {},
    cache_n = 0,
    cache_tick = 0,
    epoch = 0,
    timer = nil,
    aug = nil,
    autocmd_ids = {},
    hooks = nil,
    disposed = false,
  }
  local group_name = lease.group_name
  -- Publish identity before the first external call. A reentrant callback can
  -- now tear down only this exact partial lease; it can never select which of
  -- several live highlighters counts as current.
  LEASE_AUTH[lease] = true

  local claim = lease.callbacks.claim
  if claim then
    -- A throwing claim may already have published the lease. Mark it claimed
    -- before entering owner code so exact teardown can safely ask release to
    -- unlink only this identity.
    lease.claimed = true
    local ok, claimed = pcall(claim, lease)
    if not ok then
      pcall(M.detach, lease)
      error(claimed, 0)
    end
    if not claimed then
      lease.claimed = false
      M.detach(lease)
      return nil
    end
  else
    lease.claimed = true
  end

  local ok, err = pcall(function()
    if not active(lease) then
      error("highlighter owner is no longer alive", 0)
    end
    if not (state and state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
      error("highlighter requires a valid canvas state", 0)
    end
    if not active(lease) then
      error("highlighter attach was disposed while validating state", 0)
    end

    local timer = vim.uv.new_timer()
    if not timer then
      error("failed to allocate highlighter timer", 0)
    end
    if not exact(lease) then
      -- The allocating wrapper may have disposed this lease before returning
      -- the handle, which teardown therefore never saw.
      close_timer(timer)
      error("highlighter attach was disposed while allocating timer", 0)
    end
    lease.timer = timer
    if not active(lease) then
      error("highlighter attach was disposed while allocating timer", 0)
    end

    install_hooks(lease)
    if not active(lease) then
      error("highlighter attach was disposed while installing hooks", 0)
    end

    local aug = vim.api.nvim_create_augroup(group_name, { clear = true })
    if not exact(lease) then
      -- Per-lease names make this cleanup incapable of touching a peer's
      -- group even when the wrapper created this one after teardown ran.
      pcall(vim.api.nvim_del_augroup_by_name, group_name)
      error("highlighter attach was disposed while creating autocmds", 0)
    end
    lease.aug = aug
    if not active(lease) then
      error("highlighter attach was disposed while creating autocmds", 0)
    end

    local function create_autocmd(events, spec)
      -- Refer to the unique NAME, not its numeric ID. If an outer stale call
      -- resumes after this lease's group was deleted and Neovim recycled the
      -- number, the call fails against an absent name instead of silently
      -- joining a peer's group.
      spec.group = group_name
      local autocmd_id = vim.api.nvim_create_autocmd(events, spec)
      if not exact(lease) then
        local group_deleted = pcall(vim.api.nvim_del_augroup_by_name, group_name)
        if not group_deleted then
          pcall(vim.api.nvim_del_autocmd, autocmd_id)
        end
        error("highlighter attach was disposed while creating autocmds", 0)
      end
      lease.autocmd_ids[#lease.autocmd_ids + 1] = autocmd_id
      if not active(lease) then
        error("highlighter attach was disposed while creating autocmds", 0)
      end
    end

    create_autocmd("WinScrolled", {
      callback = function(ev)
        if not active(lease) then
          return
        end
        local win = tonumber(ev.match)
        if not win or not vim.api.nvim_win_is_valid(win) then
          return
        end
        if not active(lease) then
          return
        end
        local showing_ok, showing = pcall(vim.api.nvim_win_get_buf, win)
        if active(lease) and showing_ok and showing == lease.state.buf then
          debounce(lease)
        end
      end,
    })
    create_autocmd("BufWinEnter", {
      buffer = state.buf,
      callback = function()
        -- Surface's adoption callback may run later in this same event. Defer
        -- the windows() query so a newly adopted baseline window participates.
        defer_apply(lease)
      end,
    })
    create_autocmd("BufWinLeave", {
      buffer = state.buf,
      callback = function()
        defer_apply(lease)
      end,
    })
    create_autocmd({ "WinLeave", "WinClosed" }, {
      callback = function()
        defer_apply(lease)
      end,
    })
    create_autocmd("WinResized", {
      callback = function()
        debounce(lease)
      end,
    })

    M.apply_now(lease)
    if not active(lease) then
      error("highlighter attach was disposed during initial apply", 0)
    end
  end)
  if not ok then
    pcall(M.detach, lease)
    error(err, 0)
  end
  return lease
end

return M
