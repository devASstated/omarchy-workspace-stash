# Workspace Stash development rules

Read `docs/FEATURES.md` before making architectural or behavioral changes.
Read `docs/DESIGN-JOURNEY.md` before touching `stash()`/`restore()`/anything
in `Service.qml` that decides ordering, captures geometry, or batches
dispatches — several non-obvious bugs were already found and fixed there
(a metadata-pruning race, stale-cache geometry capture, cross-process
dispatch ordering); re-reading the relevant section first is faster than
rediscovering the same failure mode from scratch.

Current development target: V1, V2 (layout-preserving restore), and V3
(bulk workspace-move, advanced overflow/settings-menu additions, and the
V1 bar-indicator discoverability fix) are all implemented and tested — see
`docs/DESIGN-JOURNEY.md` §20 and `docs/FEATURES.md` §8 for what V3 actually
covers. There is no reserved-but-unbuilt scope left in this project as of
this note; treat any further feature work as a new request to scope from
scratch, not a continuation of an existing plan.

One exception: `docs/RECONSTRUCTION.md` is an approved *design* (no code
written yet) for replacing the layout-reconstruction limitation described
below. It's scoped to a dedicated experimental branch, not `main` — see
the "layout-reconstruction limitation" note further down for exactly what
that means and what to read before touching any of it.

Two behaviors worth knowing before touching restore/move code again:

- Restoring or bulk-moving windows must never move the mouse cursor as a
  side effect. `restore()`/`finishRestore()` and `moveWorkspaceTo()`/
  `finishMoveWorkspace()` in `Service.qml` each query `hyprctl cursorpos`
  before dispatching and append an explicit `hl.dsp.cursor.move({x,y})` as
  the last clause of the same atomic batch, to counteract Hyprland's
  cursor-follows-focus behavior during the `hl.dsp.focus()` calls inside
  `structureClauses()`. Don't remove this without preserving the fix.
- Moving/restoring two or more windows onto an already-occupied destination
  must not collapse the destination's existing window(s). `geometryClauses()`
  takes a `skipTiledResize` flag for exactly this case — when the
  destination is occupied, tiled windows skip their absolute-resize clause
  and let Hyprland's own tiling settle them.
- `restoreOrder()`/`orderDescriptors()` no longer just sort by row/x.
  `peelOrder()` repeatedly peels off whichever window is fully separated
  from the rest (`isSeparated()`, geometric, using `rowTolerance` slack),
  outermost first, to reconstruct any "caterpillar" tree — every tree
  `structureClauses()` can actually build, since each insert can only split
  the single most-recently-placed window. This was a real bug fix (see
  `docs/DESIGN-JOURNEY.md` §20's ordering-bug entry, found from a live user
  repro), not a rewrite for its own sake — don't revert to a flat sort
  without rereading why.
- Which side a new window lands on relative to its predecessor is
  Dwindle's own default heuristic unless overridden. `structureClauses()`
  now issues `hl.dsp.layout("preselect l|r|u|d")` before each non-first
  window's move/focus, direction from `preselectDirection()` against the
  immediately-previous window in the resolved order. Confirmed live, not
  just from the Lua stub — see `docs/DESIGN-JOURNEY.md` §20.

The layout-reconstruction limitation (`docs/DESIGN-JOURNEY.md` §17,
narrowed by §20) is still fully in effect on `main`: a genuinely
multi-branch layout — an actual 2×2 grid, two independently-split columns —
isn't reliably reconstructed today, because that requires the full
split-tree inference `docs/FEATURES.md` §7.4 already named as hard and this
project originally chose not to build. This is narrower than it used to
be: the "lone window plus a stacked pair" case that looked like the same
problem turned out to be fixable (see `peelOrder()` above) because it's
still a caterpillar tree, just one the old sort ordered wrong. The
remaining boundary was found, investigated, and explicitly accepted on
`main` — twice reconfirmed by the project owner as of that decision, not
an oversight.

