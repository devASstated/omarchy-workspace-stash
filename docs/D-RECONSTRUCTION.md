# Layout reconstruction: design, implementation, and evidence

What ships today: `stash()`, `restore()`, and `moveWorkspaceTo()` all
reconstruct genuine multi-branch tiled layouts — real 2×2 grids, nested
splits, Hyprland groups, pseudo-tiled windows — not just the "caterpillar"
chains the original implementation was limited to. This document explains
the mechanism, why it was chosen over the alternative that was equally
thoroughly validated, what was found and fixed while hardening it, and
what's deliberately left as a known limitation.

## Background

The original restore ordering (`peelOrder()`/`isSeparated()`, still
present on `main`) can only reconstruct "caterpillar" trees — each insert
splitting off exactly one leaf from whichever window was placed last. A
genuine multi-branch layout (an actual 2×2 grid, two independently-split
columns) doesn't fit that shape and was a documented, deliberately
accepted limitation.

Two mechanisms were investigated to close that gap, both validated
against a live Hyprland session before either was trusted — the raw
feasibility-phase experiment log (every fixture, every gate) is
preserved in `release-candidate`'s git history, not in this tree.

## Approach A: recursive bipartition (validated, not shipped)

Parse a tree from a single geometry snapshot: recursively ask "is there
any line that splits the current group into two non-empty pieces?" and
recurse into each half. This mirrors how Hyprland's Dwindle layout itself
is built (a sequence of full-span cuts), so any layout it produced is
guaranteed reconstructible this way. Tested to 128/128 across every
orientation, ratio, and window count tried, including adversarial/
malformed geometry (never fabricated a wrong tree — returned `None`
cleanly on failure).

**Where it structurally can't work**: a pseudo-tiled window's captured
rectangle is its centered *surface*, not its logical Dwindle slot, and
the gap between them is content-dependent — from negligible to drastic.
A single static snapshot has no way to recover the slot from the surface
in the drastic case. Tested directly: mild shrink parsed correctly; a
dramatic shrink returned `None`, correctly but incompletely.

## Approach D: destructive decomposition (shipped)

Instead of parsing a static snapshot, remove windows from the live batch
one at a time during stash, observe how the survivors' geometry
compensates after each removal, and reconstruct the tree from that
transition record. This sidesteps the pseudo-tiling problem entirely — it
never needs to recover a slot from a surface, because it observes the
*live compositor* deciding the slot as each removal happens. Proven to
recover exact topology in every case tried, including every pseudo-tiled
case A can't solve (single- and dual-pseudo-tiled), real Hyprland groups,
and to fail safely — never a lost window, never a wrong-but-plausible
tree — even when a window closes mid-decomposition. Costs more (genuine
compositor-side reflow time per removal step, not transport overhead) and
needs the stash to become a sequential live operation for the batch it's
used on.

D was chosen over A specifically because of the pseudo-tiling gap — not
because A was flawed. Approach A remains available later as a cheap
pre-check (see "Deferred" below) if D's cost is ever shown to matter to
users in practice.

### Mechanism

- **`collapseGroups(clients)`**: a Hyprland group's members report
  (near-)identical rectangles — feeding that into decomposition directly
  gives no separating signal. Moving or resizing only a group's
  representative address carries every other member along for free
  (confirmed live), so groups collapse to one leaf (`groupMembers: [...]`
  on the leaf) before decomposition ever sees them.
- **Decomposition sequencer** (`beginDecomposition()` and friends):
  removes one representative at a time (any order works — proven
  order-independent by random-order sweeps), diffing survivor geometry
  before/after each removal via a two-phase capture. `inferAxisAndDirection()`
  compares the removed window's position to the surviving cluster's
  position in the *before* snapshot only — deliberately not dependent on
  the cluster resizing, which is what makes dual-pseudo-tiled cases work
  (an earlier version compared bounding-box deltas instead and broke
  exactly there). A window closing mid-sequence is detected via a missing
  -window check before each step and filtered out — never crashes, never
  strands a window.
- **`reconstructTree(record, addresses, groupMembersByAddress)`**: a
  worklist that repeatedly resolves whichever pending transition-record
  entry has all its `changed` addresses in one already-built group,
  restarting the scan after every merge (load-bearing, not defensive
  styling — a single-pass scan can resolve a later entry before an
  earlier one gets a chance at the same group, silently locking in a
  structurally wrong tree). Returns `{ tree }` or `{ error }` — never a
  best-guess wrong tree.
