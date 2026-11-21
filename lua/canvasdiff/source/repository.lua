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
---
--- Every Git process runs with GIT_OPTIONAL_LOCKS=0, Git's own switch for
--- background readers: `git status` then never takes index.lock to write
--- back refreshed stat data. Without it each collection rewrote .git/index
--- while a file was "racily clean" (modified within the index's timestamp
--- granularity), the watch's .git fs watcher saw that write, and the review
--- re-collected itself again and again until the window closed -- measured
--- at up to 45 passes after one save, and over 100 once passes ran in time
--- slices. Only OPTIONAL locks are affected; staging, checkout and every
--- other write still lock as Git requires.
local GIT_ENV = { GIT_OPTIONAL_LOCKS = "0" }

--- `index_file` points the one command at an alternate index
--- (GIT_INDEX_FILE), which is how a snapshot is built without the real index
--- ever being read for writing or written at all.
local function run(dir, args, stdin, index_file)
  local cmd = { "git", "-C", dir }
  for _, a in ipairs(args) do
    cmd[#cmd + 1] = a
  end
  local env = GIT_ENV
  if index_file then
    env = { GIT_OPTIONAL_LOCKS = "0", GIT_INDEX_FILE = index_file }
  end
  return system.run(cmd, { text = false, stdin = stdin, env = env })
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
--- @return { path: string, old_path: string?, status: string, staged: string?, unstaged: string?, mode_head: string?, mode_index: string?, mode_worktree: string? }[]|nil
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
      -- "1 XY sub mH mI mW hH hI path". The three mode columns are the fact
      -- that separates a chmod-only change (equal blobs, different modes) or
      -- an empty-file add/delete (mode vs 000000) from an unchanged pair, so
      -- they ride along rather than being discarded with the hashes.
      local xy, sub, m_head, m_index, m_worktree, path =
        tok:match("^1 (%S+) (%S+) (%S+) (%S+) (%S+) %S+ %S+ (.*)$")
      if not (xy and sub and path) then
        return nil, "malformed git status porcelain-v2 ordinary record"
      end
      if sub:sub(1, 1) ~= "S" then
        local staged, unstaged = xy_pair(xy)
        files[#files + 1] = {
          path = path, status = ordinary_status(xy),
          staged = staged, unstaged = unstaged,
          mode_head = m_head, mode_index = m_index, mode_worktree = m_worktree,
        }
      end
      i = i + 1
    elseif kind == "2" then
      -- "2 XY sub mH mI mW hH hI Xscore newpath" NUL "origpath"
      local xy, sub, m_head, m_index, m_worktree, newpath =
        tok:match("^2 (%S+) (%S+) (%S+) (%S+) (%S+) %S+ %S+ %S+ (.*)$")
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
          mode_head = m_head, mode_index = m_index, mode_worktree = m_worktree,
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

--- The raw porcelain-v2 status snapshot, asynchronously: `on_done` receives
--- the bytes on the event loop (a fast context), or nil when the command
--- fails. Deliberately unparsed -- its one consumer compares snapshots for
--- drift, and byte equality of the same command's output is exactly that
--- question. Same argv as `changed_files`, so anything that would change a
--- collection changes this snapshot too.
--- The same porcelain bytes `status_poll` delivers, read synchronously:
--- the string, or nil when Git fails. For a drift baseline that must be
--- taken at a known point -- before a collection -- rather than whenever an
--- asynchronous probe happens to finish.
function M.status_snapshot(root)
  local res = run(root, { "status", "--porcelain=v2", "-z", "--untracked-files=all" })
  if res.code ~= 0 or res.stdout == nil then
    return nil
  end
  return res.stdout
end

function M.status_poll(root, on_done)
  local cmd = {
    "git", "-C", root,
    "status", "--porcelain=v2", "-z", "--untracked-files=all",
  }
  system.run_async(cmd, { text = false, env = GIT_ENV }, function(res)
    if res and res.code == 0 and res.stdout ~= nil then
      on_done(res.stdout)
    else
      on_done(nil)
    end
  end)
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
--- `--raw -z` emits one metadata field per record -- ":old_mode new_mode
--- old_sha new_sha STATUS" -- followed by one NUL-delimited path (two for
--- rename/copy: OLD_PATH, NEW_PATH). No path is whitespace-split or trimmed.
--- The mode pair is why --raw rather than --name-status: a chmod-only commit
--- has equal blobs, and the modes are the only record that it changed at all.
--- @param root string
--- When `new_oid` is present, both sides are committed and the worktree is
--- ignored. With one oid the historical oid-to-worktree behavior is retained.
--- @param oid string canonical old-side commit id
--- @param new_oid string? canonical new-side commit id
--- @return { path: string, old_path: string, status: string, score: integer?, old_mode: string, new_mode: string }[]|nil
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
    "--raw",
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
    local old_mode, new_mode, raw_status =
      tokens[i]:match("^:(%d+) (%d+) %S+ %S+ ([A-Z]%d*)$")
    i = i + 1
    if not raw_status then
      return nil, ("unexpected git diff --raw record '%s'"):format(tokens[i - 1])
    end

    local status = raw_status:sub(1, 1)
    if raw_status:match("^[RC]%d+$") then
      local old_path, new_path = tokens[i], tokens[i + 1]
      if old_path == nil or new_path == nil or old_path == "" or new_path == "" then
        return nil, "malformed git diff --raw -z rename/copy record"
      end
      files[#files + 1] = {
        path = new_path,
        old_path = old_path,
        status = status,
        score = tonumber(raw_status:sub(2)),
        old_mode = old_mode,
        new_mode = new_mode,
      }
      i = i + 2
    elseif raw_status:match("^[ADMT]$") then
      local path = tokens[i]
      if path == nil or path == "" then
        return nil, "malformed git diff --raw -z ordinary record"
      end
      files[#files + 1] = {
        path = path,
        old_path = path,
        status = status,
        old_mode = old_mode,
        new_mode = new_mode,
      }
      i = i + 1
    else
      return nil, ("unexpected git diff --raw status '%s'"):format(raw_status)
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

