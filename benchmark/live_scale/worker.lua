-- One isolated live-scale CanvasDiff replay.
--
-- Usage:
--   nvim --headless --clean -n -i NONE -l benchmark/live_scale/worker.lua \
--     OUTPUT FIXTURE_ROOT ROWS SEED RUN_INDEX
--
-- The coordinator gives this process an existing, empty, unique FIXTURE_ROOT.
-- This worker owns the complete fixture/App lifetime so fixture.cleanup sees
-- the same module-private ownership capability created by fixture.build.

local uv = vim.uv
local API = vim.api
local unpack = table.unpack or unpack
local function pack(...)
  return { n = select("#", ...), ... }
end

local SCHEMA = "canvasdiff.live_scale.worker/v1"
local HEARTBEAT_MS = 10
local RESOURCE_GROUPS = {
  "canvasdiff.watch",
  "canvasdiff.virt",
  "canvasdiff.highlight",
  "canvasdiff.status_column",
  "canvasdiff.sidebar",
  "canvasdiff.scrollbar",
  "canvasdiff.session",
  "canvasdiff.close",
  "canvasdiff.winbar",
}

local function absolute(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local resolved = vim.fn.fnamemodify(path, ":p")
  if resolved ~= "/" then
    resolved = resolved:gsub("/+$", "")
  end
  return resolved
end

local script = absolute(debug.getinfo(1, "S").source:sub(2))
local repo_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(script)))
vim.opt.runtimepath:prepend(repo_root)

local argv = _G.arg or {}
local output_path = absolute(argv[1])
local fixture_root = absolute(argv[2])
local rows = tonumber(argv[3])
local seed = tonumber(argv[4])
local run_index = tonumber(argv[5])

local result = {
  schema = SCHEMA,
  status = "fail",
  rows = rows,
  seed = seed,
  run_index = run_index,
  phases = {},
  trace = {},
  adapters = {
    git = {},
    source = {},
  },
  correctness = {
    content = {
      disk_exact = false,
      model_exact = false,
      ui_exact = false,
    },
    lenses = {
      preserved = true,
      observations = {},
    },
    projection = {
      preserved = true,
      samples = 0,
    },
    index = {
      stage_exact = false,
      unstage_exact = false,
      primary_absent = true,
      paths_exact = true,
    },
    refs = {
      branch_exact = false,
      range_exact = false,
    },
    git_failure = {
      caught = false,
    },
  },
  heartbeat = {
    interval_ms = HEARTBEAT_MS,
    scope = "plugin_operations",
    started_after_fixture = false,
    ticks = 0,
    max_gap_ns = 0,
    operation_windows = 0,
  },
  memory = {
    samples = {},
  },
  capabilities = {},
  paging = {
    mode = "unobserved",
    cache = {
      available = false,
    },
  },
  extmarks = {
    during = 0,
    after = 0,
  },
  cleanup = {
    fixture_cleanup_attempted = false,
    fixture_removed = false,
    canvas_windows = -1,
    open_timers = -1,
    wrappers_restored = false,
    owned_groups = {},
    checked_group_prefixes = vim.deepcopy(RESOURCE_GROUPS),
  },
}

local function now_ns()
  return uv.hrtime()
end

local function finite_integer(value)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value == math.floor(value)
end

local function atomic_json(path, value)
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local encoded_ok, encoded = pcall(vim.json.encode, value)
  if not encoded_ok then
    error("could not encode live-scale worker JSON: " .. tostring(encoded), 0)
  end
  local descriptor, open_error = uv.fs_open(temporary, "wx", 384)
  assert(descriptor, ("could not exclusively create %s: %s"):format(
    temporary, tostring(open_error)))
  local written, write_error = uv.fs_write(descriptor, encoded .. "\n", -1)
  local closed, close_error = uv.fs_close(descriptor)
  if not written or not closed then
    vim.fn.delete(temporary)
    error(("could not write %s: %s%s"):format(
      temporary, tostring(write_error or ""), tostring(close_error or "")), 0)
  end
  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(
      path, rename_error or "rename failed"), 0)
  end
end

local function path_within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function reserve_output()
  assert(output_path, "worker requires OUTPUT")
  assert(fixture_root, "worker requires FIXTURE_ROOT")
  assert(output_path ~= fixture_root, "OUTPUT must differ from FIXTURE_ROOT")
  assert(not path_within(output_path, repo_root),
    "OUTPUT must be outside the repository")
  assert(not path_within(output_path, fixture_root),
    "OUTPUT must be outside FIXTURE_ROOT")
  local owner_root = vim.fs.dirname(fixture_root)
  assert(vim.fs.dirname(output_path) == owner_root,
    "OUTPUT must be in the coordinator-owned fixture parent")
  assert(uv.fs_realpath(owner_root) == owner_root,
    "coordinator-owned parent must be an exact real path")
  assert(uv.fs_lstat(output_path) == nil, "OUTPUT must not already exist")
  local descriptor, open_error = uv.fs_open(output_path, "wx", 384)
  assert(descriptor, "could not reserve OUTPUT exclusively: " .. tostring(open_error))
  assert(uv.fs_close(descriptor))
end

local function read_all(path)
  local file, open_error = io.open(path, "rb")
  if not file then
    return nil, tostring(open_error)
  end
  local content = file:read("*a")
  local closed, close_error = file:close()
  if content == nil then
    return nil, "could not read " .. path
  end
  if not closed then
    return nil, tostring(close_error)
  end
  return content
end

local function write_all(path, content)
  local file, open_error = io.open(path, "wb")
  assert(file, tostring(open_error))
  assert(file:write(content))
  assert(file:close())
end

local function proc_status_bytes(field)
  local content = read_all("/proc/self/status")
  if not content then
    return nil
  end
  local value = content:match("^" .. field .. ":%s+(%d+)%s+kB")
    or content:match("\n" .. field .. ":%s+(%d+)%s+kB")
  return value and tonumber(value) * 1024 or nil
end

local observed_rss_max = 0
local rss_reader
do
  if type(uv.resident_set_memory) == "function" then
    local ok, bytes = pcall(uv.resident_set_memory)
    if ok and type(bytes) == "number" and bytes > 0 then
      result.capabilities.rss_source = "libuv.resident_set_memory"
      rss_reader = function()
        local read_ok, value = pcall(uv.resident_set_memory)
        return read_ok and type(value) == "number" and value > 0 and value or nil
      end
    end
  end
  if not rss_reader and proc_status_bytes("VmRSS") then
    result.capabilities.rss_source = "procfs.VmRSS"
    rss_reader = function()
      return proc_status_bytes("VmRSS")
    end
  end
  if not rss_reader then
    result.capabilities.rss_source = "unavailable"
    rss_reader = function()
      return nil
    end
  end
end

local hwm_reader
if proc_status_bytes("VmHWM") then
  result.capabilities.hwm_source = "procfs.VmHWM"
  hwm_reader = function()
    return proc_status_bytes("VmHWM")
  end
