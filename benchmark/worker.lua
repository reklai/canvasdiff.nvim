-- One isolated eager-canvas measurement.
--
-- This file is intentionally launched by benchmark/run.lua in a fresh
-- `nvim --headless --clean` process. The coordinator sets every XDG directory
-- and NVIM_LOG_FILE before this process starts.

local uv = vim.uv

local function absolute(path)
  return vim.fn.fnamemodify(path, ":p"):gsub("/+$", "")
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(script))
local output_path = _G.arg and _G.arg[1] and absolute(_G.arg[1]) or nil
local fixture_root = _G.arg and _G.arg[2] and absolute(_G.arg[2]) or nil
local run_index = tonumber(_G.arg and _G.arg[3])
local git_executable = vim.env.CANVASDIFF_BENCH_GIT or "git"

local result = {
  schema_version = 1,
  benchmark = "canvasdiff.eager_small_open",
  run_index = run_index,
  status = "fail",
}

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1,
    "could not create directory: " .. path)
end

local function atomic_json(path, value)
  mkdir(vim.fs.dirname(path))
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local file = assert(io.open(temporary, "wb"))
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    file:close()
    vim.fn.delete(temporary)
    error("could not encode benchmark JSON: " .. tostring(encoded), 0)
  end
  file:write(encoded, "\n")
  assert(file:close())
  local renamed, rename_err = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(path, rename_err or "rename failed"), 0)
  end
end

