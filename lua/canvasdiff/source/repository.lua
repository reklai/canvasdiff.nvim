local system = require("canvasdiff.os")

-- Owns Git command construction and protocol parsing. Raw process execution
-- remains behind the operating-system facade above.
local M = {}

--- Run `git -C dir <args...>` synchronously, optionally feeding it `stdin`.
---
--- Deliberately NOT `{ text = true }`: that option rewrites `\r\n` to `\n` in
--- stdout, which would corrupt every blob `M.show` returns for a CRLF file and
--- make it mismatch the worktree side line for line. Every other consumer is
--- safe with raw bytes -- `M.root` strips trailing whitespace (`%s` covers
--- `\r`), and `changed_files` splits porcelain-v2 `-z` output on NUL. `stdin`
--- is unaffected by the option and reaches the process byte for byte.
local function run(dir, args, stdin)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  return system.run(cmd, { text = false, stdin = stdin })
end

local function command_error(what, res)
  local detail = res and res.stderr and res.stderr:gsub("%s+$", "") or ""
  if detail ~= "" then
    return ("%s failed: %s"):format(what, detail)
  end
  return ("%s failed (exit %s)"):format(what, tostring(res and res.code or "?"))
end

local function nul_tokens(raw)
  if raw == "" then
    return {}
  end
  local tokens = vim.split(raw, "\0", { plain = true })
  if tokens[#tokens] == "" then
    table.remove(tokens)
  end
  return tokens
end

--- @param dir string
--- @return string|nil
function M.root(dir)
  local res = run(dir, { "rev-parse", "--show-toplevel" })
  if res.code ~= 0 or not res.stdout then
    return nil
  end
  local out = res.stdout:gsub("%s+$", "")
  if out == "" then
    return nil
  end
  return out
end

-- Given the XY status pair of a porcelain v2 "1" (ordinary) record, pick the
-- worktree column when it's not ".", else fall back to the index column.
local function ordinary_status(xy)
  local index_char = xy:sub(1, 1)
  local worktree_char = xy:sub(2, 2)
  if worktree_char ~= "." then
    return worktree_char
  end
  return index_char
end

-- Porcelain v2's XY pair says two separate things: X is what the INDEX has done
-- relative to HEAD (i.e. what you staged), Y is what the WORKTREE has done relative
-- to the index (i.e. what you haven't). "." means "nothing".
--
-- Keeping both is what lets the canvas say which kind of change each file is, and it
-- gives staged-then-changed for free: a file with BOTH set is one you staged and then
-- modified again -- the reviewed-then-changed signal, in git's own durable
-- vocabulary rather than our session file's.
local function xy_pair(xy)
  local function col(c) return c ~= "." and c or nil end
  return col(xy:sub(1, 1)), col(xy:sub(2, 2))
end

--- Every changed file, with both halves of its porcelain-v2 status.
---
--- `staged` / `unstaged` are the X and Y columns, nil when that column is ".":
---   staged only    -> you staged it and haven't touched it since
---   unstaged only  -> you haven't staged it at all
---   both           -> you staged it and then changed it again
---
--- @param root string
--- @return { path: string, old_path: string?, status: string, staged: string?, unstaged: string? }[]|nil
--- @return string|nil
function M.changed_files(root)
  local res = run(root, { "status", "--porcelain=v2", "-z", "--untracked-files=all" })
  if res.code ~= 0 or res.stdout == nil then
    return nil, command_error("git status", res)
  end
  if res.stdout == "" then
    return {}
  end

  local tokens = nul_tokens(res.stdout)

  local files = {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local kind = tok:sub(1, 1)

    if kind == "1" then
      -- "1 XY sub mH mI mW hH hI path"
      local xy, sub, path = tok:match("^1 (%S+) (%S+) %S+ %S+ %S+ %S+ %S+ (.*)$")
      if not (xy and sub and path) then
        return nil, "malformed git status porcelain-v2 ordinary record"
      end
      if sub:sub(1, 1) ~= "S" then
        local staged, unstaged = xy_pair(xy)
        files[#files + 1] = {
          path = path, status = ordinary_status(xy),
          staged = staged, unstaged = unstaged,
        }
      end
      i = i + 1
    elseif kind == "2" then
      -- "2 XY sub mH mI mW hH hI Xscore newpath" NUL "origpath"
      local xy, sub, newpath = tok:match("^2 (%S+) (%S+) %S+ %S+ %S+ %S+ %S+ %S+ (.*)$")
      local oldpath = tokens[i + 1]
      -- consume the origpath token unconditionally so it never leaks into
      -- the next iteration as a bogus record.
      i = i + 2
      if not (xy and sub and newpath and oldpath) then
        return nil, "malformed git status porcelain-v2 rename/copy record"
      end
      if sub:sub(1, 1) ~= "S" then
        local staged, unstaged = xy_pair(xy)
        files[#files + 1] = {
          path = newpath, old_path = oldpath, status = "R",
          staged = staged, unstaged = unstaged,
        }
      end
    elseif kind == "?" then
      local path = tok:match("^%? (.*)$")
      if path then
        -- Untracked: nothing staged by definition, and the whole file is the
        -- unstaged change.
        files[#files + 1] = { path = path, status = "?", staged = nil, unstaged = "?" }
      end
      i = i + 1
    else
      -- Unhandled record kind (e.g. "!" ignored): skip. "u" (unmerged /
      -- conflicted) records are intentionally out of MVP scope -- no
      -- conflict-resolution UI exists yet, so they're silently dropped
      -- rather than surfaced as a plain M/A/D diff.
      i = i + 1
    end
  end

  table.sort(files, function(a, b) return a.path < b.path end)
  return files
end

local function mutation_paths(file)
  local paths = {}
  if type(file) == "table" then
    if type(file.old_path) == "string" and file.old_path ~= ""
        and file.old_path ~= file.path then
      paths[#paths + 1] = file.old_path
    end
    if type(file.path) == "string" and file.path ~= "" then
      paths[#paths + 1] = file.path
    end
  end
  return paths
end

--- Stage the complete current worktree state for one file identity.
--- Rename identities deliberately name both sides so Git cannot leave a
--- historical source path behind when similarity detection changes.
function M.stage(root, file)
  if type(file) ~= "table"
      or type(file.path) ~= "string"
      or file.path == "" then
    return nil, "cannot stage a file without a path"
  end

  local paths = mutation_paths(file)
  if #paths == 0 then
    return nil, "cannot stage a file without a path"
  end
  -- A porcelain rename is already represented in the index: its old path is
  -- absent and its destination is present. Re-adding only the destination is
  -- one atomic Git mutation that updates its current disk bytes while
  -- retaining the staged old-side deletion. Naming the absent old path would
  -- make `git add` reject the whole operation, which previously forced a
  -- destructive reset/add composite.
  local args = { "--literal-pathspecs", "add", "-A", "--", file.path }
  local res = run(root, args)
  if res.code ~= 0 then
    return nil, command_error("git add", res)
  end
  return true
end

--- Restore one file identity's index entries from HEAD, leaving worktree
--- bytes untouched. In an unborn repository there is no HEAD tree to reset
--- from, so removing the entries from the index is the equivalent operation.
function M.unstage(root, file)
  local paths = mutation_paths(file)
  if #paths == 0 then
    return nil, "cannot unstage a file without a path"
  end
  local reset = { "--literal-pathspecs", "reset", "HEAD", "--" }
  vim.list_extend(reset, paths)
  local reset_res = run(root, reset)
  if reset_res.code == 0 then
    return true
  end
  local head = run(root, { "rev-parse", "--verify", "--quiet", "HEAD" })
  if head.code == 0 then
    return nil, command_error("git reset", reset_res)
  end
  if head.code ~= 1 then
    return nil, command_error("git rev-parse HEAD", head)
  end
  local remove = {
    "--literal-pathspecs", "rm", "--cached", "--ignore-unmatch", "--",
  }
  vim.list_extend(remove, paths)
  local remove_res = run(root, remove)
  if remove_res.code ~= 0 then
    return nil, command_error("git rm --cached", remove_res)
  end
  return true
end

--- Resolve an arbitrary revision expression to one canonical commit object.
---
--- `--end-of-options` makes a ref beginning with "-" data rather than another
--- rev-parse option. Appending ^{commit} accepts commits and commit-ish tags,
--- while rejecting a blob/tree that cannot serve as a diff base.
--- @param root string
--- @param ref string
--- @return string|nil oid
--- @return string|nil err
function M.resolve_commit(root, ref)
  if type(ref) ~= "string" or ref == "" then
    return nil, "revision must be a non-empty string"
  end
  local res = run(root, {
    "rev-parse", "--verify", "--quiet", "--end-of-options", ref .. "^{commit}",
  })
  if res.code ~= 0 or res.stdout == nil then
    return nil, ("revision '%s' does not resolve to a commit"):format(ref)
  end
  local oid = res.stdout:gsub("%s+$", "")
  if oid == "" or not oid:match("^[0-9a-fA-F]+$") then
    return nil, ("revision '%s' did not resolve to a canonical object id"):format(ref)
  end
  return oid
end

--- Local and remote branch metadata. Full refs remain the execution identity;
--- short names exist only for display/completion, so a same-named ref cannot
--- silently resolve to a different object. Symbolic remote HEADs are retained
--- as explicit base-picker choices.
--- @param root string
--- @return table[]|nil
--- @return string|nil
function M.branches(root)
  local res = run(root, {
    "for-each-ref",
    "--sort=refname",
    "--format=%(refname)%09%(refname:short)%09%(symref)%09%(HEAD)",
    "refs/heads",
    "refs/remotes",
  })
  if res.code ~= 0 or res.stdout == nil then
    return nil, command_error("git for-each-ref", res)
  end
  local refs = {}
  for _, line in ipairs(vim.split(res.stdout, "\n", { plain = true, trimempty = true })) do
    local ref, short, symref, head = line:match("^(.-)\t(.-)\t(.-)\t(.*)$")
    local kind = ref and ref:find("refs/heads/", 1, true) == 1 and "local" or "remote"
    local full_name = ref and ref:gsub("^refs/heads/", ""):gsub("^refs/remotes/", "")
    local remote_default = kind == "remote"
      and type(symref) == "string" and symref ~= ""
      and type(full_name) == "string"
      and full_name:match("/HEAD$") ~= nil
    -- Git lengthens refname:short when a local and remote display spelling
    -- collide (`heads/x` vs `remotes/x`). Keep that disambiguation. Symbolic
    -- remote HEAD is the exception: Git shortens it to the remote name alone,
    -- so retain the explicit `<remote>/HEAD` picker label from the full ref.
    local name = remote_default and full_name or short
    if ref and ref ~= "" and type(name) == "string" and name ~= ""
        and (symref == "" or remote_default) then
      local item = { ref = ref, name = name, kind = kind }
      if kind == "local" then
        item.current = head == "*"
      elseif remote_default then
        item.remote_default = true
      end
      refs[#refs + 1] = item
    end
  end
  table.sort(refs, function(a, b)
    if a.name ~= b.name then
      return a.name < b.name
    end
    return a.ref < b.ref
  end)
  return refs
end

local function local_branch_name(root, full_ref)
  if type(full_ref) ~= "string"
      or not full_ref:match("^refs/heads/.+$") then
    return nil, "local branch ref must match refs/heads/<name>"
  end
  local format = run(root, { "check-ref-format", full_ref })
  if format.code ~= 0 then
    return nil, command_error("git check-ref-format", format)
  end
  return full_ref:sub(#"refs/heads/" + 1)
end

local function symbolic_head(root)
  local res = run(root, { "symbolic-ref", "--quiet", "HEAD" })
  if res.code ~= 0 or res.stdout == nil then
    return nil
  end
  local ref = res.stdout:gsub("[\r\n]+$", "")
  if not ref:match("^refs/heads/.+$") then
    return nil
  end
  return ref
end

--- Resolve the exact local ref to which HEAD is currently attached.
--- Detached, unborn, and unreadable HEAD states have no local branch identity.
--- @param root string
--- @return string|nil
function M.current_branch(root)
  return symbolic_head(root)
end

local function validate_remote_ref(full_remote_ref)
  if type(full_remote_ref) ~= "string"
      or not full_remote_ref:match("^refs/remotes/[^/]+/.+$") then
    return nil, "remote branch ref must match refs/remotes/<remote>/<name>"
  end
  if full_remote_ref:match("/HEAD$") then
    return nil, "symbolic remote HEAD cannot be tracked"
  end
  return true
end

--- Switch to one validated, existing local branch without remote guessing.
--- @param root string
--- @param full_ref string
--- @return true|nil
--- @return string|nil
function M.switch_branch(root, full_ref)
  local name, validation_err = local_branch_name(root, full_ref)
  if not name then
    return nil, validation_err
  end
  local res = run(root, { "switch", "--no-guess", "--", name })
  if res.code ~= 0 then
    local err = command_error("git switch", res)
    if symbolic_head(root) == full_ref then
      return true, err
    end
    return nil, err
  end
  return true
end

--- Create and switch to one validated local branch tracking an exact remote ref.
--- @param root string
--- @param local_name string
--- @param full_remote_ref string
--- @return true|nil
--- @return string|nil
function M.track_branch(root, local_name, full_remote_ref)
  local valid_remote, remote_err = validate_remote_ref(full_remote_ref)
  if not valid_remote then
    return nil, remote_err
  end

  if type(local_name) ~= "string" or local_name == "" then
    return nil, "local branch name must be a non-empty string"
  end
  local format = run(root, { "check-ref-format", "--branch", local_name })
  if format.code ~= 0 then
    return nil, command_error("git check-ref-format --branch", format)
  end
  local checked_name = format.stdout
    and format.stdout:gsub("[\r\n]+$", "") or nil
  if checked_name ~= local_name then
    return nil, "local branch name must not use checkout shorthand"
  end

  local local_ref = "refs/heads/" .. local_name
  local collision = run(root, {
    "show-ref", "--verify", "--quiet", "--", local_ref,
  })
  if collision.code == 0 then
    return nil, ("local branch '%s' already exists; use :CanvasDiff checkout")
      :format(local_name)
  end
  if collision.code ~= 1 then
    return nil, command_error("git show-ref --verify", collision)
  end

  local res = run(root, {
    "switch", "--no-guess", "--track", "-c", local_name, "--", full_remote_ref,
  })
  if res.code ~= 0 then
    local err = command_error("git switch --track", res)
    local head_matches = symbolic_head(root) == local_ref
    local local_exists = run(root, {
      "show-ref", "--verify", "--quiet", "--", local_ref,
    }).code == 0
    local upstream = run(root, {
      "rev-parse", "--symbolic-full-name", "@{upstream}",
    })
    local upstream_ref = upstream.code == 0 and upstream.stdout
      and upstream.stdout:gsub("[\r\n]+$", "") or nil
    if head_matches and local_exists and upstream_ref == full_remote_ref then
      return true, err
    end
    return nil, err
  end
  return true
end

--- Resolve the common ancestor of two commit-ish refs.
--- @param root string
--- @param left string
--- @param right string
--- @return string|nil oid
--- @return string|nil err
function M.merge_base(root, left, right)
  local left_oid, left_err = M.resolve_commit(root, left)
  if not left_oid then
    return nil, left_err
  end
  local right_oid, right_err = M.resolve_commit(root, right)
  if not right_oid then
    return nil, right_err
  end
  local res = run(root, { "merge-base", left_oid, right_oid })
  if res.code ~= 0 or res.stdout == nil then
    return nil, ("revisions '%s' and '%s' have no merge base"):format(left, right)
  end
  local oid = res.stdout:gsub("%s+$", "")
  if oid == "" or not oid:match("^[0-9a-fA-F]+$") then
    return nil, "git merge-base did not return a canonical object id"
  end
  return oid
end

--- Files whose tracked worktree result differs from `oid`.
---
--- `--name-status -z` makes every status and path its own NUL-delimited field:
--- ordinary records are STATUS, PATH; rename/copy records are Rnnn/Cnnn,
--- OLD_PATH, NEW_PATH. No path is whitespace-split or trimmed.
--- @param root string
--- When `new_oid` is present, both sides are committed and the worktree is
--- ignored. With one oid the historical oid-to-worktree behavior is retained.
--- @param oid string canonical old-side commit id
--- @param new_oid string? canonical new-side commit id
--- @return { path: string, old_path: string, status: string, score: integer? }[]|nil
--- @return string|nil
function M.diff_files(root, oid, new_oid)
  if type(oid) ~= "string" or oid == "" then
    return nil, "diff base must be a non-empty object id"
  end
  if new_oid ~= nil and (type(new_oid) ~= "string" or new_oid == "") then
    return nil, "diff result must be a non-empty object id"
  end
  local args = {
    "diff",
    "--no-ext-diff",
    "--ignore-submodules=all",
    "--name-status",
    "-z",
    "--find-renames",
    "--diff-filter=ACDMRT",
    oid,
  }
  if new_oid then
    args[#args + 1] = new_oid
  end
  args[#args + 1] = "--"
  local res = run(root, args)
  if res.code ~= 0 or res.stdout == nil then
    return nil, command_error("git diff", res)
  end

  local tokens = nul_tokens(res.stdout)
  local files = {}
  local i = 1
  while i <= #tokens do
    local raw_status = tokens[i]
    i = i + 1

    local status = raw_status:sub(1, 1)
    if raw_status:match("^[RC]%d+$") then
      local old_path, new_path = tokens[i], tokens[i + 1]
      if old_path == nil or new_path == nil or old_path == "" or new_path == "" then
        return nil, "malformed git diff --name-status -z rename/copy record"
      end
      files[#files + 1] = {
        path = new_path,
        old_path = old_path,
        status = status,
        score = tonumber(raw_status:sub(2)),
      }
      i = i + 2
    elseif raw_status:match("^[ADMT]$") then
      local path = tokens[i]
      if path == nil or path == "" then
        return nil, "malformed git diff --name-status -z ordinary record"
      end
      files[#files + 1] = {
        path = path,
        old_path = path,
        status = status,
      }
      i = i + 1
    else
      return nil, ("unexpected git diff --name-status status '%s'"):format(raw_status)
    end
  end

  table.sort(files, function(a, b)
    if a.path == b.path then
      return a.old_path < b.old_path
    end
    return a.path < b.path
  end)
  return files
end

--- @param root string
--- @param rev string "HEAD" or ":0" (the index/staged blob)
--- @param path string
--- @return string|nil
--- @return string|nil
function M.show(root, rev, path)
  local res = run(root, { "show", rev .. ":" .. path })
  if res.code ~= 0 or res.stdout == nil then
    return nil, command_error("git show", res)
  end
  return res.stdout
end

--- @param root string
--- @param path string
--- @return string|nil
function M.show_head(root, path)
  return M.show(root, "HEAD", path)
end

--- @param root string
--- @param path string
--- @return string|nil
--- @return string|nil
function M.index_blob(root, path)
  return M.show(root, ":0", path)
end

--- @param root string
--- @param path string
--- @return string|nil
--- @return string|nil
function M.head_blob(root, path)
  return M.show_head(root, path)
end

--- Point the index at `content` for `path`, leaving the worktree alone.
---
--- The mode comes from the entry already in the index, so an executable stays
--- executable; a path the index does not carry yet becomes a plain file.
--- @param root string
--- @param path string
--- @param content string
--- @return true|nil
--- @return string|nil
function M.set_index_blob(root, path, content)
  local entry = run(root, {
    "--literal-pathspecs", "ls-files", "--stage", "--", path,
  })
  if entry.code ~= 0 or entry.stdout == nil then
    return nil, command_error("git ls-files --stage", entry)
  end
  local mode = entry.stdout:match("^(%d+)") or "100644"

  -- `--path` applies the attributes of that path, so the blob is the one
  -- `git add` would have written for it.
  local hashed = run(root, {
    "hash-object", "-w", "--stdin", "--path", path,
  }, content)
  if hashed.code ~= 0 or hashed.stdout == nil then
    return nil, command_error("git hash-object", hashed)
  end
  local oid = hashed.stdout:gsub("%s+$", "")
  if not oid:match("^[0-9a-f]+$") then
    return nil, "git hash-object did not return a canonical object id"
  end

  local updated = run(root, {
    "update-index", "--add", "--cacheinfo",
    ("%s,%s,%s"):format(mode, oid, path),
  })
  if updated.code ~= 0 then
    return nil, command_error("git update-index", updated)
  end
  return true
end

return M
