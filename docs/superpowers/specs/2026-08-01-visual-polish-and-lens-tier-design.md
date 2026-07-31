# Visual Polish and the Last-Lens Tier

Approved 2026-08-01 (all four items selected together): stage markers on
canvas file headers, quieter diff tints with a gutter alternative, scrollbar
thumb dragging (spike first), and the in-memory last lens promoted to a
deliberate open-precedence tier.

## 1. Stage markers on canvas file header bars

The gap (verified): the expanded header renders
`▎ path  (3 hunks, +12 −4)` with no stage state; `●`/`○` markers exist only
on sidebar rows, so with the sidebar closed the `all` lens cannot say
whether a file's changes are staged.

- Expanded file headers gain the same trailing markers sidebar rows carry,
  from the same source of truth: `format.stage_mark(staged, unstaged)` and
  the same glyphs (`staged`/`unstaged`/`stale` including the ASCII set) and
  highlight groups (`CanvasDiffStaged`, `CanvasDiffUnstaged`,
  `CanvasDiffStale`, `CanvasDiffStaleEmphasis`).
- Folded placeholders already carry the stale mark; they gain the stage
  marks too, before the stale mark (stale stays last, per the documented
  column order).
- The markers sit ON the tinted `CanvasDiffFileBar` row. Verify by the
  repo's measurement method that the marker colours still separate against
  the bar's background (`Folded`) under the builtin scheme and
  tokyonight-moon; if a gap collapses, the fix is the existing one — bold
  emphasis composes over any background — not a new colour.
- Ranges (READ-ONLY) have no stage state: headers render no markers there,
  matching the sidebar's behavior in range lenses (verify what the sidebar
  does and mirror it exactly).
- Live updates: markers refresh whenever the header line is re-rendered by
  reconcile — same path that updates the diffstat today; no new wiring.

## 2. Quieter diff tints, plus a gutter mode

New option `highlight.diff`, three values:

| value | meaning |
| --- | --- |
| `"quiet"` (new default) | `CanvasDiffAdd`/`CanvasDiffDel` default to a DERIVED low-intensity tint: the colorscheme's `DiffAdd`/`DiffDelete` background blended toward `Normal`'s background. Blend factor chosen by measurement (start at 60% toward Normal; pick the factor where syntax-token luminance deltas on tinted rows stay within ~15% of their untinted values under both reference schemes, and record the numbers). |
| `"classic"` | today's behavior: link raw `DiffAdd`/`DiffDelete`. |
| `"gutter"` | no row tints at all; the statuscolumn carries a coloured bar glyph per diff row (`▎`, ASCII `\|`) in `CanvasDiffAdd`/`CanvasDiffDel` foreground. Requires `statuscolumn.enabled`; when the statuscolumn is disabled, warn once and fall back to `quiet`. |

- Groups stay `default = true` in every mode — a user or colorscheme
  override always wins. `quiet` computes its derived colours in
  `ensure_hl_groups` from live `nvim_get_hl` values, so a colorscheme
  change recomputes on the next application.
- Word-diff (bold+underline), `+`/`-` prefixes, and ghost deletions are
  untouched in all modes — the shape channels are the accessibility floor.
- The README's "How diff rows are coloured" section documents the new
  option and the measured blend numbers, in its existing voice.

## 3. Scrollbar thumb dragging

Name of the thing: the scrollbar **thumb**; the feature is thumb dragging
(scrubbing) plus track jumps.

**Spike first** (`spikes/`, committed like the existing spikes): determine
whether `<LeftMouse>` over the non-focusable minimap float routes to the
float or passes through to the canvas window beneath, on this Neovim
version. Deliverable: a short spike note stating which window receives the
click and where the mappings must therefore live. The implementation task
reads that note.

**Behavior** (same regardless of spike outcome):

- Press-and-hold on the thumb, drag up/down: the canvas viewport follows
  proportionally (`mouse row within bar → topline`, clamped to
  `[1, line count]`), live during the drag.
- Press on the track (bar column, off the thumb): jump the viewport to
  that proportional position (single jump, no paging).
- Clicks NOT on the scrollbar column behave exactly as today: cursor
  placement and the double-click jump are untouched — the handlers fall
  through for any position off the bar.
- Works with tier-1 virtualization (scrubbing far triggers the existing
  near-viewport auto-expansion; no new wiring, but a test proves it).
- No new config: dragging ships as part of `scrollbar.enabled`. The
  README's scrollbar paragraph gains two sentences.
- Implementation constraints: use `vim.fn.getmousepos()` for hit-testing;
  mappings are buffer-local (canvas or scrollbar buffer per the spike);
  drag state lives on the scrollbar's lease and is cleaned up by its
  existing disposal.

## 4. The last-lens tier

Today, which lens a REOPENED canvas shows mid-session can come from
leftover in-memory state — behavior that is desirable but accidental
(pinned in test_root.lua during the q-back-out work). Promote it to a rule.

**The open precedence chain becomes** (most to least specific):

1. explicit `opts.lens`
2. explicit `opts.base`
3. **in-memory last lens for this repo root** (NEW deliberate tier)
4. session file's lens
5. session file's legacy `base`
6. `config.options.base` default

- The in-memory record: App keeps `last_lens_by_root[root]`, written when a
  canvas CLOSES (the lens it was showing at close, normalized), read at
  open. Ranges are recorded too — reopening into the comparison you closed
  in is consistent with tier 4 (the session file already restores ranges,
  and the Task-1 fallback from the lens-lifecycle branch already covers a
  range whose refs died meanwhile).
- Rationale for tier 3 above tier 4: mid-session memory is fresher than the
  disk file (which is also written at close, but tier 3 works when
  `session.enabled = false` and costs no IO).
- Whatever in-memory leak currently produces the accidental behavior is
  FOUND and REMOVED in the same change — one mechanism, not two. The
  test_root pin is updated from "quirk documented" to "rule asserted".
- `return_lens` needs no change: it already records "the lens the canvas
  was showing when a comparison was stacked", which tier 3 now makes
  deterministic.
- Docs: one paragraph in the README session section; the vimdoc sentence
  updated to match.

## Tests

1. Header markers: expanded + folded headers carry correct marks for
   staged/unstaged/mixed/stale files; range lens renders none; ASCII glyph
   set renders `*`/`o`; marker spans land on the right bytes (reuse the
   sidebar's span-testing approach).
2. `highlight.diff`: quiet derives a bg differing from raw DiffAdd and from
   Normal; classic links raw; gutter emits statuscolumn bars and no row
   tints; disabled-statuscolumn fallback warns once.
3. Thumb drag: unit-test the proportional mapping (row→topline) pure
   function; integration-test track jump and drag against a tall canvas;
   virtualization expansion on a far scrub.
4. Last-lens tier: close in `staged`, reopen with session disabled → opens
   `staged`; explicit lens still wins; session file used when no in-memory
   record (fresh instance); the updated test_root rule test.

## Verification

Full suite green per commit; manual smoke of dragging (headless mouse is
limited — the spike documents what headless CAN prove and the manual step
covers the rest).
