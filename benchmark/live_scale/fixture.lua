local M = {}

local SCHEMA = "canvasdiff.live_scale.fixture/v1"
local MARKER = ".canvasdiff-live-scale-fixture"
local EMPTY_CONFIG = ".canvasdiff-empty-gitconfig"
local MAX_STDERR = 4096
local GIT = vim.fn.exepath("git")
local owned_roots = {}
local token_sequence = 0

local SIDECARS = {
  staged = "staged.txt",
  unstaged = "unstaged.txt",
  untracked = "untracked.txt",
  deleted = "deleted.txt",
  rename_from = "rename_from.txt",
  rename_to = "rename_to.txt",
}

local function new_token(root)
  token_sequence = token_sequence + 1
  return vim.fn.sha256(table.concat({
    root,
    tostring(vim.uv.hrtime()),
    tostring(owned_roots),
    tostring(token_sequence),
  }, "\0"))
end

local function marker_body(root, token)
  return table.concat({
    SCHEMA,
    "root=" .. root,
    "token=" .. token,
    "",
  }, "\n")
end

local function exact_root(root)
  if type(root) ~= "string" or root == "" then
    return nil, "fixture root must be a nonempty absolute path"
  end
  if not vim.startswith(root, "/") or vim.fs.normalize(root) ~= root then
    return nil, "fixture root must be an exact normalized absolute path"
  end
  if root == "/" or vim.fs.dirname(root) == root then
    return nil, "fixture root must not be a filesystem root"
  end
  local stat = vim.uv.fs_lstat(root)
  if not stat or stat.type ~= "directory" then
    return nil, "fixture root must be an existing directory"
  end
  if vim.uv.fs_realpath(root) ~= root then
    return nil, "fixture root must not be a symlink or aliased path"
  end
  return true
end

local function root_is_empty(root)
  local ok, iterator = pcall(vim.fs.dir, root)
  if not ok then
    return nil, "fixture root is not readable: " .. tostring(iterator)
  end
  if iterator() ~= nil then
    return nil, "fixture root must be empty"
  end
  return true
end

local function write_file(path, content)
  local file, open_err = io.open(path, "wb")
  if not file then
    return nil, "could not open " .. path .. ": " .. tostring(open_err)
  end
  local written, write_err = file:write(content)
  local closed, close_err = file:close()
  if not written then
    return nil, "could not write " .. path .. ": " .. tostring(write_err)
  end
  if not closed then
    return nil, "could not close " .. path .. ": " .. tostring(close_err)
  end
  return true
end

local function read_file(path)
  local file, open_err = io.open(path, "rb")
  if not file then
    return nil, "could not open " .. path .. ": " .. tostring(open_err)
  end
  local content = file:read("*a")
  local closed, close_err = file:close()
  if content == nil then
    return nil, "could not read " .. path
  end
  if not closed then
    return nil, "could not close " .. path .. ": " .. tostring(close_err)
  end
  return content
end

local function path(root, relative)
  return vim.fs.joinpath(root, relative)
end

local function git(root, ...)
  if GIT == "" then
    return nil, "Git executable is not available"
  end
  local command = { GIT, "-C", root, ... }
  local ok, process = pcall(vim.system, command, {
    clear_env = true,
    cwd = root,
    env = {
      GIT_AUTHOR_DATE = "2000-01-01T00:00:00Z",
      GIT_ATTR_NOSYSTEM = "1",
      GIT_COMMITTER_DATE = "2000-01-01T00:00:00Z",
      GIT_CONFIG_GLOBAL = path(root, EMPTY_CONFIG),
      GIT_CONFIG_NOSYSTEM = "1",
      HOME = root,
      LANG = "C",
      LC_ALL = "C",
      XDG_CONFIG_HOME = root,
    },
    text = true,
    timeout = 30000,
  })
  if not ok then
    return nil, ("Git could not start: argv=%s error=%s"):format(
      vim.inspect(command), tostring(process))
  end
  local result = process:wait()
  if result.code ~= 0 then
    local stderr = (result.stderr or ""):sub(1, MAX_STDERR)
    return nil, ("Git failed: argv=%s code=%s signal=%s stderr=%s"):format(
      vim.inspect(command), tostring(result.code), tostring(result.signal), stderr)
  end
  return result.stdout or ""
end

local function must_git(root, ...)
  local stdout, err = git(root, ...)
  if not stdout then
    error(err, 0)
  end
  return stdout
end

local function must_write(path, content)
  local written, err = write_file(path, content)
  if not written then
    error(err, 0)
  end
end

local function create_base(root)
  must_write(path(root, "primary.txt"), "")
  must_write(path(root, SIDECARS.staged), "staged base\n")
  must_write(path(root, SIDECARS.unstaged), "unstaged base\n")
  must_write(path(root, SIDECARS.deleted), "deleted base\n")
  must_write(path(root, SIDECARS.rename_from), "rename base\n")
  must_write(path(root, "branch_modified.txt"), "branch base\n")
  must_write(path(root, "branch_deleted.txt"), "branch deleted\n")
  must_write(path(root, "branch_rename_from.txt"), "branch rename\n")
  must_git(root, "add", "-A")
  must_git(root, "commit", "-q", "-m", "live scale base")
  must_git(root, "branch", "scale-base", "HEAD")
end

