# experiment/d-unified-pipeline — comparison report

Branched from `experiment/tree-bipartition-restore` at `b66879f` (the
cross-batch merge-bug fix). Implements the full scope from GPT's review:
every tiled batch enters `beginDecomposition()` unconditionally (no
representative-count special-casing), `peelOrder()` made unreachable
from any new-generation batch (kept physically in the file, not
deleted), and `moveWorkspaceTo()`'s trivial case now also transits
through `root.stashWorkspace` like every other tiled batch.

## What changed in `Service.qml`

- `finishStash()`: removed the `representatives.length <= 1` special
  case (a loop of individual `root.moveAddress()` calls). Now always
  calls `root.beginDecomposition(...)` whenever `tiledClients.length >
  0`, regardless of representative count.
- `finishMoveWorkspace()`: same removal — the trivial-case
  `structureClauses()`/`geometryClauses()` branch is gone; always hands
  off to `beginDecomposition()`.
- `finishRestore()`: the `peelOrder()`-based fallback branch was
  replaced with "natural safe placement" — each tiled window placed
  independently (no preselect chaining, no forced absolute resize),
  matching the same principle already used for `moveWorkspaceTo()`'s own
  reconstruction-failure fallback. This branch is now reached only for a
  genuine `plan.unresolved` (never observed live) or a batch with no
  `root.batchPlans` entry at all (a stash predating this branch, within
  one session).
- No changes to `beginDecomposition()`, `onDecomposeCapture()`,
  `finishDecompositionSurvivor()`, `completeDecomposition()`,
  `reconstructTree()`, or `walkAndDispatch()` — tracing through the
  existing logic confirmed they already degrade correctly for a
  1-element `addresses` array: `removalOrder = addresses.slice(1)` is
  already empty, so the very first capture callback takes the
  "finish immediately" path (one quick capture, one survivor move, zero
  destructive steps), and `reconstructTree()` already returns a trivial
  `Leaf` identity for a single address with an empty record.

## The 8-point comparison

1. **Lines/functions changed**: `Service.qml` net -8 lines (44
   insertions, 52 deletions). No functions added or removed.
2. **Reconstruction branches**: 3 independent "is this batch trivial"
   decisions (`finishStash()`, `finishMoveWorkspace()`,
   `finishRestore()`) → 1. The remaining branch in `finishRestore()` is
   now a pure "did D resolve" check, not a separately-computed
   representative-count decision.
3. **Operation/representation states**: 3 (no plan / unresolved plan /
   resolved tree) → 2 (unresolved / resolved). "No plan" and
   "unresolved" used to be two different code paths; now the same one.
4. **Live behavior**: no regressions across single window, single
   group, N=2, 4-window grid, pseudo-tile, all 4 cross-batch merge
   cases from the prior bug-fix review, stash-populated-during-moveTo,
   and interrupted operation — all exact geometry, no crashes.
5. **Latency** (IPC round-trip, `time quickshell ... ipc call`): N=1
   ~44ms, group-only ~44ms, N=2 ~46ms, 4-window grid ~48ms, pseudo-tile
   ~45ms — no perceptible difference between the trivial and
   real-decomposition cases.
6. **Stash-populated + moveTo**: verified live — a real stash sitting in
   `root.stashWorkspace` was completely undisturbed by a concurrent
   `moveTo`'s own transit through that same special workspace, and
   restored correctly afterward.
7. **Cross-batch restore**: re-ran cases 1 and 3 from
   `docs/CROSS-BATCH-MERGE-BUG-REVIEW.md` (tiled+tiled,
   D-tree+D-tree) — the merge-bug fix still holds under the unified
   pipeline, no slivers.
8. **Interrupted operation**: window closed mid-decomposition on a
   4-window batch — no crash, no stranded window, clean recovery,
   consistent with every prior interruption test this session.

`peelOrder()`/`isSeparated()`/`orderDescriptors()`/`restoreOrder()`/
`sortByRowThenX()` (~106 lines, `Service.qml:278-383`) confirmed
unreachable from any live call site (verified via `grep` across the
whole file) — left physically present, not deleted, per the
experiment's own instruction.

`qmllint`/`omarchy plugin validate .` clean throughout.

## Question for review

Does this satisfy the experiment's goal well enough to merge into
`experiment/tree-bipartition-restore` (and eventually toward `main`), or
is further daily-driving/testing warranted before that decision? Also:
given `peelOrder()`'s family is now fully unreachable, is there anything
that should change about when Phase 5 (actual deletion, after a
regression review) is revisited?
