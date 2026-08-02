# Markdown Test Decoupling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every repository Markdown file freely editable without affecting test outcomes while preserving contract checks for Neovim help and executable interfaces.

**Architecture:** Remove Markdown parsing from architecture tests rather than replacing it with another prose contract. Keep checks at their authoritative source: public commands and highlights against `doc/canvasdiff.txt`, Make targets against `Makefile`, chaos arguments against the worker, and dependency policy against `rules.lua`/source analysis.

**Tech Stack:** Lua, Neovim 0.12 headless tests, Make, ripgrep, Git.

## Global Constraints

- Do not modify, stage, or commit the pre-existing `README.md` or `media/` work.
- No test may open, parse, or gate on a repository Markdown document.
- `doc/canvasdiff.txt` remains contract-tested for every public command, highlight group, and highlight precedence statement.
- `.md` strings used as ordinary model filenames remain valid fixture data.
- No production API or runtime behavior changes.

---

### Task 1: Make the documentation contract help-only

**Files:**
- Create: `test/architecture/test_help.lua`
- Delete: `test/architecture/test_documentation.lua`

**Interfaces:**
- Consumes: `canvasdiff.appearance.names()`, `canvasdiff.input.command.candidate_order`, and `doc/canvasdiff.txt`.
- Produces: architecture tests that validate Neovim help without reading `README.md` or any `docs/*.md` file.

- [ ] **Step 1: Record the coupling that must disappear**

Run:

```bash
rg -n 'README\.md|docs/.*\.md' test/architecture/test_documentation.lua
```

Expected: matches for `README.md` and `docs/architecture.md`, proving the current test directly depends on Markdown.

- [ ] **Step 2: Replace the mixed documentation test with a help-only test**

Create `test/architecture/test_help.lua` with this complete content and delete `test/architecture/test_documentation.lua`:

```lua
local appearance = require("canvasdiff.appearance")
local command = require("canvasdiff.input").command
local graph = require("architecture.graph")
local T = {}
local HIGHLIGHT_PRECEDENCE =
  "CanvasDiff defaults -> colorscheme/direct definition -> setup().highlights"

local function read_help()
  local file = assert(io.open(vim.fs.joinpath(graph.root, "doc/canvasdiff.txt"), "rb"))
  local text = file:read("*a")
  file:close()
  return text
end

T.architecture_help_names_every_public_highlight = function()
  local help = read_help()
  for _, name in ipairs(appearance.names()) do
    assert(help:find(name, 1, true), "Vim help omits " .. name)
  end
end

T.architecture_help_names_every_public_command = function()
  local help = read_help()
  for _, word in ipairs(command.candidate_order) do
    local invocation = ":CanvasDiff " .. word
    assert(help:find(invocation, 1, true), "Vim help omits " .. invocation)
  end
end

T.architecture_help_states_highlight_ownership_low_to_high = function()
  local help = read_help()
  assert(help:find(HIGHLIGHT_PRECEDENCE, 1, true),
    "Vim help reverses highlight ownership precedence")
end

return T
```

- [ ] **Step 3: Run the help contract**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-help.log \
  make test SUITE=architecture FILTER='^architecture_help_'
