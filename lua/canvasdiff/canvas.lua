local Canvas = require("canvasdiff.canvas.Canvas")
local PageList = require("canvasdiff.canvas.PageList")
local Restore = require("canvasdiff.canvas.compression.restore")
local Projection = require("canvasdiff.canvas.Projection")
local Scheduler = require("canvasdiff.canvas.Scheduler")
local config = require("canvasdiff.config")
local format = require("canvasdiff.canvas.format")

-- The canvas domain's exact public surface. Concrete storage and projection
-- owners live below this facade; callers outside the domain never import them.
return {
  format = {
    ensure_marker_hl = format.ensure_marker_hl,
    escape_path = format.escape_path,
    ghost_lines = format.ghost_lines,
    glyphs = config.glyphs,
    marker_spans = format.marker_spans,
    placeholder = format.placeholder,
    section_hl = format.section_hl,
    section_lines = format.section_lines,
    section_path = format.section_path,
    stage_mark = format.stage_mark,
  },
  insert_section = Canvas.insert_section,
  is_canvas_buf = Canvas.is_canvas_buf,
  locate = Canvas.locate,
  logical = Canvas.logical,
  open = Canvas.open,
  -- The page-backed store a Projection renders. `paginate_stream` is the
  -- ingestion entry point: it never materializes every logical row first, and
  -- `compression` is the restore adapter a compacting store must be given.
  compression = Restore.adapter,
  compression_capability = Restore.capability,
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
}
