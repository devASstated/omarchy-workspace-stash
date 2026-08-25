# Workspace Stash — Recursive Bipartition Reconstruction (design)

This document is a design, not a build record — it exists ahead of any
code change, unlike `docs/DESIGN-JOURNEY.md` (which records what actually
happened once something was built). It covers replacing `peelOrder()`'s
single-leaf-peel heuristic with a genuine recursive bipartition, to close
the one layout-reconstruction gap `docs/DESIGN-JOURNEY.md` §17/§20 and
`docs/CLAUDE.md` currently document as deliberately accepted rather than
fixed — a true multi-branch layout (an actual 2×2 grid, two independently
-split columns) does not reliably reconstruct today.

**Status update**: every mechanism this document describes has since been
tested live against a real Hyprland session, on the
`experiment/tree-bipartition-restore` branch — 128 live-compositor runs,
15 synthetic parser-safety cases, and targeted investigation of groups,
pseudo-tiling, floating windows, occupied destinations, and multi-batch
restore, all passing or failing exactly as expected. Full methodology,
every fixture, and raw results are in `docs/RECONSTRUCTION-EXPERIMENTS.md`
— read that document for the evidence; this one describes the design the
evidence supports. One part of the *original* version of this document
did **not** survive contact with testing and has been rewritten below:
the dispatch mechanism was originally sketched as a "per-subtree anchor"
tree-walk (track whichever window was placed *last* in an already-built
subtree, insert the next sibling against it). That was never built or
tested. What was actually tested — and passed 40/40, then held across
every subsequent gate — is a different, simpler mechanism:
**representative-leaf preorder expansion**. The description below reflects
that, not the original untested sketch.

`docs/FEATURES.md` §7.4 already specified the general direction — "Infer a
binary split tree from tiled rectangles by finding full-span horizontal or
vertical partition boundaries. Recursively split the remaining rectangle
set until leaf nodes map to individual windows" — but what shipped
(`peelOrder()`/`isSeparated()`) is a narrower shortcut: it only ever tries
to peel one *single window* cleanly away from the *entire* remaining group
at once, not a genuine bipartition of the group into two parts. That
works for "caterpillar" layouts and stalls on a true grid.

A native-plugin alternative (reading Hyprland's actual internal split tree
via a small companion plugin) was explored and set aside first — not
because it wouldn't work, but because this approach reaches the same
outcome with none of that route's costs (a second `hyprpm` distribution
channel, Hyprland-version ABI pinning, compositor-crash blast radius, a
C++ toolchain). This approach needs no new `hyprctl` call and no new
process at all — every input it needs is already captured by the existing
`finishStash()`/`finishMoveWorkspace()` pipeline.

## 1. Idea / solution level

- **The problem restated**: all we ever have is a snapshot of final
  rectangles, captured at stash time. Restoring means finding a sequence
  of "focus a window, split it" actions that reproduces those rectangles
  — Hyprland has no "place these rectangles" primitive.
- **Two separate mechanisms, tested separately, on purpose**: recovering
  a tree from geometry (parsing) and building Hyprland state from a known
  tree (replay) are different risks, and were deliberately tested as two
  independent gates before either was trusted — see
  `docs/RECONSTRUCTION-EXPERIMENTS.md` Gates 1 and 2. A correct parser is
  useless if Hyprland can't reliably be driven to build the tree it
  recovers; a reliable build mechanism is useless if the tree fed into it
  is wrong.
- **Recovery — recursively cut the group in two**: today's approach asks
  "is there one single window fully separable from the entire rest of the
  group?" — pulls it off, places it, repeats. Works for a caterpillar
  chain; stalls the instant no single window is separable from everything
  else at once (a real 2×2 grid, for example). The tested replacement asks
  a weaker question — "is there any line, in any position, that splits
  the *whole current group* into two non-empty pieces?" — neither side has
  to be a single window. Recurse into each half independently until every
  piece is one window. Cake-cutting instead of peeling.
