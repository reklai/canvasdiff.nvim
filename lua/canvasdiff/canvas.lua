local Canvas = require("canvasdiff.canvas.Canvas")
local config = require("canvasdiff.config")
local context = require("canvasdiff.canvas.context")
local format = require("canvasdiff.canvas.format")

-- The canvas domain's exact public surface. Concrete buffer and formatting
-- owners live below this facade; callers outside the domain never import them.
return {
  -- What a verb standing on a row is standing on -- the hunk or the file --
  -- and the same question backwards, for a caller that names a hunk and needs
  -- the row it lives on.
  context = {
    resolve = context.resolve,
    hunk_row = context.hunk_row,
  },
  format = {
    -- The struck-label group and the hunk-naming format, exported because a
    -- hunk is named in two windows: the sidebar's tree rows and the pinned
    -- header's crumb. `fit` is the cut those two labels share.
    escape_path = format.escape_path,
    fit = format.fit,
    ghost_lines = format.ghost_lines,
    -- Config's LIVE glyph table (mutated in place by setup, never replaced),
    -- re-exported here so formatters and their consumers read one table.
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
  -- Splices `section` in before index i (i = #sections + 1 appends),
  -- correcting the view in the same tick. Precondition: a non-empty canvas --
  -- the 0 -> N transition goes through render_all.
  insert_section = Canvas.insert_section,
  -- Pure name-prefix predicate; false for an invalid buffer. No registry, so
  -- no live ownership state can go stale against it.
  is_canvas_buf = Canvas.is_canvas_buf,
  -- (section index, 1-based offset into its entries) for a 0-based row.
  -- CLAMPS to the nearest section for a row past the end; nil only when the
  -- canvas has no sections at all.
  locate = Canvas.locate,
  -- The canvas's text by row -- { row_count, rows, row, export }.
  logical = Canvas.logical,
  -- Empties the section list in place so closures that captured a review
  -- cannot retain its model after disposal.
  dispose = Canvas.dispose,
  -- A fresh state every call -- buffer created, shown in the current window,
  -- sections rendered. Nothing survives close/open except what
  -- session.restore puts back.
  open = Canvas.open,
  -- Bring the canvas to `desired` with the fewest splices; an untouched
  -- section keeps its anchors, marks and rows. Returns true when it had to
  -- fall back to a full render_all -- the case where the canvas may now be
  -- the empty placeholder. The caller owns the follow-up UI sync.
  reconcile_sections = Canvas.reconcile_sections,
  -- Full from-scratch re-render (prunes dead fold keys first).
  render_all = Canvas.render_all,
  -- Splices section i in place with same-tick view correction, so content
  -- changes outside the viewport never move what the user is reading.
  -- `new_section == nil` deletes the section.
  replace_section = Canvas.replace_section,
  -- Re-splice sections to match the visibility predicate after state.folded
  -- changed (set_collapsed handles state.collapsed itself). The caller owns
  -- the follow-up UI sync.
  resync_visibility = Canvas.resync_visibility,
  -- 0-based [start_row, end_row_exclusive) for section i, resolved live --
  -- never cached, so it survives every splice.
  section_rows = Canvas.section_rows,
  -- Collapse/expand section i, recording WHOSE decision it was: intent is
  -- "user" (default) or "auto" (the virtualizer's). fold.user_folded reads
  -- that back, so navigation and session treat the two differently.
  set_collapsed = Canvas.set_collapsed,
  -- Show an existing state in `win` without rebuilding model or anchors --
  -- a second view of one review, not a new review lifetime.
  show = Canvas.show,
  -- Is `win` (default: the canvas's own) showing this canvas buffer right
  -- now? The one shared definition of that predicate.
  win_showing_canvas = Canvas.win_showing_canvas,
}