That decision has since been revisited, and the resulting design has
since been tested live — 128 real Hyprland runs plus targeted
investigation of groups, pseudo-tiling, floating windows, occupied
destinations, and multi-batch restore, all on the
`experiment/tree-bipartition-restore` branch, none of it merged or
touching `main`. `docs/RECONSTRUCTION.md` is the tested design;
`docs/RECONSTRUCTION-EXPERIMENTS.md` is the full evidence trail and the
resulting implementation checklist. The crux, compressed: Hyprland's
Dwindle can only ever build a layout via full-span cuts of a focused
container, so any layout it produced is guaranteed reconstructible by
recursively cutting the *whole remaining group* into two non-empty
pieces — not just peeling one fully-separable window off the outside,
which is all `peelOrder()`/`isSeparated()` do today. The classifier alone
isn't enough, though: §17 shows the actual dispatch loop only ever splits
relative to one global "last window placed," so it can only ever build a
linear chain; the insertion/dispatch sequencing has to change too — not,
as first sketched and never built, to a per-subtree anchor tracked during
a recursive walk, but to **representative-leaf preorder expansion**: give
every subtree one fixed representative window, place a subtree's two
representatives as a pair before recursing into either side. That's the
mechanism that was actually tested — 40/40 on the first pass, holding
across every later gate — so it's what `docs/RECONSTRUCTION.md` now
describes; the anchor sketch never got built and shouldn't be. Read
`docs/RECONSTRUCTION.md` in full before implementing any part of this —
it has the idea-level reasoning, the data-flow, and a function-by
-function map of exactly what's new, modified, and untouched
(`structureClauses()`, `geometryClauses()`, and the actual
`hyprctl --batch` dispatch stay unchanged either way).

If you're reading this on `main` and the experimental branch above doesn't
exist yet or hasn't been merged, treat the original instruction as still
fully active: do not change
`restoreOrder()`/`structureClauses()`/`geometryClauses()` to address this
limitation without raising it in conversation first, and implement any of
it only on the dedicated branch, never directly on `main`.

A second, narrower, deliberately-accepted limitation was found and
investigated on `experiment/d-unified-pipeline`
(`docs/DUAL-PSEUDO-GEOMETRY-INVESTIGATION.md`): exact geometry
restoration is not guaranteed when two directly sibling tiled windows
are both pseudo-tiled — Hyprland may recompute a pseudo-tiled client's
natural surface size the moment it's touched during replay, even by
reasserting its own already-correct captured size, so this isn't fixable
by reordering dispatch clauses. Topology, window safety, and operation
completion are all unaffected; only that one window's exact surface size
isn't guaranteed. Deliberately left unfixed — the fix would require
capturing/persisting pseudo state and threading sibling-awareness through
`geometryClauses()`, exactly the kind of special-case machinery the
unified-D refactor (`docs/D-UNIFIED-PIPELINE-COMPARISON.md`) was written
to eliminate, for a rare, cosmetic-only precondition. Revisit only if
real usage hits it often enough to matter, or Hyprland exposes a clean
authoritative pseudo-state API.

Priorities:

1. Preserve the behavior defined in FEATURES.md.
2. Prefer native Quattro/Quickshell/Hyprland facilities.
3. Keep runtime architecture event-driven and minimal.
4. No polling loops.
5. No daemon or persistent state unless the project specification is deliberately revised.
6. Gesture bindings and keyboard bindings are input adapters only.
7. Core stash/restore behavior must have one authoritative implementation.
8. Do not silently overwrite user configuration.
9. Keep the project suitable for public distribution as an Omarchy plugin.
10. When a value needs to be correct at the instant it's read, not just
    eventually consistent, prefer a fresh `hyprctl -j <query>` over
    Quickshell's cached Hyprland models — this codebase has hit real,
    hard-to-diagnose bugs from trusting that cache more than once.
11. All git actions should be requested and never be performed without user review - present the git message along with summary of what was implemented before requesting for a git commit action 
