local H = require("helpers")
local canvas = require("finding_myself.canvas")
local model = require("finding_myself.model")
local render = require("finding_myself.render")
local scrollbar = require("finding_myself.scrollbar")
local hl = require("finding_myself.hl")

local T = {}

local function bigtext(n, tag)
  local t = {}
  for i = 1, n do t[i] = ("%s line %d"):format(tag, i) end
  return table.concat(t, "\n") .. "\n"
end

-- ~55 rows per section (6 separated hunks): sections must be taller than the
-- ~22-row headless window or topline restores would clamp and the
-- scroll-targeting assertions below would silently test the wrong section.
local function big_section(path, tag)
  local old = bigtext(60, tag)
  local lines = vim.split(old, "\n", { plain = true })
  for i = 10, 60, 10 do
    lines[i] = lines[i] .. " changed"
  end
  return model.build_section(path, old, table.concat(lines, "\n"), "M")
end

local function open_three()
  return canvas.open({
    big_section("a/one.txt", "a"),
    big_section("b/two.txt", "b"),
    big_section("c/three.txt", "c"),
  }, {})
end

local function reset_view(st)
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = 1, lnum = 1 })
  end)
end

T["collapse_ renders one placeholder row and restores on expand"] = function()
  local st = open_three()
  reset_view(st)
  local sec = st.sections[2]
  local orig_lines = render.section_lines(sec)

  canvas.set_collapsed(st, 2, true)
  local s2, e2 = canvas.section_rows(st, 2)
  H.eq(e2 - s2, 1, "collapsed section spans exactly 1 row")
  local line = vim.api.nvim_buf_get_lines(st.buf, s2, s2 + 1, false)[1]
  H.eq(line, render.placeholder(sec), "buffer line equals the placeholder")

  -- rows stay contiguous across all three sections
  local prev_end
  for i = 1, 3 do
    local s, e = canvas.section_rows(st, i)
    if prev_end then
      H.eq(s, prev_end, "section " .. i .. " starts exactly where the prior one ends")
    end
    prev_end = e
  end

  canvas.set_collapsed(st, 2, false)
  local s2b, e2b = canvas.section_rows(st, 2)
  H.eq(e2b - s2b, #orig_lines, "expand restores the original row span")
  local body = vim.api.nvim_buf_get_lines(st.buf, s2b, e2b, false)
  H.eq(body[1], orig_lines[1], "first body line restored")
  H.eq(body[#body], orig_lines[#orig_lines], "last body line restored")
end

T["collapse_ above viewport keeps visible text pinned"] = function()
  local st = open_three()
  local s3 = (canvas.section_rows(st, 3))
  vim.api.nvim_win_call(st.win, function()
    vim.fn.winrestview({ topline = s3 + 3, lnum = s3 + 3 })
  end)
  local function w0_text()
    return vim.api.nvim_win_call(st.win, function()
      return vim.fn.getline(vim.fn.line("w0"))
    end)
  end
  local before = w0_text()

  canvas.set_collapsed(st, 1, true)
  H.eq(w0_text(), before, "collapsing a section above the viewport leaves visible text pinned")

  canvas.set_collapsed(st, 1, false)
  H.eq(w0_text(), before, "expanding it back leaves visible text pinned")
end

T["collapse_ locate maps the placeholder to offset 1"] = function()
  local st = open_three()
  canvas.set_collapsed(st, 2, true)
  local s2 = (canvas.section_rows(st, 2))
  local i, off = canvas.locate(st, s2)
  H.eq({ i, off }, { 2, 1 })
end

T["collapse_ scrollbar kinds shrink to one hdr"] = function()
  local st = open_three()
  local full_total = #scrollbar.line_kinds(st.sections)
  local sec1_rows = #render.section_lines(st.sections[1])
  local sec2_rows = #render.section_lines(st.sections[2])

  canvas.set_collapsed(st, 2, true)
  local kinds = scrollbar.line_kinds(st.sections, st.collapsed)
  H.eq(#kinds, full_total - (sec2_rows - 1))
  H.eq(kinds[sec1_rows + 1], "hdr", "the placeholder position is hdr")
end

T["collapse_ hl never marks a collapsed section"] = function()
  local st = open_three()
  reset_view(st)
  hl.attach(st, { margin = 1000 })
  assert(st.ts.ids_by_path["a/one.txt"] and #st.ts.ids_by_path["a/one.txt"] > 0,
    "sanity: attach marked section 1 before collapsing")

  canvas.set_collapsed(st, 1, true)
  hl.apply_now(st)
  H.eq(st.ts.ids_by_path["a/one.txt"], nil, "ids_by_path has no entry for the collapsed section")

  local ns = vim.api.nvim_create_namespace("finding_myself.canvas.ts")
  local s1, e1 = canvas.section_rows(st, 1)
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(st.buf, ns, 0, -1, {})) do
    assert(not (m[2] >= s1 and m[2] < e1), "no TS-namespace mark within the collapsed section's rows")
  end
  hl.detach(st)
end

T["collapse_ replace_section keeps a collapsed section collapsed"] = function()
  local st = open_three()
  canvas.set_collapsed(st, 2, true)
  local old_sec = st.sections[2]
  local old = old_sec.old_text

  local lines = vim.split(old, "\n", { plain = true })
  for i = 5, 60, 5 do
    lines[i] = lines[i] .. " Z"
  end
  local new_text = table.concat(lines, "\n")
  local new_sec = model.build_section(old_sec.path, old, new_text, "M")
  assert(render.placeholder(new_sec) ~= render.placeholder(old_sec),
    "sanity: the replacement actually has different hunk/add/del counts")

  canvas.replace_section(st, 2, new_sec)

  local s2, e2 = canvas.section_rows(st, 2)
  H.eq(e2 - s2, 1, "still collapsed to 1 row after replace")
  local line = vim.api.nvim_buf_get_lines(st.buf, s2, s2 + 1, false)[1]
  H.eq(line, render.placeholder(new_sec), "placeholder text reflects the NEW counts")
end

return T
