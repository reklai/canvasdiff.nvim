local H = require("helpers")
local util = require("galley.util")
local model = require("galley.model")
local render = require("galley.render")

local T = {}

-- A tiny but genuinely binary payload: NUL bytes are the part that matters,
-- because Vim strings cannot hold them.
local BIN_OLD = "PK\3\4\0\0\0\0garbage\0\1\2\3"
local BIN_NEW = "PK\3\4\0\0\0\0GARBAGE\0\4\5\6"

T["binary_ is_binary detects NUL and leaves text alone"] = function()
  H.eq(util.is_binary("hello\nworld\n"), false)
  H.eq(util.is_binary(""), false)
  H.eq(util.is_binary(nil), false)
  H.eq(util.is_binary("head\0tail"), true)
  H.eq(util.is_binary(BIN_OLD), true)
  -- UTF-8 text is not binary just because it has high bytes.
  H.eq(util.is_binary("héllo — ünicode\n"), false)
end

T["binary_ is_binary only sniffs the head, like git"] = function()
  local late = string.rep("a", 9000) .. "\0"
  H.eq(util.is_binary(late), false, "a NUL past 8000 bytes is not sniffed")
  H.eq(util.is_binary(string.rep("a", 100) .. "\0"), true, "an early NUL is")
end

-- Regression: a binary file was diffed as text. vim.text.diff produced pages
-- of line noise, and the NUL bytes reaching vim.fn.split in the word-diff
-- tier became a Blob and threw E976, taking the entire open() down.
T["binary_ a binary section carries no content entries"] = function()
  local sec = model.build_section("a.zip", BIN_OLD, BIN_NEW, "M", 3)
  assert(sec, "a changed binary file still gets a section")
  H.eq(sec.binary, true)
  H.eq({ sec.adds, sec.dels, sec.nhunks }, { 0, 0, 0 })
  local kinds = {}
  for _, e in ipairs(sec.entries) do kinds[#kinds + 1] = e.kind end
  H.eq(kinds, { "file_hdr", "binary" },
    "no ctx/add/del rows, which is what keeps worddiff and treesitter away from it")
end

T["binary_ either side being binary is enough"] = function()
  assert(model.build_section("a.bin", BIN_OLD, "now text\n", "M", 3).binary,
    "old side binary")
  assert(model.build_section("a.bin", "was text\n", BIN_NEW, "M", 3).binary,
    "new side binary")
end

T["binary_ an unchanged binary file produces no section"] = function()
  H.eq(model.build_section("a.zip", BIN_OLD, BIN_OLD, "M", 3), nil)
end

-- "(+0 −0)" would read as "nothing changed", the opposite of the truth.
T["binary_ renders as (binary), never as zero counts"] = function()
  local sec = model.build_section("a.zip", BIN_OLD, BIN_NEW, "M", 3)
  local lines = render.section_lines(sec)
  H.eq(lines[1], "▎ a.zip  (binary)")
  assert(lines[2]:match("no diff shown"), "got: " .. lines[2])
  assert(not lines[1]:match("%+0"), "must not claim zero additions")
end

T["binary_ the collapsed placeholder also says binary"] = function()
  local sec = model.build_section("a.zip", BIN_OLD, BIN_NEW, "M", 3)
  H.eq(render.placeholder(sec), "▸ a.zip  (binary)")
end

T["binary_ section_hl highlights the notice row"] = function()
  local sec = model.build_section("a.zip", BIN_OLD, BIN_NEW, "M", 3)
  local marks = render.section_hl(sec)
  local groups = {}
  for _, m in ipairs(marks) do groups[m.row] = m.group end
  H.eq(groups[0], "GalleyFileHeader")
  H.eq(groups[1], "GalleyBinary")
end

-- End to end through a real repo: this is the case that used to throw E976.
T["binary_ a repo with a binary file opens without error"] = function()
  local root = H.git_fixture({
    committed = { ["blob.bin"] = BIN_OLD, ["ok.txt"] = "one\n" },
    worktree = { ["blob.bin"] = BIN_NEW, ["ok.txt"] = "two\n" },
  })
  local old_cwd = vim.fn.getcwd()
  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["galley"] = nil
  local fm = require("galley")

  local ok, err = pcall(function()
    fm.open()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert(joined:match("▎ blob%.bin  %(binary%)"), "binary header missing:\n" .. joined)
    assert(joined:match("▎ ok%.txt  %(%+1 −1%)"), "text file must still diff:\n" .. joined)
    assert(not joined:find("\0", 1, true), "no NUL bytes may reach the canvas")
  end)

  pcall(fm.close)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

T["binary_ jumping into a binary section declines instead of opening it"] = function()
  local root = H.git_fixture({
    committed = { ["blob.bin"] = BIN_OLD },
    worktree = { ["blob.bin"] = BIN_NEW },
  })
  local old_cwd = vim.fn.getcwd()
  local real = vim.notify
  local msgs = {}
  vim.notify = function(m, l) msgs[#msgs + 1] = { msg = m, level = l } end

  vim.cmd("tabnew")
  vim.api.nvim_set_current_dir(root)
  package.loaded["galley"] = nil
  local fm = require("galley")
  local canvas = require("galley.canvas")

  local ok, err = pcall(function()
    fm.open()
    vim.api.nvim_win_set_cursor(0, { 2, 0 }) -- the "no diff shown" row
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    assert(canvas.is_canvas_buf(vim.api.nvim_get_current_buf()),
      "must stay on the canvas rather than opening a buffer of raw bytes")
    local said = false
    for _, m in ipairs(msgs) do
      if tostring(m.msg):match("binary file") then said = true end
    end
    assert(said, "and say why; got: " .. vim.inspect(msgs))
  end)

  pcall(fm.close)
  vim.notify = real
  vim.cmd("tabclose")
  vim.api.nvim_set_current_dir(old_cwd)
  assert(ok, err)
end

return T