- **Why recovery is guaranteed, not just "usually works"**: Hyprland's own
  Dwindle layout can only ever build a layout by doing exactly this kind
  of full-span cut, over and over, splitting whatever's currently
  focused. So any layout it could have produced is guaranteed cuttable
  this way — this isn't a better heuristic, it mirrors how the layout was
  actually built. Confirmed, not just argued: every fixture tried,
  including a true 2×2 grid and a 6-window tree with two independently
  -deep branches, recovered its *exact* original topology, every run
  (Gate 2).
- **Replay — representative-leaf preorder expansion**: every subtree is
  represented by one fixed window (its representative — descend via
  "first child" until a leaf is reached). Placement is preorder: place a
  subtree's two representatives as a pair *before* recursing into either
  side — focus the first representative, preselect a direction, move the
  second representative into place — then recurse into each side to
  further split their own representatives. This maps directly onto
  Dwindle's one real primitive (split whatever's currently focused), and
  because a representative never moves again once placed, later splits
  deeper in the tree never disturb it. Tested across every topology tried
  — including all four mirror/rotation orientations and real extreme
  resize skew at multiple nesting depths — 128/128 runs, zero failures
  (Gates 1, 5, 8).
- **Why reconstruction of the final visual result is guaranteed,
  independent of which mechanism gets used**: once a valid tree is found
  (by either recovery or replay), exact sizing is set in a separate,
  already-proven pass using the literally captured width/height per
  window — unchanged by any of this. The only non-definitive thing is
  which internal tree topology gets used when more than one is valid for
  the same rectangles (a symmetric grid, for instance) — invisible to the
  end result, and in every live test run so far, the recovered topology
  matched the original exactly anyway (Gate 2).
- **Asymmetry is a non-issue**: the cut-finder only cares whether a clean
  separating line exists, never at what position or proportion — a 96/4
  split is exactly as findable as an even one, confirmed with real
  Hyprland resize/compensation at multiple simultaneous nesting depths,
  not just synthetic ratios (Gate 8).
- **Hyprland groups need no new tree concept, only a small
  preprocessing step**: a group's members report (near-)identical
  captured rectangles in `hyprctl -j clients` — feeding that straight
  into the cut-finder correctly fails (two identical rectangles have no
  separating cut). Investigated live before deciding anything: moving —
  and, confirmed separately, resizing — only a group's representative
  address carries every other member along automatically, for free, with
  no per-member dispatch needed. So a group only ever needs to be *one*
  leaf to both the parser and the replay mechanism. The fix is narrow:
  before parsing, collapse each batch's windows using `hyprctl`'s own
  `grouped` field (not a geometric guess) to one representative per
  group, and reuse the *existing* 40px `rowTolerance` constant (already
  established for exactly this — a group's tab-bar chrome offset — by a
  prior live bug fix in `docs/DESIGN-JOURNEY.md` §16) for the cut
  -finder's cross-axis match. No `Group`/`SpatialGroup` tree node type is
  needed (Gate 9 and its follow-up).
- **Pseudo-tiling is a real, confirmed, content-dependent risk — and the
  existing safety net is confirmed sufficient for it**: unlike groups,
  a pseudo-tiled window's captured rectangle genuinely is not its logical
  Dwindle slot, and the gap between them isn't a fixed offset — it
  depends on how far the window's natural/preferred size is from its
  slot, and can range from negligible to drastic. Tested directly: mild
  shrink parsed and recovered correctly; a dramatic shrink returned
  `None`. In every case tried, the parser either succeeded correctly or
  failed cleanly — it never once fabricated a plausible-looking wrong
  tree. That failure path lands on the same `unresolved` → natural
  -Hyprland-sizing fallback that already exists today, unchanged (Gate 14).
- **Floating windows and occupied destinations need zero new handling**:
  floating windows must never reach the cut-finder — confirmed both as
  the correct path (works cleanly) and as load-bearing via a negative
  control (feeding them in anyway reliably breaks recovery, not just
  theoretically risky) (Gate 10). Placing a tree into an already-occupied
  destination needs no special-casing at all: `structureClauses()`
  already seeds `previousMeta = null` for the very first incoming window
  regardless of occupancy, which is exactly what representative-leaf's
  unconditional first placement step already does (Gate 11).
