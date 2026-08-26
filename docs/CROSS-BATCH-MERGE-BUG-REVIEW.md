# Cross-batch restore merge bug — review request

## The bug, reproduced live

1. Focus workspace 3, spawn a single window filling the workspace
   (`src1-A`, captured at `[12,38] [1416,850]`). `stash()`.
2. Focus workspace 7, spawn a single different window filling that
   workspace (`src2-B`, captured at `[12,38] [1416,850]`). `stash()`.
3. Focus a fresh, empty workspace 9. `restore()`.

Result:

```
src1-A [12, 38]   [1340, 850]
src2-B [1366, 38] [62, 850]
```

`src2-B` is squeezed to 62px wide. Both windows were captured as if each
owned the *entire* workspace alone — because each did, on its own
original source workspace. Restoring them together forces both
independently-captured absolute sizes into the same destination, and
whichever resize dispatches last squeezes the other down to almost
nothing.

## Root cause

`finishRestore()` computes one `occupied` flag, once, from whether the
*destination* had pre-existing windows before the restore started
(`root.isWorkspaceOccupied(destination)`). `geometryClauses()` only skips
the absolute-resize clause when `occupied` (or `unresolved[address]` for
the peelOrder fallback) is true — see `Service.qml`'s own comment on
`skipTiledResize`: forcing captured absolute sizes onto a destination
that already holds unrelated content produces exactly this squeeze,
confirmed empirically.

That existing protection only covers "destination already occupied
*before* this restore call." It does not cover "this restore call itself
is merging 2+ independent batches that were never siblings together" —
which is exactly this case: workspace 9 was empty beforehand, so
`occupied` was `false` for the whole call, yet the restore still merges
two mutually-inconsistent absolute sizes.

This is **not** part of the Approach D decomposition/reconstruction work
from this session — both `src1-A` and `src2-B` are single-window batches
(0-1 group representative), so neither ever enters
`beginDecomposition()`/gets a `root.batchPlans` entry. Both go through
`finishRestore()`'s pre-existing `peelOrder()`-based flat fallback branch,
which is functionally unchanged from before this session's work (only the
already-existing cross-batch `anchorMeta`/`anchorAddress` threading
touches it, which is a structural/ordering concern, not a sizing one).
D itself has had zero confirmed bugs across every fixture tested this
session (grids, groups, pseudo-tiling, stale windows, reentrancy, and the
same for `moveWorkspaceTo()`).

## Why "lean fully on D" doesn't, by itself, fix this

D reconstructs a tree *within one batch* — the windows that were tiled
together at the moment of one `stash()` call, using a real "before"
snapshot to decompose against. Two independently-captured batches (from
different `stash()` calls, different source workspaces) never coexisted
as siblings — there is no shared "before" state for D to decompose, so D
has no mechanism to relate batch A's tree to batch B's tree at all beyond
placing them side by side (which `finishRestore()` already does via
cross-batch anchor chaining). Even in a fully-D-centralized world, the
actual bug — both trees' *independently captured* absolute sizes being
forced into the same destination — still needs its own fix; centralizing
on D doesn't make it disappear, since the flag `geometryClauses()` reads
to decide whether to force resize would still need the same correction
regardless of which code path (tree-walk or flat fallback) is dispatching
it.

## Two options on the table

**Option 1 — targeted fix only.** Compute a `multiBatchMerge` flag
(`batchIds.length > 1`) in `finishRestore()` and OR it into the existing
`occupied` check everywhere `skipTiledResize`/`skipResizeFor` is decided
— both in the D tree-walk branch (`skipResizeFor = function(addr2) {
return occupied }` becomes `occupied || multiBatchMerge`) and the flat
fallback branch's `geometryClauses(..., occupied || flatUnresolved[fAddr])`
call (becomes `occupied || multiBatchMerge || flatUnresolved[fAddr]`).
Small, low-risk, directly fixes the reported bug. Single-batch restores
(the overwhelming common case — one `stash()`, one `restore()`) are
completely unaffected; only genuinely multi-batch merges lose forced
absolute sizing, same tradeoff already accepted for "restoring onto an
occupied destination."

**Option 2 — fix + centralize on D.** Do the Option 1 fix, and
additionally route every tiled batch — including today's trivial 0-1
representative case in both `finishStash()` and `finishMoveWorkspace()`
— through `beginDecomposition()`/`walkAndDispatch()` uniformly, even when
decomposition is trivial (a single-leaf "tree", or a 2-step decomposition
for exactly 2 windows). `peelOrder()`/`isSeparated()` would stop being a
*live* restore/move code path and become purely the safety net for a
tree that fails `validateTree()` after a genuine decomposition attempt
(a case that today's testing has never actually triggered). Larger
change, touches the trivial-case branches in three functions
(`finishStash()`, `finishMoveWorkspace()`, and `finishRestore()`'s branch
selection), and changes the commit-time answer to "does `peelOrder()`
still run in normal operation" from "yes, constantly (every single-window
batch)" to "no, only as an unresolved-tree fallback."

## Question for review

Given D has had zero confirmed bugs this session and Option 1 fully fixes
the reported issue on its own: is Option 2's centralization worth doing
now, or is it better deferred (matching the original phased plan's own
Phase 5 — "remove peelOrder()/legacy code after a regression review" —
which was explicitly scoped as a *later* step, after a daily-driving
period)? Also flag anything Option 1's fix might be missing on its own.
