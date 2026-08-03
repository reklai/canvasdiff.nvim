#!/usr/bin/env bash
# Builds the demo repository the screenshots are shot in: a small, plausible
# Lua job-queue library with a multi-file changeset — staged and unstaged
# edits, a new file, a deletion, and a feature branch for comparison mode.
set -euo pipefail

dir=${1:?usage: fixture.sh <target-dir>}
rm -rf "$dir"
mkdir -p "$dir"
cd "$dir"

git init -q -b main
git config user.name "demo"
git config user.email "demo@example.com"

mkdir -p lua/spool tests

cat > README.md <<'EOF'
# spool

A tiny job queue for Neovim plugins: enqueue functions, run them with
bounded concurrency, and observe progress.

## Usage

```lua
local spool = require("spool")
spool.enqueue(function() vim.print("hi") end)
spool.drain()
```
EOF

cat > lua/spool/init.lua <<'EOF'
local queue = require("spool.queue")
local worker = require("spool.worker")

local M = {}

function M.enqueue(job, opts)
  return queue.push(job, opts)
end

function M.drain()
  while not queue.empty() do
    worker.step()
  end
end

return M
EOF

cat > lua/spool/queue.lua <<'EOF'
local M = {}

local jobs = {}

function M.push(job, opts)
  jobs[#jobs + 1] = { run = job, tries = 0, opts = opts }
  return #jobs
end

function M.pop()
  return table.remove(jobs, 1)
end

function M.empty()
  return #jobs == 0
end

function M.size()
  return #jobs
end

return M
EOF

cat > lua/spool/worker.lua <<'EOF'
local queue = require("spool.queue")

local M = {}

function M.step()
  local job = queue.pop()
  if not job then
    return false
  end
  job.tries = job.tries + 1
  local ok = pcall(job.run)
  return ok
end

return M
EOF

cat > lua/spool/legacy.lua <<'EOF'
-- Deprecated: the pre-0.2 synchronous runner, kept for one release.
local M = {}

function M.run_all(list)
  for _, job in ipairs(list) do
    job()
  end
end

return M
EOF

cat > tests/queue_spec.lua <<'EOF'
local queue = require("spool.queue")

describe("queue", function()
  it("pops in insertion order", function()
    queue.push(function() end)
    queue.push(function() end)
    assert.equals(2, queue.size())
    queue.pop()
    assert.equals(1, queue.size())
  end)
end)
EOF

git add -A
git commit -qm "spool 0.1: queue, worker, drain"

# --- the feature branch comparison mode is shot against ----------------------

git checkout -qb feature/backoff

cat > lua/spool/worker.lua <<'EOF'
local queue = require("spool.queue")

local M = {}

local BACKOFF_BASE_MS = 50

function M.step()
  local job = queue.pop()
  if not job then
    return false
  end
  job.tries = job.tries + 1
  local ok = pcall(job.run)
  if not ok and job.tries < 3 then
    vim.defer_fn(function()
      queue.push(job.run, job.opts)
    end, BACKOFF_BASE_MS * 2 ^ job.tries)
  end
  return ok
end

return M
EOF
git commit -qam "worker: retry failed jobs with exponential backoff"

git checkout -q main

# --- the working-tree changeset the canvas shows ------------------------------

# STAGED: a new module, plus the public API that exposes it.
cat > lua/spool/log.lua <<'EOF'
local M = {}

local entries = {}

function M.record(event, detail)
  entries[#entries + 1] = { event = event, detail = detail, at = vim.uv.now() }
end

function M.tail(n)
  return vim.list_slice(entries, math.max(1, #entries - n + 1))
end

return M
EOF

cat > lua/spool/init.lua <<'EOF'
local log = require("spool.log")
local queue = require("spool.queue")
local worker = require("spool.worker")

local M = {}

function M.enqueue(job, opts)
  log.record("enqueue", opts and opts.name)
  return queue.push(job, opts)
end

function M.drain()
  while not queue.empty() do
    worker.step()
  end
end

function M.history(n)
  return log.tail(n or 10)
end

return M
EOF

git add lua/spool/log.lua lua/spool/init.lua

# UNSTAGED: a bugfix in the queue, worker logging, the deletion, docs, tests.
cat > lua/spool/queue.lua <<'EOF'
local M = {}

local jobs = {}

function M.push(job, opts)
  if type(job) ~= "function" then
    error("spool: job must be callable", 2)
  end
  jobs[#jobs + 1] = { run = job, tries = 0, opts = opts or {} }
  return #jobs
end

function M.pop()
  return table.remove(jobs, 1)
end

function M.empty()
  return #jobs == 0
end

function M.size()
  return #jobs
end

return M
EOF

cat > lua/spool/worker.lua <<'EOF'
local log = require("spool.log")
local queue = require("spool.queue")

local M = {}

function M.step()
  local job = queue.pop()
  if not job then
    return false
  end
  job.tries = job.tries + 1
  local ok, err = pcall(job.run)
  if not ok then
    log.record("failed", err)
  end
  return ok
end

return M
EOF

rm lua/spool/legacy.lua

cat > tests/queue_spec.lua <<'EOF'
local queue = require("spool.queue")

describe("queue", function()
  it("pops in insertion order", function()
    queue.push(function() end)
    queue.push(function() end)
    assert.equals(2, queue.size())
    queue.pop()
    assert.equals(1, queue.size())
  end)

  it("rejects non-callable jobs", function()
    assert.has_error(function()
      queue.push("not a job")
    end)
  end)
end)
EOF

cat > README.md <<'EOF'
# spool

A tiny job queue for Neovim plugins: enqueue functions, run them with
bounded concurrency, and observe progress.

## Usage

```lua
local spool = require("spool")
spool.enqueue(function() vim.print("hi") end, { name = "greet" })
spool.drain()
vim.print(spool.history())
```
EOF

echo "fixture ready: $dir"
