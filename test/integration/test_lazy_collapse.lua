local H = require("helpers")
local canvas = require("canvasdiff.canvas")
local diff = require("canvasdiff.diff")
local fold = diff.fold
local source = require("canvasdiff.source")

local T = {}

local function numbered(prefix, n)
  local out = {}
  for i = 1, n do
    out[i] = ("%s line %d"):format(prefix, i)
  end
  return table.concat(out, "\n") .. "\n"
end

local function in_review(root, setup, fn)
  local old_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["canvasdiff"] = nil
  local fm = require("canvasdiff")
  fm.setup(vim.tbl_deep_extend("force", {
    watch = { enabled = false }, sidebar = { enabled = false },
    scrollbar = { enabled = false }, statuscolumn = { enabled = false },
    highlight = { enabled = false }, virt = { enabled = false },
    session = { enabled = false },
  }, setup or {}))
  local ok, err = xpcall(function() fn(fm) end, debug.traceback)
  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  require("canvasdiff.config").setup({})
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

T["lazy_collapse auto-collapses lockfiles, gitattributes generated, and oversized files without diffing them"] = function()
  local root = H.git_fixture({
    committed = {
      [".gitattributes"] = "gen/schema.ts linguist-generated=true\n",
      ["src/app.lua"] = "local x = 1\nreturn x\n",
      ["package-lock.json"] = "{\n  \"v\": 1\n}\n",
      ["gen/schema.ts"] = "export type A = string;\n",
      ["huge.txt"] = numbered("old", 600),
    },
    worktree = {
      ["src/app.lua"] = "local x = 2\nreturn x\n",
      ["package-lock.json"] = "{\n  \"v\": 2\n}\n",
      ["gen/schema.ts"] = "export type A = number;\n",
      ["huge.txt"] = numbered("new", 600),
    },
  })

  local diffed = {}
  local real_build = diff.build_section
  diff.build_section = function(path, ...)
    diffed[path] = (diffed[path] or 0) + 1
    return real_build(path, ...)
  end

  local ok, err = xpcall(function()
    in_review(root, nil, function(fm)
      local st = assert(fm.open())
      -- Only src/app.lua should have been diffed at open time!
      H.eq(diffed["src/app.lua"], 1, "normal source file is diffed eagerly")
      H.eq(diffed["package-lock.json"], nil, "lockfile must NOT be diffed at open")
      H.eq(diffed["gen/schema.ts"], nil, "linguist-generated file must NOT be diffed at open")
      H.eq(diffed["huge.txt"], nil, "oversized file must NOT be diffed at open")

      -- Smart auto-collapse uses intent = "smart" (hidden, NOT user_folded).
      H.eq(st.collapsed["package-lock.json"], "smart")
      H.eq(st.collapsed["gen/schema.ts"], "smart")
      H.eq(st.collapsed["huge.txt"], "smart")
      H.eq(st.collapsed["src/app.lua"], nil)
      H.eq(fold.user_folded(st, "package-lock.json"), false)
      H.eq(fold.hidden(st, "package-lock.json"), true)

      -- Find package-lock.json and unfold it on demand.
      local lock_i
      for i, sec in ipairs(st.sections) do
        if sec.path == "package-lock.json" then
          lock_i = i
          H.eq(sec.deferred, true)
          H.eq(sec.defer_reason, "generated")
        end
      end
      assert(lock_i, "lockfile section exists")

      local start0, end0 = canvas.section_rows(st, lock_i)
      H.eq(end0 - start0, 1, "deferred lockfile renders as 1 placeholder row")
      local ph = vim.api.nvim_buf_get_lines(st.buf, start0, end0, false)[1]
      assert(ph:find("generated", 1, true), "placeholder names auto-collapse reason: " .. ph)

      -- Unfolding materializes the real section and splices real lines into buffer!
      canvas.set_collapsed(st, lock_i, false)
      H.eq(diffed["package-lock.json"], 1, "unfolding materializes the lockfile once")
      H.eq(st.sections[lock_i].deferred, nil, "section is now materialized")
      local s2, e2 = canvas.section_rows(st, lock_i)
      assert(e2 - s2 > 1, "expanded lockfile shows real diff rows")
      H.eq(st.unfolded_smart["package-lock.json"], true,
        "explicitly unfolded smart-collapsed file is remembered")

      -- Refresh must NOT re-collapse a file the user explicitly unfolded!
      assert(fm.refresh())
      H.eq(st.collapsed["package-lock.json"], nil,
        "refresh keeps user-unfolded lockfile expanded")
      H.eq(st.collapsed["huge.txt"], "smart",
        "untouched oversized file stays smart-collapsed")
    end)
  end, debug.traceback)

  diff.build_section = real_build
  assert(ok, err)
end

T["lazy_collapse virtualizer does not auto-expand smart-collapsed files"] = function()
  local root = H.git_fixture({
    committed = {
      ["a.lua"] = "local a = 1\n",
      ["package-lock.json"] = "{\n  \"a\": 1\n}\n",
    },
    worktree = {
      ["a.lua"] = "local a = 2\n",
      ["package-lock.json"] = "{\n  \"a\": 2\n}\n",
    },
  })
  in_review(root, { virt = { enabled = true } }, function(fm)
    local st = assert(fm.open())
    H.eq(st.collapsed["package-lock.json"], "smart",
      "virtualizer initial pass leaves smart-collapsed file collapsed")
    for _, sec in ipairs(st.sections) do
      if sec.path == "package-lock.json" then
        H.eq(sec.deferred, true, "file stays deferred")
      end
    end
  end)
end

T["lazy_collapse numstat and check_attributes handle renames, binary, and attributes"] = function()
  local root = H.git_fixture({
    committed = {
      [".gitattributes"] = "auto.js linguist-generated=true\nbin.custom -diff\n",
      ["old_name.lua"] = "one\ntwo\nthree\n",
      ["auto.js"] = "a\n",
      ["bin.custom"] = "x\n",
    },
    worktree = {
      ["auto.js"] = "b\n",
      ["bin.custom"] = "y\n",
    },
  })
  vim.system({ "git", "mv", "old_name.lua", "new_name.lua" }, { cwd = root }):wait()
  local f = assert(io.open(vim.fs.joinpath(root, "new_name.lua"), "w"))
  f:write("one\nTWO\nthree\nfour\n")
  f:close()

  local ok, err = xpcall(function()
    local stats = source.numstat(root, { old_rev = "HEAD" })
    assert(stats["new_name.lua"], "rename destination appears in numstat")
    H.eq(stats["new_name.lua"].old_path, "old_name.lua")
    H.eq(stats["new_name.lua"].adds, 2)
    H.eq(stats["new_name.lua"].dels, 1)

    local attrs = source.check_attributes(root, { "auto.js", "bin.custom", "new_name.lua" })
    H.eq(attrs["auto.js"] and attrs["auto.js"].generated, true)
    H.eq(attrs["bin.custom"] and attrs["bin.custom"].no_diff, true)
    H.eq(attrs["new_name.lua"], nil)
  end, debug.traceback)
  vim.fn.delete(root, "rf")
  assert(ok, err)
end

return T
