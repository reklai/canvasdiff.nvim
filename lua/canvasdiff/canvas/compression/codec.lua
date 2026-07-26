local Codec = {}

local floor = math.floor
local rawget = rawget
local RAW_EQUAL = rawequal
local type = type
local NATIVE_LIBRARY_ANCHOR = {}

Codec.RAW_TAG = "raw"
Codec.LZ4_TAG = "lz4-block-v1"
Codec.RAW = Codec.RAW_TAG
Codec.LZ4_BLOCK = Codec.LZ4_TAG
Codec.tags = {
  raw = Codec.RAW_TAG,
  lz4 = Codec.LZ4_TAG,
}

Codec.SIGNED_INT_MAX = 2147483647
Codec.LZ4_MAX_INPUT_SIZE = 0x7E000000
local LZ4_LIBRARY_CANDIDATES = {
  "lz4",
  "liblz4.so.1",
  "liblz4.so",
  "liblz4.dylib",
  "liblz4.dll",
  "lz4.dll",
}
Codec.LZ4_LIBRARY_CANDIDATES = {}
for index, candidate in ipairs(LZ4_LIBRARY_CANDIDATES) do
  Codec.LZ4_LIBRARY_CANDIDATES[index] = candidate
end

local function integer_at_most(value, maximum)
  return type(value) == "number"
    and value >= 0
    and value <= maximum
    and value == floor(value)
end

local function capability(available, fields)
  local result = {
    available = available,
    tag = Codec.LZ4_TAG,
  }
  if fields then
    for key, value in pairs(fields) do
      result[key] = value
    end
  end
  return result
end

local function unavailable(reason)
  return nil, capability(false, {
    backend = "unavailable",
    reason = reason,
  })
end

local function protected_member(driver, name)
  local ok, value = pcall(function()
    return driver[name]
  end)
  if not ok then
    return nil, "lz4 driver inspection failed"
  end
  if type(value) ~= "function" then
    return nil, "lz4 driver is missing " .. name
  end
  return value
end

local function protected_call(operation, callback, ...)
  local result = { pcall(callback, ...) }
  if not result[1] then
    return nil, "lz4 " .. operation .. " failed"
  end
  if RAW_EQUAL(result[2], nil) then
    return nil, "lz4 " .. operation .. " failed"
  end
  return result[2], result[3]
end

