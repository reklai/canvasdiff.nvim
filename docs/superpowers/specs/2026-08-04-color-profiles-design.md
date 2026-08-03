# Color profiles for the diff vocabulary

Approved 2026-08-04.

## Summary

`setup({ profile = "quiet" | "classic" | "mono" })` selects which *default*
color vocabulary the appearance manager derives for the diff-row groups.
Profiles are colors only: they never change what is drawn. Element toggles
(`statuscolumn`, `scrollbar`, glyphs) compose with any profile. The default
is `quiet`, today's measured palette, unchanged.

`tinted` (diff hue blended into the elevation, the file bar's
chroma-over-luma trick applied to rows) is explicitly deferred until its
factors are measured under the builtin dark scheme and tokyonight-moon with
the same rigor as the existing budgets.

## Scope: the ten diff-vocabulary groups

Profiles define defaults for exactly:

- `CanvasDiffAdd`, `CanvasDiffDel`, `CanvasDiffGhost`, `CanvasDiffHunkDel`
- `CanvasDiffPrefixAdd`, `CanvasDiffPrefixDel`
- `CanvasDiffGutterAdd`, `CanvasDiffGutterDel`
- `CanvasDiffScrollAdd`, `CanvasDiffScrollDel`, `CanvasDiffScrollChanged`

Everything else — file bar, headers, winbar, sidebar, crumb, scroll thumb,
and the staged/unstaged/stale status dots — is profile-independent. Status
dots are review-state semantics, not diff look, and are already
shape-distinguished (filled, hollow, emphasized).

## The profiles

**quiet** — the current derivation, byte-for-byte, including the
Visual/CursorLine collision escape. No behavior change for existing users.

**classic** — the traditional wash:

- `CanvasDiffAdd = { link = "DiffAdd" }`
- `CanvasDiffDel = { link = "DiffDelete" }`
- `CanvasDiffGhost = { link = "DiffDelete" }`
- `CanvasDiffHunkDel` keeps its link to `CanvasDiffGhost`.
- Prefixes, gutter, and minimap already carry the scheme's diff colors;
  they keep their quiet-profile derivations/links.
- No collision guard: the wash is the scheme's own vocabulary; if the
  scheme's `DiffAdd` collides with its `Visual`, that is the scheme's
  choice, not ours to correct.

**mono** — zero chroma across all ten groups:

- Rows and ghosts: quiet's derivations (elevation, ghost dim, escape rule).
- `CanvasDiffPrefixAdd`/`CanvasDiffGutterAdd`: `Normal`'s foreground.
- `CanvasDiffPrefixDel`/`CanvasDiffGutterDel`: the ghost-dim foreground
  (dimming already says "removed").
- `CanvasDiffScrollAdd`/`Del`/`Changed`: one shared neutral background,
  the row elevation — density stays visible in the minimap, direction
  comes from position in the review.

## Mechanics

- `appearance/groups.lua` `G.definitions()` gains a `profile` argument; the
  manager passes the configured name through `appearance.setup()`/`ensure()`.
- Every profile's output remains `default = true` definitions. The ownership
  chain is unchanged: profile defaults → colorscheme/direct definition →
  explicit `setup().highlights`. `ColorScheme` reloads rederive under the
  active profile; repeated setup calls replace state.
- Validation: `profile` must be one of the three names. An unknown value is
  reported as a setup diagnostic and by `:checkhealth canvasdiff`, and the
  manager falls back to `quiet`.

## Tests

- Fault suite (`test/fault/test_palette.lua` idiom):
  - classic: the three links are present as links (not flattened), and an
    explicit user override still wins.
  - mono: chroma == 0 for every one of the ten groups under a scheme whose
    diff groups carry hue (pin the invariant, not values).
  - quiet: existing tests pass untouched — the profile argument defaulting
    to quiet must be invisible to them.
- Unit config test: unknown profile name produces the diagnostic and quiet
  derivation; valid names produce none.

## Docs

- README: the classic-colors recipe becomes `profile = "classic"`; keep the
  raw `highlights` recipe as the "roll your own" example. Document `profile`
  in the configuration reference with the three names.
- `doc/canvasdiff.txt`: `profile` option entry plus one line per profile.
- `docs/design.md`: a short section on why profiles are colors-only and why
  tinted is deferred.
