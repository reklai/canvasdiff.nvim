-- Minimal msgpack-RPC UI client for the screenshot rig. Runs under `nvim -l`:
-- spawns a second Neovim with --embed, attaches as an ext_linegrid UI, and
-- keeps a cell-accurate model of the composed screen (statuscolumn, winbar,
-- floats and all), which render.lua turns into an SVG.
--
-- The codec is written out by hand because LuaJIT has no string.pack and
-- vim.mpack's streaming API is not part of the supported surface.
local bit = require("bit")

local M = {}

-- --- msgpack encode (only the shapes a client sends) ------------------------

local function enc_uint(n, out)
  if n < 0x80 then
    out[#out + 1] = string.char(n)
  elseif n < 0x100 then
    out[#out + 1] = string.char(0xcc, n)
  elseif n < 0x10000 then
    out[#out + 1] = string.char(0xcd, bit.rshift(n, 8), bit.band(n, 0xff))
  else
    out[#out + 1] = string.char(0xce,
      bit.band(bit.rshift(n, 24), 0xff), bit.band(bit.rshift(n, 16), 0xff),
      bit.band(bit.rshift(n, 8), 0xff), bit.band(n, 0xff))
  end
end

local function encode(value, out)
  out = out or {}
  local t = type(value)
  if value == nil then
    out[#out + 1] = "\xc0"
  elseif t == "boolean" then
    out[#out + 1] = value and "\xc3" or "\xc2"
  elseif t == "number" then
    if value >= 0 then
      enc_uint(value, out)
    elseif value >= -32 then
      out[#out + 1] = string.char(0x100 + value)
    else
      local n = value + 0x100000000
      out[#out + 1] = string.char(0xd2,
        bit.band(bit.rshift(n, 24), 0xff), bit.band(bit.rshift(n, 16), 0xff),
        bit.band(bit.rshift(n, 8), 0xff), bit.band(n, 0xff))
    end
  elseif t == "string" then
    local len = #value
    if len < 32 then
      out[#out + 1] = string.char(0xa0 + len)
    elseif len < 0x100 then
      out[#out + 1] = string.char(0xd9, len)
    else
      out[#out + 1] = string.char(0xda, bit.rshift(len, 8), bit.band(len, 0xff))
    end
    out[#out + 1] = value
  elseif t == "table" then
    local n = #value
    local is_array = n > 0 or next(value) == nil
    if is_array then
      if n < 16 then
        out[#out + 1] = string.char(0x90 + n)
      else
        out[#out + 1] = string.char(0xdc, bit.rshift(n, 8), bit.band(n, 0xff))
      end
      for i = 1, n do encode(value[i], out) end
    else
      local keys = {}
      for k in pairs(value) do keys[#keys + 1] = k end
      if #keys < 16 then
        out[#out + 1] = string.char(0x80 + #keys)
      else
        out[#out + 1] = string.char(0xde,
          bit.rshift(#keys, 8), bit.band(#keys, 0xff))
      end
      for _, k in ipairs(keys) do
        encode(k, out)
        encode(value[k], out)
      end
    end
  else
    error("cannot encode " .. t)
  end
  return out
end

function M.encode(value)
  return table.concat(encode(value))
end

-- --- msgpack decode (everything a Neovim server may send) --------------------

local TRUNCATED = {}

local function need(buf, pos, n)
  if pos + n - 1 > #buf then error(TRUNCATED) end
end

local function ru(buf, pos, n)
  need(buf, pos, n)
  local v = 0
  for i = 0, n - 1 do
    v = v * 256 + buf:byte(pos + i)
  end
  return v, pos + n
end

local function rf64(buf, pos)
  need(buf, pos, 8)
  local b = { buf:byte(pos, pos + 7) }
  local sign = b[1] >= 0x80 and -1 or 1
  local exp = (b[1] % 0x80) * 16 + math.floor(b[2] / 16)
  local mant = b[2] % 16
  for i = 3, 8 do mant = mant * 256 + b[i] end
  local value
  if exp == 0 then
    value = mant * 2 ^ -1074
  elseif exp == 0x7ff then
    value = mant == 0 and math.huge or (0 / 0)
  else
    value = (1 + mant / 2 ^ 52) * 2 ^ (exp - 1023)
  end
  return sign * value, pos + 8
end

local decode

local function rstr(buf, pos, len)
  need(buf, pos, len)
  return buf:sub(pos, pos + len - 1), pos + len
end

local function rarr(buf, pos, n)
  local out = {}
  for i = 1, n do
    out[i], pos = decode(buf, pos)
  end
  return out, pos
end

local function rmap(buf, pos, n)
  local out = {}
  for _ = 1, n do
    local k, v
    k, pos = decode(buf, pos)
    v, pos = decode(buf, pos)
    out[k] = v
  end
  return out, pos
end

decode = function(buf, pos)
  need(buf, pos, 1)
  local b = buf:byte(pos)
  pos = pos + 1
  if b < 0x80 then return b, pos end
  if b >= 0xe0 then return b - 0x100, pos end
  if b >= 0xa0 and b <= 0xbf then return rstr(buf, pos, b - 0xa0) end
  if b >= 0x90 and b <= 0x9f then return rarr(buf, pos, b - 0x90) end
  if b >= 0x80 and b <= 0x8f then return rmap(buf, pos, b - 0x80) end
  if b == 0xc0 then return nil, pos end
  if b == 0xc2 then return false, pos end
  if b == 0xc3 then return true, pos end
  if b == 0xca then
    local raw; raw, pos = ru(buf, pos, 4)
    local sign = raw >= 0x80000000 and -1 or 1
    local exp = math.floor(raw / 2 ^ 23) % 0x100
    local mant = raw % 2 ^ 23
    if exp == 0 then return sign * mant * 2 ^ -149, pos end
    if exp == 0xff then return sign * math.huge, pos end
    return sign * (1 + mant / 2 ^ 23) * 2 ^ (exp - 127), pos
  end
  if b == 0xcb then return rf64(buf, pos) end
  if b >= 0xcc and b <= 0xcf then return ru(buf, pos, 2 ^ (b - 0xcc)) end
  if b >= 0xd0 and b <= 0xd3 then
    local n = 2 ^ (b - 0xd0)
    local v; v, pos = ru(buf, pos, n)
    local limit = 2 ^ (n * 8 - 1)
    if v >= limit then v = v - 2 * limit end
    return v, pos
  end
  if b == 0xd9 or b == 0xc4 then
    local len; len, pos = ru(buf, pos, 1)
    return rstr(buf, pos, len)
  end
  if b == 0xda or b == 0xc5 then
    local len; len, pos = ru(buf, pos, 2)
    return rstr(buf, pos, len)
  end
  if b == 0xdb or b == 0xc6 then
    local len; len, pos = ru(buf, pos, 4)
    return rstr(buf, pos, len)
  end
  if b == 0xdc then
    local n; n, pos = ru(buf, pos, 2)
    return rarr(buf, pos, n)
  end
  if b == 0xdd then
    local n; n, pos = ru(buf, pos, 4)
    return rarr(buf, pos, n)
  end
  if b == 0xde then
    local n; n, pos = ru(buf, pos, 2)
    return rmap(buf, pos, n)
  end
  if b == 0xdf then
    local n; n, pos = ru(buf, pos, 4)
    return rmap(buf, pos, n)
  end
  if b >= 0xd4 and b <= 0xd8 then -- fixext: type byte + payload
    local len = 2 ^ (b - 0xd4)
    local etype; etype, pos = ru(buf, pos, 1)
    local data; data, pos = rstr(buf, pos, len)
    return { __ext = etype, data = data }, pos
  end
  if b >= 0xc7 and b <= 0xc9 then
    local len; len, pos = ru(buf, pos, 2 ^ (b - 0xc7))
    local etype; etype, pos = ru(buf, pos, 1)
    local data; data, pos = rstr(buf, pos, len)
    return { __ext = etype, data = data }, pos
  end
  error(("unhandled msgpack byte 0x%02x"):format(b))
end

-- --- the screen-grid model ---------------------------------------------------

local Grid = {}
Grid.__index = Grid

function Grid.new()
  return setmetatable({
    hl = { [0] = {} },
    default_fg = 0xffffff,
    default_bg = 0x000000,
    default_sp = 0xff0000,
    rows = {},
    width = 0,
    height = 0,
    cursor = { row = 0, col = 0 },
  }, Grid)
end

function Grid:blank_row()
  local row = {}
  for c = 1, self.width do row[c] = { " ", 0 } end
  return row
end

function Grid:apply(name, args)
  if name == "grid_resize" then
    self.width, self.height = args[2], args[3]
    for r = 1, self.height do self.rows[r] = self:blank_row() end
  elseif name == "default_colors_set" then
    self.default_fg = args[1]
    self.default_bg = args[2]
    self.default_sp = args[3]
  elseif name == "hl_attr_define" then
    self.hl[args[1]] = args[2]
  elseif name == "grid_clear" then
    for r = 1, self.height do self.rows[r] = self:blank_row() end
  elseif name == "grid_line" then
    local row = self.rows[args[2] + 1]
    local col = args[3] + 1
    local last_hl = 0
    for _, cell in ipairs(args[4]) do
      local text = cell[1]
      local hl = cell[2] or last_hl
      local rep = cell[3] or 1
      last_hl = hl
      for _ = 1, rep do
        row[col] = { text, hl }
        col = col + 1
      end
    end
  elseif name == "grid_scroll" then
    local top, bot = args[2], args[3]
    local delta = args[6]
    if delta > 0 then
      for r = top, bot - 1 - delta do
        self.rows[r + 1] = self.rows[r + 1 + delta]
      end
      for r = bot - delta, bot - 1 do
        self.rows[r + 1] = self:blank_row()
      end
    else
      for r = bot - 1, top - delta, -1 do
        self.rows[r + 1] = self.rows[r + 1 + delta]
      end
      for r = top, top - delta - 1 do
        self.rows[r + 1] = self:blank_row()
      end
    end
  elseif name == "grid_cursor_goto" then
    self.cursor.row, self.cursor.col = args[2], args[3]
  end
end

-- --- the client ---------------------------------------------------------------

local Client = {}
Client.__index = Client

function M.spawn(opts)
  local uv = vim.uv
  local self = setmetatable({
    buf = "",
    msgid = 0,
    responses = {},
    grid = Grid.new(),
    stderr_text = {},
    exited = false,
  }, Client)

  self.stdin = uv.new_pipe()
  self.stdout = uv.new_pipe()
  self.stderr = uv.new_pipe()
  self.proc = uv.spawn("nvim", {
    args = opts.args,
    cwd = opts.cwd,
    env = opts.env,
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function()
    self.exited = true
  end)
  assert(self.proc, "failed to spawn nvim")

  self.stdout:read_start(function(err, data)
    assert(not err, err)
    if data then
      self.buf = self.buf .. data
      self:drain()
    end
  end)
  self.stderr:read_start(function(err, data)
    if not err and data then
      self.stderr_text[#self.stderr_text + 1] = data
    end
  end)

  self:request("nvim_ui_attach", opts.width, opts.height,
    { rgb = true, ext_linegrid = true })
  return self
end

function Client:drain()
  local pos = 1
  while true do
    local ok, msg, newpos = pcall(decode, self.buf, pos)
    if not ok then
      if msg == TRUNCATED or tostring(msg):find("TRUNCATED") then break end
      -- A decode bug would loop forever; surface it instead.
      error(msg)
    end
    pos = newpos
    if msg[1] == 1 then
      self.responses[msg[2]] = { error = msg[3], result = msg[4] }
    elseif msg[1] == 2 and msg[2] == "redraw" then
      for _, batch in ipairs(msg[3]) do
        local name = batch[1]
        for i = 2, #batch do
          self.grid:apply(name, batch[i])
        end
      end
    end
    if pos > #self.buf then break end
  end
  self.buf = self.buf:sub(pos)
end

function Client:request(method, ...)
  self.msgid = self.msgid + 1
  local id = self.msgid
  self.stdin:write(M.encode({ 0, id, method, { ... } }))
  local ok = vim.wait(15000, function()
    return self.responses[id] ~= nil or self.exited
  end, 5)
  assert(ok and self.responses[id],
    ("no response to %s; stderr: %s"):format(
      method, table.concat(self.stderr_text)))
  local response = self.responses[id]
  self.responses[id] = nil
  assert(response.error == nil,
    method .. " failed: " .. vim.inspect(response.error))
  return response.result
end

function Client:lua(code, ...)
  return self:request("nvim_exec_lua", code, { ... })
end

function Client:input(keys)
  self:request("nvim_input", keys)
  self:settle()
end

-- Input and redraw are asynchronous; a round-trip after a short grace period
-- means everything the action caused has been flushed to the grid.
function Client:settle(ms)
  vim.wait(ms or 120, function() return false end, 10)
  self:request("nvim_eval", "1")
  vim.wait(30, function() return false end, 10)
end

function Client:close()
  pcall(function() self:request("nvim_command", "qa!") end)
  vim.wait(500, function() return self.exited end, 10)
  if not self.exited then self.proc:kill("sigterm") end
end

-- The TRUNCATED sentinel must be reachable from the pcall boundary above.
M.TRUNCATED = TRUNCATED

return M
