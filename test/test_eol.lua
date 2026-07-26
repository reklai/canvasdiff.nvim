local H = require("helpers")
local collect = require("canvasdiff.collect")
local model = require("canvasdiff.model")
local util = require("canvasdiff.util")

local T = {}

--- git's own verdict, the reference we must match.
local function numstat(root, path)
  local res = vim.system({ "git", "-C", root, "diff", "--numstat", "HEAD", "--", path },
    { text = true }):wait()
  local a, d = tostring(res.stdout):match("(%d+)%s+(%d+)")
  return tonumber(a), tonumber(d)
end

--- What the plugin would render for `path`.
local function canvasdiff_counts(root, path)
  for _, f in ipairs(collect.files(root, "HEAD")) do
    if f.path == path then
      local sec = model.build_section(f.path, f.old_text, f.new_text, f.status, 3)
      if not sec then return 0, 0 end
      return sec.adds, sec.dels
    end
  end
  error("no section collected for " .. path)
end

local function fixture()
  return H.git_fixture({
    committed = {
      ["dos.txt"] = "alpha\r\nbeta\r\ngamma\r\n",
      ["noeol.txt"] = "one\ntwo\nthree",
      ["plain.txt"] = "x\ny\n",
    },
    worktree = {
      ["dos.txt"] = "alpha\r\nbeta\r\ngammaX\r\n",
      ["noeol.txt"] = "one\ntwo\nthreeX",
      ["plain.txt"] = "x\nyY\n",
    },
  })
end

--- Load `abs` into a buffer WITHOUT displaying it.
---
--- Deliberately not `:edit`: the suite shares one Neovim process and an
--- earlier test can leave the current window showing the sidebar, which is
--- 'winfixbuf' -- so `:edit` fails with E1513, and on the runs where it
--- succeeds it strands the window on a foreign buffer for every later test.
--- bufadd+bufload reads the file through the normal path (so 'fileformat' and
--- 'endofline' are detected exactly as they would be) and touches no window.
local function load_buf(abs)
  local b = vim.fn.bufadd(abs)
  vim.fn.bufload(b)
  return b
end

local function wipe(b)
  pcall(vim.api.nvim_buf_delete, b, { force = true })
end

-- Regression: git.run used { text = true }, which rewrites \r\n -> \n in
-- stdout. The old side then came back LF while the disk read preserved CRLF,
-- so every line mismatched and a one-line edit rendered as a whole-file
-- rewrite (-3 +3 against git's -1 +1).
T["eol_ CRLF file matches git with no buffer loaded"] = function()
  local root = fixture()
  local ga, gd = numstat(root, "dos.txt")
  local a, d = canvasdiff_counts(root, "dos.txt")
  H.eq({ a, d }, { ga, gd }, "adds/dels must match git for an unloaded CRLF file")
end

-- The other half of the same bug: the buffer path rejoined lines with a
-- hardcoded "\n", so a CRLF file that happened to be open disagreed with the
-- very same file when closed. Both paths must agree, and both must match git.
T["eol_ CRLF file matches git with the buffer loaded"] = function()
  local root = fixture()
  local abs = vim.fs.joinpath(root, "dos.txt")
  local ga, gd = numstat(root, "dos.txt")
  local b = load_buf(abs)
  local ok, a, d = pcall(canvasdiff_counts, root, "dos.txt")
  wipe(b)
  assert(ok, a)
  H.eq({ a, d }, { ga, gd }, "adds/dels must match git for a loaded CRLF file")
end

T["eol_ noeol file agrees loaded and unloaded"] = function()
  local root = fixture()
  local abs = vim.fs.joinpath(root, "noeol.txt")
  local ua, ud = canvasdiff_counts(root, "noeol.txt")
  local b = load_buf(abs)
  local ok, la, ld = pcall(canvasdiff_counts, root, "noeol.txt")
  wipe(b)
  assert(ok, la)
  H.eq({ la, ld }, { ua, ud }, "loaded and unloaded must agree for a noeol file")
  local ga, gd = numstat(root, "noeol.txt")
  H.eq({ ua, ud }, { ga, gd }, "and both must match git")
end

T["eol_ plain LF file is unaffected"] = function()
  local root = fixture()
  local ga, gd = numstat(root, "plain.txt")
  H.eq({ canvasdiff_counts(root, "plain.txt") }, { ga, gd })
end

T["eol_ buf_text reconstructs fileformat and endofline"] = function()
  local root = fixture()
  for _, case in ipairs({
    { "dos.txt", "alpha\r\nbeta\r\ngammaX\r\n" },
    { "noeol.txt", "one\ntwo\nthreeX" },
    { "plain.txt", "x\nyY\n" },
  }) do
    local b = load_buf(vim.fs.joinpath(root, case[1]))
    local got = util.buf_text(b)
    wipe(b)
    H.eq(got, case[2], case[1] .. " must round-trip byte-exactly through the buffer")
  end
end

T["eol_ buf_text treats an empty buffer as empty"] = function()
  local b = vim.api.nvim_create_buf(false, true)
  H.eq(util.buf_text(b), "")
  vim.api.nvim_buf_delete(b, { force = true })
end

return T
