# CanvasDiff name audit

Date: 2026-07-26

Decision: **PASS**. Use `CanvasDiff` as the product name, `canvasdiff.nvim`
as the repository slug, `canvasdiff` as the Lua namespace, and `:CanvasDiff`
as the command.

This is an availability check, not a trademark opinion. Public indexes cannot
prove that no private, unpublished, or newly-created project has the name.
Repeat the checks immediately before publishing a public repository.

## Neovim ecosystem checks

The following searches returned no plugin, repository, or module named
`CanvasDiff`, `canvasdiff`, or `canvasdiff.nvim`:

- [GitHub repository search for `canvasdiff` in names][github-name] returned
  `total_count: 0` with `incomplete_results: false`.
- GitHub searches for `canvasdiff neovim`, `canvasdiff nvim`,
  `canvasdiff.nvim in:name`, and CanvasDiff topic combinations also returned
  zero complete results.
- [Dotfyle's plugin catalog search][dotfyle] returned `0 plugins`.
- [Neovimcraft's catalog][neovimcraft] contained no case-insensitive name,
  slug, or module match.
- [awesome-neovim][awesome-neovim] contained no case-insensitive match.
- [LuaRocks][luarocks] returned no modules for `canvasdiff`.
- The local Neovim configuration, data, state, and cache trees contained no
  `CanvasDiff` command, module, plugin directory, guard, or name match.

Anonymous GitHub code search was not available, so repository-name search and
the public Neovim catalogs are the authoritative reproducible checks in this
audit.

## Nearby names and product position

There are unrelated global uses of similar words:

- `jonathanolson/canvas-diff` is an old browser-canvas rendering comparison.
- `CanvasDiff` appears as a type or feature name in non-Neovim projects such
  as `flo_ui`.

The hyphenated slug `canvas-diff` is therefore avoided.

CanvasDiff also does not claim that Neovim lacks diff tools. Projects such as
Diffview, CodeDiff, diffs.nvim, mini.diff, and unified.nvim occupy adjacent
space. CanvasDiff's distinguishing promise is a paged, aggregate, single-canvas
review surface that remains interactive at very large logical line counts.

## Publication recheck

Run all of these immediately before creating or renaming a public remote:

1. Search GitHub repository names for `canvasdiff`, `canvasdiff.nvim`, and
   `"CanvasDiff" neovim`.
2. Search Dotfyle, Neovimcraft, awesome-neovim, and LuaRocks again.
3. Search the intended package manager and remote host for the exact slug.
4. Check the local runtime path for an installed module or command collision.
5. Record the date, result counts, and any collision decision in this file.

[github-name]: https://api.github.com/search/repositories?q=canvasdiff+in%3Aname&per_page=100
[dotfyle]: https://dotfyle.com/neovim/plugins/trending?q=canvasdiff
[neovimcraft]: https://neovimcraft.com/
[awesome-neovim]: https://github.com/rockerBOO/awesome-neovim
[luarocks]: https://luarocks.org/search?q=canvasdiff
