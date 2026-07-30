# Global Checkout Keymap Design

## Goal

Make local-branch checkout as directly accessible as branch comparison while
preserving CanvasDiff's conservative global-keymap ownership rules.

The built-in global defaults become:

```lua
keymaps = {
  global = {
    compare = "<leader>lb",
    checkout = "<leader>lc",
  },
}
```

`<leader>lb` opens the existing local-branch comparison flow.
`<leader>lc` opens the existing safe local-branch checkout flow.

## User-facing behavior

The two mappings are independent:

- `global.compare` invokes `App:compare()`;
- `global.checkout` invokes `App:checkout()`;
- either action accepts the same supported keymap configuration forms as the
  existing compare action: one key, a dense list of keys, or `false`;
- overriding or disabling one action does not alter the other;
- checkout continues to list only exact local branches and retains all
  existing modified-buffer, Git safety, callback-fencing, and refresh
  behavior.

If a configured CanvasDiff mapping conflicts with a mapping owned by another
plugin or by the user's configuration, the foreign mapping wins. CanvasDiff
reports the collision and does not replace it.

If compare and checkout resolve to the same effective key after Neovim
termcode expansion, setup rejects the configuration before adding, replacing,
or removing any global mappings. A single key cannot dispatch two actions.

## Architecture

The existing authenticated global-mapping reconciler remains the sole owner of
installation, reconfiguration, collision handling, and cleanup. It becomes
action-aware instead of being specialized for compare.

Each desired mapping record carries:

- its normalized left-hand side;
- its action (`compare` or `checkout`);
- its description;
- its callback identity and authenticated ownership metadata.

The reconciler routes each callback to the named `App` method. It keeps an
existing mapping only when the authenticated record still matches both the
effective key and action. This prevents a key whose configured action changes
from retaining the old callback.

Reconfiguration preserves the current install-before-delete behavior:

1. resolve and validate the complete desired mapping set;
2. reject internal action collisions atomically;
3. retain matching authenticated mappings;
4. install non-conflicting new mappings;
5. remove only stale mappings whose ownership can still be authenticated.

Reentry, reload, and foreign-takeover protection remain unchanged. CanvasDiff
never deletes or overwrites a mapping it can no longer prove it owns.

## Discoverability and wording

The generated cheatsheet shows both actions in its `Global` group with these
descriptions:

- compare: `Compare two branches or revisions`;
- checkout: `Checkout a local branch`.

The README documents both defaults, their configuration, independent
disabling, and the rule that existing foreign mappings are preserved.

The `r` action description changes everywhere it is presented to:

```text
Refresh the current diff
```

This is a copy-only clarification. The refresh implementation and its
position-preserving behavior do not change.

## Error handling

- Invalid global keymap shapes continue to fail validation with an
  action-specific diagnostic.
- Duplicate effective keys across global actions fail before mutation.
- A foreign mapping collision is reported for the affected key while leaving
  that mapping intact.
- A disabled action installs no mappings and removes only previously
  authenticated mappings for that action.
- A callback calls only its configured, allowlisted CanvasDiff action; config
  values cannot select arbitrary `App` methods.

## Verification

Tests must prove:

1. the default compare and checkout mappings are present;
2. each callback routes to the correct `App` method;
3. each action can be overridden, assigned multiple keys, or disabled
   independently;
4. compare/checkout effective-key collisions are rejected atomically;
5. pre-existing foreign mappings are preserved and reported;
6. foreign takeover after CanvasDiff installation is never removed;
7. setup reentry and module reload retain authenticated ownership behavior;
8. changing the action assigned to an effective key cannot retain a stale
   callback;
9. the cheatsheet and README expose both global actions;
10. refresh help uses exactly `Refresh the current diff`;
11. existing checkout safety and branch-selection tests remain passing.

Focused configuration, key ownership, callback, cheatsheet, and documentation
tests precede one fresh authoritative full-suite run. Review follows the
existing five-round repair cap and rejects scenarios outside the documented
Neovim/Git trust and platform boundary.

## Non-goals

- changing the checkout picker or Git switching semantics;
- adding force, stash, fetch, pull, detach, or remote-branch checkout;
- adding buffer-local checkout mappings;
- changing `<leader>lb`;
- changing the behavior of `r`;
- replacing Neovim's mapping APIs or CanvasDiff's ownership protocol.