- **Multi-batch stash/restore doesn't get an "ideal" combined layout,
  and isn't supposed to, and this doesn't change**: `docs/FEATURES.md`
  §7.1 already states there's no single original combined layout when
  batches came from different source workspaces. Confirmed directly by
  reading the shipped code first: `previousMeta` already carries across
  batch boundaries today, unconditionally, in both `finishRestore()` and
  `finishMoveWorkspace()` — meaning a later batch's root already attaches
  to whichever leaf the previous batch happened to place last, and
  necessarily subdivides it further, in the *current* shipped design, not
  as a new side effect of this one. Each batch's own internal structure
  is still what gets reconstructed faithfully; the relationship between
  batches was never promised and stays best-effort (Gate 12).

## 2. Flow level

The pipeline `restore()` and `moveWorkspaceTo()` both drive, in order:

1. **Capture** — fresh `hyprctl -j clients` query gets x/y/width/height/
   floating per window. *(existing, unchanged)*
2. **Group** — descriptors grouped by stash batch (restore only;
   bulk-move has one implicit batch). *(existing, unchanged)*
3. **Separate floating from tiled** — floating restore is its own path
   (`geometryClauses()`'s floating branch) and is untouched by this work
   entirely; tested directly that mixing the two in one batch doesn't
   cross-contaminate either path (Gate 10). *(existing, unchanged)*
4. **Collapse Hyprland groups** — within the tiled subset, collapse each
   group (via the `grouped` field) to one representative address; the
   others are dropped from what reaches the next step, not from the
   batch overall — they still get moved/resized identically for free.
   *(new, small — Gate 9)*
5. **Build a tree** — for each batch's tiled (post-collapse) group,
   recursively cut it into a binary tree via the guillotine-cut
   partition. Returns `None` on ungapped, non-guillotine, or malformed
   geometry — an expected, load-bearing result, not an exceptional
   failure to special-case around. *(new — replaces the flat peel-based
   order; verified against adversarial/malformed synthetic input as well
   as live captures — Gates 2, 13)*
6. **Walk the tree and dispatch structure clauses** — representative-leaf
   preorder expansion: place each subtree's two representatives as a
   pair, focus/preselect/move exactly as `structureClauses()` already
   does, recurse. Multi-batch: the next batch's root chains onto whatever
   window the previous batch's expansion dispatched last, exactly
   matching today's `previousMeta` continuity. *(new traversal, same
   clause vocabulary, same cross-batch chaining shape — Gates 1, 5, 8, 12)*
7. **Resize pass** — once every batch's structure clauses are queued,
   resize every window to its exact captured size in one separate pass;
   `skipTiledResize` when the destination was occupied, unchanged.
   *(existing, unchanged — this is what guarantees the final visual
   result is exact regardless of which valid tree was chosen — confirmed
   still true with an occupied destination in Gate 11)*
8. **Cursor handling + one combined dispatch** — capture cursor position,
   append a restore-cursor clause, fire everything as one
   `hyprctl --batch` call. *(existing, unchanged — every gate's harness
   used this exact atomic-batch pattern throughout, including with
   floating windows and multi-batch chaining mixed in)*

## 3. Function level

What's actually touched, versus what stays exactly as-is:

