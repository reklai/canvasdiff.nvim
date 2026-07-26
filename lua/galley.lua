local App = require("galley.App")

local app = App.new()

return {
  setup = function(opts)
    return app:setup(opts)
  end,
  open = function(opts)
    return app:open(opts)
  end,
  close = function()
    return app:close()
  end,
  toggle = function()
    return app:toggle()
  end,
  refresh = function()
    return app:refresh()
  end,
  set_lens = function(value)
    return app:set_lens(value)
  end,
  cycle_lens = function(delta)
    return app:cycle_lens(delta)
  end,
  set_branch = function(ref)
    return app:set_branch(ref)
  end,
  set_base = function(base)
    return app:set_base(base)
  end,
  toggle_base = function()
    return app:toggle_base()
  end,
}
