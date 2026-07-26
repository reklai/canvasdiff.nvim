local codec = require("canvasdiff.session.codec")

-- Session persistence enters through this exact facade. Payload shape,
-- serialization, storage, and semantic viewport restoration stay owned by the
-- internal codec.
return {
  capture = codec.capture,
  load = codec.load,
  path_for = codec.path_for,
  restore = codec.restore,
  save = codec.save,
}
