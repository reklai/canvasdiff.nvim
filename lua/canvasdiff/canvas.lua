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
  -- The canvas's text by logical row -- { row_count, rows, row, export } --
  -- identical in shape for eager and paged canvases. Readers must ask this,
  -- never the buffer: a paged buffer holds only blank skeleton lines.
  logical = Canvas.logical,
  -- Releases a paged canvas's store and projection; true (a no-op) on an
  -- eager one, whose buffer is the state.
  dispose = Canvas.dispose,
  -- A fresh state every call -- buffer created, shown in the current window,
  -- sections rendered. Nothing survives close/open except what
  -- session.restore puts back.
  open = Canvas.open,
  -- The page-backed open: same state shape as `open` so every reader keeps
  -- working, but returns `nil, err` when the store or projection refuses.
  open_paged = Canvas.open_paged,
  -- The page-backed store a Projection renders. `paginate_stream` is the
  -- ingestion entry point: it never materializes every logical row first, and
  -- `compression` is the restore adapter a compacting store must be given.
  -- Compression is a capability, not a requirement: `compression` answers
  -- `nil, capability` when no lz4 backend exists, and `compression_capability`
  -- always answers a record -- { available = true, codec } or
  -- { available = false, reason }.
  compression = Restore.adapter,
  compression_capability = Restore.capability,
  -- The page-backed canvas: same text at the same logical rows as the eager
  -- one, but the text lives in the store and the colours are emitted per
  -- visible row, so a million rows cost no persistent extmark.
  --
  -- Unlike their eager counterparts these verbs can refuse: each answers its
  -- result on success and `nil, err` when the store or projection rejects the
  -- splice. `locate` keeps the eager 1-based offset contract exactly.
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
  -- Both builders answer the checked read-only row store or `nil, err`;
  -- `paginate` takes a dense list it does not retain, `paginate_stream` a
  -- pull iterator whose throws are contained into ordinary errors.
  paginate = PageList.create,
  paginate_stream = PageList.from_iterator,
  -- A skeleton buffer plus decoration provider over a page store, or
  -- `nil, err` (invalid store, buffer creation failure).
  project = Projection.create,
  -- Bring the canvas to `desired` with the fewest splices; an untouched
  -- section keeps its anchors, marks and rows. Returns true when it had to
  -- fall back to a full render_all -- the case where the canvas may now be
  -- the empty placeholder. The caller owns the follow-up UI sync.
  reconcile_sections = Canvas.reconcile_sections,
  -- Full from-scratch re-render (prunes dead fold keys first). No return on
  -- the eager path; asserts if a paged store refuses.
  render_all = Canvas.render_all,
  -- Splices section i in place with same-tick view correction, so content
  -- changes outside the viewport never move what the user is reading.
  -- `new_section == nil` deletes the section.
  replace_section = Canvas.replace_section,
  -- Re-splice sections to match the visibility predicate after state.folded
  -- changed (set_collapsed handles state.collapsed itself). The caller owns
  -- the follow-up UI sync.
  resync_visibility = Canvas.resync_visibility,
  -- The idle compaction driver for one page store, or `nil, err`.
  schedule = Scheduler.create,
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
  -- Note activity so a paged canvas defers compaction; true and nothing to
  -- defer on an eager one.
  touch = Canvas.touch,
  -- Is `win` (default: the canvas's own) showing this canvas buffer right
  -- now? The one shared definition of that predicate.
  win_showing_canvas = Canvas.win_showing_canvas,
}
