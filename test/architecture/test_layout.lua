local H = require("helpers")
local graph = require("architecture.graph")
local rules = require("architecture.rules")

local T = {}

local function source_set()
  local set = {}
  for _, file in ipairs(graph.source_files(graph.root)) do
    set[file.rel] = true
  end
  return set
end

local function assert_no_errors(errors)
  table.sort(errors)
  assert(#errors == 0, "architecture layout violations:\n- " .. table.concat(errors, "\n- "))
end

T.architecture_layout_uses_only_the_singular_test_root = function()
  local test_stat = vim.uv.fs_stat(vim.fs.joinpath(graph.root, "test"))
  assert(test_stat and test_stat.type == "directory", "test/ must exist")
  assert(vim.uv.fs_stat(vim.fs.joinpath(graph.root, "tests")) == nil, "tests/ must not exist")

  local errors = {}
  for _, file in ipairs(graph.source_files(graph.root)) do
    if file.rel:match("^tests/") then
      errors[#errors + 1] = "legacy test path remains: " .. file.rel
    end
  end
  assert_no_errors(errors)
end

T.architecture_layout_legacy_ledger_is_sorted_unique_and_exact = function()
  local files = source_set()
  local actual = {}
  local seen = {}

  H.eq(vim.tbl_count(rules.legacy_ceiling), 24, "the original legacy ceiling is immutable")
  for index, path in ipairs(rules.legacy_paths) do
    assert(not seen[path], "duplicate legacy ledger entry: " .. path)
    seen[path] = true
    if index > 1 then
      assert(rules.legacy_paths[index - 1] < path, "legacy ledger must stay sorted")
    end
    assert(rules.legacy_ceiling[path], "new legacy exemptions are forbidden: " .. path)
    assert(path:match("^lua/canvasdiff/[^/]+%.lua$"), "legacy exemptions must be flat: " .. path)
    assert(files[path], "stale legacy ledger entry; remove or restore it: " .. path)
    H.eq(rules.classify(path), "legacy", "ledger path must classify as legacy")
    actual[#actual + 1] = path
  end

  table.sort(actual)
  H.eq(actual, rules.legacy_paths)
end

T.architecture_layout_module_ids_are_unique_and_paths_are_owned = function()
  local modules = {}
  local errors = {}

  for _, file in ipairs(graph.source_files(graph.root)) do
    if file.rel:match("^lua/") then
      local module = graph.module_id(file.rel)
      if not module then
        errors[#errors + 1] = "invalid Lua module path: " .. file.rel
      elseif modules[module] then
        errors[#errors + 1] = (
          "module %q has two providers: %s and %s"
        ):format(module, modules[module], file.rel)
      else
        modules[module] = file.rel
      end

      if file.rel:match("^lua/canvasdiff") and not rules.classify(file.rel) then
        errors[#errors + 1] = "unowned CanvasDiff module path: " .. file.rel
      elseif not file.rel:match("^lua/canvasdiff") then
        errors[#errors + 1] = "production Lua must live in the CanvasDiff package: " .. file.rel
      end
    elseif (file.rel:match("^plugin/") or file.rel:match("^benchmark/"))
        and not rules.classify(file.rel) then
      errors[#errors + 1] = "unowned Lua entrypoint: " .. file.rel
    end
  end

  assert_no_errors(errors)
end

T.architecture_layout_names_have_one_meaning = function()
  local errors = {}

  for _, file in ipairs(graph.source_files(graph.root)) do
    if file.rel:match("^lua/canvasdiff")
        or file.rel:match("^plugin/")
        or file.rel:match("^benchmark/") then
      local basename = file.rel:match("([^/]+)%.lua$")
      if not basename then
        errors[#errors + 1] = "invalid Lua filename: " .. file.rel
      elseif basename == "main" then
        errors[#errors + 1] = "main.lua is a forbidden catch-all: " .. file.rel
      end
      if basename and (
        basename == "util"
        or basename == "utils"
        or file.rel:find("/util/", 1, true)
        or file.rel:find("/utils/", 1, true)
      ) then
        errors[#errors + 1] = "util catch-all is forbidden: " .. file.rel
      end

      if basename and rules.stateful_paths[file.rel] then
        if not basename:match("^[A-Z][A-Za-z0-9]*$") then
          errors[#errors + 1] = "stateful type must use PascalCase: " .. file.rel
        end
      elseif basename and not basename:match("^[a-z][a-z0-9_]*$") then
        errors[#errors + 1] = "non-stateful module must use lower_snake_case: " .. file.rel
      end

      local directory = file.rel:match("^lua/canvasdiff/(.+)/[^/]+%.lua$")
      if directory then
        for segment in directory:gmatch("[^/]+") do
          if not segment:match("^[a-z][a-z0-9_]*$") then
            errors[#errors + 1] = "module directory must use lower_snake_case: " .. file.rel
          end
        end
      end
    end
  end

  assert_no_errors(errors)
end

T.architecture_layout_every_domain_has_a_facade_and_a_real_owner = function()
  local files = source_set()
  local errors = {}

  local domains = vim.tbl_keys(rules.domains)
  table.sort(domains)
  for _, domain in ipairs(domains) do
    local facade_path = ("lua/canvasdiff/%s.lua"):format(domain)
    local has_facade = files[facade_path] and not rules.legacy[facade_path]
    local has_owner = false
    local owner_prefix = ("lua/canvasdiff/%s/"):format(domain)

    for path in pairs(files) do
      if path:sub(1, #owner_prefix) == owner_prefix then
        has_owner = true
        break
      end
    end

    if has_owner and not has_facade then
      errors[#errors + 1] = ("%s has internals but no %s facade"):format(owner_prefix, facade_path)
    elseif has_facade and not has_owner then
      errors[#errors + 1] = ("%s is empty taxonomy without a real owner"):format(facade_path)
    end
  end

  assert_no_errors(errors)
end

T.architecture_identity_contains_no_retired_token_or_path = function()
  local retired = "gal" .. "ley"
  local historical_record = "docs/journeys/2026-07-26-canvasdiff-migration.md"
  local result = vim.system({
    "git",
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
  }, { cwd = graph.root }):wait()
  assert(result.code == 0, "could not enumerate repository files: " .. (result.stderr or ""))

  local errors = {}
  local casefolded_paths = {}
  for relative in (result.stdout or ""):gmatch("([^%z]+)") do
    local absolute = vim.fs.joinpath(graph.root, relative)
    local stat = vim.uv.fs_stat(absolute)
    if stat and stat.type == "file" then
      local folded_path = relative:lower()
      if folded_path:find(retired, 1, true) then
        errors[#errors + 1] = "retired identity remains in path: " .. relative
      end
      if casefolded_paths[folded_path] and casefolded_paths[folded_path] ~= relative then
        errors[#errors + 1] = (
          "case-folded path collision: %s and %s"
        ):format(casefolded_paths[folded_path], relative)
      end
      casefolded_paths[folded_path] = relative

      if relative ~= historical_record then
        local file, open_err = io.open(absolute, "rb")
        assert(file, ("%s: %s"):format(relative, open_err or "could not open"))
        local content = file:read("*a")
        file:close()
        if content:lower():find(retired, 1, true) then
          errors[#errors + 1] = "retired identity remains in content: " .. relative
        end
      end
    end
  end

  assert_no_errors(errors)
end

return T