local function create_comparison_refs(root)
  must_git(root, "switch", "-q", "-c", "scale-branch")
  must_write(path(root, "branch_modified.txt"), "branch changed\n")
  assert(vim.fn.delete(path(root, "branch_deleted.txt")) == 0,
    "could not delete branch comparison sidecar")
  must_git(root, "mv", "--", "branch_rename_from.txt", "branch_rename_to.txt")
  must_write(path(root, "branch_added.txt"), "branch added\n")
  must_git(root, "add", "-A")
  must_git(root, "commit", "-q", "-m", "live scale comparison")
  must_git(root, "branch", "scale-range", "HEAD")
  must_git(root, "switch", "-q", "main")
end

local function write_primary(root, rows, seed)
  local primary = path(root, "primary.txt")
  local file, open_err = io.open(primary, "wb")
  if not file then
    error("could not open " .. primary .. ": " .. tostring(open_err), 0)
  end
  for index = 1, rows do
    local written, write_err =
      file:write(("scale %d seed %d\n"):format(index, seed))
    if not written then
      file:close()
      error("could not write " .. primary .. ": " .. tostring(write_err), 0)
    end
  end
  local closed, close_err = file:close()
  if not closed then
    error("could not close " .. primary .. ": " .. tostring(close_err), 0)
  end

  local content, read_err = read_file(primary)
  if not content then
    error(read_err, 0)
  end
  return vim.fn.sha256(content)
end

local function apply_worktree_state(root, rows, seed)
  local digest = write_primary(root, rows, seed)
  must_write(path(root, SIDECARS.staged),
    ("staged seed %d\n"):format(seed))
  must_git(root, "add", "--", SIDECARS.staged)
  must_write(path(root, SIDECARS.unstaged),
    ("unstaged seed %d\n"):format(seed))
  assert(vim.fn.delete(path(root, SIDECARS.deleted)) == 0,
    "could not delete worktree sidecar")
  must_git(root, "mv", "--", SIDECARS.rename_from, SIDECARS.rename_to)
  must_write(path(root, SIDECARS.untracked),
    ("untracked seed %d\n"):format(seed))
  return digest
end

function M.build(root, rows, seed)
  if type(rows) ~= "number" or rows <= 0 or rows % 1 ~= 0 then
    return nil, "fixture rows must be a positive integer"
  end
  if type(seed) ~= "number" or seed % 1 ~= 0 then
    return nil, "fixture seed must be an integer"
  end

  local valid, root_err = exact_root(root)
  if not valid then
    return nil, root_err
  end
  local empty, empty_err = root_is_empty(root)
  if not empty then
    return nil, empty_err
  end

  local token = new_token(root)
  owned_roots[root] = token
  local ok, result = pcall(function()
    must_write(path(root, MARKER), marker_body(root, token))
    must_write(path(root, EMPTY_CONFIG), "")
    must_git(root, "init", "-q", "-b", "main", "--template=")
    must_git(root, "config", "--local", "user.email",
      "canvasdiff-live-scale@example.invalid")
    must_git(root, "config", "--local", "user.name",
      "CanvasDiff Live Scale Fixture")
    must_git(root, "config", "--local", "commit.gpgsign", "false")
    must_git(root, "config", "--local", "core.autocrlf", "false")
    assert(vim.fn.mkdir(path(root, ".git/info"), "p") == 1,
      "could not create isolated Git info directory")
    assert(vim.fn.mkdir(
      path(root, ".git/canvasdiff-empty-hooks"), "p") == 1,
      "could not create isolated Git hooks directory")
    must_git(root, "config", "--local", "core.hooksPath",
      ".git/canvasdiff-empty-hooks")
    must_write(path(root, ".git/info/exclude"),
      MARKER .. "\n" .. EMPTY_CONFIG .. "\n")

    create_base(root)
    create_comparison_refs(root)
    local digest = apply_worktree_state(root, rows, seed)

    return {
      schema = SCHEMA,
      root = root,
      seed = seed,
      rows = rows,
      primary_path = "primary.txt",
      first_line = ("scale 1 seed %d"):format(seed),
      last_line = ("scale %d seed %d"):format(rows, seed),
      digest = digest,
      base_ref = "scale-base",
      branch_ref = "scale-branch",
      range_ref = "scale-base..scale-range",
      sidecars = vim.deepcopy(SIDECARS),
    }
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

function M.cleanup(root)
  local valid, root_err = exact_root(root)
  if not valid then
    return nil, root_err
  end

  local token = owned_roots[root]
  if not token then
    return nil, "cleanup refused: root is not owned by this fixture module instance"
  end

  local marker_path = path(root, MARKER)
  local marker_stat = vim.uv.fs_lstat(marker_path)
  if not marker_stat or marker_stat.type ~= "file" then
    return nil, "cleanup refused: fixture ownership marker is missing"
  end
  local marker, marker_err = read_file(marker_path)
  if not marker then
    return nil, "cleanup refused: " .. marker_err
  end
  if marker ~= marker_body(root, token) then
    return nil, "cleanup refused: fixture ownership marker does not match exact root and schema"
  end

  local git_stat = vim.uv.fs_lstat(path(root, ".git"))
  if not git_stat or git_stat.type ~= "directory" then
    return nil, "cleanup refused: target is not a fixture repository root"
  end

  local deleted = vim.fn.delete(root, "rf")
  if deleted ~= 0 then
    return nil, "could not remove exact fixture root: " .. root
  end
  owned_roots[root] = nil
  return true
end

return M
