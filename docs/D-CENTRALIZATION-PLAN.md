# Centralizing tiled-batch representation on LayoutTree

## Status / context

D (destructive decomposition) has had zero confirmed bugs across every
fixture tested this session — grids, real Hyprland groups, pseudo-tiling,
stale windows, reentrancy, and the `moveWorkspaceTo()` extension. The
cross-batch resize collapse found and fixed in `b66879f` was *not* a D
bug: both repro windows were single-representative batches that never
enter `beginDecomposition()` at all, and the actual defect lived in
`geometryClauses()`/`occupied` logic shared equally by the D tree-walk
path and the `peelOrder()` fallback path — fixed in both simultaneously.

The user asked whether the codebase should lean further into D — ideally
retiring `peelOrder()`/`isSeparated()` as a *live* code path. GPT's prior
review already sketched the right shape for this (quoted from that
review):

```
one tiled window:
    tree = Leaf(A)

one grouped spatial leaf:
    tree = Leaf(representative, members)

multi-window tiled batch:
    tree = D reconstruction

failed/legacy:
    unresolved/fallback
```

— explicitly **not** "always run the destructive sequencer": a single
window or single group has no structure to decompose, so building a
trivial `Leaf` tree directly (no async decomposition) is both cheaper
and more correct than invoking `beginDecomposition()` for nothing.

## Why this doc doesn't propose "peelOrder() is unsafe, replace it"

Worth being precise about the actual motivation, since the premise "the
more we depend on peelOrder() the more exotic bugs surface" doesn't
fully hold up: as things stand today, `peelOrder()` is *already* almost
never exercised as a live path beyond the trivially-safe 0-1-window case
(nothing to get wrong there) — the only other way to reach it is a
genuine D reconstruction failure (`validateTree()` false), which has
never been observed once in ~150+ live runs this session. The real
motivation for unifying is **not** "escape peelOrder()'s bug surface" —
it's collapsing three independent copies of "is this batch trivial"
logic (`finishStash()`, `finishMoveWorkspace()`, and `finishRestore()`'s
branch selection all separately encode this today) into one
representation, so there's a single source of truth for how a batch is
modeled, and the trivial-vs-real-decomposition decision is made in
exactly one place.

## Current shape (read directly from `Service.qml`)

- `finishStash()`: `representatives.length <= 1` → loop over every raw
  tiled client individually via `root.moveAddress()`, return — **no**
  `root.batchPlans` entry created for this batch. `representatives.length
  >= 2` → `root.beginDecomposition(...)`.
- `finishMoveWorkspace()`: same `<= 1` / `>= 2` split, but the trivial
  branch dispatches directly via `structureClauses()`/`geometryClauses()`
  (looping every raw client) rather than `root.moveAddress()`.
- `finishRestore()`: `var plan = root.batchPlans[batchId2]; if (plan &&
  !plan.unresolved && plan.tree && tiledAddrs.length > 0) { ...
  walkAndDispatch ... } else if (tiledAddrs.length > 0) { ... peelOrder
  flat fallback ... }` — trivial batches fall into the `else if` branch
  today purely because no plan was ever stored for them.

Important existing fact that makes this refactor small:
**`walkAndDispatch()` already handles a bare `Leaf` tree correctly with
zero changes.** `representativeOfNode(leaf)` returns the leaf itself,
and `expand(leaf)` is a no-op (`if (node.isLeaf) return`) — so
`walkAndDispatch(makeLeaf(address, groupMembers), ...)` degenerates
exactly to today's flat single-window dispatch, using `incomingMeta`/
`incomingAddress` as the cross-batch anchor exactly as the flat loop
does today. Likewise `pruneNodeForDeadAddress()`/`pruneBatchPlans()`
already handle a whole-tree-is-a-dead-leaf case generically (falls back
to `{ tree: null, unresolved: true }`) — no changes needed there either.

## Proposed change

1. **`finishStash()`**: for `representatives.length <= 1` and exactly
   one representative, build `var tree = root.makeLeaf(representatives[0],
   grouped.representativeOf[representatives[0]])` directly (no
   `beginDecomposition()` call) and store `nextPlans[batchId] = { tree:
   tree, unresolved: false }` in `root.batchPlans`, then dispatch the
   representative's move the same way `beginDecomposition()`'s survivor
   move already does (`root.moveAddress(representative, root.stashWorkspace,
   false)`) — a single dispatch carries the whole group for free (proven
   this session), replacing today's per-member loop. For `representatives.length
   === 0` (all-floating batch), no tiled tree is needed — behavior
   unchanged.

2. **`finishMoveWorkspace()`**: same trivial-Leaf construction, but
   dispatched via `root.walkAndDispatch(tree, destination, monitor,
   function(a){ return occupied }, null, null, metaMap)` merged with the
   floating clauses — no stash-transit needed for a single representative
   (the same-workspace-redispatch scrambling found and fixed for the 2+
   case was specifically about *relative ordering between siblings*,
   which doesn't exist when there's only one thing being placed — needs
   explicit live verification, not just this reasoning, before trusting
   it).

3. **`finishRestore()`**: no structural change needed — the existing `if
   (plan && !plan.unresolved && plan.tree && tiledAddrs.length > 0)`
   branch already does the right thing once every batch has a tree.
   The `else if` `peelOrder()` fallback remains, reachable only for a
   genuine reconstruction failure or a stash predating this change
   (`root.batchPlans` has no entry) — never deleted, matching this
   project's own "keep the old path available until proven" convention
   (`docs/CLAUDE.md`).

4. `partitionRemovalOrder()`/`beginDecomposition()`/the decomposition
   `Process` pair/`reconstructTree()`/`inferAxisAndDirection()` — all
   unchanged. They simply get invoked less often (only genuine 2+
   representative batches), never differently.

## Explicitly out of scope for this change

- Deleting `peelOrder()`/`isSeparated()` — stays as the fallback for a
  genuine reconstruction failure and for restoring a stash created before
  this change (no stored plan). This is representation unification, not
  cleanup/removal (that's GPT's own named Phase 5, later, after a
  regression review).
- Any change to the D decomposition algorithm itself, `walkAndDispatch()`,
  or the `moveWorkspaceTo()` stash-transit mechanism from the previous
  phase.
- The cross-batch anchor-chaining interleaving behavior observed during
  the merge-bug verification (case 3: a second batch's windows landing
  physically between the first batch's own pair) — pre-existing,
  orthogonal to this change, not addressed here.

## Verification

1. `qmllint`/`omarchy plugin validate .` clean.
2. `omarchy restart shell`, then live smoke tests, focusing on exactly
   the behaviors changing:
   - Single window: stash, restore — confirm still exact (now via
     `walkAndDispatch` on a trivial Leaf instead of the old flat path).
   - Single real Hyprland group (2-3 members): stash, restore — confirm
     the group survives, and confirm the stash-time move now carries the
     whole group via one representative-only dispatch instead of N
     per-member dispatches.
   - `moveTo` with a single window and a single group — confirm both
     still land correctly without the stash-transit (direct
     `walkAndDispatch` onto the real destination for the trivial case).
   - Re-run the 4 cross-batch merge cases from `docs/CROSS-BATCH-MERGE-BUG-REVIEW.md`
     to confirm this refactor doesn't reintroduce that bug or change its
     fix's behavior (trivial batches are now real `batchPlans` entries,
     which changes `tiledBatchCount`'s inputs but not its logic).
   - Stale-after-stash and reentrancy cases, re-run once more for the
     now-unified trivial path.
3. Present the diff and a proposed commit message before any `git
   commit`, same convention as every other change this session.
