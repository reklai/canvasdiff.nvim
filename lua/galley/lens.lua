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
--- read a lens without a dependency cycle -- same discipline as fold.lua.
local L = {}

--- The staged blob of a path, in git's rev syntax.
L.INDEX_REV = ":0"

--- @class GalleyLens
--- @field id string     stable key for per-lens bookkeeping and the session
--- @field old string    git rev for the old side
--- @field new string    "worktree" | "index"
--- @field label string  human text for the on-screen indicator

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
  return lens ~= nil and lens.new == "worktree"
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
  return type(l) == "table"
    and type(l.old) == "string" and l.old ~= ""
    and (l.new == "worktree" or l.new == L.INDEX_REV)
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
  return a.old == b.old and a.new == b.new
end

return L
