local H = require("helpers")
local fixture = require("benchmark.live_scale.fixture")

local T = {}

local function git(root, ...)
  local command = { "git", ... }
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0,
    table.concat(command, " ") .. " failed: " .. (result.stderr or ""))
  return (result.stdout or ""):gsub("%s+$", "")
end

local function remove_test_root(root)
  local prefix = vim.fs.joinpath(vim.uv.os_tmpdir(), "canvasdiff_test_")
  assert(root:sub(1, #prefix) == prefix,
    "refusing to remove a path outside the test-owned prefix: " .. root)
  assert(vim.fn.delete(root, "rf") == 0, "could not remove test root: " .. root)
end

local function read_bytes(path)
  local file = assert(io.open(path, "rb"))
  local content = assert(file:read("*a"))
  assert(file:close())
  return content
end

local function write_bytes(path, content)
  local file = assert(io.open(path, "wb"))
  assert(file:write(content))
  assert(file:close())
end

local function with_environment(values, body)
  local previous = {}
  for name, value in pairs(values) do
    previous[name] = vim.env[name]
    vim.env[name] = value
  end
  local ok, first, second = pcall(body)
  for name in pairs(values) do
    vim.env[name] = previous[name]
  end
  if not ok then
    error(first, 0)
  end
  return first, second
end

local function build(rows, seed)
  local root = H.tmpdir()
  local manifest, err = fixture.build(root, rows, seed)
  assert(manifest, err)
  return root, manifest
end

T["live_scale_fixture_build creates an exact one-row real Git repository"] = function()
  local root, manifest = build(1, 1729)

  H.eq(manifest, {
    schema = "canvasdiff.live_scale.fixture/v1",
    root = root,
    seed = 1729,
    rows = 1,
    primary_path = "primary.txt",
    first_line = "scale 1 seed 1729",
    last_line = "scale 1 seed 1729",
    digest = vim.fn.sha256("scale 1 seed 1729\n"),
    base_ref = "scale-base",
    branch_ref = "scale-branch",
    range_ref = "scale-base..scale-range",
    sidecars = {
      staged = "staged.txt",
      unstaged = "unstaged.txt",
      untracked = "untracked.txt",
      deleted = "deleted.txt",
      rename_from = "rename_from.txt",
      rename_to = "rename_to.txt",
    },
  })
  H.eq(git(root, "diff", "--numstat", "--", "primary.txt"), "1\t0\tprimary.txt")
  H.eq(git(root, "diff", "--check"), "")
  H.eq(git(root, "branch", "--show-current"), "main")

  local status = git(root, "status", "--short")
  assert(status:find(" M primary.txt", 1, true), "missing primary unstaged status")
  assert(status:find("M  staged.txt", 1, true), "missing staged status")
  assert(status:find(" M unstaged.txt", 1, true), "missing unstaged status")
  assert(status:find(" D deleted.txt", 1, true), "missing delete status")
  assert(status:find("R  rename_from.txt -> rename_to.txt", 1, true),
    "missing rename status")
  assert(status:find("?? untracked.txt", 1, true), "missing untracked status")

  for _, ref in ipairs({ "scale-base", "scale-branch", "scale-range" }) do
    assert(git(root, "rev-parse", "--verify", ref .. "^{commit}"):match("^[0-9a-f]+$"),
      ref .. " must resolve to a commit")
  end
  assert(git(root, "rev-list", "--count", manifest.range_ref) == "1",
    "range ref must select one deterministic commit")

  local comparison = table.concat({
    "A\tbranch_added.txt",
    "D\tbranch_deleted.txt",
    "M\tbranch_modified.txt",
    "R100\tbranch_rename_from.txt\tbranch_rename_to.txt",
  }, "\n")
  H.eq(git(root, "diff", "--name-status", "--find-renames",
    manifest.base_ref, manifest.branch_ref), comparison)
  H.eq(git(root, "diff", "--name-status", "--find-renames",
    manifest.range_ref), comparison)

  local cleaned, cleanup_err = fixture.cleanup(root)
  assert(cleaned, cleanup_err)
  H.eq(vim.uv.fs_stat(root), nil, "cleanup must remove the exact fixture root")
end

T["live_scale_fixture_build streams an exact thousand-row primary diff"] = function()
  local root, manifest = build(1000, -7)

  H.eq(manifest.first_line, "scale 1 seed -7")
  H.eq(manifest.last_line, "scale 1000 seed -7")
  H.eq(manifest.rows, 1000)
  H.eq(git(root, "diff", "--numstat", "--", "primary.txt"),
    "1000\t0\tprimary.txt")
  H.eq(git(root, "diff", "--check"), "")
  local lines = vim.fn.readfile(vim.fs.joinpath(root, manifest.primary_path))
  H.eq(#lines, 1000)
  H.eq(lines[1], "scale 1 seed -7")
  H.eq(lines[500], "scale 500 seed -7")
  H.eq(lines[1000], "scale 1000 seed -7")

  local cleaned, cleanup_err = fixture.cleanup(root)
  assert(cleaned, cleanup_err)
end

T["live_scale_fixture_build rejects invalid rows and nonempty targets"] = function()
  for _, rows in ipairs({ 0, -1, 1.5 }) do
    local root = H.tmpdir()
    local manifest, err = fixture.build(root, rows, 1)
    H.eq(manifest, nil)
    assert(type(err) == "string" and err:find("positive integer", 1, true),
      "invalid rows must report the positive-integer contract")
    H.eq(vim.uv.fs_stat(vim.fs.joinpath(root, ".git")), nil)
    remove_test_root(root)
  end

  local root = H.tmpdir()
  local sentinel = vim.fs.joinpath(root, "keep.txt")
  assert(vim.fn.writefile({ "keep" }, sentinel) == 0)
  local manifest, err = fixture.build(root, 1, 1)
  H.eq(manifest, nil)
  assert(type(err) == "string" and err:find("empty", 1, true),
    "nonempty root must be rejected")
  H.eq(vim.fn.readfile(sentinel), { "keep" })
  remove_test_root(root)
end

T["live_scale_fixture_build isolates Git environment config index and hooks"] = function()
  local external = H.tmpdir()
  local fixture_root = H.tmpdir()
  local hooks = H.tmpdir()
  local template = H.tmpdir()
  local hook_sentinel = vim.fs.joinpath(hooks, "hook-ran")
  local external_sentinel = vim.fs.joinpath(external, "external.txt")
  local external_index = vim.fs.joinpath(external, ".git", "index")
  local poison_index = vim.fs.joinpath(external, "poison.index")
  local poison_config = vim.fs.joinpath(external, "poison.gitconfig")

  git(external, "init", "-q", "-b", "main")
  git(external, "config", "user.email", "external@example.invalid")
  git(external, "config", "user.name", "External Sentinel")
  write_bytes(external_sentinel, "external sentinel\n")
  git(external, "add", "--", "external.txt")
  git(external, "commit", "-q", "-m", "external sentinel")
  local external_head = git(external, "rev-parse", "HEAD")
  assert(vim.uv.fs_copyfile(external_index, poison_index))
  local original_index = read_bytes(external_index)
  local original_poison_index = read_bytes(poison_index)

  local external_hook = vim.fs.joinpath(hooks, "pre-commit")
  write_bytes(external_hook,
    "#!/bin/sh\nprintf poisoned > " .. hook_sentinel .. "\n")
  assert(vim.uv.fs_chmod(external_hook, 493))
  local template_hooks = vim.fs.joinpath(template, "hooks")
  assert(vim.fn.mkdir(template_hooks, "p") == 1)
  local template_hook = vim.fs.joinpath(template_hooks, "pre-commit")
  write_bytes(template_hook,
    "#!/bin/sh\nprintf poisoned > " .. hook_sentinel .. "\n")
  assert(vim.uv.fs_chmod(template_hook, 493))
  write_bytes(poison_config, table.concat({
    "[core]",
    "\thooksPath = " .. hooks,
    "[init]",
    "\ttemplateDir = " .. template,
    "",
  }, "\n"))

  local ok, failure = pcall(function()
    local manifest, err = with_environment({
      GIT_ALTERNATE_OBJECT_DIRECTORIES =
        vim.fs.joinpath(external, ".git", "objects"),
      GIT_CONFIG_GLOBAL = poison_config,
      GIT_DIR = vim.fs.joinpath(external, ".git"),
      GIT_INDEX_FILE = poison_index,
      GIT_OBJECT_DIRECTORY = vim.fs.joinpath(external, ".git", "objects"),
      GIT_WORK_TREE = external,
    }, function()
      return fixture.build(fixture_root, 1, 99)
    end)
    assert(manifest, err)

    H.eq(git(external, "rev-parse", "HEAD"), external_head)
    H.eq(read_bytes(external_sentinel), "external sentinel\n")
    H.eq(read_bytes(external_index), original_index)
    H.eq(read_bytes(poison_index), original_poison_index)
    H.eq(vim.uv.fs_stat(hook_sentinel), nil,
      "ambient hooks must not execute")
    H.eq(vim.uv.fs_stat(vim.fs.joinpath(
      fixture_root, ".git", "hooks", "pre-commit")), nil,
      "ambient templates must not populate the fixture")
  end)

  if vim.uv.fs_stat(fixture_root) then
    local cleaned = fixture.cleanup(fixture_root)
    if not cleaned then
      remove_test_root(fixture_root)
    end
  end
  remove_test_root(external)
  remove_test_root(hooks)
  remove_test_root(template)
  if not ok then
    error(failure, 0)
  end
end

T["live_scale_fixture_cleanup rejects unowned and non-root targets"] = function()
  local unowned = H.tmpdir()
  local sentinel = vim.fs.joinpath(unowned, "keep.txt")
  assert(vim.fn.writefile({ "keep" }, sentinel) == 0)

  local cleaned, err = fixture.cleanup(unowned)
  H.eq(cleaned, nil)
  assert(type(err) == "string")
  H.eq(vim.fn.readfile(sentinel), { "keep" },
    "cleanup must preserve an unowned target")
  remove_test_root(unowned)

  local root = build(1, 3)
  local nested = vim.fs.joinpath(root, "nested")
  assert(vim.fn.mkdir(nested) == 1)
  local marker = ".canvasdiff-live-scale-fixture"
  assert(vim.uv.fs_copyfile(
    vim.fs.joinpath(root, marker),
    vim.fs.joinpath(nested, marker)))
  local nested_sentinel = vim.fs.joinpath(nested, "keep.txt")
  assert(vim.fn.writefile({ "keep" }, nested_sentinel) == 0)

  cleaned, err = fixture.cleanup(nested)
  H.eq(cleaned, nil)
  assert(type(err) == "string")
  H.eq(vim.fn.readfile(nested_sentinel), { "keep" },
    "a copied marker must not authorize nested-root removal")

  local cleaned_root, cleanup_err = fixture.cleanup(root)
  assert(cleaned_root, cleanup_err)
end

T["live_scale_fixture_cleanup rejects a forged marker in a real repository"] = function()
  local root = H.tmpdir()
  git(root, "init", "-q", "-b", "main")
  local sentinel = vim.fs.joinpath(root, "keep.txt")
  write_bytes(sentinel, "keep\n")
  write_bytes(vim.fs.joinpath(root, ".canvasdiff-live-scale-fixture"),
    "canvasdiff.live_scale.fixture/v1\nroot=" .. root
      .. "\ntoken=forged-public-token\n")

  local cleaned, err = fixture.cleanup(root)
  H.eq(cleaned, nil)
  assert(type(err) == "string")
  H.eq(read_bytes(sentinel), "keep\n",
    "public marker bytes must not authorize recursive removal")
  remove_test_root(root)
end

return T