else
  result.capabilities.hwm_source = "sampled_rss_max"
  hwm_reader = function()
    return observed_rss_max > 0 and observed_rss_max or nil
  end
end
result.capabilities.paged_canvas = true
result.capabilities.procfs = vim.fn.filereadable("/proc/self/status") == 1

local function sample_memory(name)
  local rss = rss_reader()
  if rss then
    observed_rss_max = math.max(observed_rss_max, rss)
  end
  result.memory.samples[#result.memory.samples + 1] = {
    name = name,
    heap_bytes = collectgarbage("count") * 1024,
    rss_bytes = rss,
    hwm_bytes = hwm_reader(),
  }
end

local function phase(name, callback)
  local started = now_ns()
  local packed = pack(xpcall(callback, debug.traceback))
  local sample = {
    name = name,
    elapsed_ns = now_ns() - started,
    status = packed[1] and "ok" or "fail",
  }
  if not packed[1] then
    sample.error = tostring(packed[2])
  end
  result.phases[#result.phases + 1] = sample
  if not packed[1] then
    error(packed[2], 0)
  end
  return unpack(packed, 2, packed.n)
end

local function count_extmarks(buffer)
  if not (buffer and API.nvim_buf_is_valid(buffer)) then
    return 0
  end
  local total = 0
  for _, namespace in pairs(API.nvim_get_namespaces()) do
    local ok, marks = pcall(
      API.nvim_buf_get_extmarks, buffer, namespace, 0, -1, {})
    if ok then
      total = total + #marks
    end
  end
  return total
end

local function controller_groups()
  local groups, seen = {}, {}
  for _, autocmd in ipairs(API.nvim_get_autocmds({})) do
    local name = autocmd.group_name
    if name then
      for _, prefix in ipairs(RESOURCE_GROUPS) do
        if name == prefix
            or name:sub(1, #prefix + 1) == prefix .. "." then
          if not seen[name] then
            seen[name] = true
            groups[#groups + 1] = name
          end
          break
        end
      end
    end
  end
  table.sort(groups)
  return groups
end

local fixture = require("benchmark.live_scale.fixture")
local actions = require("benchmark.live_scale.actions")
local manifest
local fm
local source
local system
local canvas
local input
local lens
local state
local tracked_timers = {}
local installed_wrappers = {}
local heartbeat_timer
local heartbeat_last_ns
local heartbeat_running = false
local current_measurement
local original_uv_new_timer = uv.new_timer
local original_set_extmark = API.nvim_buf_set_extmark
local projection_capture = {}
local git_executable = vim.fn.exepath("git")
local fixture_build_started = false
local resident_observation

local function track_timer(timer, owner)
  if timer then
    tracked_timers[timer] = tracked_timers[timer] or owner
  end
  return timer
end

local function timer_is_open(timer)
  local ok, closing = pcall(function()
    return timer:is_closing()
  end)
  return not ok or not closing
end

local function git_category(command)
  if type(command) ~= "table" then
    return "unknown"
  end
  local index = 2
  if command[index] == "-C" then
    index = index + 2
  end
  while type(command[index]) == "string"
      and command[index]:sub(1, 1) == "-" do
    index = index + 1
  end
  return command[index] or "unknown"
end

local function install_wrapper(target, name, samples, describe)
  local original = assert(type(target[name]) == "function" and target[name],
    "adapter target is not callable: " .. name)
  local wrapper
  wrapper = function(...)
    local started = now_ns()
    local packed = pack(pcall(original, ...))
    local sample = describe and describe(...) or {}
    sample.elapsed_ns = now_ns() - started
    sample.status = packed[1] and "ok" or "error"
    if packed[1] then
      local first = packed[2]
      if type(first) == "table" and type(first.code) == "number" then
        sample.exit_code = first.code
      end
    else
      sample.error = tostring(packed[2])
    end
    samples[#samples + 1] = sample
    if not packed[1] then
      error(packed[2], 0)
    end
    return unpack(packed, 2, packed.n)
  end
  target[name] = wrapper
  installed_wrappers[#installed_wrappers + 1] = {
    target = target,
    name = name,
    original = original,
    wrapper = wrapper,
  }
end

local function restore_wrappers()
  local restored = true
  for index = #installed_wrappers, 1, -1 do
    local item = installed_wrappers[index]
    if item.target[item.name] ~= item.wrapper then
      restored = false
    end
    item.target[item.name] = item.original
  end
  if uv.new_timer ~= original_uv_new_timer then
    if not installed_wrappers._uv_timer_wrapper
        or uv.new_timer ~= installed_wrappers._uv_timer_wrapper then
      restored = false
    end
    uv.new_timer = original_uv_new_timer
  end
  if API.nvim_buf_set_extmark ~= original_set_extmark then
    if not installed_wrappers._set_extmark_wrapper
        or API.nvim_buf_set_extmark ~= installed_wrappers._set_extmark_wrapper then
      restored = false
    end
    API.nvim_buf_set_extmark = original_set_extmark
  end
  return restored
end

local function install_adapters()
  -- Track raw timers before loading App: the highlighter allocates directly
  -- from libuv, while the other controllers allocate through canvasdiff.os.
  local uv_timer_wrapper = function(...)
    return track_timer(original_uv_new_timer(...), "canvasdiff")
  end
  installed_wrappers._uv_timer_wrapper = uv_timer_wrapper
  uv.new_timer = uv_timer_wrapper

  -- Projection captures this API function at module load. Keep a narrowly
  -- scoped observation seam so paged redraws can be checked against bytes
  -- generated independently by the benchmark.
  local set_extmark_wrapper = function(buffer, namespace, row, column, opts)
    if projection_capture.active
        and projection_capture.buffer == buffer
        and projection_capture.row == row
        and type(opts) == "table"
        and opts.ephemeral == true
        and type(opts.virt_text) == "table"
        and type(opts.virt_text[1]) == "table" then
      projection_capture.actual = opts.virt_text[1][1]
    end
    return original_set_extmark(buffer, namespace, row, column, opts)
  end
  installed_wrappers._set_extmark_wrapper = set_extmark_wrapper
  API.nvim_buf_set_extmark = set_extmark_wrapper

  -- Raw OS process timing is installed first. source.repository keeps this
  -- facade table, so replacing the method before loading the source facade is
  -- the seam every later Git command crosses.
  system = require("canvasdiff.os")
  install_wrapper(system, "run", result.adapters.git, function(command)
    return {
      category = git_category(command),
      argv = type(command) == "table" and vim.deepcopy(command) or {},
    }
  end)

  -- Load and wrap the source facade before App captures it.
  source = require("canvasdiff.source")
  for _, name in ipairs({
    "root", "sections", "changed_files", "stage", "unstage",
  }) do
    install_wrapper(source, name, result.adapters.source, function()
      return { name = name }
    end)
  end
end

local function start_heartbeat_window()
  assert(heartbeat_timer, "heartbeat is unavailable")
  heartbeat_last_ns = now_ns()
  heartbeat_timer:start(HEARTBEAT_MS, HEARTBEAT_MS, function()
    local at = now_ns()
    local gap = at - heartbeat_last_ns
    heartbeat_last_ns = at
    result.heartbeat.ticks = result.heartbeat.ticks + 1
    result.heartbeat.max_gap_ns = math.max(result.heartbeat.max_gap_ns, gap)
  end)
  heartbeat_running = true
  result.heartbeat.operation_windows = result.heartbeat.operation_windows + 1
end

local function stop_heartbeat_window()
  if heartbeat_timer and heartbeat_running then
    heartbeat_timer:stop()
  end
  heartbeat_running = false
  heartbeat_last_ns = nil
end

local function operation(callback, label)
  assert(current_measurement, "plugin operation executed outside an action")
  start_heartbeat_window()
  local started = now_ns()
  local packed = pack(xpcall(callback, debug.traceback))
  local elapsed = now_ns() - started
  current_measurement.operation_ns =
    current_measurement.operation_ns + elapsed
  current_measurement.operation_count =
    current_measurement.operation_count + 1
  if label == "first_view" then
    assert(current_measurement.first_view_ns == nil,
      "first-view operation was measured more than once")
    current_measurement.first_view_ns = elapsed
  end
  -- Establish a real event-loop observation once without charging the wait to
  -- plugin operation latency. Later windows only observe naturally due work.
  if result.heartbeat.ticks == 0 then
    vim.wait(HEARTBEAT_MS + 2, function()
      return result.heartbeat.ticks > 0
    end, 1)
  else
    vim.wait(0)
  end
  stop_heartbeat_window()
  if not packed[1] then
    error(packed[2], 0)
  end
  return unpack(packed, 2, packed.n)
end

local function direct_git(...)
  assert(git_executable ~= "", "Git executable is unavailable")
  local command = { git_executable, "-C", fixture_root }
  for index = 1, select("#", ...) do
    command[#command + 1] = select(index, ...)
  end
  local completed = vim.system(command, {
    cwd = fixture_root,
    text = false,
  }):wait()
  if completed.code ~= 0 then
    return nil, ("direct Git failed: argv=%s code=%s stderr=%s"):format(
      vim.inspect(command), tostring(completed.code),
      tostring(completed.stderr or ""))
  end
  return completed.stdout or ""
end

local function must_git(...)
  local output, err = direct_git(...)
  assert(output ~= nil, err)
  return output
end

local function verify_generated_text(text)
  if type(text) ~= "string" then
    return false, "primary model text is unavailable"
  end
  local offset = 1
  for index = 1, manifest.rows do
    local expected = ("scale %d seed %d\n"):format(index, manifest.seed)
    if text:sub(offset, offset + #expected - 1) ~= expected then
      return false, ("primary bytes differ at generated row %d"):format(index)
    end
    offset = offset + #expected
  end
  if offset ~= #text + 1 then
    return false, "primary model text contains trailing bytes"
  end
  return true
end

local function verify_generated_file(path)
  local file, open_error = io.open(path, "rb")
  if not file then
    return false, tostring(open_error)
  end
  for index = 1, manifest.rows do
    local actual = file:read("*l")
    local expected = ("scale %d seed %d"):format(index, manifest.seed)
    if actual ~= expected then
      file:close()
      return false, ("primary disk bytes differ at generated row %d"):format(index)
    end
  end
  if file:read(1) ~= nil then
    file:close()
    return false, "primary disk file contains trailing bytes"
  end
  local size = assert(file:seek("end"))
  if size == 0 then
    file:close()
    return false, "primary disk file is empty"
  end
  assert(file:seek("set", size - 1))
  local last = file:read(1)
  assert(file:close())
  if last ~= "\n" then
    return false, "primary disk file has no terminal newline"
  end
  return true
end

local function section_by_path(path)
  assert(state and type(state.sections) == "table",
    "no active CanvasDiff model")
  for index, section in ipairs(state.sections) do
    if section.path == path then
      return index, section
    end
  end
  return nil
end

local function current_lens_id()
  return state and lens.of(state).id or nil
end

local function observe_lens(expected, label)
  local actual = current_lens_id()
  result.correctness.lenses.observations[
    #result.correctness.lenses.observations + 1] = {
    label = label,
    expected = expected,
    actual = actual,
  }
  if actual ~= expected then
    result.correctness.lenses.preserved = false
  end
  assert(actual == expected, (
    "%s lens mismatch: expected %s got %s"
  ):format(label, expected, tostring(actual)))
end

local function set_lens_named(name, label)
  local changed, err = operation(function()
    return fm.set_lens(assert(lens.get(name)))
  end)
  assert(changed, err or ("could not select " .. name))
  observe_lens(name, label)
end

local function primary_logical_row(row)
  local section_index, section = section_by_path(manifest.primary_path)
  assert(section_index, "primary section is absent from the active lens")
  local layout = rawget(section, "_live_scale_layout")
  if not layout then
    for index, entry in ipairs(section.entries or {}) do
      if entry.new_lnum ~= nil then
        layout = {
          entry_index = index,
          new_lnum = entry.new_lnum,
        }
        break
      end
    end
    -- Benchmark-only memoization on the worker-owned model keeps 200 random
    -- jumps O(actions), rather than rescanning a million entries per jump.
    section._live_scale_layout = layout
  end
  local entry_index = layout
    and layout.entry_index + row - layout.new_lnum
    or nil
  local entry = entry_index and section.entries[entry_index] or nil
  if not entry or entry.new_lnum ~= row then
    entry_index = nil
    for index, candidate in ipairs(section.entries or {}) do
      if candidate.new_lnum == row then
        entry_index = index
        break
      end
    end
  end
  assert(entry_index, ("primary row %d has no rendered entry"):format(row))
  local start0 = assert(canvas.section_rows(state, section_index))
  return start0 + entry_index - 1, section
end

local function move_to_primary_row(row)
  local logical0 = primary_logical_row(row)
  local win = assert(state.win)
  assert(API.nvim_win_is_valid(win), "primary CanvasDiff window is invalid")
  local expected = ("+scale %d seed %d"):format(row, manifest.seed)
  projection_capture.active = state.paged ~= nil
  projection_capture.buffer = state.buf
  projection_capture.row = logical0
  projection_capture.actual = nil
  operation(function()
    API.nvim_set_current_win(win)
    API.nvim_win_set_cursor(win, { logical0 + 1, 0 })
    API.nvim_win_call(win, function()
      vim.cmd("normal! zt")
    end)
    local touched, touch_error = canvas.touch(state)
    assert(touched, touch_error)
    if state.paged and state.paged.projection then
      local drawn, draw_error = state.paged.projection:redraw()
      assert(drawn, draw_error)
    else
      vim.cmd("redraw")
    end
  end)
  projection_capture.active = false
  local actual
  if state.paged then
    actual = projection_capture.actual
  else
    actual = API.nvim_buf_get_lines(
      state.buf, logical0, logical0 + 1, false)[1]
  end
  local exact = actual == expected
  result.correctness.projection.samples =
    result.correctness.projection.samples + 1
  if not exact then
    result.correctness.projection.preserved = false
  end
  assert(exact, "visible projection differs from generated primary row")
  return logical0, {
    sampled = true,
    mode = state.paged and "paged" or "eager",
    logical_row = logical0,
    expected = expected,
    actual = actual,
    exact = exact,
  }
end

local function sample_paged_resident(label, navigation)
  if not (state and state.paged and state.paged.list) then
    return true
  end
  local current, resident_error = state.paged.list:resident_stats()
  assert(current, resident_error)
  if not resident_observation then
    resident_observation = {
      pages = 0,
      bytes = 0,
      max_pages = current.max_pages,
      max_bytes = current.max_bytes,
      samples = 0,
      navigation_samples = 0,
      scope = "live_after_first_view_and_actions",
      first_sample = label,
    }
  end
  assert(current.max_pages == resident_observation.max_pages
      and current.max_bytes == resident_observation.max_bytes,
    "paged resident limits changed during replay")
  resident_observation.pages =
    math.max(resident_observation.pages, current.pages)
  resident_observation.bytes =
    math.max(resident_observation.bytes, current.bytes)
  resident_observation.samples = resident_observation.samples + 1
  if navigation then
    resident_observation.navigation_samples =
      resident_observation.navigation_samples + 1
  end
  resident_observation.last_sample = label
  if result.paging.mode == "paged" then
    result.paging.cache.resident = resident_observation
  end
  return true
end

local function observe_paging()
  local logical = canvas.logical(state)
  local row_count = logical.row_count()
  if state.paged then
    local cache = state.paged.list and state.paged.list:stats() or {
      available = false,
    }
    cache.available = state.paged.list ~= nil
    result.paging = {
      mode = "paged",
      logical_rows = row_count,
      cache = cache,
      projection = state.paged.projection and state.paged.projection:stats() or {},
      scheduler = state.paged.scheduler and state.paged.scheduler:stats() or {},
    }
    assert(sample_paged_resident("open_first_view", false))
  else
    result.paging = {
      mode = "eager",
      logical_rows = row_count,
      buffer_rows = API.nvim_buf_line_count(state.buf),
      cache = {
        available = false,
        page_count = 0,
      },
    }
  end
  result.extmarks.during = count_extmarks(state.buf)
end

local function observe_initial_content()
  local primary_path = vim.fs.joinpath(fixture_root, manifest.primary_path)
  local disk_ok, disk_error = verify_generated_file(primary_path)
  assert(disk_ok, disk_error)
  result.correctness.content.disk_exact = true

  local _, primary = section_by_path(manifest.primary_path)
  assert(primary, "primary section is absent after open")
  local model_ok, model_error = verify_generated_text(primary.new_text)
  assert(model_ok, model_error)
  result.correctness.content.model_exact = true

  local logical = canvas.logical(state)
  local first0 = primary_logical_row(1)
  local last0 = primary_logical_row(manifest.rows)
  local first = assert(logical.row(first0))
  local last = assert(logical.row(last0))
  assert(first == "+" .. manifest.first_line,
    "first rendered primary row does not match the manifest")
  assert(last == "+" .. manifest.last_line,
    "last rendered primary row does not match the manifest")
  result.correctness.content.ui_exact = true
end

local function open_named(name, label)
  local opened, err = operation(function()
    return fm.open({ lens = assert(lens.get(name)) })
  end)
  assert(opened, err)
  state = opened
  observe_lens(name, label)
  return opened
end

local function canvas_windows()
  local windows = {}
  if not canvas then
    return windows
  end
  for _, win in ipairs(API.nvim_list_wins()) do
    local ok, buffer = pcall(API.nvim_win_get_buf, win)
    if ok and canvas.is_canvas_buf(buffer) then
      windows[#windows + 1] = win
    end
  end
  return windows
end

local handlers = {}

handlers.open = function()
  state = assert(operation(function()
    return fm.open({ lens = assert(lens.get("all")) })
  end))
  operation(function()
    vim.cmd("redraw")
  end, "first_view")
  observe_lens("all", "open")
  observe_initial_content()
  observe_paging()
  return {
    content_exact = true,
    lens = current_lens_id(),
    sections = #state.sections,
    paged = state.paged ~= nil,
  }
end

handlers.sequential_scroll = function(arguments)
  local logical0, projection = move_to_primary_row(arguments.row)
  return {
    requested_row = arguments.row,
    logical_row = logical0,
    cursor_row = API.nvim_win_get_cursor(state.win)[1],
    destination_exact = API.nvim_win_get_cursor(state.win)[1] == logical0 + 1,
    projection = projection,
  }
end

handlers.random_jump = handlers.sequential_scroll

handlers.search = function(arguments)
  local found0 = operation(function()
    if state.paged then
      local found = assert(canvas.paged.search(state.paged, arguments.query, {
        from0 = 0,
        wrap = true,
      }))
      API.nvim_win_set_cursor(state.win, { found + 1, 0 })
      return found
    end
    local found = API.nvim_win_call(state.win, function()
      API.nvim_win_set_cursor(state.win, { 1, 0 })
      local found1 = vim.fn.search(arguments.query, "W")
      return found1 > 0 and found1 - 1 or nil
    end)
    assert(found, "eager canvas search found no match")
    return found
  end)
  local text = assert(canvas.logical(state).row(found0))
  assert(text:find(arguments.query, 1, true),
    "search landed on a row without the query")
  return {
    query = arguments.query,
    logical_row = found0,
    destination_exact = true,
  }
end

handlers.yank = function(arguments)
  local start0 = primary_logical_row(arguments.start_row)
  local end0 = primary_logical_row(arguments.end_row)
  local count = end0 - start0 + 1
  local text, err
  operation(function()
    if state.paged then
      text, err = canvas.paged.yank(state.paged, start0, count, {
        register = '"',
      })
    else
      text, err = canvas.logical(state).export(start0, count, {
        terminal_eol = true,
      })
      if text then
        vim.fn.setreg('"', text, "V")
      end
    end
  end)
  assert(text, err)
  local expected_parts = {}
  for row = arguments.start_row, arguments.end_row do
    expected_parts[#expected_parts + 1] =
      ("+scale %d seed %d\n"):format(row, manifest.seed)
  end
  local expected = table.concat(expected_parts)
  assert(text == expected, "yank bytes differ from independent generation")
  assert(vim.fn.getreg('"') == text, "yank register does not match exported text")
  return {
    logical_start = start0,
    logical_count = count,
    bytes = #text,
    exact = true,
  }
end

local unfolded_layout
local function layout_snapshot()
  local snapshot = {
    row_count = canvas.logical(state).row_count(),
    sections = {},
  }
  for index, section in ipairs(state.sections) do
    snapshot.sections[index] = {
      path = section.path,
      start0 = canvas.section_rows(state, index),
      entries = #section.entries,
    }
  end
  return snapshot
end

handlers.fold = function()
  local section_index, section = section_by_path(manifest.primary_path)
  assert(section_index)
  local before = canvas.logical(state).row_count()
  unfolded_layout = layout_snapshot()
  operation(function()
    canvas.set_collapsed(state, section_index, true, "user", state.win)
  end)
  assert(state.collapsed[section.path] == "user",
    "fold did not record user ownership")
  local after = canvas.logical(state).row_count()
  assert(after < before, "fold did not strictly reduce the logical canvas")
  return {
    before_rows = before,
    after_rows = after,
    path = section.path,
    reduced = true,
  }
end

handlers.unfold = function()
  local section_index, section = section_by_path(manifest.primary_path)
  assert(section_index)
  operation(function()
    canvas.set_collapsed(state, section_index, false, "user", state.win)
  end)
  assert(state.collapsed[section.path] == nil,
    "unfold retained the collapsed identity")
  local logical0 = primary_logical_row(1)
  local restored = vim.deep_equal(layout_snapshot(), unfolded_layout)
  assert(restored, "unfold did not restore the exact logical layout")
  return {
    logical_row = logical0,
    path = section.path,
    restored = restored,
  }
end

handlers.cycle_all = function()
  set_lens_named("all", "cycle_all")
  return { lens = current_lens_id(), lens_exact = true }
end

handlers.cycle_staged = function()
  set_lens_named("staged", "cycle_staged")
  return { lens = current_lens_id(), lens_exact = true }
end

handlers.cycle_unstaged = function()
  set_lens_named("unstaged", "cycle_unstaged")
  return { lens = current_lens_id(), lens_exact = true }
end

local refresh_sequence = 0
local function expected_sidecar_bytes(kind)
  refresh_sequence = refresh_sequence + 1
  return ("unstaged %s seed %d run %d refresh %d\n"):format(
    kind, seed, run_index, refresh_sequence)
end

local function sidecar_convergence(path, expected)
  local disk = read_all(vim.fs.joinpath(fixture_root, path))
  local section_index, section = section_by_path(path)
  local model_exact = section and section.new_text == expected or false
  local ui_exact = false
  if section_index then
    local start0 = canvas.section_rows(state, section_index)
    for entry_index, entry in ipairs(section.entries or {}) do
      if entry.new_lnum == 1 then
        ui_exact = canvas.logical(state).row(start0 + entry_index - 1)
          == "+" .. expected:gsub("\n$", "")
        break
      end
    end
  end
  local convergence = {
    mutated = true,
    expected_bytes = expected,
    expected_digest = vim.fn.sha256(expected),
    disk_exact = disk == expected,
    model_exact = model_exact,
    ui_exact = ui_exact,
  }
  assert(convergence.disk_exact and convergence.model_exact
      and convergence.ui_exact,
    "refresh did not converge disk, model, and logical UI")
  return convergence
end

handlers.manual_refresh = function()
  local expected = expected_sidecar_bytes("manual")
  write_all(vim.fs.joinpath(fixture_root, "unstaged.txt"), expected)
  local refreshed, err = operation(function()
    return fm.refresh()
  end)
  assert(refreshed, err)
  return {
    lens = current_lens_id(),
    sections = #state.sections,
    convergence = sidecar_convergence("unstaged.txt", expected),
  }
end

handlers.watch_refresh = function()
  local lease = assert(state.surface and state.surface.controllers.watch,
    "active Surface has no watch lease")
  local before = #result.adapters.source
  local expected = expected_sidecar_bytes("watch")
  write_all(vim.fs.joinpath(fixture_root, "unstaged.txt"), expected)
  local reconciled = operation(function()
    API.nvim_exec_autocmds("FocusGained", {})
    return vim.wait(1500, function()
      local _, section = section_by_path("unstaged.txt")
      return section and section.new_text == expected
    end, 5)
  end)
  assert(reconciled, "watch refresh did not converge to expected bytes")
  assert(not lease.disposed, "watch refresh disposed its live lease")
  return {
    group = lease.group_name,
    source_samples = #result.adapters.source - before,
    convergence = sidecar_convergence("unstaged.txt", expected),
  }
end

local function expected_file_row(dir)
  local before0 = API.nvim_win_get_cursor(state.win)[1] - 1
  local section_index = canvas.locate(state, before0) or 1
  local target = math.min(math.max(section_index + dir, 1), #state.sections)
  return canvas.section_rows(state, target) + 1
end

local function expected_hunk_row(dir)
  local rows = {}
  for section_index, section in ipairs(state.sections) do
    local start0 = canvas.section_rows(state, section_index)
    if state.collapsed[section.path] then
      rows[#rows + 1] = start0 + 1
    else
      for entry_index, entry in ipairs(section.entries or {}) do
        if entry.kind == "hunk_hdr" then
          rows[#rows + 1] = start0 + entry_index
        end
      end
    end
  end
  table.sort(rows)
  local before = API.nvim_win_get_cursor(state.win)[1]
  if dir > 0 then
    for _, row in ipairs(rows) do
      if row > before then return row end
    end
  else
    for index = #rows, 1, -1 do
      if rows[index] < before then return rows[index] end
    end
  end
  return before
end

local function motion_observation(expected, callback)
  local before = API.nvim_win_get_cursor(state.win)[1]
  operation(callback)
  local after = API.nvim_win_get_cursor(state.win)[1]
  assert(after == expected, "navigation landed on the wrong destination")
  return {
    before_row = before,
    after_row = after,
    expected_row = expected,
    destination_exact = after == expected,
  }
end

handlers.file_next = function()
  return motion_observation(expected_file_row(1), function()
    input.motions.goto_file(state, 1, 1, state.win)
  end)
end

handlers.file_prev = function()
  return motion_observation(expected_file_row(-1), function()
    input.motions.goto_file(state, -1, 1, state.win)
  end)
end

handlers.hunk_next = function()
  return motion_observation(expected_hunk_row(1), function()
    input.motions.goto_hunk(state, 1, 1, state.win)
  end)
end

handlers.hunk_prev = function()
  return motion_observation(expected_hunk_row(-1), function()
    input.motions.goto_hunk(state, -1, 1, state.win)
  end)
end

handlers.jump = function(arguments)
  move_to_primary_row(arguments.row)
  local callback
  for _, mapping in ipairs(API.nvim_buf_get_keymap(state.buf, "n")) do
    if mapping.lhs == "<CR>" then
      callback = mapping.callback
      break
    end
  end
  assert(type(callback) == "function", "CanvasDiff jump mapping is unavailable")
  operation(callback)
  local buffer = API.nvim_get_current_buf()
  local name = API.nvim_buf_get_name(buffer)
  assert(name == vim.fs.joinpath(fixture_root, manifest.primary_path),
    "jump did not open the manifest primary path")
  return {
    path = name,
    buffer = buffer,
    destination_exact = true,
  }
end

handlers.back = function()
  local returned = operation(function()
    return fm.jump_back()
  end)
  assert(returned, "jump back did not return to the canvas")
  assert(API.nvim_get_current_buf() == state.buf,
    "jump back returned to the wrong buffer")
  return {
    canvas_buffer = state.buf,
    destination_exact = true,
  }
end

local function cached_name_status()
  local output = must_git(
    "diff", "--cached", "--name-status", "--no-renames", "-z")
  local records = {}
  local offset = 1
  local function token()
    if offset > #output then return nil end
    local boundary = output:find("\0", offset, true)
    assert(boundary, "cached name-status output is not NUL terminated")
    local value = output:sub(offset, boundary - 1)
    offset = boundary + 1
    return value
  end
  while offset <= #output do
    local status = assert(token(), "cached status is absent")
    local path = assert(token(), "cached path is absent")
    records[#records + 1] = { status = status, path = path }
  end
  table.sort(records, function(left, right) return left.path < right.path end)
  return records
end

local function cached_paths(records)
  local paths = {}
  for _, record in ipairs(records) do paths[#paths + 1] = record.path end
  table.sort(paths)
  return paths
end

local function path_set(paths)
  local set = {}
  for _, path in ipairs(paths) do set[path] = true end
  return set
end

local function exact_index_delta(before, after, added_path, removed_path)
  local before_set, after_set = path_set(before), path_set(after)
  local added, removed = {}, {}
  for path in pairs(after_set) do
    if not before_set[path] then added[#added + 1] = path end
  end
  for path in pairs(before_set) do
    if not after_set[path] then removed[#removed + 1] = path end
  end
  table.sort(added)
  table.sort(removed)
  local expected_added = added_path and { added_path } or {}
  local expected_removed = removed_path and { removed_path } or {}
  return vim.deep_equal(added, expected_added)
    and vim.deep_equal(removed, expected_removed)
end

handlers.stage = function(arguments)
  set_lens_named("unstaged", "stage preflight")
  local section_index = assert(section_by_path(arguments.path))
  local start0 = assert(canvas.section_rows(state, section_index))
  API.nvim_set_current_win(state.win)
  API.nvim_win_set_cursor(state.win, { start0 + 1, 0 })

  local before_name_status = cached_name_status()
  local before_paths = cached_paths(before_name_status)
  local disk = assert(read_all(vim.fs.joinpath(fixture_root, arguments.path)))
  local changed, err = operation(function()
    return fm.toggle_stage()
  end)
  assert(changed, err)
  local after_name_status = cached_name_status()
  local after_paths = cached_paths(after_name_status)
  local indexed = must_git("show", ":0:" .. arguments.path)
  result.correctness.index.stage_exact = indexed == disk
  local primary_absent = not path_set(before_paths)[manifest.primary_path]
    and not path_set(after_paths)[manifest.primary_path]
  local paths_exact = exact_index_delta(
    before_paths, after_paths, arguments.path, nil)
  result.correctness.index.primary_absent =
    result.correctness.index.primary_absent and primary_absent
  result.correctness.index.paths_exact =
    result.correctness.index.paths_exact and paths_exact
  assert(result.correctness.index.stage_exact,
    "stage action did not put exact disk bytes in the index")
  assert(primary_absent and paths_exact,
    "stage action changed index paths outside the bounded sidecar")
  return {
    path = arguments.path,
    index_digest = vim.fn.sha256(indexed),
    disk_digest = vim.fn.sha256(disk),
    before_paths = before_paths,
    after_paths = after_paths,
    before_name_status = before_name_status,
    after_name_status = after_name_status,
    bytes_exact = result.correctness.index.stage_exact,
    primary_absent = primary_absent,
    paths_exact = paths_exact,
  }
end

handlers.unstage = function(arguments)
  set_lens_named("staged", "unstage preflight")
  local section_index = assert(section_by_path(arguments.path))
  local start0 = assert(canvas.section_rows(state, section_index))
  API.nvim_set_current_win(state.win)
  API.nvim_win_set_cursor(state.win, { start0 + 1, 0 })

  local before_name_status = cached_name_status()
  local before_paths = cached_paths(before_name_status)
  local head = must_git("show", "HEAD:" .. arguments.path)
  local changed, err = operation(function()
    return fm.toggle_stage()
  end)
  assert(changed, err)
  local after_name_status = cached_name_status()
  local after_paths = cached_paths(after_name_status)
  local indexed = must_git("show", ":0:" .. arguments.path)
  result.correctness.index.unstage_exact = indexed == head
  local primary_absent = not path_set(before_paths)[manifest.primary_path]
    and not path_set(after_paths)[manifest.primary_path]
  local paths_exact = exact_index_delta(
    before_paths, after_paths, nil, arguments.path)
  result.correctness.index.primary_absent =
    result.correctness.index.primary_absent and primary_absent
  result.correctness.index.paths_exact =
    result.correctness.index.paths_exact and paths_exact
  assert(result.correctness.index.unstage_exact,
    "unstage action did not restore exact HEAD bytes in the index")
  assert(primary_absent and paths_exact,
    "unstage action changed index paths outside the bounded sidecar")
  return {
    path = arguments.path,
    index_digest = vim.fn.sha256(indexed),
    head_digest = vim.fn.sha256(head),
    before_paths = before_paths,
    after_paths = after_paths,
    before_name_status = before_name_status,
    after_name_status = after_name_status,
    bytes_exact = result.correctness.index.unstage_exact,
    primary_absent = primary_absent,
    paths_exact = paths_exact,
  }
end

handlers.branch_compare = function(arguments)
  local changed, err = operation(function()
    return fm.set_branch(arguments.target)
  end)
  assert(changed, err)
  local expected_id = "branch:" .. arguments.target
  observe_lens(expected_id, "branch_compare")
  local oid = must_git(
    "rev-parse", "--verify", arguments.target .. "^{commit}"):gsub("%s+$", "")
  result.correctness.refs.branch_exact =
    lens.of(state).old == arguments.target and oid:match("^[0-9a-f]+$") ~= nil
  assert(result.correctness.refs.branch_exact,
    "branch comparison did not preserve ref identity")
  return {
    ref = arguments.target,
    oid = oid,
    lens = current_lens_id(),
    ref_exact = result.correctness.refs.branch_exact,
  }
end

handlers.range_compare = function(arguments)
  local changed, err = operation(function()
    return fm.set_range(arguments.range)
  end)
  assert(changed, err)
  local expected_id = "range:" .. arguments.range
  observe_lens(expected_id, "range_compare")
  local left, right = arguments.range:match("^(.-)%.%.(.-)$")
  assert(left and right, "fixture range is not a two-dot range")
  local left_oid = must_git(
    "rev-parse", "--verify", left .. "^{commit}"):gsub("%s+$", "")
  local right_oid = must_git(
    "rev-parse", "--verify", right .. "^{commit}"):gsub("%s+$", "")
  local current = lens.of(state)
  result.correctness.refs.range_exact =
    current.old == left and current.new == right and current.operator == ".."
      and left_oid:match("^[0-9a-f]+$") ~= nil
      and right_oid:match("^[0-9a-f]+$") ~= nil
  assert(result.correctness.refs.range_exact,
    "range comparison did not preserve both ref identities")
  return {
    left = left,
    right = right,
    left_oid = left_oid,
    right_oid = right_oid,
    lens = current_lens_id(),
    ref_exact = result.correctness.refs.range_exact,
  }
end

handlers.git_failure = function(arguments)
  local oid, err = operation(function()
    return source.resolve_commit(fixture_root, arguments.ref)
  end)
  result.correctness.git_failure = {
    caught = oid == nil and type(err) == "string",
    ref = arguments.ref,
    error = err,
  }
  assert(result.correctness.git_failure.caught,
    "injected missing Git ref was not contained")
  return {
    expected_failure = true,
    ref = arguments.ref,
    error = err,
    caught = result.correctness.git_failure.caught,
  }
end

local function digit_sum_through(count)
  local total, first, digits = 0, 1, 1
  while first <= count do
    local last = math.min(count, first * 10 - 1)
    total = total + (last - first + 1) * digits
    first = first * 10
    digits = digits + 1
  end
  return total
end

local function generated_offset0(row)
  local constant = 13 + #tostring(manifest.seed)
  return (row - 1) * constant + digit_sum_through(row - 1)
end

local function bounded_equivalence()
  local samples = { 1, math.max(1, math.floor(manifest.rows / 2)), manifest.rows }
  local path = vim.fs.joinpath(fixture_root, manifest.primary_path)
  local file = assert(io.open(path, "rb"))
  local _, section = section_by_path(manifest.primary_path)
  assert(section, "primary model absent after reopen")
  local logical = canvas.logical(state)
  local disk_exact, model_exact, ui_exact = true, true, true
  for _, row in ipairs(samples) do
    local expected = ("scale %d seed %d\n"):format(row, manifest.seed)
    assert(file:seek("set", generated_offset0(row)))
    disk_exact = disk_exact and file:read(#expected) == expected
    model_exact = model_exact
      and section.new_text:sub(
        generated_offset0(row) + 1,
        generated_offset0(row) + #expected) == expected
    ui_exact = ui_exact
      and logical.row(primary_logical_row(row)) == "+" .. expected:gsub("\n$", "")
  end
  assert(file:close())
  local logical_rows = logical.row_count()
  local paging_exact
  if state.paged then
    local projection = state.paged.projection:stats()
    local cache = state.paged.list:stats()
    paging_exact = projection.logical_rows == logical_rows
      and projection.skeleton_rows == logical_rows
      and cache.row_count == logical_rows
  else
    paging_exact = API.nvim_buf_line_count(state.buf) == logical_rows
  end
  assert(disk_exact and model_exact and ui_exact and paging_exact,
    "bounded reopen equivalence failed")
  return {
    disk_exact = disk_exact,
    model_exact = model_exact,
    ui_exact = ui_exact,
    paging_exact = paging_exact,
    sampled_rows = samples,
  }
end

handlers.close_reopen = function()
  operation(function() fm.close() end)
  state = nil
  vim.wait(0)
  open_named("all", "close_reopen")
  return {
    lens = current_lens_id(),
    canvas_windows = #canvas_windows(),
    equivalence = bounded_equivalence(),
  }
end

handlers.close_orders = function(arguments)
  operation(function() fm.close() end)
  state = nil
  vim.wait(0)
  local home_tab = API.nvim_get_current_tabpage()
  local views = {}
  local lens_names = {
    working = "all",
    staged = "staged",
    unstaged = "unstaged",
  }

  for _, name in ipairs(arguments.order) do
    vim.cmd("tabnew")
    local selected = assert(lens_names[name], "unknown close-order lens " .. name)
    local opened = assert(operation(function()
      return fm.open({ lens = assert(lens.get(selected)) })
    end))
    views[name] = {
      tab = API.nvim_get_current_tabpage(),
      win = opened.win,
      state = opened,
      lens = selected,
    }
    state = opened
    observe_lens(selected, "close_orders open " .. name)
  end

  local closed = {}
  for _, name in ipairs(arguments.order) do
    local view = assert(views[name])
    assert(API.nvim_tabpage_is_valid(view.tab),
      "close-order tab vanished before its turn")
    API.nvim_set_current_tabpage(view.tab)
    API.nvim_set_current_win(view.win)
    operation(function() fm.close() end)
    vim.wait(0)
    closed[#closed + 1] = name
    if API.nvim_tabpage_is_valid(view.tab) and #API.nvim_list_tabpages() > 1 then
      vim.cmd("tabclose!")
    end
  end
  if API.nvim_tabpage_is_valid(home_tab) then
    API.nvim_set_current_tabpage(home_tab)
  end
  state = nil
  assert(#canvas_windows() == 0,
    "close-order replay left a CanvasDiff window")
  return {
    order = closed,
    canvas_windows = 0,
    order_exact = vim.deep_equal(closed, arguments.order),
  }
end

handlers.final_close = function()
  if #canvas_windows() == 0 then
    open_named("all", "final_close open")
  end
  operation(function() fm.close() end)
  state = nil
  vim.wait(0)
  assert(#canvas_windows() == 0, "final close left a CanvasDiff window")
  return {
    canvas_windows = 0,
    closed_exact = true,
  }
end

local function execute_plan()
  local plan = actions.plan(rows, seed)
  for index, action in ipairs(plan) do
    local record = {
      index = index,
      name = action.name,
      arguments = vim.deepcopy(action.arguments),
      observations = {},
    }
    local started = now_ns()
    current_measurement = {
      operation_ns = 0,
      operation_count = 0,
    }
    local handler = handlers[action.name]
    local ok, observations = xpcall(function()
      assert(handler, "no worker handler for action " .. tostring(action.name))
      local observed = handler(action.arguments)
      if action.name ~= "open" then
        assert(sample_paged_resident(
          "after_" .. action.name, action.class == "navigation"))
      end
      return observed
    end, debug.traceback)
    record.wall_ns = now_ns() - started
    record.operation_ns = current_measurement.operation_ns
    record.elapsed_ns = record.operation_ns
    record.oracle_ns = math.max(0, record.wall_ns - record.operation_ns)
    record.operation_count = current_measurement.operation_count
    record.first_view_ns = current_measurement.first_view_ns
    current_measurement = nil
    record.status = ok and "ok" or "fail"
    if ok then
      record.observations = observations or {}
    else
      record.error = tostring(observations)
    end
    result.trace[#result.trace + 1] = record
    if not ok then
      error(observations, 0)
    end
    -- Let libuv callbacks and scheduled main-loop work cross their real
    -- boundaries between otherwise synchronous actions.
    vim.wait(0)
  end
end

local function close_all_canvases()
  if not (fm and canvas) then
    return
  end
  for _ = 1, 32 do
    local windows = canvas_windows()
    if #windows == 0 then
      return
    end
    local win = windows[1]
    if API.nvim_win_is_valid(win) then
      pcall(API.nvim_set_current_win, win)
      pcall(fm.close)
      vim.wait(0)
    end
  end
end

sample_memory("worker_start")

local output_reserved, output_error = pcall(reserve_output)
if not output_reserved then
  vim.api.nvim_err_writeln(tostring(output_error))
  os.exit(1)
end

local main_ok, main_error = xpcall(function()
  assert(finite_integer(rows) and rows >= 1,
    "worker ROWS must be a positive integer")
  assert(finite_integer(seed), "worker SEED must be an integer")
  assert(finite_integer(run_index) and run_index >= 1,
    "worker RUN_INDEX must be a positive integer")
  for key, value in pairs(argv) do
    if type(key) == "number" and key >= 6 and value ~= nil then
      error(("unexpected worker argument #%d: %s"):format(
        key, tostring(value)), 0)
    end
  end

  manifest = phase("fixture_build", function()
    fixture_build_started = true
    local built, build_error = fixture.build(fixture_root, rows, seed)
    assert(built, build_error)
    if vim.env.CANVASDIFF_LIVE_SCALE_FAIL_FIXTURE_AFTER_BUILD == "1" then
      error("injected failure after fixture ownership", 0)
    end
    return built
  end)
  result.manifest = vim.deepcopy(manifest)
  sample_memory("after_fixture")

  phase("adapter_install", install_adapters)
  phase("app_load", function()
    fm = require("canvasdiff")
    canvas = require("canvasdiff.canvas")
    input = require("canvasdiff.input")
    lens = require("canvasdiff.diff").lens
    -- The workload explicitly exercises fold/unfold itself. Disable automatic
    -- virtualization so a 100k/1m primary section remains expanded and the
    -- paging/search/yank journey measures the requested rows rather than one
    -- auto-collapsed placeholder.
    fm.setup({
      virt = {
        enabled = false,
      },
    })
  end)
  sample_memory("after_app_load")

  heartbeat_timer = assert(original_uv_new_timer())
  track_timer(heartbeat_timer, "heartbeat")
  result.heartbeat.started_after_fixture = true

  vim.api.nvim_set_current_dir(fixture_root)
  phase("replay", execute_plan)
  sample_memory("after_replay")
end, debug.traceback)

if not main_ok then
  result.error = tostring(main_error)
end

-- One finalizer owns every restoration and cleanup path, including failures
-- before App load and failures in the middle of a multi-surface close order.
local cleanup_started = now_ns()
local cleanup_errors = {}
local function cleanup_attempt(label, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if not ok then
    cleanup_errors[#cleanup_errors + 1] =
      label .. ": " .. tostring(err)
  end
end

cleanup_attempt("close canvases", close_all_canvases)
cleanup_attempt("stop heartbeat", function()
  stop_heartbeat_window()
  if heartbeat_timer then
    pcall(function()
      heartbeat_timer:stop()
    end)
    if not heartbeat_timer:is_closing() then
      heartbeat_timer:close()
    end
  end
end)
local injected_timer
if vim.env.CANVASDIFF_LIVE_SCALE_DEFER_TIMER == "1" then
  vim.schedule(function()
    injected_timer = uv.new_timer()
  end)
end
cleanup_attempt("drain callbacks", function()
  vim.wait(20, function()
    return false
  end, 2)
end)
cleanup_attempt("collect garbage", function()
  collectgarbage("collect")
  collectgarbage("collect")
end)
cleanup_attempt("inspect editor resources", function()
  result.cleanup.canvas_windows = #canvas_windows()
  result.cleanup.owned_groups = controller_groups()
  local open_timers = 0
  local timer_owners = {}
  for timer, owner in pairs(tracked_timers) do
    if timer_is_open(timer) then
      open_timers = open_timers + 1
      timer_owners[#timer_owners + 1] = owner
    end
  end
  table.sort(timer_owners)
  result.cleanup.open_timers = open_timers
  result.cleanup.open_timer_owners = timer_owners
  local marks = 0
  for _, buffer in ipairs(API.nvim_list_bufs()) do
    if API.nvim_buf_is_valid(buffer) and canvas and canvas.is_canvas_buf(buffer) then
      marks = marks + count_extmarks(buffer)
    end
  end
  result.extmarks.after = marks
end)
cleanup_attempt("close injected timer after observation", function()
  if injected_timer and not injected_timer:is_closing() then
    injected_timer:close()
  end
end)
cleanup_attempt("restore adapters", function()
  result.cleanup.wrappers_restored = restore_wrappers()
  assert(result.cleanup.wrappers_restored,
    "an installed timing adapter was replaced before restoration")
end)
cleanup_attempt("restore cwd", function()
  vim.api.nvim_set_current_dir(repo_root)
end)
cleanup_attempt("cleanup fixture", function()
  if fixture_build_started and uv.fs_stat(fixture_root) then
    result.cleanup.fixture_cleanup_attempted = true
    local cleaned, cleanup_error = fixture.cleanup(fixture_root)
    assert(cleaned, cleanup_error)
    result.cleanup.fixture_removed = uv.fs_stat(fixture_root) == nil
  else
    result.cleanup.fixture_removed = uv.fs_stat(fixture_root) == nil
  end
end)
sample_memory("after_cleanup")

local cleanup_status = #cleanup_errors == 0
  and result.cleanup.fixture_removed
  and result.cleanup.canvas_windows == 0
  and result.cleanup.open_timers == 0
  and #result.cleanup.owned_groups == 0
  and result.cleanup.wrappers_restored
  and finite_integer(result.heartbeat.ticks)
  and result.heartbeat.ticks >= 1
  and type(result.heartbeat.max_gap_ns) == "number"
  and result.heartbeat.max_gap_ns > 0
  and result.correctness.projection.preserved
  and result.correctness.projection.samples > 0
result.phases[#result.phases + 1] = {
  name = "cleanup",
  elapsed_ns = now_ns() - cleanup_started,
  status = cleanup_status and "ok" or "fail",
  errors = #cleanup_errors > 0 and cleanup_errors or nil,
}

if main_ok and cleanup_status then
  result.status = "ok"
  result.error = nil
else
  result.status = "fail"
  if #cleanup_errors > 0 then
    local suffix = table.concat(cleanup_errors, "\n")
    result.error = result.error and (result.error .. "\n" .. suffix) or suffix
  elseif not cleanup_status and not result.error then
    result.error = "worker cleanup invariants failed"
  end
end

local published, publish_error = pcall(function()
  assert(output_path, "worker requires OUTPUT")
  atomic_json(output_path, result)
end)
if not published then
  vim.api.nvim_err_writeln(tostring(publish_error))
end
os.exit(result.status == "ok" and published and 0 or 1)
