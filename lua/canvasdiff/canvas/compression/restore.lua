local Codec = require("canvasdiff.canvas.compression.codec")

local Restore = {}

--- The production resident-restore adapter: what a compacted page is encoded
--- with, and how it is proved intact on the way back.
---
--- The codec module already speaks `encode(raw, capacity)` and
--- `decode(block, size)`, which is exactly what PageList compaction calls, so
--- this is a naming bridge rather than a layer -- but it is the bridge that
--- was missing. Without it no PageList in production had a restore adapter
--- configured, so every compaction attempt failed with "adapter is not
--- configured" and the whole compaction tier was unreachable outside tests.
---
--- Compression is a CAPABILITY, not a requirement: a build without an lz4
--- library still runs, with pages left raw. Returning the reason rather than
--- throwing is what lets a caller record that in its own diagnostics.
--- @param opts table|nil forwarded to the codec's driver selection
--- @return table|nil adapter { codec, encode, decode, crc32 }
--- @return table|nil capability why it is unavailable, when it is
function Restore.adapter(opts)
  local codec, capability = Codec.lz4(opts)
  if not codec then
    return nil, capability
  end
  return {
    codec = codec.tag,
    encode = codec.encode,
    decode = codec.decode,
    crc32 = Codec.crc32,
  }
end

--- Whether compaction is available here, and why not when it is not.
--- @return table capability
function Restore.capability(opts)
  local adapter, capability = Restore.adapter(opts)
  if adapter then
    return { available = true, codec = adapter.codec }
  end
  return capability or { available = false, reason = "unknown" }
end

return Restore