local function read_all(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_all(path, content)
  mkdir(vim.fs.dirname(path))
  local file = assert(io.open(path, "wb"))
  file:write(content)
  assert(file:close())
end

local function command(cwd, arguments, environment)
  local completed = vim.system(arguments, {
    cwd = cwd,
    text = true,
    env = environment,
  }):wait()
  local signal = completed.signal
  assert(completed.code == 0 and (signal == nil or signal == 0), (
    "%s failed with exit %s signal %s\nstdout: %s\nstderr: %s"
  ):format(
    table.concat(arguments, " "),
    tostring(completed.code),
    tostring(signal),
    completed.stdout or "",
    completed.stderr or ""
  ))
  return (completed.stdout or ""):gsub("%s+$", "")
end

local function git(cwd, ...)
  local arguments = { git_executable }
  for index = 1, select("#", ...) do
    arguments[#arguments + 1] = select(index, ...)
  end
  return command(cwd, arguments)
end

local function tracked_path(index)
  return ("src/group_%02d/file_%03d.lua"):format(
    math.floor((index - 1) / 6) + 1,
    index
  )
end

local function tracked_content(file_index, changed)
  local lines = {}
  for line_index = 1, 120 do
    local value = file_index * 10000 + line_index
    local suffix = ""
    if changed and line_index % 12 == 0 then
      value = value + 900000
      suffix = " -- changed"
    end
    lines[#lines + 1] = (
      "local value_%03d_%03d = %d -- deterministic module %03d%s"
    ):format(file_index, line_index, value, file_index, suffix)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function untracked_path(index)
  return ("notes/generated_%02d.txt"):format(index)
end

local function untracked_content(index)
  local lines = {}
  for line_index = 1, 60 do
    lines[#lines + 1] = (
      "review note %02d/%03d: deterministic CanvasDiff eager baseline"
    ):format(index, line_index)
  end
  return table.concat(lines, "\n") .. "\n"
end

local function build_fixture(root)
  assert(vim.fn.isdirectory(root) == 0,
    "fixture path already exists: " .. root)
  mkdir(root)
  git(root, "init", "-b", "main")
  git(root, "config", "user.email", "benchmark@canvasdiff.invalid")
  git(root, "config", "user.name", "CanvasDiff Benchmark")

  local manifest = {}
  for index = 1, 36 do
    local path = tracked_path(index)
    local content = tracked_content(index, false)
    write_all(vim.fs.joinpath(root, path), content)
    manifest[#manifest + 1] = (
      "committed\0%s\0%s"
    ):format(path, vim.fn.sha256(content))
  end

  git(root, "add", "-A")
  command(root, {
    git_executable,
    "commit",
    "--date=2000-01-01T00:00:00Z",
    "-m",
    "deterministic eager benchmark fixture",
  }, {
    GIT_AUTHOR_DATE = "2000-01-01T00:00:00Z",
    GIT_COMMITTER_DATE = "2000-01-01T00:00:00Z",
  })
  local fixture_commit = git(root, "rev-parse", "HEAD")

  local expected_paths = {}
  for index = 1, 24 do
    local path = tracked_path(index)
    local content = tracked_content(index, true)
    write_all(vim.fs.joinpath(root, path), content)
    manifest[#manifest + 1] = (
      "worktree\0%s\0%s"
    ):format(path, vim.fn.sha256(content))
    expected_paths[#expected_paths + 1] = path
  end

  for index = 25, 28 do
    local path = tracked_path(index)
    local deleted = vim.fn.delete(vim.fs.joinpath(root, path))
    assert(deleted == 0, "could not delete fixture path: " .. path)
    manifest[#manifest + 1] = "deleted\0" .. path
    expected_paths[#expected_paths + 1] = path
  end

  for index = 1, 4 do
    local path = untracked_path(index)
    local content = untracked_content(index)
    write_all(vim.fs.joinpath(root, path), content)
    manifest[#manifest + 1] = (
      "untracked\0%s\0%s"
    ):format(path, vim.fn.sha256(content))
    expected_paths[#expected_paths + 1] = path
  end

  table.sort(expected_paths)
  table.sort(manifest)

  local porcelain = git(root, "status", "--porcelain=v1",
    "--untracked-files=all")
  local changed = 0
  for _ in porcelain:gmatch("[^\n]+") do
    changed = changed + 1
  end
  assert(changed == #expected_paths, (
    "fixture expected %d changed paths, git reported %d\n%s"
  ):format(#expected_paths, changed, porcelain))

  return {
    committed_files = 36,
    committed_lines_per_file = 120,
    modified_files = 24,
    deleted_files = 4,
    untracked_files = 4,
    untracked_lines_per_file = 60,
    expected_sections = #expected_paths,
    expected_paths = expected_paths,
    digest = vim.fn.sha256(table.concat(manifest, "\n")),
    fixture_commit = fixture_commit,
  }
end

local function finite_number(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
end

local function proc_status_bytes(field)
  local status = read_all("/proc/self/status")
  if not status then
    return nil
  end
  local pattern = field .. ":%s+(%d+)%s+kB"
  local kib = status:match("^" .. pattern)
    or status:match("\n" .. pattern)
  return kib and tonumber(kib) * 1024 or nil
end

local function memory_sampler()
  local rss_reader
  local rss_source
  if type(uv.resident_set_memory) == "function" then
    local ok, resident = pcall(uv.resident_set_memory)
    if ok and finite_number(resident) and resident > 0 then
      rss_source = "libuv.resident_set_memory"
      rss_reader = function()
        local read_ok, value = pcall(uv.resident_set_memory)
        assert(read_ok and finite_number(value) and value > 0,
          "libuv RSS capability failed after benchmark start")
        return value
      end
    end
  end
  if not rss_reader then
    local resident = proc_status_bytes("VmRSS")
    if finite_number(resident) and resident > 0 then
      rss_source = "procfs.VmRSS"
      rss_reader = function()
        local value = proc_status_bytes("VmRSS")
        assert(finite_number(value) and value > 0,
          "procfs RSS capability failed after benchmark start")
        return value
      end
    end
  end
  assert(rss_reader,
    "benchmark requires libuv resident_set_memory or /proc/self/status VmRSS")

  local observed_rss_max = 0
  local function rss()
    local value = rss_reader()
    observed_rss_max = math.max(observed_rss_max, value)
    return value
  end

  local hwm_source
  local hwm_fallback = false
  local hwm_reader
  local proc_hwm = proc_status_bytes("VmHWM")
  if finite_number(proc_hwm) and proc_hwm > 0 then
    hwm_source = "procfs.VmHWM"
    hwm_reader = function()
      local value = proc_status_bytes("VmHWM")
      assert(finite_number(value) and value > 0,
        "procfs high-water RSS capability failed after benchmark start")
      return value
    end
  else
    hwm_source = "sampled_rss_max"
    hwm_fallback = true
    hwm_reader = function()
      if observed_rss_max == 0 then
        rss()
      end
      return observed_rss_max
    end
  end

  -- Prove both selected paths before publishing a capability record.
  local initial_rss = rss()
  local initial_hwm = hwm_reader()
  assert(finite_number(initial_rss) and finite_number(initial_hwm),
    "memory capability returned a non-finite sample")

  return {
    rss = rss,
    hwm = hwm_reader,
    capabilities = {
      rss_source = rss_source,
      hwm_source = hwm_source,
      hwm_is_fallback = hwm_fallback,
    },
  }
end

local function lua_heap_bytes()
  return math.floor(collectgarbage("count") * 1024 + 0.5)
end

local function full_gc()
  collectgarbage("collect")
  collectgarbage("collect")
end

local function delta(after, before)
  return after - before
end

local function source_tree_snapshot()
  local completed = vim.system({
    git_executable,
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
  }, {
    cwd = repo_root,
    text = false,
  }):wait()
  local signal = completed.signal
  assert(completed.code == 0 and (signal == nil or signal == 0),
    ("could not enumerate benchmark source tree: exit=%s signal=%s %s"):format(
      tostring(completed.code),
      tostring(signal),
      completed.stderr or "git ls-files failed"
    ))

  local paths = {}
  for relative in (completed.stdout or ""):gmatch("([^%z]+)") do
    paths[#paths + 1] = relative
  end
  table.sort(paths)

  local records = {}
  for _, relative in ipairs(paths) do
    local path = vim.fs.joinpath(repo_root, relative)
    local stat = uv.fs_lstat(path)
    if not stat then
      records[#records + 1] = "missing\0" .. relative
    elseif stat.type == "file" then
      local content = assert(read_all(path),
        "could not read source-tree file: " .. relative)
      records[#records + 1] = (
        "file\0%s\0%s"
      ):format(relative, vim.fn.sha256(content))
    elseif stat.type == "link" then
      local target = assert(uv.fs_readlink(path),
        "could not read source-tree symlink: " .. relative)
      records[#records + 1] = (
        "link\0%s\0%s"
      ):format(relative, vim.fn.sha256(target))
    else
      records[#records + 1] = stat.type .. "\0" .. relative
    end
  end

  return {
    digest = vim.fn.sha256(table.concat(records, "\n")),
    entries = #records,
  }
end

local function environment()
  local uname = uv.os_uname()
  local cpu
  local cpuinfo = read_all("/proc/cpuinfo")
  if cpuinfo then
    cpu = cpuinfo:match("\nmodel name%s*:%s*([^\n]+)")
      or cpuinfo:match("^model name%s*:%s*([^\n]+)")
  end

  local revision = command(repo_root,
    { git_executable, "rev-parse", "HEAD" })
  local dirty = command(repo_root, {
    git_executable,
    "status",
    "--porcelain",
    "--untracked-files=normal",
  }) ~= ""
  local version = vim.version()
  local lua_version = _G.jit and jit.version or _VERSION
  local lua_os = _G.jit and jit.os or uname.sysname
  local lua_arch = _G.jit and jit.arch or uname.machine
  local git_version = command(repo_root, { git_executable, "--version" })
  local source_tree = source_tree_snapshot()

  local fingerprint_source = table.concat({
    uname.sysname or "",
    uname.release or "",
    uname.machine or "",
    cpu or "",
    ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    lua_version or "",
  }, "\0")

  return {
    git_revision = revision,
    git_dirty = dirty,
    nvim = ("%d.%d.%d"):format(version.major, version.minor, version.patch),
    lua = lua_version,
    lua_os = lua_os,
    lua_arch = lua_arch,
    os = uname.sysname,
    os_release = uname.release,
    machine = uname.machine,
    cpu = cpu,
    git = git_version,
    host_fingerprint = vim.fn.sha256(fingerprint_source),
    source_tree_digest = source_tree.digest,
    source_tree_entries = source_tree.entries,
  }
end

local function canvas_extmarks(buf)
  local counts = {}
  local total = 0
  for name, namespace in pairs(vim.api.nvim_get_namespaces()) do
    if name:sub(1, #"canvasdiff") == "canvasdiff" then
      local count = #vim.api.nvim_buf_get_extmarks(
        buf, namespace, 0, -1, {})
      counts[name] = count
      total = total + count
    end
  end
  return counts, total
end

-- Canvas buffers are per-review: one Surface owns one numbered canvas buffer,
-- so the name is a prefix plus that Surface's id rather than a fixed string.
-- The benchmark checks the observable name rather than calling the production
-- predicate, so that a change to how a canvas is identified still has to
-- survive an independent check here.
local CANVAS_BUFNAME_PREFIX = "canvasdiff://canvas/"

local function assert_canvas_identity(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  assert(name:sub(1, #CANVAS_BUFNAME_PREFIX) == CANVAS_BUFNAME_PREFIX
    and name:sub(#CANVAS_BUFNAME_PREFIX + 1):match("^%d+$") ~= nil,
    "the real :CanvasDiff open command did not enter the canvas buffer: " .. name)
  assert(vim.api.nvim_get_option_value("buftype", { buf = buf }) == "nofile",
    "canvas buffer lost buftype=nofile")
  assert(vim.api.nvim_get_option_value("modifiable", { buf = buf }) == false,
    "canvas buffer must be non-modifiable after eager render")
end

local function inspect_canvas(buf, corpus)
  assert_canvas_identity(buf)

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  assert(#lines == vim.api.nvim_buf_line_count(buf),
    "canvas line retrieval disagrees with buffer line count")
  assert(#lines > corpus.expected_sections,
    "ordinary fixture did not render section bodies")
  assert(#lines < 10000,
    "small eager fixture unexpectedly exceeded its bounded canvas size")

  local render = require("canvasdiff.canvas").format
  local header_prefix = render.glyphs.file .. " "
  local headers = 0
  for _, line in ipairs(lines) do
    if line:sub(1, #header_prefix) == header_prefix then
      headers = headers + 1
    end
  end
  assert(headers == corpus.expected_sections, (
    "expected %d file headers, rendered %d"
  ):format(corpus.expected_sections, headers))

  for _, path in ipairs(corpus.expected_paths) do
    local prefix = header_prefix .. render.escape_path(path) .. "  ("
    local found = 0
    for _, line in ipairs(lines) do
      if line:sub(1, #prefix) == prefix then
        found = found + 1
      end
    end
    assert(found == 1, (
      "expected one eager section for %s, found %d"
    ):format(path, found))
  end

  local namespaces, extmark_total = canvas_extmarks(buf)
  local anchors = namespaces["canvasdiff.canvas.anchors"] or 0
  assert(anchors == corpus.expected_sections + 1, (
    "expected %d section/EOF anchors, found %d"
  ):format(corpus.expected_sections + 1, anchors))
  assert(extmark_total > anchors,
    "eager canvas did not install its line-tier extmarks")

  -- Canvas buffers are per-review now, so this counts the prefix rather than a
  -- fixed name. One open must still leave exactly one behind: more would mean
  -- a Surface leaked a buffer, and none would mean the name changed under us.
  local canvas_buffers = 0
  for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_valid(candidate)
      and vim.api.nvim_buf_get_name(candidate) or ""
    if name:sub(1, #CANVAS_BUFNAME_PREFIX) == CANVAS_BUFNAME_PREFIX then
      canvas_buffers = canvas_buffers + 1
    end
  end
  assert(canvas_buffers == 1, (
    "one open must leave exactly one canvas buffer, found %d"
  ):format(canvas_buffers))

  return {
    buf = buf,
    rendered_rows = #lines,
    rendered_headers = headers,
    canvas_buffers = canvas_buffers,
    extmarks_total = extmark_total,
    extmarks_by_namespace = namespaces,
    first_row_sha256 = vim.fn.sha256(lines[1] or ""),
    last_row_sha256 = vim.fn.sha256(lines[#lines] or ""),
    rendered_sha256 = vim.fn.sha256(table.concat(lines, "\0")),
  }
end

local function assert_closed_canvas(canvas_buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assert(vim.api.nvim_win_get_buf(win) ~= canvas_buf,
      ":CanvasDiff close left a window displaying the eager canvas")
  end
  assert(vim.api.nvim_buf_is_valid(canvas_buf),
    "close unexpectedly destroyed the reusable canvas buffer")
  assert(vim.api.nvim_get_option_value("modifiable", { buf = canvas_buf }) == false,
    "close left the hidden canvas modifiable")
end

local ok, failure = xpcall(function()
  assert(output_path, "worker requires an output JSON path")
  assert(fixture_root, "worker requires an isolated fixture path")
  assert(run_index and run_index == math.floor(run_index) and run_index >= 1,
    "worker requires a positive integer run index")

  result.environment = environment()
  local memory = memory_sampler()
  result.capabilities = {
    memory = memory.capabilities,
  }
  result.profile = {
    name = "eager-core-v1",
    command = ":CanvasDiff open",
    optional_controllers = {
      highlight = false,
      watch = false,
      sidebar = false,
      scrollbar = false,
      statuscolumn = false,
      virtualizer = false,
      session = false,
    },
  }

  result.corpus = build_fixture(fixture_root)
  vim.api.nvim_set_current_dir(fixture_root)
  vim.cmd("enew")

  vim.opt.runtimepath:prepend(repo_root)
  vim.cmd("runtime plugin/canvasdiff.lua")
  assert(vim.fn.exists(":CanvasDiff") == 2,
    "repository plugin entrypoint did not register :CanvasDiff")

  require("canvasdiff").setup({
    highlight = { enabled = false },
    watch = { enabled = false },
    sidebar = { enabled = false },
    scrollbar = { enabled = false },
    statuscolumn = { enabled = false },
    virt = { enabled = false },
    session = { enabled = false },
  })

  full_gc()
  local heap_before = lua_heap_bytes()
  local rss_before = memory.rss()
  local hwm_before = memory.hwm()

  local open_started = uv.hrtime()
  vim.cmd("CanvasDiff open")
  vim.cmd("redraw")
  local open_wall_ns = uv.hrtime() - open_started

  -- Keep all allocation-heavy correctness work after the final measurement.
  -- These three API reads establish only that the command reached the intended
  -- buffer and left it in the required projection-safe state.
  local canvas_buf = vim.api.nvim_get_current_buf()
  assert_canvas_identity(canvas_buf)
  local rss_after_open = memory.rss()
  local hwm_after_open = memory.hwm()
  local heap_after_open = lua_heap_bytes()

  full_gc()
  local heap_retained = lua_heap_bytes()
  local rss_after_open_gc = memory.rss()

  local close_started = uv.hrtime()
  vim.cmd("CanvasDiff close")
  local close_wall_ns = uv.hrtime() - close_started
  full_gc()
  local heap_after_close = lua_heap_bytes()
  local rss_after_close = memory.rss()

  -- The reusable eager buffer remains valid and hidden after close, so exact
  -- row/extmark verification can run now without contaminating any metric.
  local correctness = inspect_canvas(canvas_buf, result.corpus)
  assert_closed_canvas(canvas_buf)

  result.correctness = {
    command_registered = true,
    canvas_name = "canvasdiff://canvas",
    expected_sections = result.corpus.expected_sections,
    rendered_rows = correctness.rendered_rows,
    rendered_headers = correctness.rendered_headers,
    canvas_buffers = correctness.canvas_buffers,
    extmarks_total = correctness.extmarks_total,
    extmarks_by_namespace = correctness.extmarks_by_namespace,
    first_row_sha256 = correctness.first_row_sha256,
    last_row_sha256 = correctness.last_row_sha256,
    rendered_sha256 = correctness.rendered_sha256,
    close_removed_all_views = true,
  }
  result.metrics = {
    open_wall_ns = open_wall_ns,
    close_wall_ns = close_wall_ns,
    rss_before_bytes = rss_before,
    rss_after_open_bytes = rss_after_open,
    rss_after_open_gc_bytes = rss_after_open_gc,
    rss_after_close_bytes = rss_after_close,
    rss_open_delta_bytes = delta(rss_after_open, rss_before),
    rss_retained_delta_bytes = delta(rss_after_open_gc, rss_before),
    rss_after_close_delta_bytes = delta(rss_after_close, rss_before),
    rss_hwm_before_bytes = hwm_before,
    rss_hwm_after_open_bytes = hwm_after_open,
    rss_hwm_delta_bytes = delta(hwm_after_open, hwm_before),
    lua_heap_before_bytes = heap_before,
    lua_heap_after_open_bytes = heap_after_open,
    lua_heap_retained_bytes = heap_retained,
    lua_heap_after_close_bytes = heap_after_close,
    lua_heap_open_delta_bytes = delta(heap_after_open, heap_before),
    lua_heap_retained_delta_bytes = delta(heap_retained, heap_before),
    lua_heap_after_close_delta_bytes = delta(heap_after_close, heap_before),
  }
  result.status = "pass"
end, debug.traceback)

if not ok then
  result.error = tostring(failure)
end

local wrote, write_error = pcall(atomic_json, assert(output_path), result)
if not wrote then
  io.stderr:write("CanvasDiff eager benchmark could not write result: ",
    tostring(write_error), "\n")
  os.exit(1)
end

if ok then
  print("CanvasDiff eager worker result: " .. output_path)
  os.exit(0)
else
  io.stderr:write("CanvasDiff eager benchmark failed: ",
    tostring(failure), "\n")
  os.exit(1)
end
