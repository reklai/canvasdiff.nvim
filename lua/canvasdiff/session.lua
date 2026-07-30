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

function M.activate(state)
  if state and state.root then
    state.session_epoch = epoch(state.root)
  end
  return state
end

function M.invalidate(root)
  if type(root) ~= "string" or root == "" then
    return false
  end
  epochs[root] = epoch(root) + 1
  invalidated[root] = true
  return true
end

function M.load(root)
  if invalidated[root] then
    return nil
  end
  return codec.load(root)
end

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

M.capture = codec.capture
M.path_for = codec.path_for
M.restore = codec.restore

return M
