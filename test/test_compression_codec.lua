local H = require("helpers")
local Codec = require("canvasdiff.canvas.compression.codec")

local T = {}

local function fake_driver(overrides)
  overrides = overrides or {}
  local driver = {}

  driver.compress_bound = overrides.compress_bound or function(size)
    return size + 1
  end
  driver.compress = overrides.compress or function(raw, capacity)
    local block = "\1" .. raw:reverse()
    if #block > capacity then
      return false
    end
    return block
  end
  driver.decompress = overrides.decompress or function(block)
    if block:sub(1, 1) ~= "\1" then
      return nil
    end
    return block:sub(2):reverse()
  end
  return driver
end

local function injected(driver)
  local adapter, capability = Codec.lz4({ driver = driver })
  assert(adapter, capability and capability.reason)
  H.eq(capability.available, true)
  H.eq(capability.backend, "injected")
  H.eq(capability.tag, "lz4-block-v1")
  return adapter
end

T["compression_codec_ module load is editor-free and does not probe FFI"] = function()
  local root = vim.fs.dirname(vim.fs.dirname(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  local path = vim.fs.joinpath(
    root,
    "lua",
    "canvasdiff",
    "canvas",
    "compression",
    "codec.lua"
  )
  local original_vim = _G.vim
  local original_bit = _G.bit
  local original_bit32 = _G.bit32
  local original_require = _G.require
  local ffi_probes = 0
  _G.vim = nil
  _G.bit = nil
  _G.bit32 = nil
  _G.require = function(name)
    if name == "ffi" then
      ffi_probes = ffi_probes + 1
      error("ffi must not be loaded")
    end
    return original_require(name)
  end

  local ok, loaded = pcall(assert(loadfile(path)))
  _G.require = original_require
  _G.bit = original_bit
  _G.bit32 = original_bit32
  _G.vim = original_vim

  assert(ok, loaded)
  H.eq(ffi_probes, 0)
  H.eq(loaded.RAW_TAG, "raw")
  H.eq(loaded.LZ4_TAG, "lz4-block-v1")
  H.eq(type(loaded.lz4), "function")
  H.eq(loaded.crc32("123456789"), 0xCBF43926)
end

T["compression_codec_ injected driver round-trips binary strings"] = function()
  local adapter = injected(fake_driver())
  local raw = table.concat({
    "",
    "\0",
    string.char(0xFF, 0x80, 0x01),
    "終わり",
    "\0tail",
  })
  local block = assert(adapter.encode(raw, #raw + 1))

  H.eq(block, "\1" .. raw:reverse())
  H.eq(adapter.decode(block, #raw), raw)
  H.eq(adapter.tag, Codec.LZ4_TAG)
  H.eq(Codec.tags, {
    raw = "raw",
    lz4 = "lz4-block-v1",
  })
end

T["compression_codec_ encode honors the exact destination budget"] = function()
  local capacities = {}
  local driver = fake_driver({
    compress = function(raw, capacity)
      capacities[#capacities + 1] = capacity
      local block = "\1" .. raw
      if #block > capacity then
        return false
      end
      return block
    end,
  })
  local adapter = injected(driver)

  H.eq(adapter.encode("abc", 0), false)
  H.eq(adapter.encode("abc", 3), false)
  H.eq(adapter.encode("abc", 4), "\1abc")
  H.eq(capacities, { 3, 4 })
end

T["compression_codec_ unavailable is a capability rather than an exception"] = function()
  local adapter, capability = Codec.lz4({ driver = false })
  H.eq(adapter, nil)
  H.eq(capability.available, false)
  H.eq(capability.backend, "unavailable")
  H.eq(capability.tag, Codec.LZ4_TAG)
  assert(capability.reason:find("disabled", 1, true), capability.reason)

  adapter, capability = Codec.lz4(false)
  H.eq(adapter, nil)
  H.eq(capability.available, false)
  assert(capability.reason:find("options", 1, true), capability.reason)

  adapter, capability = Codec.lz4({ driver = {} })
  H.eq(adapter, nil)
  H.eq(capability.available, false)
  assert(capability.reason:find("compress_bound", 1, true), capability.reason)

  local hostile = setmetatable({}, {
    __index = function()
      error(string.rep("hostile", 1000))
    end,
  })
  local ok
  ok, adapter, capability = pcall(Codec.lz4, { driver = hostile })
  H.eq(ok, true)
  H.eq(adapter, nil)
  H.eq(capability.available, false)
  assert(#capability.reason < 100, capability.reason)
end

T["compression_codec_ cdata cannot run equality inside adapter fences"] =
  function()
    local ffi = require("ffi")
    ffi.cdef([[
      typedef struct {
        int value;
      } canvasdiff_codec_equality_probe;
    ]])
    local calls = 0
    local Probe = ffi.metatype("canvasdiff_codec_equality_probe", {
      __eq = function()
        calls = calls + 1
        return false
      end,
    })
    local probe = Probe(0)

    local adapter, capability = Codec.lz4({ driver = probe })
    H.eq(adapter, nil)
    H.eq(capability.available, false)
    assert(capability.reason:find("must be a table", 1, true), capability.reason)
    H.eq(calls, 0)

    adapter = injected(fake_driver({
      compress = function() return probe end,
      decompress = function() return probe end,
    }))
    local encoded, encode_err = adapter.encode("abc", 4)
    H.eq(encoded, nil)
    assert(encode_err:find("non-string block", 1, true), encode_err)
    local decoded, decode_err = adapter.decode("\1abc", 3)
    H.eq(decoded, nil)
    assert(decode_err:find("non-string decode", 1, true), decode_err)
    H.eq(calls, 0)
  end

T["compression_codec_ encode contains every injected driver fault"] = function()
  local cases = {
    {
      fake_driver({
        compress_bound = function()
          error(string.rep("bound", 1000))
        end,
      }),
      "compress bound failed",
    },
    {
      fake_driver({ compress_bound = function() return "4" end }),
      "invalid compression bound",
    },
    {
      fake_driver({ compress_bound = function() return -1 end }),
      "invalid compression bound",
    },
    {
      fake_driver({ compress_bound = function() return 1.5 end }),
      "invalid compression bound",
    },
    {
      fake_driver({
        compress_bound = function()
          return Codec.SIGNED_INT_MAX + 1
        end,
      }),
      "invalid compression bound",
    },
    {
      fake_driver({
        compress = function()
          error(string.rep("compress", 1000))
        end,
      }),
      "compress failed",
    },
    {
      fake_driver({ compress = function() return nil end }),
      "compress failed",
    },
    {
      fake_driver({ compress = function() return 42 end }),
      "non-string block",
    },
    {
      fake_driver({ compress = function() return "oversized" end }),
      "larger than its capacity",
    },
  }

  for _, case in ipairs(cases) do
    local adapter = injected(case[1])
    local ok, encoded, err = pcall(adapter.encode, "abc", 4)
    H.eq(ok, true)
    H.eq(encoded, nil)
    assert(err:find(case[2], 1, true), err)
    assert(#err < 100, err)
  end

  local adapter = injected(fake_driver())
  H.eq(adapter.encode(false, 4), nil)
  H.eq(adapter.encode("abc", false), nil)
  H.eq(adapter.encode("abc", -1), nil)
  H.eq(adapter.encode("abc", 1.5), nil)
  H.eq(adapter.encode("abc", math.huge), nil)
  H.eq(adapter.encode("abc", 0 / 0), nil)
end

T["compression_codec_ decode contains faults and requires the exact size"] = function()
  local cases = {
    {
      fake_driver({
        decompress = function()
          error(string.rep("decode", 1000))
        end,
      }),
      "decompress failed",
    },
    {
      fake_driver({ decompress = function() return nil end }),
      "decompress failed",
    },
    {
      fake_driver({ decompress = function() return false end }),
      "decompress failed",
    },
    {
      fake_driver({
        decompress = function()
          return false, string.rep("untrusted", 1000)
        end,
      }),
      "decompress failed",
    },
    {
      fake_driver({ decompress = function() return 42 end }),
      "non-string decode",
    },
    {
      fake_driver({ decompress = function() return "too long" end }),
      "does not match",
    },
  }

  for _, case in ipairs(cases) do
    local adapter = injected(case[1])
    local ok, decoded, err = pcall(adapter.decode, "\1abc", 3)
    H.eq(ok, true)
    H.eq(decoded, nil)
    assert(err:find(case[2], 1, true), err)
    assert(#err < 100, err)
  end

  local adapter = injected(fake_driver())
  local block = assert(adapter.encode("abc", 4))
  H.eq(adapter.decode(block, 2), nil)
  H.eq(adapter.decode(false, 3), nil)
  H.eq(adapter.decode(block, false), nil)
  H.eq(adapter.decode(block, -1), nil)
  H.eq(adapter.decode(block, 1.5), nil)
  H.eq(adapter.decode(block, math.huge), nil)
  H.eq(adapter.decode(block, 0 / 0), nil)
end

T["compression_codec_ native library candidates have a fixed probe order"] = function()
  local original = package.loaded.ffi
  local attempted = {}
  local published_first = Codec.LZ4_LIBRARY_CANDIDATES[1]
  Codec.LZ4_LIBRARY_CANDIDATES[1] = "mutated-public-copy"
  package.loaded.ffi = {
    cdef = function() end,
    new = function() end,
    string = function() end,
    load = function(name)
      attempted[#attempted + 1] = name
      error("missing")
    end,
  }

  local ok, adapter, capability = pcall(Codec.lz4)
  package.loaded.ffi = original
  Codec.LZ4_LIBRARY_CANDIDATES[1] = published_first

  H.eq(ok, true)
  H.eq(adapter, nil)
  H.eq(capability.available, false)
  H.eq(attempted, {
    "lz4",
    "liblz4.so.1",
    "liblz4.so",
    "liblz4.dylib",
    "liblz4.dll",
    "lz4.dll",
  })
end

T["compression_codec_ native probe skips an incomplete first library"] =
  function()
    local original = package.loaded.ffi
    local attempted = {}
    local complete = {
      LZ4_versionNumber = function() return 11000 end,
      LZ4_compressBound = function(size) return size + 1 end,
      LZ4_compress_default = function() return 0 end,
      LZ4_decompress_safe = function() return -1 end,
    }
    package.loaded.ffi = {
      cdef = function() end,
      new = function() end,
      string = function() end,
      load = function(name)
        attempted[#attempted + 1] = name
        if name == "lz4" then
          return {
            LZ4_versionNumber = function() return 11000 end,
          }
        end
        if name == "liblz4.so.1" then
          return complete
        end
        error("unexpected candidate " .. name)
      end,
    }

    local ok, adapter, capability = pcall(Codec.lz4)
    package.loaded.ffi = original

    H.eq(ok, true)
    assert(adapter, capability and capability.reason)
    H.eq(capability.available, true)
    H.eq(capability.library, "liblz4.so.1")
    H.eq(capability.version, 11000)
    H.eq(attempted, { "lz4", "liblz4.so.1" })
  end

T["compression_codec_ native adapter smoke is optional and binary exact"] = function()
  local adapter, capability = Codec.lz4()
  if not adapter then
    H.eq(capability.available, false)
    assert(type(capability.reason) == "string")
    return
  end

  H.eq(capability.available, true)
  H.eq(capability.backend, "native-ffi")
  assert(type(capability.version) == "number")
  assert(type(capability.library) == "string")

  local encode = adapter.encode
  local decode = adapter.decode
  adapter = nil
  collectgarbage("collect")
  collectgarbage("collect")
  local raw = string.rep("native-lz4\0", 128)
    .. string.char(0xFF, 0x80, 0x01)
  local block = assert(encode(raw, #raw))
  assert(#block <= #raw)
  H.eq(decode(block, #raw), raw)
  H.eq(decode(block, #raw + 1), nil)
  H.eq(decode(block:sub(1, #block - 1), #raw), nil)

  local empty_block = assert(encode("", 16))
  H.eq(decode(empty_block, 0), "")
end

T["compression_codec_ CRC-32 uses unsigned deterministic arithmetic"] = function()
  H.eq(Codec.crc32(""), 0)
  H.eq(Codec.crc32("123456789"), 0xCBF43926)
  H.eq(Codec.crc32_hex("123456789"), "cbf43926")
  H.eq(
    Codec.crc32("The quick brown fox jumps over the lazy dog"),
    0x414FA339
  )

  local binary = "\0\1\2\3" .. string.char(0xFF, 0x80) .. "\0"
  local first = assert(Codec.crc32(binary))
  H.eq(Codec.crc32(binary), first)
  H.eq(Codec.crc32_hex(binary), string.format("%08x", first))
  H.eq(Codec.crc32(false), nil)
  H.eq(Codec.crc32_hex(false), nil)
end

return T
