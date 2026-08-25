# D-only reconstruction: production implementation plan

This is a concrete implementation plan for `Service.qml`. GPT reviewed
an earlier draft and approved it subject to five architectural
amendments plus a storage-shape change — all incorporated below, not
listed separately. It covers GPT's own Phase 1+2 (merged — QML/JS has no
formal interface system, so the shared data shapes don't need a separate
commit from the functions that use them) plus a smoke-test gate before
Phase 3 (daily-driving) begins. Phases 3-5 stay as GPT already proposed
them and aren't repeated here in detail.

## Context

`docs/CLAUDE.md` documents a known, accepted limitation: `peelOrder()`/
`isSeparated()` in `Service.qml` can only reconstruct "caterpillar"
layouts, and stalls on a true multi-branch grid.

`docs/RECONSTRUCTION.md` and `docs/RECONSTRUCTION-EXPERIMENTS.md` record
an extensive feasibility investigation (128+ live-compositor runs, 15
synthetic adversarial cases, and a deliberate campaign to attack two
alternative approaches) that settled on two viable mechanisms:

- **Approach A** (static geometry → recursive guillotine partition):
  fast, simple, fully proven, but structurally cannot recover a
  pseudo-tiled window's logical slot from a single snapshot — returns
  `None` in that case, correctly but incompletely.
- **Approach D** (destructive decomposition: remove one window at a
  time during stash, observe the compensating transition, reconstruct
  the tree from the transition record): proven to recover exact
  topology in every case tried, *including* every pseudo-tiled case A
  cannot solve (5/5, both single- and dual-pseudo-tiled), real Hyprland
  groups, and to fail safely (never a lost window, never a
  wrong-but-plausible tree) even when a window is closed mid
  -decomposition. Costs more — genuine compositor-side reflow time, not
  transport overhead — and needs `stash()` to become a sequential live
  operation for the batch it's used on.

The user and GPT have both agreed to build **D-only first**, commit it
to `experiment/tree-bipartition-restore`, and daily-drive it for real
-world exposure — confirmed this is already the live plugin
(`~/.config/omarchy/plugins/io.github.devASstated.workspace-stash` is a
symlink straight to this repo checkout) — before adding Approach A as a
cheap first-line check on top later. Nothing built in this phase is
discarded when A is added: D-only is a strict subset of the eventual
hybrid's surface.

## What stays exactly as-is

Confirmed unchanged by every relevant test this session, re-confirmed by
re-reading the current file directly for this plan: `structureClauses()`,
`geometryClauses()`, `preselectDirection()`, `clampToMonitor()`,
`moveAddress()`, `dispatchClause()`, cursor capture/restore in both
`finishRestore()` and `finishMoveWorkspace()`, `isWorkspaceOccupied()`/
`skipTiledResize` semantics, the `pendingStash*`/`pendingRestore*`/
`pendingMove*` property pattern, the external-focus collision safeguard,
the `IpcHandler` surface, existing capture-size hardening
(`maxCaptureBytes`/`maxDisplayTextLength`). `pruneMeta()` itself is
unchanged — it gains a sibling responsibility (batch-plan pruning, §
below), not a rewrite.

## New shared shapes

- **`LayoutNode`**: `{ isLeaf: true, address, groupMembers: [address...] }`
  or `{ isLeaf: false, axis: "V"|"H", first: LayoutNode, second: LayoutNode }`.
  `groupMembers` is `[address]` (just itself) for an ungrouped window —
  always present, never a special case to branch on. Storing the full
  membership *in the leaf*, not just transiently during collapse, is
  what makes amendment 2 (group leaves resolvable through survivors)
  possible at restore time, long after `collapseGroups()` has finished.
- **Transition record entry**: `{ removed: address, changed: [address...],
  axis: "V"|"H"|null, removedIsFirst: bool|null }` — one per
  decomposition step, port of `experiments/attack_D_full_topology.py`'s
  record shape.
- **`root.batchPlans`**: `{ [batchId]: { tree: LayoutNode|null,
  unresolved: bool } }` — a **new, separate top-level property**, not
  embedded in `root.meta`. GPT's storage-shape amendment: a batch-level
  tree doesn't have a natural single "owning" window inside per-window
  `meta`, and duplicating it across every window in the batch risks
  drift if one copy gets updated and others don't. `root.meta` stays
  exactly what it is today — per-window geometry/batch-id bookkeeping —
  and `batchPlans` is the tree's own home, keyed the same way batches
  already are (`batchId`).

