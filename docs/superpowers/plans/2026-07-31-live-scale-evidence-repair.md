# Live-scale evidence repair and optimization plan

Date: 2026-07-31
Status: executing on explicitly authorized `main`

## Evidence

The first authoritative five-size run at `1830134` was preserved in
`.superpowers/sdd/2026-07-30-live-scale-performance-campaign/`. It established
two supported failures:

- the otherwise-correct 100K worker measured a 141.18 ms maximum heartbeat
  gap and was rejected by the provisional universal 100 ms gate;
- the 1M watcher refresh crossed its fixed 1.5 second convergence deadline in
  the authoritative run, while an isolated replay converged correctly in
  924.03 ms.

The isolated 1M replay also measured 10.76 seconds across 24 complete source
collections, 2.89 GiB peak Lua heap, 3.38 GiB RSS after replay, and 759 MiB
post-cleanup Lua heap. The page cache itself retained only 24.9 MiB and two
decoded resident pages, so the dominant pressure is the complete diff model,
transaction snapshots, and per-row render metadata rather than paging
residency.

## Repairs

1. Preserve failed worker evidence and attribute heartbeat maxima to the
   active action. Keep 100 ms as a reported responsiveness target, but use a
   documented finite completion ceiling for the synchronous million-row
   lifecycle. Give watcher convergence a finite scale-tolerant deadline.
2. Stream the initial paged row build into `PageList` instead of constructing
   a second million-element row array.
3. Derive visible-row styling from the section entry at redraw time instead
   of retaining a second per-row style graph.
4. Record both old- and new-side fingerprints, release raw file sides after a
   paged splice commits, and reconcile released sections by those identities.
5. Snapshot transactional section lists by immutable section identity rather
   than recursively copying every entry. Rollback still receives its own
   shallow list so nested reconciliation cannot mutate the checkpoint.

## Acceptance

- Focused RED/GREEN tests prove streamed ingestion, released text identity,
  lazy styles, transactional rollback, evidence preservation, and finite
  watcher/heartbeat policy.
- Existing paged, lens, watch, root, lifecycle worker, and coordinator suites
  remain green.
- A fresh exact `1, 1000, 10000, 100000, 1000000` ladder passes correctness,
  cleanup, paging, and bounded-completion gates and becomes
  `docs/verification/live-scale.json`.
- The existing million-row paged campaign, chaos campaign, and one fresh full
  suite pass before finalization.
- Review remains inside the documented Linux/current-Neovim trust boundary and
  the existing five-round repair cap.
