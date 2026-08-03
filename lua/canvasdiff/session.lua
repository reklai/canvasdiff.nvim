local codec = require("canvasdiff.session.codec")

-- Session persistence enters through this exact facade. Payload shape,
-- serialization, storage, and semantic viewport restoration stay owned by the
-- internal codec.
local M = {}
local epochs = {}
local invalidated = {}

local function epoch(root)
  return epochs[root] or 0
end

-- Stamp `state` with its root's current epoch so a later save can prove it
-- postdates any invalidation. Returns `state` unchanged otherwise; a state
-- without a root passes through untouched. Never errors.
function M.activate(state)
  if state and state.root then
    state.session_epoch = epoch(state.root)
  end
  return state
end

-- Refuse this root's persisted session until a state activated AFTER this
-- call saves again: loads answer nil and stale-epoch saves answer false.
-- Returns false for a non-string or empty root, true otherwise.
function M.invalidate(root)
  if type(root) ~= "string" or root == "" then
    return false
  end
  epochs[root] = epoch(root) + 1
  invalidated[root] = true
  return true
end

-- A root's saved payload, or nil: none on disk, undecodable, an incompatible
-- version, or the root was invalidated this process. Never errors.
function M.load(root)
  if invalidated[root] then
    return nil
  end
  return codec.load(root)
end

-- Persist `state` unless it predates an invalidation of its root (stale or
-- absent epoch), which answers a bare false. Otherwise defers to the codec:
-- `true` on success (clearing the invalidation), `false, err` on failure --
-- entirely guarded, so saving can never break closing the canvas.
function M.save(state)
  if not (state and state.root) then
    return codec.save(state)
  end
  local current = epoch(state.root)
  if state.session_epoch ~= nil and state.session_epoch ~= current then
    return false
  end
  if invalidated[state.root] and state.session_epoch == nil then
    return false
  end
  local saved, err = codec.save(state)
  if saved then
    invalidated[state.root] = nil
  end
  return saved, err
end

-- Snapshot the live canvas view/cursor onto state.session_snapshot. The
-- second return says whether a live view was observed: (nil, false) leaves
-- the last good snapshot alone, while an observed placeholder answers
-- (nil, true) and deliberately clears it.
M.capture = codec.capture
-- Where a root's session file lives on disk. Pure.
M.path_for = codec.path_for
-- Reapply a loaded payload onto a fresh state (folds, collapses, view). Each
-- sub-step is independently guarded, so one failure never blocks the rest;
-- no return value.
M.restore = codec.restore

return M
