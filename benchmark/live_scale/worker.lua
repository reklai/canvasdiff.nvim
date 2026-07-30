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
    index = {
      stage_exact = false,
      unstage_exact = false,
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
    ticks = 0,
    max_gap_ns = 0,
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

local function mkdir(path)
  assert(vim.fn.mkdir(path, "p") == 1 or vim.fn.isdirectory(path) == 1,
    "could not create directory: " .. path)
end

local function atomic_json(path, value)
  mkdir(vim.fs.dirname(path))
  local temporary = ("%s.tmp.%d"):format(path, vim.fn.getpid())
  local file = assert(io.open(temporary, "wb"))
  local encoded_ok, encoded = pcall(vim.json.encode, value)
  if not encoded_ok then
    file:close()
    vim.fn.delete(temporary)
    error("could not encode live-scale worker JSON: " .. tostring(encoded), 0)
  end
  assert(file:write(encoded, "\n"))
  assert(file:close())
  local renamed, rename_error = uv.fs_rename(temporary, path)
  if not renamed then
    vim.fn.delete(temporary)
    error(("could not publish %s: %s"):format(
      path, rename_error or "rename failed"), 0)
  end
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
local original_uv_new_timer = uv.new_timer
local git_executable = vim.fn.exepath("git")

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
  local changed, err = fm.set_lens(assert(lens.get(name)))
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
  return logical0
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
  local opened, err = fm.open({ lens = assert(lens.get(name)) })
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
  state = assert(fm.open({ lens = assert(lens.get("all")) }))
  observe_lens("all", "open")
  observe_initial_content()
  observe_paging()
  return {
    lens = current_lens_id(),
    sections = #state.sections,
    paged = state.paged ~= nil,
  }
end

handlers.sequential_scroll = function(arguments)
  local logical0 = move_to_primary_row(arguments.row)
  return {
    requested_row = arguments.row,
    logical_row = logical0,
    cursor_row = API.nvim_win_get_cursor(state.win)[1],
  }
end

handlers.random_jump = handlers.sequential_scroll

handlers.search = function(arguments)
  local found0
  if state.paged then
    found0 = assert(canvas.paged.search(state.paged, arguments.query, {
      from0 = 0,
      wrap = true,
    }))
    API.nvim_win_set_cursor(state.win, { found0 + 1, 0 })
  else
    found0 = API.nvim_win_call(state.win, function()
      API.nvim_win_set_cursor(state.win, { 1, 0 })
      local found1 = vim.fn.search(arguments.query, "W")
      return found1 > 0 and found1 - 1 or nil
    end)
    assert(found0, "eager canvas search found no match")
  end
  local text = assert(canvas.logical(state).row(found0))
  assert(text:find(arguments.query, 1, true),
    "search landed on a row without the query")
  return {
    query = arguments.query,
    logical_row = found0,
  }
end

handlers.yank = function(arguments)
  local start0 = primary_logical_row(arguments.start_row)
  local end0 = primary_logical_row(arguments.end_row)
  local count = end0 - start0 + 1
  local text, err
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
  assert(text, err)
  local expected_first = ("+scale %d seed %d"):format(
    arguments.start_row, manifest.seed)
  local expected_last = ("+scale %d seed %d"):format(
    arguments.end_row, manifest.seed)
  assert(vim.startswith(text, expected_first),
    "yank did not begin with the expected generated row")
  assert(text:find(expected_last, 1, true),
    "yank did not include the expected final generated row")
  assert(vim.fn.getreg('"') == text, "yank register does not match exported text")
  return {
    logical_start = start0,
    logical_count = count,
    bytes = #text,
  }
end

handlers.fold = function()
  local section_index, section = section_by_path(manifest.primary_path)
  assert(section_index)
  local before = canvas.logical(state).row_count()
  canvas.set_collapsed(state, section_index, true, "user", state.win)
  assert(state.collapsed[section.path] == "user",
    "fold did not record user ownership")
  local after = canvas.logical(state).row_count()
  assert(after <= before, "fold increased the logical canvas")
  return {
    before_rows = before,
    after_rows = after,
    path = section.path,
  }
end

handlers.unfold = function()
  local section_index, section = section_by_path(manifest.primary_path)
  assert(section_index)
  canvas.set_collapsed(state, section_index, false, "user", state.win)
  assert(state.collapsed[section.path] == nil,
    "unfold retained the collapsed identity")
  local logical0 = primary_logical_row(1)
  return {
    logical_row = logical0,
    path = section.path,
  }
end

handlers.cycle_all = function()
  set_lens_named("all", "cycle_all")
  return { lens = current_lens_id() }
end

handlers.cycle_staged = function()
  set_lens_named("staged", "cycle_staged")
  return { lens = current_lens_id() }
end

handlers.cycle_unstaged = function()
  set_lens_named("unstaged", "cycle_unstaged")
  return { lens = current_lens_id() }
end

handlers.manual_refresh = function()
  local refreshed, err = fm.refresh()
  assert(refreshed, err)
  return {
    lens = current_lens_id(),
    sections = #state.sections,
  }
end

handlers.watch_refresh = function()
  local lease = assert(state.surface and state.surface.controllers.watch,
    "active Surface has no watch lease")
  local before = #result.adapters.source
  API.nvim_exec_autocmds("FocusGained", {})
  local reconciled = vim.wait(1500, function()
    for index = before + 1, #result.adapters.source do
      if result.adapters.source[index].name == "sections" then
        return true
      end
    end
    return false
  end, 5)
  assert(reconciled, "watch refresh did not cross the source facade")
  assert(not lease.disposed, "watch refresh disposed its live lease")
  return {
    group = lease.group_name,
    source_samples = #result.adapters.source - before,
  }
end

local function motion_observation(callback)
  local before = API.nvim_win_get_cursor(state.win)[1]
  callback()
  local after = API.nvim_win_get_cursor(state.win)[1]
  return {
    before_row = before,
    after_row = after,
  }
end

handlers.file_next = function()
  return motion_observation(function()
    input.motions.goto_file(state, 1, 1, state.win)
  end)
end

handlers.file_prev = function()
  return motion_observation(function()
    input.motions.goto_file(state, -1, 1, state.win)
  end)
end

handlers.hunk_next = function()
  return motion_observation(function()
    input.motions.goto_hunk(state, 1, 1, state.win)
  end)
end

handlers.hunk_prev = function()
  return motion_observation(function()
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
  callback()
  local buffer = API.nvim_get_current_buf()
  local name = API.nvim_buf_get_name(buffer)
  assert(name == vim.fs.joinpath(fixture_root, manifest.primary_path),
    "jump did not open the manifest primary path")
  return {
    path = name,
    buffer = buffer,
  }
end

handlers.back = function()
  local returned = fm.jump_back()
  assert(returned, "jump back did not return to the canvas")
  assert(API.nvim_get_current_buf() == state.buf,
    "jump back returned to the wrong buffer")
  return {
    canvas_buffer = state.buf,
  }
end

handlers.stage = function(arguments)
  set_lens_named("unstaged", "stage preflight")
  local section_index = assert(section_by_path(arguments.path))
  local start0 = assert(canvas.section_rows(state, section_index))
  API.nvim_set_current_win(state.win)
  API.nvim_win_set_cursor(state.win, { start0 + 1, 0 })

  local disk = assert(read_all(vim.fs.joinpath(fixture_root, arguments.path)))
  local changed, err = fm.toggle_stage()
  assert(changed, err)
  local indexed = must_git("show", ":0:" .. arguments.path)
  result.correctness.index.stage_exact = indexed == disk
  assert(result.correctness.index.stage_exact,
    "stage action did not put exact disk bytes in the index")
  return {
    path = arguments.path,
    index_digest = vim.fn.sha256(indexed),
    disk_digest = vim.fn.sha256(disk),
  }
end

handlers.unstage = function(arguments)
  set_lens_named("staged", "unstage preflight")
  local section_index = assert(section_by_path(arguments.path))
  local start0 = assert(canvas.section_rows(state, section_index))
  API.nvim_set_current_win(state.win)
  API.nvim_win_set_cursor(state.win, { start0 + 1, 0 })

  local head = must_git("show", "HEAD:" .. arguments.path)
  local changed, err = fm.toggle_stage()
  assert(changed, err)
  local indexed = must_git("show", ":0:" .. arguments.path)
  result.correctness.index.unstage_exact = indexed == head
  assert(result.correctness.index.unstage_exact,
    "unstage action did not restore exact HEAD bytes in the index")
  return {
    path = arguments.path,
    index_digest = vim.fn.sha256(indexed),
    head_digest = vim.fn.sha256(head),
  }
end

handlers.branch_compare = function(arguments)
  local changed, err = fm.set_branch(arguments.target)
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
  }
end

handlers.range_compare = function(arguments)
  local changed, err = fm.set_range(arguments.range)
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
  }
