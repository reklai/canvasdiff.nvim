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

return T
