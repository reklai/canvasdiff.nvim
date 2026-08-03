-- The appearance domain's only cross-domain entry point. It exposes canonical
-- highlight names and the manager's setup/repair contract; definitions and
-- process-wide authorship remain internal, and this domain imports no peer.
local groups = require("canvasdiff.appearance.groups")
local manager = require("canvasdiff.appearance.manager")

return {
  -- Validation only -- writes no highlight state. Returns a list of
  -- diagnostic strings for the given overrides/profile (highlight
  -- diagnostics sorted, a profile diagnostic last); empty when clean.
  audit = manager.audit,
  -- Reapply derived defaults then explicit overrides, replacing only our own
  -- prior authorship -- a colorscheme's or user's direct definition survives.
  -- No return value.
  ensure = manager.ensure,
  -- A fresh copy of the canonical group-name list, safe for callers to keep.
  names = groups.names,
  -- Validates overrides and the profile name, applies them, and installs the
  -- ColorScheme reload. Never errors: rejected specs and an unknown profile
  -- become entries in the returned diagnostics list (profile falls back to
  -- "quiet").
  setup = manager.setup,
}