| Responsibility | Function | Status |
|---|---|---|
| Capture geometry | `stash()`, `stashCaptureProcess`, `finishStash()` | Unchanged |
| Capture geometry (move) | `moveWorkspaceTo()`, `moveCaptureProcess` | Unchanged |
| Shared ordering entry point | `orderDescriptors(descriptors)` | Modified — internal batch loop calls group-collapse then the new bipartition function instead of `peelOrder()` |
| Per-restore wrapper | `restoreOrder(addresses)` | Modified — thin wrapper, now passing through a tree instead of only a flat order |
| Old single-leaf-peel classifier | `peelOrder()`, `isSeparated()` | Retired as the default path (kept reachable as a fallback until the new path clears a full regression pass) |
| Row/column tie-break fallback | `sortByRowThenX()` | Possibly retained as a fallback/tie-break utility, not necessarily deleted |
| New group-collapse preprocessing | *(new — e.g. `collapseGroups(descriptors)`)* | New — reads the `grouped` field, picks one representative per group |
| New recursive cut-finder | `partitionTree()` (tested as `partition_tree()` in `experiments/partition.py`) | New — port into `Service.qml` largely as-is |
| New representative-leaf dispatch driver | *(new — e.g. `expandTree()`)* | New — replaces the flat loop inside `finishRestore()`/`finishMoveWorkspace()`; tested as `build_steps()`/`place_tree()` in `experiments/harness_common.py` |
| Restore dispatch assembly | `finishRestore(cursor)` | Modified — flat `for` + one `previousMeta` becomes a call into the new tree-walk driver, with `previousMeta` continuity preserved across batches |
| Move dispatch assembly | `finishMoveWorkspace(clients)` | Modified — same change as `finishRestore()` |
| Per-window structure clauses | `structureClauses(address, destination, meta, previousMeta)` | Unchanged signature and logic — just called from the tree-walk instead of a flat loop; confirmed correct with an occupied destination (Gate 11) with zero changes |
| Per-window sizing clauses | `geometryClauses(address, meta, monitor, skipTiledResize)` | Unchanged — confirmed correct with `skipTiledResize` (Gate 11) and alongside floating windows in the same batch (Gate 10) |
| Direction inference | `preselectDirection(meta, reference)` | Unchanged — reused as-is by the new tree-walk, including for cross-batch chaining |
| Floating-window clamping | `clampToMonitor()` | Unchanged |

The shape to notice: everything that actually talks to Hyprland
(`structureClauses()`, `geometryClauses()`, the final `hyprctl --batch`
dispatch) is untouched. Everything that changes is upstream of that — how
order and direction get computed, never what gets sent or how it's
batched.

## 4. Verification — done, live, before this document was updated

Every item below has already been run against a real Hyprland session,
not simulated — full methodology and raw results in
`docs/RECONSTRUCTION-EXPERIMENTS.md`:

1. **Regression** — every layout `peelOrder()` already handles correctly
   (simple caterpillar shapes, the §20 ordering-bug repro) reconstructs
   identically under the new approach (Gates 1, 2).
2. **New capability** — the exact 2×2 independently-split-columns repro
   named in `docs/DESIGN-JOURNEY.md` §17/§20 now restores/moves
   correctly, and so does a 6-window tree with two independently-deep
   branches — beyond the minimum bar (Gates 1, 2).
3. **Orientation** — all four mirror/rotation variants, not just the one
   canonical direction convention every other fixture happened to use
   (Gate 5).
4. **Extreme ratios** — real Hyprland resize/compensation at multiple
   simultaneous nesting depths, not synthetic numbers (Gate 8).
5. **Adversarial/malformed geometry** — overlaps, non-guillotine
   arrangements, and malformed bounds all rejected cleanly, never
   crashed, never fabricated a wrong tree; positive controls confirm the
   parser didn't just get too conservative (Gate 13).
6. **Hyprland groups** — investigated live, decision made from evidence,
   not assumed (Gate 9 and its follow-up).
7. **Pseudo-tiled windows** — investigated live across mild and drastic
   cases, both alone and combined with extreme ratios (Gate 14).
8. **Mixed tiled + floating, occupied destinations, multi-batch** — all
   three integration cases confirmed against real Hyprland, using
   existing, unchanged production behavior wherever evidence showed it
   already worked (Gates 10, 11, 12).

Remaining, once implementation actually starts (not before): `qmllint`
and `omarchy plugin validate .` clean, and a live functional pass inside
the real plugin (Quickshell/Quattro), matching this project's standard
verification bar for every other change — the experiments above used a
standalone harness driving the same `hl.dsp.*` primitives directly via
`hyprctl`, not the actual QML code path.

## Status

Design fully tested, not yet built. No `Service.qml` code has been
changed. `docs/RECONSTRUCTION-EXPERIMENTS.md` has the complete evidence
trail this document's claims are built on — every fixture, every live
finding, and the final evidence-based implementation checklist. `docs/CLAUDE.md`
still documents the accepted limitation on `main` and instructs against
touching `restoreOrder()`/`structureClauses()`/`geometryClauses()` without
raising it first — implementation, when it happens, belongs on
`experiment/tree-bipartition-restore` (or a successor branch), never
directly on `main`, and should keep `peelOrder()` reachable as a fallback
until the new path clears a full regression pass against real Hyprland.