--- Per-path line churn and binary flags from one bounded `git diff --numstat -z`
--- call, without reading blob bytes in Lua.
---
--- `mode` selects the pair Git compares:
---   * `cached = true` -> HEAD vs index (staged lens)
---   * `old_rev` and `new_rev` -> commit range `old_rev` vs `new_rev`
---   * `old_rev` only -> `old_rev` vs worktree (all / branch / checkpoint lens)
---   * neither -> index vs worktree (unstaged lens)
---
--- Returns `{ [path] = { adds = n, dels = m, binary = bool, old_path = str? } }`.
--- On an unborn repository or transient error returns `{}` so collection falls
--- back gracefully without aborting.
function M.numstat(root, opts)
  opts = opts or {}
  local args = {
    "diff",
    "--no-ext-diff",
    "--ignore-submodules=all",
    "--numstat",
    "-z",
    "--find-renames",
  }
  if opts.cached then
    args[#args + 1] = "--cached"
  elseif opts.old_rev and opts.new_rev then
    args[#args + 1] = opts.old_rev
    args[#args + 1] = opts.new_rev
  elseif opts.old_rev then
    args[#args + 1] = opts.old_rev
  end
  args[#args + 1] = "--"

  local res = run(root, args)
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return {}
  end

  local tokens = nul_tokens(res.stdout)
  local stats = {}
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local raw_adds, raw_dels, path = tok:match("^([^\t]+)\t([^\t]+)\t(.*)$")
    if not raw_adds then
      i = i + 1
    else
      local binary = raw_adds == "-" and raw_dels == "-"
      local adds = binary and 0 or (tonumber(raw_adds) or 0)
      local dels = binary and 0 or (tonumber(raw_dels) or 0)
      if path == "" then
        -- Rename/copy record under `-z`: empty path followed by old_path, new_path.
        local old_path = tokens[i + 1]
        local new_path = tokens[i + 2]
        i = i + 3
        if new_path and new_path ~= "" then
          stats[new_path] = {
            adds = adds,
            dels = dels,
            binary = binary,
            old_path = old_path,
          }
        end
      else
        stats[path] = {
          adds = adds,
          dels = dels,
          binary = binary,
        }
        i = i + 1
      end
    end
  end
  return stats
end

--- Query `.gitattributes` for `paths` in one bounded `git check-attr -z --stdin`
--- invocation. Returns `{ [path] = { generated = bool, no_diff = bool, binary = bool } }`.
function M.check_attributes(root, paths)
  if type(paths) ~= "table" or #paths == 0 then
    return {}
  end
  local stdin = table.concat(paths, "\0") .. "\0"
  local res = run(root, {
    "check-attr", "-z", "--stdin", "linguist-generated", "diff", "binary",
  }, stdin)
  if res.code ~= 0 or not res.stdout or res.stdout == "" then
    return {}
  end
  local tokens = nul_tokens(res.stdout)
  local out = {}
  local i = 1
  while i + 2 <= #tokens do
    local path = tokens[i]
    local attr = tokens[i + 1]
    local info = tokens[i + 2]
    i = i + 3
    if path and path ~= "" then
      local rec = out[path]
      if attr == "linguist-generated" and (info == "set" or info == "true") then
        rec = rec or {}
        rec.generated = true
        out[path] = rec
      elseif attr == "diff" and info == "unset" then
        rec = rec or {}
        rec.no_diff = true
        out[path] = rec
      elseif attr == "binary" and (info == "set" or info == "true") then
        rec = rec or {}
        rec.binary = true
        out[path] = rec
      end
    end
  end
  return out
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
--- @return string|nil
function M.show_head(root, path)
  return M.show(root, "HEAD", path)
end

--- Point the index at `content` for `path`, leaving the worktree alone.
---
--- The mode comes from the entry already in the index, so an executable stays
--- executable. A path the index does not carry yet is an UNTRACKED file being
--- staged a hunk at a time, and its worktree file is what git would have read
--- the mode from: `git add` records 100755 for an owner-executable file, so a
--- hunk press on a new shell script or hook has to record the same, or `s` and
--- `S` would write different index entries for it. Only a regular file can
--- carry that bit here -- a symlink's own permissions say nothing about the
--- blob this writes -- and a path with no worktree file at all falls back to a
--- plain mode, which is all a caller inventing an entry can mean by it.
--- @param root string
--- @param path string
--- @param content string
--- @return true|nil
--- @return string|nil
function M.set_index_blob(root, path, content, index_file)
  local entry = run(root, {
    "--literal-pathspecs", "ls-files", "--stage", "--", path,
  }, nil, index_file)
  if entry.code ~= 0 or entry.stdout == nil then
    return nil, command_error("git ls-files --stage", entry)
  end
  local mode = entry.stdout:match("^(%d+)")
  if not mode then
    local stat = vim.uv.fs_lstat(vim.fs.joinpath(root, path))
    if stat and stat.type == "link" then
      -- Git records a symlink as mode 120000 with the payload as its blob;
      -- 100644 here would commit a regular file where the worktree has a link.
      mode = "120000"
    else
      local executable = stat ~= nil
        and stat.type == "file"
        and bit.band(stat.mode, tonumber("100", 8)) ~= 0
      mode = executable and "100755" or "100644"
    end
  end

  -- `--path` applies the attributes of that path, so the blob is the one
  -- `git add` would have written for it. Except for a symlink: git never runs
  -- text/eol filters over a link payload, so hash it raw.
  local hash_args = { "hash-object", "-w", "--stdin" }
  if mode ~= "120000" then
    vim.list_extend(hash_args, { "--path", path })
  end
  local hashed = run(root, hash_args, content, index_file)
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
  }, nil, index_file)
  if updated.code ~= 0 then
    return nil, command_error("git update-index", updated)
  end
  return true
end

--- Record the worktree as it is right now as a commit, and point `ref` at it.
---
--- What `git stash create` would be if it also took untracked files and left
--- nothing behind but the object: a throwaway index seeded from the real one
--- (so only what differs is hashed) takes `git add -A`, then each `overlays`
--- entry -- { path, text }, a loaded buffer's unsaved bytes -- on top, and its
--- tree becomes a commit whose parent is HEAD when there is one.
---
--- The real index and the worktree are never written: every command that
--- writes an index is pointed at the throwaway one, and that file is deleted
--- on every exit. What the repository gains is objects and one ref -- and
--- `ref` is the caller's, meant to be a private one (refs/worktree/..., which
--- is per-worktree and outside every branch listing).
---
--- Ignored files are not in the snapshot, by `git add`'s own rule.
--- @param root string
--- @param ref string full ref name to move
--- @param overlays { path: string, text: string }[]|nil
--- @return string|nil commit the new commit's object id
--- @return string|nil err nothing was moved when this is set
function M.snapshot(root, ref, overlays)
  if type(ref) ~= "string" or not ref:match("^refs/") then
    return nil, "snapshot needs a full ref name"
  end
  local index_file = vim.fn.tempname()
  local function done(commit, err)
    pcall(vim.uv.fs_unlink, index_file)
    pcall(vim.uv.fs_unlink, index_file .. ".lock")
    return commit, err
  end

  local located = run(root, { "rev-parse", "--git-path", "index" })
  if located.code ~= 0 or located.stdout == nil then
    return done(nil, command_error("git rev-parse --git-path", located))
  end
  local real_index = located.stdout:gsub("%s+$", "")
  if not real_index:match("^/") and not real_index:match("^%a:[/\\]") then
    real_index = vim.fs.joinpath(root, real_index)
  end
  -- No index yet (a repository with nothing ever added) is not a failure: the
  -- throwaway index simply starts empty.
  if vim.uv.fs_stat(real_index) then
    local copied, copy_err = vim.uv.fs_copyfile(real_index, index_file)
    if not copied then
      return done(nil, "could not seed a snapshot index: " .. tostring(copy_err))
    end
  end

  local added = run(root, { "add", "-A" }, nil, index_file)
  if added.code ~= 0 then
    return done(nil, command_error("git add", added))
  end
  for _, overlay in ipairs(overlays or {}) do
    local set, set_err = M.set_index_blob(root, overlay.path, overlay.text, index_file)
    if not set then
      return done(nil, set_err)
    end
  end

  local wrote = run(root, { "write-tree" }, nil, index_file)
  local tree = wrote.code == 0 and wrote.stdout
    and wrote.stdout:gsub("%s+$", "") or ""
  if not tree:match("^[0-9a-f]+$") then
    return done(nil, command_error("git write-tree", wrote))
  end

  -- An identity of its own: commit-tree refuses to run without one, and a
  -- snapshot must not depend on (or be attributed to) the user's.
  local commit_args = {
    "-c", "user.name=canvasdiff", "-c", "user.email=canvasdiff@localhost",
    "commit-tree", tree, "-m", "canvasdiff checkpoint",
  }
  local head = M.resolve_commit(root, "HEAD")
  if head then
    vim.list_extend(commit_args, { "-p", head })
  end
  local committed = run(root, commit_args)
  local commit = committed.code == 0 and committed.stdout
    and committed.stdout:gsub("%s+$", "") or ""
  if not commit:match("^[0-9a-f]+$") then
    return done(nil, command_error("git commit-tree", committed))
  end

  local moved = run(root, {
    "update-ref", "-m", "canvasdiff: checkpoint", "--end-of-options", ref, commit,
  })
  if moved.code ~= 0 then
    return done(nil, command_error("git update-ref", moved))
  end
  return done(commit)
end

return M
