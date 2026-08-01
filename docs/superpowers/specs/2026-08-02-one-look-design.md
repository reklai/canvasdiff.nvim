# One Look: Neutral Field, Margin Hue, Sticky Header

Approved 2026-08-02. Amended same day: §4 split into the unified top band
plus a sticky header ROW (was: the winbar as a composed sticky header);
§2's neutral field reconfirmed against the alternative of keeping the hued
quiet tints. Five decisions taken together, replacing yesterday's
three-mode `highlight.diff` with a single opinionated rendering:

1. **Zero modes.** `highlight.diff` is deleted. The canvas always renders
   the neutral-field palette below plus the statuscolumn gutter bars.
   Every look the modes offered stays reachable through the documented
   `default = true` group overrides.
2. **Neutral field, margin hue, dimmed past.** Hue leaves the text body:
   changed rows get one derived neutral elevation, deleted content gets a
   dimmed foreground, and green/red live only in the margin (prefix +
   gutter bar) and the stat counts.
3. **Derived header bar colour.** `CanvasDiffFileBar` stops linking
   `Folded` (one scheme's luck) and derives a guaranteed-contrast bar.
4. **Unified top band.** The sidebar and canvas winbars share one
   focus-stable group; the canvas half is the comparison label alone.
5. **Sticky file-header row.** The breadcrumb leaves the winbar: a
   one-row float under it mirrors the in-buffer file header for the
   section under the topline.

> **Supersedes in part**
> `2026-08-01-visual-polish-and-lens-tier-design.md` §2 (the three-mode
> `highlight.diff`). §2's derived-blend machinery, authorship tracking,
> gutter glyph, and statuscolumn bars all survive — recomposed, not
> removed. Users who set `highlight.diff` during its brief life get the
> removed-option diagnostic (the `REMOVED_ACTIONS`-style pattern, applied
> to options).

## 1. Zero modes

- Delete the `highlight.diff` option: defaults table, validation, the
  README/vimdoc mode documentation. Add a removed-option diagnostic naming
  the replacement ("override the CanvasDiff highlight groups instead;
  see README").
- Gutter bars render whenever the statuscolumn is enabled (which is the
  default); `statuscolumn.enabled = false` simply loses the bars — no
  warning, the tints and prefixes still carry the diff.
- The warn-once downgrade machinery for gutter-without-statuscolumn is
  deleted with the mode.

## 2. The palette

| Element | Treatment | Group (all `default = true`) |
| --- | --- | --- |
| Changed real row (add, or a deleted file's `-` rows) | ONE derived neutral elevation: `Normal` bg shifted by a measured luminance delta — no hue | `CanvasDiffAdd` and `CanvasDiffDel` both default to it (kept as two groups so per-kind overrides still work) |
| Ghost deletion lines | dimmed foreground (blend fg toward Normal bg by a measured factor), NO background | `CanvasDiffGhost` (no longer defaults to `CanvasDiffDel`) |
| `+` / `-` prefix cell | coloured foreground: green/red derived from the scheme's `DiffAdd`/`DiffDelete` fg (fallback pair when absent) | NEW `CanvasDiffPrefixAdd` / `CanvasDiffPrefixDel` |
| Gutter bar (statuscolumn `▎`) | same green/red as the prefixes | existing `CanvasDiffGutterAdd` / `CanvasDiffGutterDel`, re-derived from the prefix colours |
| Context rows | untouched | — |
| Word-diff | bold + underline, unchanged | existing |

- All derived values go through the existing authorship-tracking
  machinery (`set_diff_default`) so user/scheme overrides always win and
  colorscheme switches recompute cleanly.
- Deltas and blend factors chosen by the repo's measurement method under
  the builtin scheme and tokyonight-moon; the elevation delta must land
  between `CursorLine` (too subtle alone) and yesterday's quiet tints;
  the ghost dim factor must keep `@comment`-class tokens readable
  (measured floor, recorded in the commit body).
- Wholly-deleted files: real `-` rows get the neutral elevation + dimmed
  fg + red margin. Yankable/searchable as before.
- README's "How diff rows are coloured" is rewritten around the three
  channels (elevation = changed, dimming = removed, margin hue =
  direction), replacing the mode table; the quieting-overrides example
  updates to the new group names.

## 3. Derived header bar

- `CanvasDiffFileBar` defaults to a derived bar: `Normal` bg shifted by a
  measured delta toward greater contrast than the row elevation (the bar
  must clear the elevation by a measured margin, not just clear Normal),
  optionally tinted toward the scheme's `Title` fg at low blend if the
  measurement shows pure luminance is too anonymous — decide by
  measurement, record numbers.
- Same authorship machinery; `CanvasDiffFileHeader` (fg-only) unchanged;
  the stage markers' contrast re-measured against the NEW bar bg (Task-1
  work measured against `Folded`).

## 4. Unified top band

- The band group is the EXISTING `CanvasDiffWinbar` (`default = true`,
  link `WinBar` — the sidebar's current effective colour), not a new
  name: users who overrode it keep their override, and the
  `CanvasDiffWinbar`/`CanvasDiffWinbarReadOnly` pair stays coherent.
  Both the sidebar winbar and the canvas winbar OPEN their expressions
  with it, and the statusline fill inherits the last active group, so
  each bar is painted edge to edge and the paint stops flipping between
  `WinBar`/`WinBarNC` with focus — that flip is today's visual
  disconnect between the two bars.
- The canvas winbar text is the comparison label alone; the breadcrumb
  path leaves the winbar (§5). Escaping, the identical-text cache, and
  the option-ownership bookkeeping in `ui/winbar.lua` stay as they are.
- READ-ONLY still outranks location: a range lens paints the whole
  CANVAS half `CanvasDiffWinbarReadOnly` while the sidebar half keeps
  the band group. The band visibly breaking at the seam IS the mode
  signal.
- The window-separator column crosses the band at the seam (one cell).
  Accepted: a literally seamless band across two windows does not exist.
- Sidebar title text (`Files changed (N)  +A −D`) unchanged; its
  `update_winbar` gains only the group prefix, and its prior/applied
  option protocol is untouched.

## 5. Sticky file-header row

- One-row float on the canvas window: pinned at the text area's first
  row (directly under the winbar, via the same `getwininfo().winbar`
  geometry the minimap uses), col 0, canvas width, non-focusable,
  `style = "minimal"`, zindex BELOW the minimap's 40 so the minimap owns
  the shared top-right cell.
- Content: EXACTLY the in-buffer file header line for the section under
  the topline — same `section_line` formatter, same `CanvasDiffFileBar`
  line background (§3's derived bar), same marker spans. No second
  formatter and no composed variant: the sticky row IS the header row,
  pinned.
- Resolution rides the existing scroll-sync path (`path_under_top`),
  like the winbar today; stats come from the live section, so a
  reconcile refreshes what the row shows.
- Hidden when the real header row is itself the topline (no doubling),
  when the canvas is empty or no section resolves, and during excursions
  — same lease lifecycle as the minimap: hide on BufWinLeave, re-show on
  BufWinEnter, reposition on WinResized, teardown on WinClosed.
- Accepted behaviours, recorded: the float COVERS the top canvas text
  row rather than pushing content down (anti-reflow — content never
  moves); clicks on it fall through to the covered row (non-focusable
  floats are mouse-transparent, spike-verified).

## Tests

1. Zero modes: option gone; removed-option diagnostic (canvas + any
   context it lived in); bars render by default; `statuscolumn.enabled =
   false` loses bars silently; existing mode tests deleted/rewritten.
2. Palette: add row and deleted-file row share the neutral bg; ghost has
   no bg and a dimmed fg differing from Normal fg; prefix cells carry the
   new groups at the right byte spans; gutter bars still render on ghost
   virt rows; word-diff attributes unchanged; override survival (user
   pre-defines `CanvasDiffAdd` → untouched).
3. Header bar: derived bg differs from `Folded`-linked value and clears
   the row elevation by the measured margin (assert the relationship, not
   raw numbers); marker spans still correct.
4. Top band: both winbars open with `CanvasDiffWinbar`; the canvas
   winbar is the comparison label alone (no path); a focus change leaves
   both bars painted with the band group; READ-ONLY paints the canvas
   half only.
5. Sticky row: appears once the topline passes a header and mirrors the
   header string + marker spans byte-for-byte; swaps when crossing a
   boundary (drive the scroll hook as existing tests do); hidden when
   the header row is the topline and on an empty canvas; stats reflect a
   live reconcile (edit a file, refresh, the row's counts change); the
   float dies with the canvas window; zindex sits below the minimap's.

## Verification

Full suite green per commit; manual smoke: scroll a 20-file canvas and
watch the sticky row swap at each boundary; the top band reads as one
bar across sidebar and canvas whichever window has focus; a deleted
file reads dimmed-with-red-margin; `:CanvasDiff main..topic` shows the
READ-ONLY tint on the canvas half of the band only.
