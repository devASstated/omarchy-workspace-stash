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
- Which side a new window lands on relative to its predecessor is
  Dwindle's own default heuristic unless overridden. `structureClauses()`
  issues `hl.dsp.layout("preselect l|r|u|d")` before each non-first
  window's move/focus, direction from `preselectDirection()` against the
  anchor window it's being placed relative to. Confirmed live, not just
  from the Lua stub — see `docs/DESIGN-JOURNEY.md` §20.

### Layout reconstruction

`main` still has the original limitation: a genuinely multi-branch
layout (an actual 2×2 grid, two independently-split columns) isn't
reliably reconstructed there, because it requires full split-tree
inference (`docs/FEATURES.md` §7.4), which the project originally chose
not to build (`docs/DESIGN-JOURNEY.md` §17, narrowed by §20). Do not
change `structureClauses()`/`geometryClauses()`/restore ordering on
`main` to address this without raising it in conversation first.

That decision has since been revisited on experimental branches,
culminating in `release-candidate` (branched from
`experiment/d-unified-pipeline`), where genuine multi-branch layouts —
grids, real Hyprland groups, pseudo-tiled windows — reconstruct
correctly for `stash()`/`restore()`/`moveWorkspaceTo()` alike. Full
design, mechanism, and evidence: `docs/D-RECONSTRUCTION.md` — start
there before touching any reconstruction code. (The raw feasibility
-phase experiment log this was validated against isn't part of this
tree; it's preserved in `release-candidate`'s own git history.) The
old flat/geometric-ordering fallback (`peelOrder()`, `isSeparated()`,
`orderDescriptors()`, `restoreOrder()`, `sortByRowThenX()`) has been
deleted on `release-candidate` — confirmed fully unreachable before
removal — not merely deprecated; a batch the new mechanism can't
resolve now uses natural placement instead (see
`docs/D-RECONSTRUCTION.md`).

One narrower, deliberately-accepted limitation from that work: exact
geometry restoration is not guaranteed when two directly sibling tiled
windows are both pseudo-tiled (a genuine Hyprland compositor behavior,
not a dispatch-ordering bug — see `docs/D-RECONSTRUCTION.md` for the
investigation and why it's left unfixed).

This is scoped to experimental branches, not `main` — treat `main` as
still governed by the paragraph above until this work is actually
merged.

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
