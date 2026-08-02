local Canvas = require("canvasdiff.canvas.Canvas")
local PageList = require("canvasdiff.canvas.PageList")
local Restore = require("canvasdiff.canvas.compression.restore")
local Paged = require("canvasdiff.canvas.paged")
local Projection = require("canvasdiff.canvas.Projection")
local Scheduler = require("canvasdiff.canvas.Scheduler")
local config = require("canvasdiff.config")
local context = require("canvasdiff.canvas.context")
local format = require("canvasdiff.canvas.format")

-- The canvas domain's exact public surface. Concrete storage and projection
-- owners live below this facade; callers outside the domain never import them.
return {
  -- What a verb standing on a row is standing on -- the hunk or the file --
  -- and the same question backwards, for a caller that names a hunk and needs
  -- the row it lives on.
  context = {
    resolve = context.resolve,
    hunk_row = context.hunk_row,
    -- Deleted lines are virtual text, so the only way to reach them is to ask
    -- the row they hang on.
    ghosts = context.ghosts,
  },
  format = {
    -- The struck-label group and the hunk-naming format, exported because a
    -- hunk is named in two windows: the sidebar's tree rows and the pinned
    -- header's crumb. `fit` is the cut those two labels share.
    ensure_hunk_hl = format.ensure_hunk_hl,
    ensure_marker_hl = format.ensure_marker_hl,
    escape_path = format.escape_path,
    fit = format.fit,
    ghost_lines = format.ghost_lines,
    glyphs = config.glyphs,
    hunk_name = format.hunk_name,
    marker_spans = format.marker_spans,
    placeholder = format.placeholder,
    section_hl = format.section_hl,
    -- One row, not the whole list: the sticky header re-resolves its line on
    -- every topline change, and a consumer that only wants the file_hdr row
    -- must not pay for materializing a large section's every entry.
    section_line = format.section_line,
    section_lines = format.section_lines,
    section_path = format.section_path,
    stage_mark = format.stage_mark,
    -- The placeholder's summary without its path or markers, so the sidebar's
    -- folded file row can say the same thing the canvas placeholder says.
    summary = format.summary,
  },
  insert_section = Canvas.insert_section,
  is_canvas_buf = Canvas.is_canvas_buf,
  locate = Canvas.locate,
  logical = Canvas.logical,
  dispose = Canvas.dispose,
  open = Canvas.open,
  open_paged = Canvas.open_paged,
  -- The page-backed store a Projection renders. `paginate_stream` is the
  -- ingestion entry point: it never materializes every logical row first, and
  -- `compression` is the restore adapter a compacting store must be given.
  compression = Restore.adapter,
  compression_capability = Restore.capability,
  -- The page-backed canvas: same text at the same logical rows as the eager
  -- one, but the text lives in the store and the colours are emitted per
  -- visible row, so a million rows cost no persistent extmark.
  paged = {
    render = Paged.render,
    insert_section = Paged.insert_section,
    logical = Paged.logical,
    locate = Paged.locate,
    refresh_ghosts = Paged.refresh_ghosts,
    render_all = Paged.render_all,
    replace_section = Paged.replace_section,
    search = Paged.search,
    section_rows = Paged.section_rows,
    set_collapsed = Paged.set_collapsed,
    touch = Paged.touch,
    yank = Paged.yank,
    dispose = Paged.dispose,
  },
  paginate = PageList.create,
  paginate_stream = PageList.from_iterator,
  project = Projection.create,
  reconcile_sections = Canvas.reconcile_sections,
  render_all = Canvas.render_all,
  replace_section = Canvas.replace_section,
  resync_visibility = Canvas.resync_visibility,
  schedule = Scheduler.create,
  section_rows = Canvas.section_rows,
  set_collapsed = Canvas.set_collapsed,
  show = Canvas.show,
  touch = Canvas.touch,
  win_showing_canvas = Canvas.win_showing_canvas,
}
