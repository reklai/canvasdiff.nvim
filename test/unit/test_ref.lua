local H = require("helpers")
local ref = require("canvasdiff.source.ref")

local T = {}

T["ref_format describes branch roles without changing execution identity"] = function()
  H.eq(ref.format({
    ref = "refs/heads/main", name = "main", kind = "local", current = true,
  }), "main [checked out]")
  H.eq(ref.format({
    ref = "refs/remotes/origin/HEAD", name = "origin/HEAD",
    kind = "remote", remote_default = true,
  }), "origin/HEAD [default for origin]")
  H.eq(ref.format({
    ref = "refs/remotes/upstream/topic", name = "upstream/topic",
    kind = "remote",
  }), "upstream/topic [remote-tracking ref]")
  H.eq(ref.format({
    ref = "refs/heads/topic", name = "topic", kind = "local",
  }), "topic")
end

T["ref_filters preserve order and return independent record copies"] = function()
  local items = {
    { ref = "refs/remotes/origin/topic", name = "origin/topic", kind = "remote" },
    { ref = "refs/heads/zeta", name = "zeta", kind = "local", current = true },
    {
      ref = "refs/remotes/origin/HEAD", name = "origin/HEAD",
      kind = "remote", remote_default = true,
    },
    { ref = "refs/heads/alpha", name = "alpha", kind = "local", current = false },
    { ref = "refs/remotes/upstream/topic", name = "upstream/topic", kind = "remote" },
  }

  local locals = ref.local_branches(items)
  H.eq(vim.tbl_map(function(item) return item.name end, locals), { "zeta", "alpha" },
    "local filtering excludes every remote ref without sorting")

  locals[1].name = "changed"
  H.eq(items[2].name, "zeta", "local results do not alias input records")
end

T["ref_remote_name derives only symbolic-default remotes from the full ref"] = function()
  H.eq(ref.remote_name({
    ref = "refs/remotes/origin/HEAD",
    name = "wrong/HEAD",
    kind = "remote",
  }), "origin")
  H.eq(ref.remote_name({
    ref = "refs/remotes/upstream/topic",
    name = "upstream/HEAD",
    kind = "remote",
  }), nil, "the display name cannot fabricate a symbolic default")
  H.eq(ref.remote_name({ ref = "refs/remotes/team/sub/HEAD", kind = "remote" }), nil,
    "a remote name is one full-ref path component")
  H.eq(ref.remote_name(nil), nil)
end

T["ref_source facade exports the pure helpers under role-specific aliases"] = function()
  local source = require("canvasdiff.source")
  H.eq(source.format_ref, ref.format)
  H.eq(source.local_branches, ref.local_branches)
  H.eq(source.remote_name, ref.remote_name)
end

return T