```

Expected: 3/3 tests pass.

- [ ] **Step 4: Commit only the help contract files**

```bash
git add test/architecture/test_help.lua test/architecture/test_documentation.lua
git commit -m "test: keep documentation contracts in Vim help"
```

---

### Task 2: Remove Markdown from architecture layout contracts

**Files:**
- Modify: `test/architecture/test_layout.lua`

**Interfaces:**
- Consumes: `Makefile`, `benchmark/chaos/worker.lua`, architecture source/rule helpers, and the repository file list.
- Produces: direct executable-interface checks and an identity scan that completely skips files whose lowercased path ends in `.md`.

- [ ] **Step 1: Replace the contributor-document test with direct interface tests**

Remove both reads of `docs/architecture.md`, all assertions over its prose/table, and the `rules.allowed_edges` documentation comparison. Keep the existing `read()` helper and add these tests:

```lua
T.architecture_layout_exposes_required_make_targets = function()
  local makefile = read("Makefile")
  for _, target in ipairs({
    "unit", "integration", "e2e", "fault", "architecture", "test",
    "verify", "bench-chaos",
  }) do
    local declared = makefile:find("\n" .. target .. ":", 1, true)
      or makefile:sub(1, #target + 1) == target .. ":"
    assert(declared, "required Make target does not exist: " .. target)
  end
end

T.architecture_layout_chaos_worker_argument_order_is_stable = function()
  local worker = read("benchmark/chaos/worker.lua")
  for _, argument in ipairs({
    { "output_path", 1 },
    { "seed", 2 },
    { "actions", 3 },
    { "harness", 4 },
  }) do
    local declaration = worker:match(
      "local%s+" .. argument[1] .. "%s*=[^\n]+")
    assert(declaration and declaration:find(
      "_G.arg[" .. argument[2] .. "]", 1, true),
      ("chaos worker no longer reads %s from argument %d")
        :format(argument[1], argument[2]))
  end
end
```

- [ ] **Step 2: Exclude Markdown completely from the retired-identity scan**

Delete the one-file `historical_record` exception. Inside the repository-file loop, compute the lowercased path first and execute every retired-name, case-collision, and content check only when it is not Markdown:

```lua
local folded_path = relative:lower()
if not folded_path:match("%.md$") then
  if folded_path:find(retired, 1, true) then
    errors[#errors + 1] = "retired identity remains in path: " .. relative
  end
  if casefolded_paths[folded_path]
      and casefolded_paths[folded_path] ~= relative then
    errors[#errors + 1] = (
      "case-folded path collision: %s and %s"
    ):format(casefolded_paths[folded_path], relative)
  end
  casefolded_paths[folded_path] = relative

  local file, open_err = io.open(absolute, "rb")
  assert(file, ("%s: %s"):format(relative, open_err or "could not open"))
  local content = file:read("*a")
  file:close()
  if content:lower():find(retired, 1, true) then
    errors[#errors + 1] = "retired identity remains in content: " .. relative
  end
end
```

- [ ] **Step 3: Run the focused layout tests**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-layout.log \
  make test SUITE=architecture FILTER='^architecture_layout_'
NVIM_LOG_FILE=/tmp/canvasdiff-identity.log \
  make test SUITE=architecture FILTER='^architecture_identity_'
```

Expected: every selected layout and identity test passes.

- [ ] **Step 4: Commit the architecture decoupling**

```bash
git add test/architecture/test_layout.lua
git commit -m "test: decouple architecture checks from Markdown"
```

---

### Task 3: Remove misleading README-labelled test names and verify the boundary

**Files:**
- Modify: `test/integration/test_root.lua`

**Interfaces:**
- Consumes: the existing root setup and appearance APIs.
- Produces: behavior-focused integration names with no implied README ownership.

- [ ] **Step 1: Rename the helper and two tests without changing behavior**

Apply these exact renames in `test/integration/test_root.lua`:

```lua
-- before
local function with_readme_highlights(fn)
T["README LazyVim opts apply through the root setup"] = function()
T["README setup cleanup runs after a failed assertion"] = function()

-- after
local function with_root_highlights(fn)
T["root_ highlight opts apply through setup"] = function()
T["root_ highlight setup cleanup runs after a failed assertion"] = function()
```

Update both calls and assertion/error strings from “README” to “highlight
override”; do not change setup, cleanup, or highlight expectations.

- [ ] **Step 2: Run the renamed integration tests**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-root-highlights.log \
  make test SUITE=integration FILTER='^root_ highlight'
```

Expected: 2/2 tests pass.

- [ ] **Step 3: Verify no repository Markdown is opened or parsed by tests**

Run:

```bash
! rg -n -i 'README\.md|docs/[^" ]*\.md|readme' \
  test/architecture test/integration/test_root.lua
```

Expected: exit 0 with no matches. References such as `root.md` and
`README.md` used purely as model path strings are allowed.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
NVIM_LOG_FILE=/tmp/canvasdiff-architecture.log make architecture
NVIM_LOG_FILE=/tmp/canvasdiff-integration.log make integration
NVIM_LOG_FILE=/tmp/canvasdiff-test.log make test
git diff --check
```

Expected: all three test commands pass and `git diff --check` emits no output.

- [ ] **Step 5: Confirm user-owned files remain outside the task diff**

Run:

```bash
git status --short
git diff -- test/architecture/test_help.lua \
  test/architecture/test_documentation.lua \
  test/architecture/test_layout.lua test/integration/test_root.lua
```

Expected: this task's diff contains only the four named test paths;
pre-existing README/media changes may still appear in status but are neither
staged nor included in task commits.

- [ ] **Step 6: Commit the naming cleanup**

```bash
git add test/integration/test_root.lua
git commit -m "test: name setup coverage by behavior"
```
