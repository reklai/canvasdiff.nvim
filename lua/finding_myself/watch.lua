local canvas = require("finding_myself.canvas")
local model = require("finding_myself.model")
local collect = require("finding_myself.collect")
local config = require("finding_myself.config")
local hl = require("finding_myself.hl")

local W = {}

--- Assignable callback: fired by reconcile when the canvas becomes empty
--- (all changes gone), so the owner can render its empty-state message.
W.on_empty = nil

--- Synchronous full reconcile of the live canvas against the working tree:
--- collect desired sections, then splice the difference section-by-section.
--- Sections whose old_text AND new_text are unchanged are never touched, so
--- their anchors, highlight marks, and rows stay exactly as they are -- the
--- niri invariant then rests entirely on the canvas splice primitives.
function W.reconcile(state)
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end
  local desired = model.build(collect.files(state.root), config.options.context)

  -- 0 <-> N transitions: the empty canvas holds a placeholder line, not
  -- sections; splicing against it is meaningless. Full re-render instead.
  if #state.sections == 0 or #desired == 0 then
    if #state.sections ~= 0 or #desired ~= 0 then
      canvas.render_all(state, desired)
      if #desired == 0 and W.on_empty then
        W.on_empty()
      end
      hl.apply_now(state)
    end
    return
  end

  -- Both lists are sorted by path: sorted merge-walk.
  local i, j = 1, 1
  while i <= #state.sections or j <= #desired do
    local cur = state.sections[i]
    local des = desired[j]
    if cur and des and cur.path == des.path then
      if cur.old_text ~= des.old_text or cur.new_text ~= des.new_text then
        canvas.replace_section(state, i, des)
      end
      i, j = i + 1, j + 1
    elseif cur and (not des or cur.path < des.path) then
      if #state.sections == 1 then
        -- Deleting the last remaining section would leave the
        -- placeholder-line empty canvas, which splices can't target;
        -- finish with a full render of whatever is desired instead.
        canvas.render_all(state, desired)
        hl.apply_now(state)
        return
      end
      canvas.replace_section(state, i, nil) -- delete shrinks the list; keep i
    else
      canvas.insert_section(state, i, des)
      i, j = i + 1, j + 1
    end
  end

  hl.apply_now(state)
end

return W
