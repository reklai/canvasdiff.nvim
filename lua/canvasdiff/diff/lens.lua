--- What the canvas is currently comparing -- the one dimension of control.
---
--- A lens is a pair of sides:
---   old  any git rev: "HEAD", ":0" (the staged blob), a branch, a sha
---   new  "worktree" (the files as they are now, unsaved buffers included) or
---        "index" (what you have staged)
---
--- The new side is what decides whether the canvas is a workspace or a viewer.
--- `new = "worktree"` means every section maps onto a file you can open and edit,
--- so <CR>/<M-CR> work and the canvas is somewhere you get things done.
--- `new = "index"` cannot be edited as text -- but it is still ACTIONABLE, since
--- unstaging moves that content back into the worktree. That is the line: a lens
--- whose new side is neither of those (commit vs commit) would make the canvas a
--- read-only diff viewer, which is a thing the world already has plenty of.
---
--- Pure, and requires nothing, so it unit-tests standalone and every module can
--- read a lens without a dependency cycle -- the same discipline as diff.fold.
local L = {}

--- The staged blob of a path, in git's rev syntax.
L.INDEX_REV = ":0"

--- @class CanvasDiffLens
--- @field id string     stable key for per-lens bookkeeping and the session
--- @field old string    git rev for the old side
--- @field new string    "worktree" | "index" | a committed range's right ref
--- @field label string  human text for the on-screen indicator
--- @field operator string? ".." | "..." for a committed range

--- The three fixed lenses. `branch` is built per-ref by L.branch.
---
--- Labels read "new vs old" because that is the direction a diff is read in, and
--- they name the git concept rather than our own vocabulary -- someone who knows
--- `git diff` should recognise which one they are looking at immediately.
L.named = {
  all = {
    id = "all", old = "HEAD", new = "worktree",
    label = "worktree vs HEAD",
  },
  unstaged = {
    id = "unstaged", old = L.INDEX_REV, new = "worktree",
    label = "worktree vs index (unstaged)",
  },
  staged = {
    id = "staged", old = "HEAD", new = L.INDEX_REV,
    label = "index vs HEAD (staged)",
  },
}

--- Order the UI offers them in: everything, then the two halves it splits into.
L.order = { "all", "unstaged", "staged" }

local function range_shape(l)
  return type(l) == "table"
    and type(l.old) == "string" and l.old ~= ""
    and type(l.new) == "string" and l.new ~= ""
    and (l.operator == ".." or l.operator == "...")
    and l.id == "range:" .. l.old .. l.operator .. l.new
end

local function named_shape(l)
  if type(l) ~= "table" or l.operator ~= nil then
    return false
  end
  local named = L.named[l.id]
  return named ~= nil and l.old == named.old and l.new == named.new
end

local function branch_shape(l)
  return type(l) == "table"
    and l.operator == nil
    and type(l.old) == "string" and l.old ~= ""
    and l.new == "worktree"
    and l.id == "branch:" .. l.old
end

--- A read-only comparison between two committed refs.
---
--- Two-dot compares the tips directly. Three-dot resolves the left side to the
--- merge base during source collection, while keeping the requested refs here
--- so the lens remains stable and serializable.
function L.range(left, right, operator)
  if type(left) ~= "string" or left == ""
      or type(right) ~= "string" or right == ""
      or (operator ~= ".." and operator ~= "...") then
    return nil
  end
  local label
  if operator == "..." then
    label = right .. " vs merge-base(" .. left .. ")"
  else
    label = right .. " vs " .. left
  end
  return {
    id = "range:" .. left .. operator .. right,
    old = left,
    new = right,
    operator = operator,
    label = label,
  }
end

--- True when `l` is an intact committed-range lens.
function L.is_range(l)
  return range_shape(l)
end

--- A lens comparing the worktree against an arbitrary ref.
---
--- New side stays the worktree deliberately, so "how do I differ from main" is
--- still a place you can work rather than something you can only look at.
function L.branch(ref)
  if type(ref) ~= "string" or ref == "" then
    return nil
  end
  return {
    id = "branch:" .. ref,
    old = ref,
    new = "worktree",
    label = "worktree vs " .. ref,
  }
end

--- True when `l` is one of the arbitrary-ref lenses built by L.branch.
---
--- `new == "worktree"` alone is not enough: both fixed editable lenses have
--- that same new side. The id is the stable discriminator carried through the
--- session payload, and requiring it to agree with `old` rejects a malformed
--- hand-built record rather than routing it through the ref-specific collector.
function L.is_branch(l)
  return branch_shape(l)
end

--- A named lens by name, or nil. Returns a COPY: lenses end up on `state`, and a
--- caller that mutated one would corrupt the table for every later open.
function L.get(name)
  local l = L.named[name]
  if not l then
    return nil
  end
  return { id = l.id, old = l.old, new = l.new, label = l.label }
end

--- True when this lens's sections map onto files the user can actually edit.
--- `jump.enter` gates on this.
function L.editable(lens)
  return L.valid(lens) and not range_shape(lens) and lens.new == "worktree"
end

--- The legacy `base` string ("HEAD" | "index") as a lens.
---
--- `config.options.base` and every previously-saved session speak this older
--- two-value vocabulary, which only ever described the OLD side. Keeping the
--- translation in one place means neither of them has to learn about lenses.
function L.from_base(base)
  if base == "index" then
    return L.get("unstaged")
  end
  return L.get("all")
end

--- The legacy `base` string for a lens, or nil when it has no equivalent.
---
--- Only the two worktree-vs-something lenses map back; `staged` and `branch` are
--- inexpressible in the old vocabulary, which is why the session persists the lens
--- itself and treats `base` as a courtesy for older readers.
function L.to_base(lens)
  if not lens then
    return nil
  end
  if lens.id == "unstaged" then
    return "index"
  end
  if lens.id == "all" then
    return "HEAD"
  end
  return nil
end

--- Is this a lens we are willing to act on? Guards a restored session payload,
--- which is on disk and hand-editable, from putting a nonsense new side on `state`
--- where every reader would then trust it.
function L.valid(l)
  return range_shape(l) or branch_shape(l) or named_shape(l)
end

--- The lens a state is looking through.
---
--- Falls back to translating the older `state.base` string, so a state built before
--- lenses existed -- or by a test that only sets `base` -- still reads correctly
--- everywhere instead of needing every call site to know about the transition.
function L.of(state)
  if state and L.valid(state.lens) then
    return state.lens
  end
  return L.from_base(state and state.base)
end

--- The next named lens, cycling. `delta` of 1 goes all -> unstaged -> staged -> all.
--- A branch lens is not in the cycle, so stepping from one enters it at `all`.
function L.step(l, delta)
  local at
  for i, name in ipairs(L.order) do
    if l and L.same(L.named[name], l) then
      at = i
      break
    end
  end
  if not at then
    return L.get(L.order[1])
  end
  local n = #L.order
  return L.get(L.order[((at - 1 + (delta or 1)) % n) + 1])
end

--- Same comparison? Compared on the sides rather than the id, so a hand-built
--- lens equal to a named one counts as the same.
function L.same(a, b)
  if a == nil or b == nil then
    return a == b
  end
  local a_range = range_shape(a)
  local b_range = range_shape(b)
  if a_range or b_range then
    return a_range and b_range
      and a.old == b.old and a.new == b.new and a.operator == b.operator
  end
  return a.old == b.old and a.new == b.new
end

return L
