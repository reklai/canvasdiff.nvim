# Publication-readiness and configuration design

Date: 2026-08-03

## Context

This pass prepares CanvasDiff for a first public audience: it must install with
lazy.nvim or LazyVim, work with no configuration, expose the subjective parts
of its presentation without making users learn an unnecessary abstraction,
orient a contributor who already understands Lua and Neovim, and withstand a
deliberately hostile smoke campaign.

The design is grounded in four inspected sources:

- the current CanvasDiff tree, help, architecture rules, tests, benchmarks, and
  deterministic chaos harness;
- the local Ghostty checkout at
  `/home/reklai/coding/personal/ts_js/ghostty`;
- Ghostty's current configuration and theme documentation; and
- the current lazy.nvim, LazyVim, and Neovim documentation fetched through
  Context7.

The transferable Ghostty principles are zero-configuration defaults, a simple
override surface for subjective choices, one named owner for each contract,
comments that explain public meaning and load-bearing invariants, and reference
documentation that is kept accountable to the source contract.

## Goals

1. Keep `require("canvasdiff").setup()` optional and make the defaults strong
   enough that an empty lazy.nvim `opts` table is a complete installation.
2. Let a LazyVim user override any CanvasDiff highlight group directly in
   `opts`, including foreground, background, links, and text attributes.
3. Make highlight definitions, colorscheme recovery, validation, and user
   override precedence one maintainable subsystem instead of scattered setup
   calls.
4. Add only contributor comments that explain ownership, invariants, public
   contracts, or a non-obvious design choice.
5. Turn the README and help into an accurate installation, configuration, and
   usage path, with a separate contributor guide for development detail.
6. Extend deterministic hostile testing to configuration, colorscheme, and
   lazy-loading lifecycles, repair every admitted regression it exposes, and
   run the repository's full publication verification.

## Non-goals

- No bundled theme collection or CanvasDiff-specific semantic color language.
- No configuration GUI, hot-reload command, preset framework, or callback
  system.
- No unrelated reorganization of diff, storage, staging, or session behavior.
- No claim that pre-alpha behavior is stable merely because the README is
  publishable.
- No comments that paraphrase straightforward Lua.

## Architectural change: the appearance domain

Add a focused `appearance` domain:

```text
lua/canvasdiff/appearance.lua
lua/canvasdiff/appearance/groups.lua
lua/canvasdiff/appearance/manager.lua
```

`appearance.lua` is the cross-domain facade. `groups.lua` is the canonical
registry of every supported `CanvasDiff*` group and owns static definitions and
the existing measured palette derivation. `manager.lua` owns the process-wide
application lifecycle: default installation, validated user overrides,
authorship tracking, and one `ColorScheme` autocmd.

The domain accepts options as input rather than reading application state. It
has no outgoing cross-domain dependency; callers pass the highlight table into
the facade. App, canvas, and UI may depend on the facade, and architecture
tests will enforce that none imports an appearance implementation module
directly.

Move the palette derivation and group setup currently spread across
`canvas/format.lua`, `canvas/Canvas.lua`, `ui/sidebar.lua`, `ui/scrollbar.lua`,
and `ui/winbar.lua` into this owner. Rendering modules continue to choose which
group marks a piece of text, but they no longer define what that group means.

Rename the current `ui/highlight.lua` Tree-sitter engine to `ui/syntax.lua` and
rename the UI facade member from `highlight` to `syntax`. It highlights diff
content syntactically; calling it merely “highlight” becomes ambiguous as soon
as appearance has a real owner. This is an internal boundary rename, not a new
public plugin API.

This refactor is bounded to the configuration and presentation seam touched by
the release pass. Existing unrelated architecture debt remains out of scope.

## Public configuration contract

Add `highlights = {}` to the setup schema. Keys are exact public highlight
group names and values are Neovim highlight specifications:

```lua
{
  "reklai/canvasdiff.nvim",
  opts = {
    highlights = {
      CanvasDiffFileBar = {
        fg = "#c6d0f5",
        bg = "#303446",
        bold = true,
      },
      CanvasDiffGhost = { link = "Comment" },
    },
  },
}
```

The specification uses the same fields accepted by `nvim_set_hl`, so users do
not learn a second color vocabulary. `default` and `force` are manager-owned
control fields and are rejected in user specifications. A group value of
`false` explicitly removes a previously managed override and returns that group
to its CanvasDiff or colorscheme default. An omitted group does the same on a
later `setup()` call because setup is replacement-from-defaults, as it is for
the rest of CanvasDiff's configuration.

The appearance registry, not the config module, owns the group-name set. The
config module treats `highlights` as a validated extension table in the same
way it already treats `glyphs` specially. Appearance reports:

- an unknown CanvasDiff group;
- a non-table/non-false group value;
- manager-owned `default` or `force` fields; and
- any specification Neovim rejects.

Invalid entries never throw out of `setup()`. They are diagnosed, omitted from
the accepted override set, and the affected old managed override is released
back to its default. Valid sibling entries still apply. `:checkhealth
canvasdiff` repeats the audit against the original user table, so a startup
notification is not the only chance to see the error.