local function adapter_for(driver, metadata)
  if type(driver) ~= "table" then
    return unavailable("lz4 driver must be a table")
  end

  local compress_bound, inspect_err = protected_member(driver, "compress_bound")
  if not compress_bound then
    return unavailable(inspect_err)
  end
  local compress
  compress, inspect_err = protected_member(driver, "compress")
  if not compress then
    return unavailable(inspect_err)
  end
  local decompress
  decompress, inspect_err = protected_member(driver, "decompress")
  if not decompress then
    return unavailable(inspect_err)
  end

  local adapter = {
    tag = Codec.LZ4_TAG,
  }

  function adapter.encode(raw, max_encoded_bytes)
    if type(raw) ~= "string" then
      return nil, "lz4 input must be a string"
    end
    if #raw > Codec.LZ4_MAX_INPUT_SIZE then
      return nil, "lz4 input exceeds the signed input limit"
    end
    if not integer_at_most(max_encoded_bytes, Codec.SIGNED_INT_MAX) then
      return nil, "lz4 encoded budget must be a non-negative signed integer"
    end
    if max_encoded_bytes == 0 then
      return false
    end

    local bound, bound_err = protected_call("compress bound", compress_bound, #raw)
    if RAW_EQUAL(bound, nil) then
      return nil, bound_err
    end
    if not integer_at_most(bound, Codec.SIGNED_INT_MAX) or bound == 0 then
      return nil, "lz4 driver returned an invalid compression bound"
    end

    local capacity = bound
    if capacity > max_encoded_bytes then
      capacity = max_encoded_bytes
    end
    if capacity == 0 then
      return false
    end

    local encoded, encode_err = protected_call("compress", compress, raw, capacity)
    if RAW_EQUAL(encoded, false) then
      return false
    end
    if RAW_EQUAL(encoded, nil) then
      return nil, encode_err
    end
    if type(encoded) ~= "string" then
      return nil, "lz4 driver returned a non-string block"
    end
    if #encoded > capacity then
      return nil, "lz4 driver returned a block larger than its capacity"
    end
    return encoded
  end

  function adapter.decode(block, expected_size)
    if type(block) ~= "string" then
      return nil, "lz4 block must be a string"
    end
    if #block > Codec.SIGNED_INT_MAX then
      return nil, "lz4 block exceeds the signed input limit"
    end
    if not integer_at_most(expected_size, Codec.SIGNED_INT_MAX) then
      return nil, "lz4 decoded size must be a non-negative signed integer"
    end

    local decoded, decode_err = protected_call(
      "decompress",
      decompress,
      block,
      expected_size
    )
    if RAW_EQUAL(decoded, nil) then
      return nil, decode_err
    end
    if RAW_EQUAL(decoded, false) then
      return nil, "lz4 decompress failed"
    end
    if type(decoded) ~= "string" then
      return nil, "lz4 driver returned a non-string decode"
    end
    if #decoded ~= expected_size then
      return nil, "lz4 decoded size does not match the expected size"
    end
    return decoded
  end

  return adapter, capability(true, metadata)
end

local function native_driver()
  local ffi_ok, ffi = pcall(function()
    return require("ffi")
  end)
  if not ffi_ok or type(ffi) ~= "table" then
    return nil, "LuaJIT FFI is unavailable"
  end

  local cdef_get_ok, cdef = pcall(function()
    return ffi.cdef
  end)
  local load_get_ok, load_library = pcall(function()
    return ffi.load
  end)
  local new_get_ok, allocate = pcall(function()
    return ffi.new
  end)
  local string_get_ok, copy_string = pcall(function()
    return ffi.string
  end)
  if not cdef_get_ok or type(cdef) ~= "function"
      or not load_get_ok or type(load_library) ~= "function"
      or not new_get_ok or type(allocate) ~= "function"
      or not string_get_ok or type(copy_string) ~= "function" then
    return nil, "LuaJIT FFI is missing a required operation"
  end

  local cdef_ok = pcall(cdef, [[
    int LZ4_versionNumber(void);
    int LZ4_compressBound(int inputSize);
    int LZ4_compress_default(
      const char *src,
      char *dst,
      int srcSize,
      int dstCapacity
    );
    int LZ4_decompress_safe(
      const char *src,
      char *dst,
      int compressedSize,
      int dstCapacity
    );
  ]])
  if not cdef_ok then
    return nil, "could not declare the LZ4 native interface"
  end

  local library_name
  local symbols
  local version
  local symbol_names = {
    "LZ4_versionNumber",
    "LZ4_compressBound",
    "LZ4_compress_default",
    "LZ4_decompress_safe",
  }
  for _, candidate in ipairs(LZ4_LIBRARY_CANDIDATES) do
    local load_ok, loaded = pcall(load_library, candidate)
    if load_ok and loaded then
      local found = {}
      local complete = true
      for _, name in ipairs(symbol_names) do
        local symbol_ok, symbol = pcall(function()
          return loaded[name]
        end)
        local symbol_type = type(symbol)
        if not symbol_ok
            or (symbol_type ~= "function" and symbol_type ~= "cdata") then
          complete = false
          break
        end
        found[name] = symbol
      end
      if complete then
        local version_ok, candidate_version = pcall(function()
          return tonumber(found.LZ4_versionNumber())
        end)
        if version_ok
            and integer_at_most(
              candidate_version,
              Codec.SIGNED_INT_MAX
            )
            and candidate_version > 0 then
          found[NATIVE_LIBRARY_ANCHOR] = loaded
          symbols = found
          version = candidate_version
          library_name = candidate
          break
        end
      end
    end
  end
  if not symbols then
    return nil, "the LZ4 native library is unavailable or incomplete"
  end

  local driver = {}

  function driver.version_number()
    return version
  end

  function driver.compress_bound(input_size)
    if not integer_at_most(input_size, Codec.LZ4_MAX_INPUT_SIZE) then
      return nil
    end
    return tonumber(symbols.LZ4_compressBound(input_size))
  end

  function driver.compress(raw, capacity)
    if type(raw) ~= "string"
        or #raw > Codec.LZ4_MAX_INPUT_SIZE
        or not integer_at_most(capacity, Codec.SIGNED_INT_MAX)
        or capacity == 0 then
      return nil
    end

    local destination = allocate("char[?]", capacity)
    local written = tonumber(symbols.LZ4_compress_default(
      raw,
      destination,
      #raw,
      capacity
    ))
    if not written then
      return nil
    end
    if written == 0 then
      return false
    end
    if written < 0 or written > capacity then
      return nil
    end
    return copy_string(destination, written)
  end

  function driver.decompress(block, expected_size)
    if type(block) ~= "string"
        or #block > Codec.SIGNED_INT_MAX
        or not integer_at_most(expected_size, Codec.SIGNED_INT_MAX) then
      return nil
    end

    local destination = allocate("char[?]", expected_size)
    local written = tonumber(symbols.LZ4_decompress_safe(
      block,
      destination,
      #block,
      expected_size
    ))
    if not written or written < 0 or written ~= expected_size then
      return nil
    end
    return copy_string(destination, written)
  end

  local version, version_err = protected_call(
    "version probe",
    driver.version_number
  )
  if RAW_EQUAL(version, nil) then
    return nil, version_err
  end
  if not integer_at_most(version, Codec.SIGNED_INT_MAX) or version == 0 then
    return nil, "the LZ4 native library returned an invalid version"
  end

  return driver, {
    backend = "native-ffi",
    library = library_name,
    version = version,
  }
end

--- Lazily acquire an LZ4 block adapter.
---
--- An injected driver is a table of plain callbacks:
--- `compress_bound(size)`, `compress(raw, capacity)`, and
--- `decompress(block, expected_size)`. Every callback is protected. Passing
--- `driver = false` deterministically disables the optional capability.
function Codec.lz4(opts)
  if RAW_EQUAL(opts, nil) then
    opts = {}
  elseif type(opts) ~= "table" then
    return unavailable("lz4 options must be a table")
  end

  local configured = rawget(opts, "driver")
  if RAW_EQUAL(configured, false) then
    return unavailable("lz4 was disabled by configuration")
  end
  if not RAW_EQUAL(configured, nil) then
    return adapter_for(configured, {
      backend = "injected",
    })
  end

  local driver, metadata_or_error = native_driver()
  if not driver then
    return unavailable(metadata_or_error)
  end
  return adapter_for(driver, metadata_or_error)
end

local XOR_NIBBLE = {}
for left = 0, 15 do
  local row = {}
  for right = 0, 15 do
    local a = left
    local b = right
    local result = 0
    local place = 1
    for _ = 1, 4 do
      if a % 2 ~= b % 2 then
        result = result + place
      end
      a = floor(a / 2)
      b = floor(b / 2)
      place = place * 2
    end
    row[right] = result
  end
  XOR_NIBBLE[left] = row
end

local function arithmetic_xor32(left, right)
  local result = 0
  local place = 1
  for _ = 1, 8 do
    local left_nibble = left % 16
    local right_nibble = right % 16
    result = result + XOR_NIBBLE[left_nibble][right_nibble] * place
    left = floor(left / 16)
    right = floor(right / 16)
    place = place * 16
  end
  return result
end

local BIT_XOR
do
  local bit_library = rawget(_G, "bit")
  if type(bit_library) ~= "table" then
    bit_library = rawget(_G, "bit32")
  end
  if type(bit_library) == "table" then
    local candidate = rawget(bit_library, "bxor")
    if type(candidate) == "function" then
      local ok, value = pcall(candidate, 0x5A, 0xA5)
      if ok and value == 0xFF then
        BIT_XOR = candidate
      end
    end
  end
end

local function xor32(left, right)
  if BIT_XOR then
    return BIT_XOR(left, right) % 4294967296
  end
  return arithmetic_xor32(left, right)
end

local CRC_TABLE = {}
for byte = 0, 255 do
  local value = byte
  for _ = 1, 8 do
    if value % 2 == 1 then
      value = xor32(floor(value / 2), 0xEDB88320)
    else
      value = floor(value / 2)
    end
  end
  CRC_TABLE[byte] = value
end

--- Return the unsigned IEEE CRC-32 of an arbitrary byte string.
---
--- LuaJIT's bit operation is used when already present; the exact arithmetic
--- path produces the same unsigned result on a plain Lua runtime.
function Codec.crc32(raw)
  if type(raw) ~= "string" then
    return nil, "crc32 input must be a string"
  end

  local checksum = 0xFFFFFFFF
  for index = 1, #raw do
    local table_index = xor32(checksum % 256, string.byte(raw, index))
    checksum = xor32(floor(checksum / 256), CRC_TABLE[table_index])
  end
  return xor32(checksum, 0xFFFFFFFF)
end

function Codec.crc32_hex(raw)
  local checksum, err = Codec.crc32(raw)
  if checksum == nil then
    return nil, err
  end
  return string.format("%08x", checksum)
end

return Codec
