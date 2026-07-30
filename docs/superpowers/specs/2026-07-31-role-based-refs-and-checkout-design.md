# Role-Based Refs and Safe Checkout Design

## Goal

Replace ambiguous “local versus remote” presentation with exact comparison
roles and add an explicit, conservative branch-switching workflow. Comparison
remains read-only; checkout becomes a separate mutation with its own command,
selection rules, safety checks, and lifecycle.

## Terminology

CanvasDiff describes a diff as `OLD → NEW`.

- `HEAD` is the currently checked-out commit.
- `INDEX` is Git's staged snapshot.
- `WORKTREE` is the editable worktree, including supported loaded-buffer
  content.
- A local branch is a ref under `refs/heads/`.
- A remote-tracking ref is a locally stored observation under
  `refs/remotes/`; it is not a live network connection.
- A remote default is a symbolic remote-tracking ref such as `origin/HEAD`.
- A checked-out branch is the local branch to which `HEAD` is attached.

“Local” and “remote” are provenance metadata, never diff-side roles.

## Directional comparison labels

All canvas, notification, session, and picker-facing comparison labels use
old-to-new direction:

| Lens | Label |
| --- | --- |
| all | `HEAD → WORKTREE` |
| unstaged | `INDEX → WORKTREE (unstaged)` |
| staged | `HEAD → INDEX (staged)` |
| arbitrary ref | `<ref> → WORKTREE` |
| `A..B` | `A → B` |
| `A...B` | `merge-base(A, B) → B` |

The underlying lens IDs and `old`/`new` values remain unchanged, preserving
session and public data compatibility. Previously persisted valid lenses are
normalized through their identities, so stale serialized label text cannot
restore obsolete “versus” language.

## Comparison picker

`:CanvasDiff compare` remains non-mutating and may select local branches,
remote-tracking refs, or detached `HEAD`.

The first prompt is `CanvasDiff compare from (base):`. The base priority
remains:

1. `origin/HEAD`;
2. other remote defaults;
3. local `main`;
4. local `master`;
5. remaining refs.

Presentation replaces terse provenance tags:

- current local branch: `<name> [checked out]`;
- remote default: `<remote>/HEAD [default for <remote>]`;
- other remote-tracking ref: `<name> [remote-tracking ref]`;
- other local branch: `<name>`.

After selecting a base, the target prompt names the effective operation:
`CanvasDiff compare to (merge-base(<base>, target) → target):`. Selecting the
target is confirmation. There is no redundant third dialog.

Full refs remain the execution identity. Display names never flow back into
Git commands, so same-named local and remote refs cannot become ambiguous.

## Local branch checkout

`:CanvasDiff checkout` opens a picker containing only concrete local branches
under `refs/heads/`. Remote defaults and remote-tracking refs are excluded.
The prompt is `CanvasDiff switch local branch:` and the current branch is
marked `[checked out]`.

Selecting the current branch is a successful no-op. Selecting another branch:

1. resolves the exact repository associated with the invoking CanvasDiff
   surface or current buffer;
2. refuses while any modified loaded buffer belongs to that repository,
   protecting unsaved text that Git cannot see;
3. invalidates pending comparison and watch callbacks for the affected
   surface;
4. runs a non-forcing Git switch against the selected full local ref;
5. never passes force, merge, detach, stash, fetch, delete, or checkout-path
   options;
6. trusts Git's own overwrite checks for saved worktree/index changes and
   returns Git's diagnostic unchanged when switching is unsafe;
7. performs a full source recollection at `HEAD → WORKTREE`;
8. preserves whether the canvas was visible before the switch;
9. restores the prior semantic file/hunk position when it still resolves,
   otherwise lands at the first available change;
10. restarts owned controllers only after the replacement canvas is
    published.

If Git switches successfully but rebuilding the canvas fails, CanvasDiff does
not attempt an automatic reverse checkout. It reports that the branch changed
and the refresh failed, because an automatic reversal could overwrite
subsequent user or hook changes.

