-- Renders a captured screen grid (see rpc.lua) to SVG. One <rect> run per
-- background change, one <text> run per foreground/attribute change, with
-- per-character x positions so monospace alignment never drifts.
local R = {}

local FONT = "FiraCode Nerd Font Mono"
local FS = 16.25        -- font-size that makes the advance exactly 10px
local CW = 10           -- cell width
local CH = 21           -- cell height
local BASELINE = 15.5   -- baseline offset inside a cell
local PAD = 20          -- padding around the grid, in the default background

local function color(rgb)
  return ("#%06x"):format(rgb)
end

local function esc(text)
  return (text:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local function resolve(grid, hl_id)
  local attr = grid.hl[hl_id] or {}
  local fg = attr.foreground or grid.default_fg
  local bg = attr.background or grid.default_bg
  if attr.reverse then fg, bg = bg, fg end
  return {
    fg = fg,
    bg = bg,
    sp = attr.special or fg,
    bold = attr.bold or false,
    italic = attr.italic or false,
    underline = attr.underline or attr.undercurl or attr.underdouble
      or attr.underdotted or attr.underdashed or false,
    strikethrough = attr.strikethrough or false,
  }
end

-- opts: cursor (draw a block cursor), rows {first,last} 1-indexed crop,
-- cols {first,last} 1-indexed crop.
function R.svg(grid, opts)
  opts = opts or {}
  local r1 = opts.rows and opts.rows[1] or 1
  local r2 = opts.rows and opts.rows[2] or grid.height
  local c1 = opts.cols and opts.cols[1] or 1
  local c2 = opts.cols and opts.cols[2] or grid.width
  local width = (c2 - c1 + 1) * CW + 2 * PAD
  local height = (r2 - r1 + 1) * CH + 2 * PAD

  local out = {}
  local function push(fragment) out[#out + 1] = fragment end

  push(('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">')
    :format(width, height))
  push(('<rect width="%d" height="%d" fill="%s"/>')
    :format(width, height, color(grid.default_bg)))

  -- Backgrounds first, merged into runs.
  for r = r1, r2 do
    local row = grid.rows[r]
    if row then
      local y = PAD + (r - r1) * CH
      local run_bg, run_start = nil, nil
      local function flush(at)
        if run_bg and run_bg ~= grid.default_bg then
          push(('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>')
            :format(PAD + (run_start - c1) * CW, y,
              (at - run_start) * CW, CH, color(run_bg)))
        end
      end
      for c = c1, c2 do
        local cell = row[c]
        local bg = cell and resolve(grid, cell[2]).bg or grid.default_bg
        if bg ~= run_bg then
          if run_bg then flush(c) end
          run_bg, run_start = bg, c
        end
      end
      flush(c2 + 1)
    end
  end

  -- Cursor block underneath the glyph layer.
  local cur_r, cur_c = grid.cursor.row + 1, grid.cursor.col + 1
  if opts.cursor and cur_r >= r1 and cur_r <= r2
      and cur_c >= c1 and cur_c <= c2 then
    push(('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>')
      :format(PAD + (cur_c - c1) * CW, PAD + (cur_r - r1) * CH,
        CW, CH, color(grid.default_fg)))
  end

  -- Glyphs, one run per style change, positioned per character.
  push(('<g font-family="%s" font-size="%gpx">'):format(FONT, FS))
  for r = r1, r2 do
    local row = grid.rows[r]
    if row then
      local y = PAD + (r - r1) * CH + BASELINE
      local run, run_style, run_xs, run_start = nil, nil, nil, nil
      local function flush()
        if run and #run > 0 then
          local style = run_style
          local attrs = { ('fill="%s"'):format(color(style.fg)) }
          if style.bold then attrs[#attrs + 1] = 'font-weight="bold"' end
          if style.italic then attrs[#attrs + 1] = 'font-style="italic"' end
          push(('<text x="%s" y="%g" %s>%s</text>'):format(
            table.concat(run_xs, " "), y, table.concat(attrs, " "),
            esc(table.concat(run))))
          if style.underline then
            push(('<rect x="%g" y="%g" width="%g" height="1" fill="%s"/>')
              :format(run_start, y + 3, #run * CW, color(style.sp)))
          end
          if style.strikethrough then
            push(('<rect x="%g" y="%g" width="%g" height="1" fill="%s"/>')
              :format(run_start, y - 4.5, #run * CW, color(style.fg)))
          end
        end
        run = nil
      end
      for c = c1, c2 do
        local cell = row[c]
        local text = cell and cell[1] or " "
        local style = resolve(grid, cell and cell[2] or 0)
        local is_cursor = opts.cursor and r == cur_r and c == cur_c
        if is_cursor then
          flush()
          if text ~= " " and text ~= "" then
            push(('<text x="%g" y="%g" fill="%s">%s</text>'):format(
              PAD + (c - c1) * CW, y, color(style.bg == grid.default_bg
                and grid.default_bg or style.bg), esc(text)))
          end
        elseif text == " " or text == "" then
          -- Spaces carry no glyph; runs simply break around them.
          flush()
        else
          local key = table.concat({ style.fg, tostring(style.bold),
            tostring(style.italic), tostring(style.underline),
            tostring(style.strikethrough), style.sp }, ":")
          if not run or run_style.key ~= key then
            flush()
            run, run_xs = {}, {}
            run_style = style
            run_style.key = key
            run_start = PAD + (c - c1) * CW
          end
          run[#run + 1] = text
          run_xs[#run_xs + 1] = ("%g"):format(PAD + (c - c1) * CW)
        end
      end
      flush()
    end
  end
  push("</g></svg>")
  return table.concat(out, "\n")
end

function R.write(grid, path, opts)
  local file = assert(io.open(path, "w"))
  file:write(R.svg(grid, opts))
  file:close()
end

return R