- **`validateTree(tree, expectedAddresses)`**: a structural self-check
  (leaf set exactly matches what was captured) run before any tree is
  ever stored or dispatched — production has no ground truth to compare
  against the way testing did.
- **`walkAndDispatch()`**: representative-leaf preorder expansion replays
  the tree — place a subtree's two representatives as a pair before
  recursing into either side. Proven 128/128 across every orientation,
  ratio, and window count tested.

## `moveWorkspaceTo()`: the stash-transit requirement

Extending D into bulk workspace-move seemed like it should be
straightforward — decompose, then replay directly onto the real
destination instead of the stash scratchpad. Tried exactly that first; it
reliably scrambled left/right order. Root cause: decomposition's own
per-step moves had already relocated every window onto the destination
*before* the tree-replay pass ran, so the replay was redispatching
move/focus/preselect against windows already on that workspace —
Hyprland's insertion behavior for "already here, just re-preselect-and
-move" is not the same as a genuine cross-workspace arrival.

Fixed by having decomposition's internal moves always transit through
`root.stashWorkspace` first, exactly like a real stash, then chaining one
genuine cross-workspace replay onto the real destination once
decomposition finishes — mirroring `restore()`'s own already-proven
mechanism. The transit is momentary and invisible to the user, and only
ever touches the specific move's own addresses on the way back out, so it
coexists safely with an unrelated real stash already parked there
(verified live).

On reconstruction failure inside a move, the fix above also matters:
leaving windows in `stashWorkspace` (as `stash()`'s own unresolved case
safely does) would strand them, since a "move" batch has no
`root.batchPlans` entry to ever pull them back out later. Instead, every
surviving representative is moved onto the real destination individually
— no preselect chaining, no forced resize, no attempt to reconstruct a
source topology that no longer exists.

## Unified pipeline: every batch, trivial or complex, same mechanism