When no canvas is active, checkout switches the branch but does not
automatically open a review.

## Remote-tracking branch creation

`:CanvasDiff track` is the explicit path from a remote-tracking ref to a local
branch. Its picker:

- includes concrete `refs/remotes/<remote>/<branch>` refs;
- excludes symbolic remote defaults such as `origin/HEAD`;
- labels every item `<remote>/<branch> [remote-tracking ref]`.

The default local name removes only the first remote path component:
`origin/feature/api` becomes `feature/api`. CanvasDiff refuses when that local
branch already exists and instructs the user to use
`:CanvasDiff checkout`. It does not invent a suffix or overwrite the branch.

After selection it applies the same modified-buffer guard and lifecycle as
checkout, then asks Git to create and switch to the exact local branch tracking
the exact full remote ref. It performs no fetch. Success leaves the canvas on
`HEAD → WORKTREE`.

## Public surface

The command grammar adds the reserved words `checkout` and `track`, checked
before revision parsing and included in completion and command help.

The Lua facade adds:

```lua
require("canvasdiff").checkout()
require("canvasdiff").track()
```

Both functions use the same picker flows as their commands. No force-capable
checkout API is exposed.

Repository operations are kept below `App`:

```lua
repository.switch_branch(root, full_ref)
repository.track_branch(root, local_name, full_remote_ref)
```

They return `true` on success or `nil, diagnostic` on failure. Inputs must be
metadata returned by the repository ref enumerator, not unchecked display
text.

## Rendering environments

The role model is renderer-independent. Neovim consumes it through the winbar,
notifications, and pickers. A future OpenTUI adapter can render the same
`old`, `new`, and directional label without introducing “local/remote” sides.
No OpenTUI dependency or runtime adapter is added in this change.

## Error handling

- Outside a Git repository: warn `not inside a git repository`.
- No local branches: warn `no local branches found`.
- No concrete remote-tracking refs: warn
  `no remote-tracking branches found`.
- Modified repository buffer: refuse before Git with the exact buffer path.
- Missing or stale selected ref: let the exact full-ref Git operation fail;
  do not fall back to a display name.
- Existing derived tracking branch: refuse before Git and recommend checkout.
- Superseded, closed, or ownership-changed picker request: silently discard it.
- Successful Git mutation followed by UI failure: report both facts and keep
  the new branch.

All diagnostics are bounded and must not expose environment variables or
unrelated command output.

## Testing

Pure tests cover:

- directional lens labels and normalization of persisted labels;
- command parsing, planning, completion, and reserved-word precedence;
- picker presentation for checked-out, remote-default, remote-tracking, and
  ordinary local refs;
- local/remote filtering and derived tracking names.

Repository integration tests use isolated real Git repositories to prove:

- local switch changes `HEAD` without force;
- dirty changes that Git can preserve remain preserved;
- conflicting saved changes are refused by Git;
- exact full refs prevent local/remote ambiguity;
- tracking creates the expected local branch and upstream;
- collisions and symbolic remote defaults are refused;
- no fetch, stash, detach, force, or deletion occurs.

Application integration tests prove:

- modified loaded buffers block both mutation paths;
- picker callbacks are fenced against closure, replacement, and reentry;
- an active canvas is fully recollected at `HEAD → WORKTREE`;
- a hidden/absent canvas remains hidden;
- semantic position is restored when possible;
- a post-switch refresh failure reports an already-changed repository.

The authoritative full suite, branch/range comparison tests, lifecycle tests,
chaos campaign, and live-scale performance suite remain required. Independent
review is bounded by the repository adversarial-development policy.

## Out of scope

- Fetching, pulling, pushing, deleting, renaming, merging, rebasing, stashing,
  forcing, or detaching refs.
- Editing remotes or upstream configuration outside Git's normal
  `switch --track` result.
- A conflict-resolution UI.
- OpenTUI implementation.
- Network freshness or “last fetched” timestamps.