end

handlers.git_failure = function(arguments)
  local oid, err = source.resolve_commit(fixture_root, arguments.ref)
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
  }
end

handlers.close_reopen = function()
  fm.close()
  state = nil
  vim.wait(0)
  open_named("all", "close_reopen")
  return {
    lens = current_lens_id(),
    canvas_windows = #canvas_windows(),
  }
end

handlers.close_orders = function(arguments)
  fm.close()
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
    local opened = assert(fm.open({ lens = assert(lens.get(selected)) }))
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
    fm.close()
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
  }
end

handlers.final_close = function()
  if #canvas_windows() == 0 then
    open_named("all", "final_close open")
  end
  fm.close()
  state = nil
  vim.wait(0)
  assert(#canvas_windows() == 0, "final close left a CanvasDiff window")
  return {
    canvas_windows = 0,
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
    local handler = handlers[action.name]
    local ok, observations = xpcall(function()
      assert(handler, "no worker handler for action " .. tostring(action.name))
      return handler(action.arguments)
    end, debug.traceback)
    record.elapsed_ns = now_ns() - started
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

local heartbeat_ok, heartbeat_error = pcall(function()
  heartbeat_timer = assert(original_uv_new_timer())
  track_timer(heartbeat_timer, "heartbeat")
  heartbeat_last_ns = now_ns()
  heartbeat_timer:start(HEARTBEAT_MS, HEARTBEAT_MS, function()
    local at = now_ns()
    local gap = at - heartbeat_last_ns
    heartbeat_last_ns = at
    result.heartbeat.ticks = result.heartbeat.ticks + 1
    result.heartbeat.max_gap_ns = math.max(
      result.heartbeat.max_gap_ns, gap)
  end)
end)
if not heartbeat_ok then
  result.error = "heartbeat setup failed: " .. tostring(heartbeat_error)
end

local main_ok, main_error = xpcall(function()
  assert(heartbeat_ok, result.error)
  assert(output_path, "worker requires OUTPUT")
  assert(fixture_root, "worker requires FIXTURE_ROOT")
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
    local built, build_error = fixture.build(fixture_root, rows, seed)
    assert(built, build_error)
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
  if heartbeat_timer then
    pcall(function()
      heartbeat_timer:stop()
    end)
    if not heartbeat_timer:is_closing() then
      heartbeat_timer:close()
    end
  end
end)
cleanup_attempt("restore adapters", function()
  result.cleanup.wrappers_restored = restore_wrappers()
  assert(result.cleanup.wrappers_restored,
    "an installed timing adapter was replaced before restoration")
end)
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
cleanup_attempt("restore cwd", function()
  vim.api.nvim_set_current_dir(repo_root)
end)
cleanup_attempt("cleanup fixture", function()
  if manifest then
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