## Concrete `Service.qml` changes

### 1. `collapseGroups(clients)` — new, ~30 lines

Reads each client's `grouped` field (already present in `hyprctl -j
clients` output, confirmed live this session — no new query). For each
distinct group, picks one deterministic representative address (e.g.
lowest address) and returns `{ representativeOf: {repAddr:
[allMembers]}, memberOf: {memberAddress: repAddr} }`. The full member
list flows straight into the `LayoutNode` leaf's `groupMembers` field
when a leaf is created (§ new shapes) — collapse-time bookkeeping and
the tree's own long-term record of membership are the same data, not two
copies that could drift.

### 2. `resolveLiveAddress(leaf)` — new, ~10 lines

Amendment 2 (group leaves resolvable through survivors). At any point a
leaf's address is actually needed for a dispatch — restore, or a future
decomposition step touching this leaf — check whether `leaf.address` is
still a live toplevel; if not, fall back to the first still-live address
in `leaf.groupMembers`. Matches Gate 9's proven finding that any
surviving group member can stand in for the whole group. If *no* member
in `groupMembers` is alive, the leaf itself is dead — feeds into §
stale-tree pruning below, not handled ad hoc here.

### 3. `partitionRemovalOrder(addresses)` — new, ~5 lines

Any deterministic order works (proven order-independent by
`experiments/attack_D_stress.py`'s random-order sweep, 15/15). Simplest
choice: the array order `hyprctl -j clients` already returned, reversed,
leaving the first-captured window as the implicit final survivor.

### 4. `inferAxisAndDirection(removedRectBefore, clusterBboxBefore)` — new, ~15 lines

Direct port of the (twice-fixed) robust version from
`experiments/attack_D_full_topology.py`: compares the removed window's
position to the surviving cluster's position, in the *before* snapshot
only — whichever axis they overlap most on is the split axis. Does
*not* depend on the compensating side resizing (the fix that made
dual-pseudo-tiled cases work).

### 5. `reconstructTree(record, addresses)` — new, ~40 lines

Direct port of the (three-times-fixed) worklist reconstruction from
`experiments/attack_D_full_topology.py`: repeatedly resolve whichever
pending record entry currently has all its `changed` addresses in one
already-built group, **restarting the scan from the beginning after
every merge** (the fix for the premature-resolution-order bug found
live on the `F7` fixture). Returns `{ tree: LayoutNode }` or `{ error:
reason }` — a null tree, never a best-guess wrong one.

### 6. `validateTree(tree, expectedAddresses)` — new, ~20 lines

Amendment 5. Every correctness check up to now compared a reconstructed
tree against *ground truth only available in testing* (`repr(rebuilt) ==
repr(tree)`). Production has no ground truth to compare against, so this
is a structural self-check instead: walk `tree`, collect every leaf's
full `groupMembers` set, and confirm the union exactly equals
`expectedAddresses` — no duplicates, nothing missing, nothing extra.
Called immediately after `reconstructTree()` succeeds, *before* the
result is ever written to `batchPlans` or used for a dispatch. A tree
that fails this (should never happen if `reconstructTree()` is correct,
but "should never happen" is exactly what validation is for) is treated
identically to a `reconstructTree()` error — `unresolved: true`, not a
tree anyone trusts.

### 7. The stash-time sequencer — new, the largest piece (~180-220 lines)

This is the one genuinely new *pattern* for this codebase: every
existing `Process` here is a single fire-and-wait-for-`onExited` step;
D needs an ordered chain of N such steps, each depending on the
previous one's captured result. Built the same way this file already
solves async orchestration — reusable `Process` components plus
`pending*` state properties on `root` — not a new abstraction, a new
*instance* of the existing idiom, run in a loop:

- `root.pendingDecomposition`: `{ addresses, removalOrder, stepIndex,
  priorRects, record, addrToTitle, batchId, sourceWorkspace,
  representativeMeta }` (the group-collapsed geometry/meta captured
  once at the start, before anything moves).
- One reusable `Process` (`decomposeDispatchProcess`, `hyprctl dispatch
  ...`) and one reusable `Process` (`decomposeCaptureProcess`, `hyprctl
  -j clients`), both restarted per step. **Not** `Quickshell.execDetached()`
  for the dispatch — confirmed this session that a dispatch `Process`
  only exits once Hyprland has actually applied it (this is what made
  zero explicit settle-wait provably safe in every experiment), so
  chaining on `onExited` gives the same free correctness guarantee in
  production.
- Each step: dispatch the next window's move → on exit, capture → on
  exit, diff against `priorRects`, infer axis/direction, push the
  record entry, advance `stepIndex` or, if this was the last address,
  fall through to the **explicit final-survivor move** (the bug found
  live in the seam test: the N-1 diffing steps alone never move the
  last window at all) — then call `reconstructTree()` →
  `validateTree()` (§6) and hand off to the existing
  `finishStash()`-equivalent bookkeeping (batch metadata, writing
  `root.batchPlans[batchId]`).
- **Failure tolerance, built in from the start, not bolted on**: before
  each step, check whether the window it's about to remove (or any
  still-`remaining` window) is still actually present. A window closed
  mid-sequence (real `SIGTERM`, proven live in the seam test) is
  detected, removed from `remaining`, and the sequence continues —
  never crashes, never strands a window. `reconstructTree()` is called
  with the killed address filtered out of every recorded cluster; if
  that specific relationship becomes unrecoverable, the batch's tree
  comes back as an `error`, not a wrong guess.
- **Amendment 4 — reentrancy/busy invariant**: `root.decompositionInFlight`,
  a single boolean, set `true` the moment the sequencer starts and
  `false` only once it has *fully* finished — including the
  final-survivor move and the `batchPlans` write, not just when the
  last `Process` exits. The existing `stash()` busy-check
  (`stashCaptureProcess.running`) only covers the *initial* capture,
  which returns quickly; the sequencer that follows can run for many
  steps. `stash()`, `restore()`, and `moveWorkspaceTo()` all gain this
  same check alongside their existing busy-guards — a restore or a
  second stash triggered mid-decomposition must be rejected exactly
  like today's existing "busy" cases, not race against in-flight state.

### 8. `finishStash()` — modified

Today: one flat loop, `moveAddress()` per client, independent. New
shape: split the fresh capture into floating (unchanged — same simple
independent move as today, never enters the sequencer) and tiled.
Tiled, group-collapsed (§1): if 0-1 representative addresses, no
reconstruction needed (trivial case, simple move, matches today).
2+: hand off to the sequencer (§7), which writes
`root.batchPlans[batchId]` on completion — `root.meta` itself is
unchanged in shape, same `nextMeta`/per-window fields as today.

### 9. Stale-tree pruning — new, hooked into the existing `pruneMeta()` trigger

Amendment 1. A window can close *after* a successful stash, while just
sitting in the stash workspace, before restore is ever called — leaving
`batchPlans[batchId].tree` referencing a now-dead address.
`onStashedToplevelsChanged` already calls `pruneMeta()` on every live
-toplevel-list change (i.e. every window close, anywhere); it gains one
more call alongside it, `pruneBatchPlans()`:

- For each batch whose tree references an address that's no longer
  alive **and** has no live `groupMembers` fallback (§2): a genuine
  tree-structure edit, not a blanket invalidation — find the dead leaf,
  replace its *parent* `Split` node with the leaf's *sibling* subtree
  (standard binary-tree leaf removal, promoting the sibling up one
  level). This is the same "remove one leaf, the rest of the tree
  closes over the gap" operation the decomposition sequencer already
  embodies conceptually, just applied after the fact instead of during
  capture.
- If the dead leaf's sibling was itself the tree's root (a 2-leaf batch
  losing one member), the batch's tree collapses to a single surviving
  leaf — no tree needed at all, matches today's trivial-case handling.
- If a promoted-sibling edit would itself leave `groupMembers`-emptied
  leaves or an otherwise malformed structure, run `validateTree()` (§6)
  again on the result — fail closed to `unresolved: true` rather than
  storing a doubtful edited tree.

### 10. `finishRestore()` / `finishMoveWorkspace()` — modified

Replace the flat `previousMeta`-threaded loop with a tree-walk:
representative-leaf preorder expansion (proven 128/128 across every
orientation, ratio, and window count tested) over
`root.batchPlans[batchId].tree` — place a subtree's two representatives
as a pair before recursing into either side, using the *exact same*
`structureClauses()` calls, unchanged, with each leaf's actual dispatch
address resolved through `resolveLiveAddress()` (§2) rather than read
directly off the stored leaf. A batch with `unresolved: true` (or no
stored plan at all — e.g. a stash predating this change) falls back to
today's exact flat/`peelOrder()` behavior — **`peelOrder()`/
`isSeparated()` stay in the file, reachable, not deleted**, per
`docs/CLAUDE.md`'s own "keep the old path available until proven"
convention.

**Amendment 3 — cross-batch chaining, explicitly preserved.** Today's
flat loop threads one `previousMeta` continuously across *every* batch
in the restore, not just within one — batch N+1's first window
preselects against whatever batch N's loop placed last (confirmed by
reading `finishRestore()` directly: `previousMeta` is initialized once,
before the whole loop, never reset per batch). The tree-walk replacing
that flat loop must reproduce this exactly, not silently regress to
per-batch-independent placement: the representative-leaf walk over
batch N's tree returns whichever leaf it dispatched *last* (the same
"last placed window" concept, just derived from a tree walk instead of
a flat index), and that becomes the incoming anchor for batch N+1's
tree-walk root — oldest batch first, same as today. Gate 12 already
proved this exact chaining mechanism live.

Cursor capture/restore, `skipTiledResize`, and the final
`hyprctl --batch` join are unchanged — the tree-walk only changes what
clauses get built and where addresses are resolved from, never how
they're sent.

### 11. `moveWorkspaceTo()` path

Same treatment as `finishRestore()` (§10), applied to
`finishMoveWorkspace()` — it already shares `orderDescriptors()`/the
flat-loop pattern with restore, so the same tree-walk driver serves both
call sites (matching the existing code's own reuse pattern). Bulk-move
has one implicit batch, so cross-batch chaining doesn't apply here, only
to `restore()`.

## Deliberately deferred, not part of this phase

- **Approach A / hybrid integration** (`partitionTree()` as a pre-check)
  — Phase 4, only after D-only has been daily-driven and is "boring."
- **Raw Unix-socket transport** (`Quickshell.Io.Socket`) — confirmed
  with GPT: keep `Process`/`hyprctl` for this phase, do not introduce
  `Socket` yet. One new pattern at a time; this session's own
  measurements showed the dominant D cost is compositor-side reflow,
  not transport, so the payoff is unproven for production regardless.
- Deleting `peelOrder()`/`isSeparated()`/any temporary diagnostics —
  GPT's Phase 5, after a full regression review.

## Verification, before this becomes the daily driver

1. `qmllint` and `omarchy plugin validate .` clean.
2. Manual smoke test, live, walking through the exact fixtures already
   proven in Python: a plain 2-way split, a true 2×2 grid, a 3-window
   caterpillar, a real Hyprland group (`SUPER+G`), a real pseudo-tiled
   window (`SUPER+P`) in a nested branch. Each: stash, inspect the
   restored layout visually and via `hyprctl -j clients`, confirm it
   matches.
3. One deliberate interruption test: start a stash with 4+ tiled
   windows, close one mid-operation (if timing allows — otherwise this
   stays covered by the Python-proven safety net and gets exercised
   naturally during Phase 3 daily use).
4. **Stale-after-stash** (new, per GPT): stash a 3+ window batch
   successfully, close one of the now-stashed windows *while it sits in
   the stash workspace*, before ever restoring — confirm
   `pruneBatchPlans()` (§9) correctly edits the tree rather than leaving
   a dangling reference, and that restoring afterward places the
   surviving windows correctly.
5. **Rapid reentry** (new, per GPT): trigger `stash()` again (or
   `restore()`) while a previous stash's decomposition sequencer is
   still mid-flight — confirm `decompositionInFlight` (§7) correctly
   rejects the second call as busy rather than racing against in-flight
   state.
6. Only after 1-5 pass does this become "safe to lean on" for daily use
   per the user's plan (Phase 3 itself — real apps, groups, pseudo
   windows, repeated cycling, multi-batch, timing telemetry — is
   exploratory daily use, not a gated step here).

## Commit

Per `docs/CLAUDE.md` priority #11: no git commit without presenting the
diff and proposed message for review first, same as every other change
in this project. This plan does not commit anything by itself.
