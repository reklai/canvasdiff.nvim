local G = {}

local this_file = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
G.root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(this_file)))

local function read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local source = file:read("*a")
  file:close()
  return source
end

local function count_newlines(text)
  local _, count = text:gsub("\n", "")
  return count
end

local function long_bracket_open(source, at)
  if source:sub(at, at) ~= "[" then
    return nil
  end
  local cursor = at + 1
  while source:sub(cursor, cursor) == "=" do
    cursor = cursor + 1
  end
  if source:sub(cursor, cursor) ~= "[" then
    return nil
  end
  return cursor - at - 1, cursor + 1
end

local function decode_literal(literal, label, line)
  local loader = loadstring or load
  local chunk, err = loader("return " .. literal, "@" .. label .. ":" .. line)
  if not chunk then
    error(("%s:%d: invalid string literal: %s"):format(label, line, err), 0)
  end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "string" then
    error(("%s:%d: could not decode string literal"):format(label, line), 0)
  end
  return value
end

--- Tokenize enough Lua syntax to distinguish real require calls from text in
--- comments and strings. Tokens retain source lines for actionable failures.
function G.lex(source, label)
  label = label or "<source>"
  local tokens = {}
  local at, line = 1, 1
  local length = #source

  local function fail(message, failure_line)
    error(("%s:%d: %s"):format(label, failure_line or line, message), 0)
  end

  local function skip_long(open_at, equals, content_at, kind)
    local closer = "]" .. string.rep("=", equals) .. "]"
    local close_at, close_end = source:find(closer, content_at, true)
    if not close_at then
      fail("unterminated long " .. kind)
    end
    line = line + count_newlines(source:sub(open_at, close_end))
    at = close_end + 1
    return close_at, close_end
  end

  while at <= length do
    local char = source:sub(at, at)
    local next_char = source:sub(at + 1, at + 1)

    if char == " " or char == "\t" or char == "\r" or char == "\f" or char == "\v" then
      at = at + 1
    elseif char == "\n" then
      line = line + 1
      at = at + 1
    elseif char == "-" and next_char == "-" then
      local equals, content_at = long_bracket_open(source, at + 2)
      if equals then
        skip_long(at, equals, content_at, "comment")
      else
        local newline = source:find("\n", at + 2, true)
        at = newline or (length + 1)
      end
    elseif char == "'" or char == '"' then
      local quote = char
      local start_at, start_line = at, line
      at = at + 1
      local closed = false

      while at <= length do
        char = source:sub(at, at)
        if char == "\\" then
          local escaped = source:sub(at + 1, at + 1)
          if escaped == "" then
            fail("unterminated quoted string", start_line)
          elseif escaped == "\n" then
            line = line + 1
            at = at + 2
          elseif escaped == "\r" and source:sub(at + 2, at + 2) == "\n" then
            line = line + 1
            at = at + 3
          elseif escaped == "z" then
            at = at + 2
            while at <= length and source:sub(at, at):match("%s") do
              if source:sub(at, at) == "\n" then
                line = line + 1
              end
              at = at + 1
            end
          else
            at = at + 2
          end
        elseif char == quote then
          at = at + 1
          closed = true
          break
        elseif char == "\n" or char == "\r" then
          fail("newline in quoted string", start_line)
        else
          at = at + 1
        end
      end

      if not closed then
        fail("unterminated quoted string", start_line)
      end
      local literal = source:sub(start_at, at - 1)
      tokens[#tokens + 1] = {
        kind = "string",
        line = start_line,
        value = decode_literal(literal, label, start_line),
      }
    elseif char == "[" then
      local start_at, start_line = at, line
      local equals, content_at = long_bracket_open(source, at)
      if equals then
        local _, close_end = skip_long(start_at, equals, content_at, "string")
        local literal = source:sub(start_at, close_end)
        tokens[#tokens + 1] = {
          kind = "string",
          line = start_line,
          value = decode_literal(literal, label, start_line),
        }
      else
        tokens[#tokens + 1] = { kind = "symbol", line = line, value = char }
        at = at + 1
      end
    elseif char:match("[%a_]") then
      local start_at = at
      at = at + 1
      while at <= length and source:sub(at, at):match("[%w_]") do
        at = at + 1
      end
      tokens[#tokens + 1] = {
        kind = "identifier",
        line = line,
        value = source:sub(start_at, at - 1),
      }
    else
      tokens[#tokens + 1] = { kind = "symbol", line = line, value = char }
      at = at + 1
    end
  end

  return tokens
end

--- Extract canonical, literal require calls. Indirect or computed requires
--- cannot be checked statically, so production code must not use them.
function G.requires(source, label)
  local tokens = G.lex(source, label)
  local dependencies = {}

  local function fail(token, message)
    error(("%s:%d: %s"):format(label or "<source>", token.line, message), 0)
  end

  for index, token in ipairs(tokens) do
    if token.kind == "identifier" and token.value == "require" then
      local previous = tokens[index - 1]
      local is_member = previous
        and previous.kind == "symbol"
        and (previous.value == "." or previous.value == ":")

      if not is_member then
        local following = tokens[index + 1]
        local argument

        if following and following.kind == "symbol" and following.value == "(" then
          argument = tokens[index + 2]
          if not argument or argument.kind ~= "string" then
            fail(token, "require argument must be one static string literal")
          end
          local closing = tokens[index + 3]
          if not closing or closing.kind ~= "symbol" or closing.value ~= ")" then
            fail(token, "require must have exactly one static string argument")
          end
        elseif following and following.kind == "string" then
          argument = following
        else
          fail(token, "require must be called directly with a static string literal")
        end

        dependencies[#dependencies + 1] = {
          line = token.line,
          module = argument.value,
        }
      end
    end
  end

  return dependencies
end

--- List tracked and untracked, non-ignored source files as they exist in the
--- worktree. NUL separation keeps whitespace and unusual path bytes intact.
function G.source_files(root)
  local result = vim.system({
    "git",
    "ls-files",
    "-z",
    "--cached",
    "--others",
    "--exclude-standard",
    "--",
    "lua",
    "plugin",
    "test",
    "tests",
  }, { cwd = root }):wait()

  if result.code ~= 0 then
    error(("git ls-files failed in %s: %s"):format(root, result.stderr or ""), 0)
  end

  local files = {}
  for relative in (result.stdout or ""):gmatch("([^%z]+)") do
    if relative:match("%.lua$") then
      local absolute = vim.fs.joinpath(root, relative)
      local stat = vim.uv.fs_stat(absolute)
      if stat and stat.type == "file" then
        files[#files + 1] = { abs = absolute, rel = relative }
      end
    end
  end
  table.sort(files, function(left, right)
    return left.rel < right.rel
  end)
  return files
end

function G.module_id(relative)
  local path = relative:match("^lua/(.+)%.lua$")
  if not path then
    return nil
  end
  path = path:gsub("/init$", "")
  return path:gsub("/", ".")
end

function G.inspect(root)
  local inspection = {
    edges = {},
    errors = {},
    files = G.source_files(root),
    modules = {},
    nodes = {},
  }

  for _, file in ipairs(inspection.files) do
    local module = G.module_id(file.rel)
    if module then
      if inspection.modules[module] then
        inspection.errors[#inspection.errors + 1] = (
          "duplicate module %q: %s and %s"
        ):format(module, inspection.modules[module], file.rel)
      else
        inspection.modules[module] = file.rel
      end
      inspection.nodes[module] = { module = module, rel = file.rel }
    elseif file.rel:match("^plugin/") then
      local node = "@" .. file.rel
      inspection.nodes[node] = { module = node, rel = file.rel }
    end
  end

  for _, file in ipairs(inspection.files) do
    if file.rel:match("^lua/") or file.rel:match("^plugin/") then
      local source, read_err = read_file(file.abs)
      if not source then
        inspection.errors[#inspection.errors + 1] = (
          "%s: could not read source: %s"
        ):format(file.rel, read_err or "")
      else
        local ok, dependencies = pcall(G.requires, source, file.rel)
        if not ok then
          inspection.errors[#inspection.errors + 1] = tostring(dependencies)
        else
          local from = G.module_id(file.rel) or ("@" .. file.rel)
          for _, dependency in ipairs(dependencies) do
            local internal = dependency.module == "canvasdiff"
              or dependency.module:match("^canvasdiff%.") ~= nil
            if internal then
              local target_path = inspection.modules[dependency.module]
              if not target_path then
                inspection.errors[#inspection.errors + 1] = (
                  "%s:%d: unresolved internal require %q"
                ):format(file.rel, dependency.line, dependency.module)
              else
                inspection.edges[#inspection.edges + 1] = {
                  from = from,
                  from_path = file.rel,
                  line = dependency.line,
                  to = dependency.module,
                  to_path = target_path,
                }
              end
            end
          end
        end
      end
    end
  end

  table.sort(inspection.errors)
  table.sort(inspection.edges, function(left, right)
    if left.from ~= right.from then
      return left.from < right.from
    elseif left.to ~= right.to then
      return left.to < right.to
    end
    return left.line < right.line
  end)
  return inspection
end

--- Return the first deterministic cycle as `{a, b, ..., a}`, or nil.
function G.find_cycle(nodes, edges, include)
  local adjacency = {}
  for node in pairs(nodes) do
    if include(node) then
      adjacency[node] = {}
    end
  end
  for _, edge in ipairs(edges) do
    if edge.from ~= edge.to and adjacency[edge.from] and adjacency[edge.to] then
      adjacency[edge.from][#adjacency[edge.from] + 1] = edge.to
    end
  end
  for _, targets in pairs(adjacency) do
    table.sort(targets)
  end

  local ordered = vim.tbl_keys(adjacency)
  table.sort(ordered)
  local state, stack, position = {}, {}, {}

  local function visit(node)
    state[node] = "visiting"
    stack[#stack + 1] = node
    position[node] = #stack

    for _, target in ipairs(adjacency[node]) do
      if state[target] == "visiting" then
        local cycle = {}
        for index = position[target], #stack do
          cycle[#cycle + 1] = stack[index]
        end
        cycle[#cycle + 1] = target
        return cycle
      elseif not state[target] then
        local cycle = visit(target)
        if cycle then
          return cycle
        end
      end
    end

    position[node] = nil
    stack[#stack] = nil
    state[node] = "visited"
    return nil
  end

  for _, node in ipairs(ordered) do
    if not state[node] then
      local cycle = visit(node)
      if cycle then
        return cycle
      end
    end
  end
  return nil
end

return G
