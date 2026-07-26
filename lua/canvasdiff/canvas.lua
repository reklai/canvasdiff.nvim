local Canvas = require("canvasdiff.canvas.Canvas")

-- The canvas domain's exact public surface. Concrete storage and projection
-- owners live below this facade; callers outside the domain never import them.
return {
  insert_section = Canvas.insert_section,
  is_canvas_buf = Canvas.is_canvas_buf,
  locate = Canvas.locate,
  open = Canvas.open,
  reconcile_sections = Canvas.reconcile_sections,
  render_all = Canvas.render_all,
  replace_section = Canvas.replace_section,
  resync_visibility = Canvas.resync_visibility,
  section_rows = Canvas.section_rows,
  set_collapsed = Canvas.set_collapsed,
  show = Canvas.show,
}