All existing behavior, keymap, glyph, performance, and layout options retain
their current names and merge semantics. The release pass may rename an
internal variable or module when it removes ambiguity, but it will not churn a
working public option without a concrete correctness reason.

## Highlight precedence and lifecycle

The explicit precedence is:

```text
colorscheme -> CanvasDiff defaults -> setup().highlights
```

CanvasDiff static and derived definitions remain defaults, so a colorscheme may
define a `CanvasDiff*` group. A group named in `setup().highlights` is an
explicit user choice and wins over both. The manager records the exact
definitions it authored. When setup later removes an override, it clears it
only if the current definition is still the manager's; a direct
`nvim_set_hl()` call made afterward belongs to the user and is preserved.

One process-wide `ColorScheme` autocmd reinstalls defaults and then accepted
overrides after a scheme clears custom groups. Repeated `setup()` calls replace
that state without accumulating autocmds or groups. The zero-config root load
initializes the same manager with an empty override table, so colorscheme
recovery is not conditional on calling setup.

Derived groups keep their existing measured behavior. Their authorship record
continues to permit re-derivation when `Normal`, `Directory`, or diff colors
change while refusing to overwrite a foreign definition.

## Contributor-facing comments and documentation

Use the Ghostty comment rule rather than increasing comment volume generally:

- module headers state what a major owner owns, what it deliberately does not
  own, and its lifetime;
- public functions document input/output and failure behavior when the name and
  types do not make those facts obvious;
- inline comments explain load-bearing ordering, ownership checks, measured
  behavior, or a rejected tempting alternative; and
- obvious control flow is left uncommented.

Add concise orientation headers where currently absent in the large owners,
especially App, Surface, Page, PageList, Projection, Scheduler, the renamed
syntax engine, and the new appearance modules. Update `docs/architecture.md`
with the appearance seam and dependency direction.

Add `CONTRIBUTING.md` covering repository layout, domain/facade rules, comment
expectations, focused test commands, full verification, chaos replay, and the
requirement to add executable guardrails for boundary or lifecycle fixes.

## README and help structure

The README becomes a public entry path rather than a running development note:

1. value proposition and the existing text preview;
2. status and requirements;
3. lazy.nvim/LazyVim installation, including eager and correct command/key
   lazy-loading specs;
4. quick start;
5. common configuration recipes before the complete defaults;
6. appearance customization through `opts.highlights`, plus direct
   `nvim_set_hl` for colorscheme authors;
7. usage and behavior reference;
8. troubleshooting and `:checkhealth`;
9. documentation and contributing links; and
10. license.

Remove the unfulfilled demo placeholder. Remove historical “changed behavior”
material that does not help a new install; durable rationale remains in design
documentation and current behavior remains in the keymap reference. Do not add
decorative badges or promise release stability that has not been established.

Update `doc/canvasdiff.txt` with the same public option, precedence, reset, and
colorscheme behavior. An executable documentation guard checks that every
registry group appears in both the README highlight reference and Vim help, so
adding a group cannot silently omit its user-facing documentation.

## Test and deliberate-breakage design

Implementation follows test-driven development. Focused tests cover:

- the exact appearance facade and registry;
- native foreground/background/link/attribute application;
- unknown and malformed group diagnostics;
- rejection of manager control fields;
- repeated setup replacing prior overrides;
- preservation of a foreign definition written after setup;
- recovery after `:colorscheme` clears custom groups;
- one autocmd owner after repeated setup/module use;
- config health output;
- every documented group matching the canonical registry;
- the `ui.highlight` to `ui.syntax` boundary rename; and
- eager and lazy.nvim-style root entry points with partial `opts`.

Extend the deterministic Surface chaos campaign with actions that:

- apply randomized valid partial configuration;
- submit malformed highlight groups and specifications;
- reset setup to defaults;
- switch or clear colorschemes while reviews are open;
- open, refresh, split, close, and reopen after those changes; and
- alternate ASCII and default glyph sets with narrow and wide windows.

After every action, assert that accepted explicit highlight overrides are
observable, all required default groups exist, the appearance autocmd count is
bounded, invalid setup did not dismantle a live review, and existing Surface
ownership invariants still hold. Seeds and recent action history remain
replayable exactly.

Run focused tests while implementing, then `make test`, the full three-seed
chaos lane, and `make verify`. Any failure is classified as change-caused,
pre-existing, or environmental; only authoritative reruns count as repaired.

## Completion evidence

The branch is complete only when all of the following are true in the current
tree:

- branch name is `final_stretch`;
- the canonical appearance registry owns every `CanvasDiff*` definition and
  architecture tests enforce the new seam;
- the LazyVim `opts.highlights` example runs and survives colorscheme changes;
- unknown or invalid appearance configuration is actionable through setup and
  checkhealth;
- README, Vim help, architecture documentation, and `CONTRIBUTING.md` agree
  with the implemented contract;
- targeted Ghostty-style orientation comments exist without narration noise;
- focused, integration, documentation, and deterministic chaos regressions
  pass;
- the full deliberate-breakage campaign and repository verification pass; and
- independent adversarial reviewers have no admitted Critical or Important
  finding left unresolved.