Originally, a single window or single group bypassed D entirely (a
separate "trivial case" in `finishStash()`, `finishMoveWorkspace()`, and
`finishRestore()`'s branch selection) and used simple direct dispatch or
an older flat geometric-ordering fallback (`peelOrder()`). Tracing
through the decomposition sequencer showed it already handles a
single-representative batch correctly and cheaply as its own natural base
case — `removalOrder` is empty for one address, so the first capture
callback finishes immediately with zero destructive steps, one survivor
move, and `reconstructTree()` already returns a trivial one-leaf tree
identity for an empty record. So unifying every tiled batch onto the same
pipeline turned out to be **deletion, not addition**: removing the three
separate special-case branches, with no changes needed to the
decomposition mechanism itself.

Comparison against the prior (bifurcated) architecture:

- Special-case "is this batch trivial" branches: 3 → 1.
- Representational states a batch could be in: 3 (no plan / unresolved
  plan / resolved tree) → 2 (unresolved / resolved).
- Net `Service.qml` change: -8 lines, no functions added or removed.
- Latency (IPC round-trip): single window ~44ms, single group ~44ms,
  N=2 ~46ms, 4-window grid ~48ms — no measurable difference between the
  trivial and real-decomposition cases.
- `peelOrder()`/`isSeparated()`/`orderDescriptors()`/`restoreOrder()`/
  `sortByRowThenX()` confirmed fully unreachable from any live call site
  and removed (~131 lines) — a batch D can't resolve now uses natural
  placement (no preselect chaining, no forced resize), never a second,
  weaker engine guessing an order.

The motivation wasn't "escape a buggy fallback" — `peelOrder()` was
already almost never exercised for anything beyond the always-safe
trivial case. It was collapsing three independent copies of "is this
batch trivial" policy into one, so the trivial/complex decision is made
in exactly one place.

## Bug found and fixed: cross-batch geometry merge

Restoring two *independently* stashed batches together (e.g. one window
stashed from workspace 1, another from workspace 2) squeezed one down to
a sliver. Each batch's absolute size was captured relative only to
whatever else was on its own original source workspace — never relative
to any other batch — so forcing both independently-captured absolute
sizes into the same destination collapsed one of them. The existing
`isWorkspaceOccupied()`/`skipTiledResize` check only caught the
destination already having *other, pre-existing* content before the
restore started; it said nothing about the restore itself merging two
unrelated batches.

Fixed by counting unique batch IDs among *tiled* windows only (a second,
floating-only batch shouldn't suppress a tiled batch's own resize, since
floating geometry never depends on tiled sibling structure) and skipping
forced absolute resize whenever more than one tiled batch is being
merged — the same tradeoff already accepted for occupied destinations.
Verified against four cases: tiled+tiled (fixed), D-tree+single-window,
D-tree+D-tree (both: no collapse, natural proportions), and
tiled+floating-only (tiled batch keeps its exact resize, confirming the
fix doesn't overreach).

## Adversarial testing: the fail-closed path, confirmed for real

D had zero confirmed reconstruction failures across every fixture tried
during design and hardening. Rather than wait for daily use to
(maybe) find one, a synthetic pressure-testing pass specifically tried to
trigger `plan.unresolved`.

**Found a real trigger**: killing a batch's *designated final survivor*
(the one window never destructively removed during the diff loop, only
explicitly moved at the very end) partway through decomposition
reliably produces `plan.unresolved`, reproduced twice. Mechanism: the
survivor is expected to be part of whichever cluster visibly compensates
when a sibling is removed; once it's already gone, the final removal
step has no surviving neighbor left to observe a compensating change
against, and reconstruction correctly refuses to invent one.

Both times, the resulting unresolved batch restored cleanly via natural
placement — no slivers, no crash, no stranded window. This closes what
was previously a reasoning-by-analogy gap: the fail-closed fallback is
now confirmed to work when actually triggered, not just argued to.

The same pass also tried an 8-window deeply nested grid, double
mid-decomposition window kills, and a real stash coexisting with a
concurrent `moveTo`'s stash-transit — all held with no regressions.

## Known limitation: dual pseudo-tiled siblings

Two directly-sibling tiled windows that are *both* pseudo-tiled don't
reliably both restore their exact captured size. Investigated by
isolating resize order and sibling interaction as causes — neither is
responsible. A lone pseudo-tiled window with a normal sibling is
completely stable under a direct resize (exact match every time); a
pseudo-tiled window whose sibling is also pseudo-tiled changes its
"natural" size the moment *anything* touches it — an absolute resize,
or even a bare pseudo re-toggle with no resize at all. This reads as a
genuine Hyprland compositor behavior around pseudo-size caching when
both sides of a split are pseudo, not a defect in this file's dispatch
logic or ordering.

**Deliberately left unfixed.** Topology, window safety, and operation
completion are all unaffected — only one window's exact surface size
isn't guaranteed, in a precondition that needs two windows to be direct
siblings and both pseudo-tiled. The fix would require capturing and
persisting pseudo state (not currently tracked) and threading
sibling-awareness through the resize decision (currently a clean
per-address function with no sibling context) — exactly the kind of
special-case machinery the unified-pipeline work above was written to
eliminate, for a rare, cosmetic-only precondition. Revisit only if real
usage hits it often enough to matter, or Hyprland exposes a clean
authoritative pseudo-state API.

## Deliberately deferred

- **Approach A as a pre-check ahead of D** (a cheap hybrid: try the
  static-geometry parse first, fall through to D only when it returns
  `None`). Not introduced now — D's own cost has been measured as low
  enough even for the trivial single-window case that the payoff is
  unproven until real usage shows it matters.
- **Raw Unix-socket transport** (`Quickshell.Io.Socket`, confirmed to
  exist and be usable natively) as an alternative to the current
  `Process`/`hyprctl` subprocess pattern. The dominant D cost measured
  during design was compositor-side reflow, not transport, so this
  optimization's payoff is unproven.

## Verification summary

Feasibility phase (pre-implementation): 128+ live-compositor runs plus
15 synthetic adversarial parser-safety cases, full methodology and raw
results preserved in `release-candidate`'s git history.

Post-implementation: `qmllint`/`omarchy plugin validate .` clean
throughout. A 19-case automated regression sweep (single window, single
group, N=2, 4/8-window grids, single pseudo-tile, floating, mixed
floating+tiled, cross-batch merge, occupied destination,
stale-after-stash, reentrancy, `toggle()`, interrupted operation — each
via both `stash`/`restore` and `moveTo` where applicable) passes 19/19,
re-confirmed after the unified-pipeline refactor and again after the
dead-code removal that followed it.
