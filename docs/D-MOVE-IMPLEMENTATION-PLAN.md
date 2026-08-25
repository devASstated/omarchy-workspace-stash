# Extending Approach D into `moveWorkspaceTo()` (bulk workspace-move)

## Status

`docs/D-ONLY-IMPLEMENTATION-PLAN.md` covered Approach D for `stash()`/
`restore()` only. That work is implemented, live-verified, and committed
(`cba0198` on `experiment/tree-bipartition-restore`) — real 2x2 grid,
3-window caterpillar, real Hyprland group, nested pseudo-tiled window,
stale-window-during-stash, and concurrent-call reentrancy all reproduced
the original layout's exact geometry.

This document is the next, explicitly separate increment: extending the
same D mechanism into `moveWorkspaceTo()`, the V3 bulk workspace-move
feature ("move everything on my current workspace onto workspace N"),
which today still uses the old flat/`peelOrder()` ordering and therefore
still has the pre-D caterpillar-only limitation. No Approach A / hybrid
work is involved in this increment — that remains a later, separate phase.

## Why this wasn't included the first time

Building D's async decompose-while-moving into a second call site was
flagged as a deliberate deviation in the original plan, reasoned as "a
third complex async flow not yet built." The user has since decided not
to wait through a daily-driving period before finishing it, so this
increment closes that gap now.

## Current shape, read directly from `Service.qml`

- `walkAndDispatch(tree, destination, monitor, skipTiledResizeFor,
  incomingMeta, incomingAddress)` (`Service.qml:620`) looks up each
  window's geometry via `root.meta[address]` directly — hardcoded to the
  stash's global, persistent meta store.
- The decomposition sequencer — `beginDecomposition` (`:727`),
  `onDecomposeCapture` (`:785`), `finishDecompositionSurvivor` (`:851`),
  `completeDecomposition` (`:860`) — hardcodes `root.stashWorkspace` as
  the destination of every destructive move performed *during*
  decomposition, and `completeDecomposition()` unconditionally stores its
  result into `root.batchPlans`, a persistent, cross-call structure keyed
  by stash batch id.
- `finishMoveWorkspace()` (`Service.qml:1226`) is documented today as
  deliberately orthogonal to the stash: it never reads or writes
  `root.meta`, and never touches `stashWorkspace`. It builds a local
  `descriptors` array from a fresh `hyprctl -j clients` capture, calls the
  flat `orderDescriptors()`/`peelOrder()` path unconditionally, and
  dispatches through `moveCursorProcess` (which queries cursor position,
  appends a trailing `hl.dsp.cursor.move` clause, and fires the real
  `hyprctl --batch`).

## Plan

1. **Generalize `walkAndDispatch`**: add an optional 7th parameter
   `metaMap`. Inside, use `metaMap || root.meta` in place of the current
   hardcoded `root.meta` lookup. The existing `finishRestore()` call site
   needs no change (it simply omits the new argument, keeping today's
   behavior byte-identical).

2. **Generalize the decomposition sequencer to an arbitrary destination**:
   - `beginDecomposition(batchId, sourceWorkspace, addresses,
     groupMembersByAddress, destinationWorkspace, extra)` — add the new
     required `destinationWorkspace` parameter (the existing `finishStash()`
     call site is updated to pass `root.stashWorkspace` explicitly — no
     behavior change there) and an optional `extra` object merged into
     `pendingDecomposition`'s state, defaulting to `{ purpose: "stash" }`.
   - `onDecomposeCapture`'s dispatch line and `finishDecompositionSurvivor`'s
     final-survivor move both switch from the hardcoded `root.stashWorkspace`
     to `st.destinationWorkspace`.
   - `completeDecomposition()` branches on `st.purpose`: `"stash"` keeps
     today's exact behavior unchanged (store into `root.batchPlans`);
     `"move"` instead calls a new `finishMoveDecomposition(st,
     resolvedTreeOrNull)` and never touches `root.batchPlans` at all.

3. **New `finishMoveDecomposition(st, tree)`**: if `tree` is non-null
   (reconstruction succeeded and validated), dispatch via
   `root.walkAndDispatch(tree, st.destinationWorkspace, st.monitor,
   function(a){ return st.occupied }, null, null, st.metaMap)`. If `tree`
   is null (unresolved — e.g. a genuinely non-reconstructible case, or a
   window closed mid-sequence in a way that broke the record), fall back
   to the exact same `orderDescriptors()`/`peelOrder()`-driven flat loop
   `finishMoveWorkspace()` uses today, over `st.metaMap` instead of fresh
   descriptors. Either branch's result is concatenated with
   `st.floatingStructure`/`st.floatingGeometry` (built once, before
   decomposition began), assigned to `root.pendingMoveClauses`, and
   dispatched through the existing, unchanged `moveCursorProcess`.

4. **Rewrite `finishMoveWorkspace(clients)`**: build a local `metaMap`
   (same shape as today's `descriptors`, keyed by address) covering every
   eligible client on the source workspace — including non-representative
   group members, for the same reason `finishStash()`'s `nextMeta` already
   does this (a representative can die mid-sequence; the leaf's
   `groupMembers` list needs live geometry for every member, not just the
   chosen representative). Split into floating (dispatched independently,
   same treatment `finishStash()` already gives floating windows) and
   tiled. Group-collapse the tiled clients via the existing
   `collapseGroups()`. 0-1 resulting representatives: keep today's exact
   simple-move behavior, merged with the floating clauses. 2+
   representatives: call `root.beginDecomposition(0,
   root.pendingMoveSourceWorkspace, representatives,
   grouped.representativeOf, destination, { purpose: "move", metaMap,
   monitor, occupied, floatingStructure, floatingGeometry })`.

5. Update the doc comment above `finishMoveWorkspace()`: still true that it
   never reads or writes `root.meta`, and never touches `stashWorkspace` or
   `root.batchPlans` — note that it now shares the decomposition
   sequencer's *ephemeral* `pendingDecomposition` state (torn down at the
   end of every call, same as today) rather than any of the stash's
   persistent bookkeeping.

## Explicitly unchanged

`structureClauses()`, `geometryClauses()`, `collapseGroups()`,
`partitionRemovalOrder()`, `inferAxisAndDirection()`, `reconstructTree()`,
`validateTree()`, `resolveLiveAddress()`, the `decomposeCaptureProcess`/
`decomposeDispatchProcess` `Process` components, `moveCursorProcess`,
`orderDescriptors()`/`peelOrder()`, `root.batchPlans` and stale-tree
pruning (`finishStash()`'s own call sites keep behaving exactly as
before), and the shared `decompositionInFlight` reentrancy guard
(`moveWorkspaceTo()` already checks it today).

## GPT review amendments (approved, incorporated below)

1. **Destination occupancy is a frozen pre-operation property.** `occupied`
   is computed exactly once, from the single fresh capture at the very
   start of `finishMoveWorkspace()`, before anything moves — never
   recomputed mid-sequence. (Already true by construction in the plan
   above; called out explicitly here since decomposition's own destructive
   moves land windows on the destination workspace partway through, which
   could otherwise tempt a "re-check occupancy" bug.)
2. **`metaMap` is immutable source-snapshot metadata.** Built once from
   the initial capture, read-only for the rest of the operation (including
   inside `walkAndDispatch`) — never mutated to reflect windows' physical
   moves during decomposition.
3. **Tree replay after D operates on clients already on the destination**
   (unlike `restore()`, where replay always targets a workspace different
   from wherever the stash special workspace currently holds them). This
   needs live verification, not just documentation: confirm
   `hl.dsp.window.move({workspace=destination, ...})` re-dispatched by
   `structureClauses()` against a window that's *already* on `destination`
   still correctly re-triggers Dwindle's insertion/split behavior (focus +
   preselect + move), rather than being treated as a same-workspace no-op
   that skips re-splitting. Added as its own explicit verification item
   below.
4. **On reconstruction failure, prefer the natural post-decomposition
   placement over a synthetic re-layout pass.** Originally planned to fall
   back to `orderDescriptors()`/`peelOrder()` over `metaMap` and re-dispatch
   `structureClauses()`/`geometryClauses()` for every tiled window, same as
   `finishRestore()`'s fallback. Changed: by the point reconstruction fails,
   decomposition has already destructively relocated every tiled window
   onto the destination workspace — the source topology no longer exists to
   reconstruct against, and forcing a second full move/focus/preselect pass
   on top of that risks compounding an already-degraded case. Instead,
   `finishMoveDecomposition()` on `tree === null` dispatches only the
   already-built floating clauses (plus the cursor-preservation clause) and
   leaves the tiled windows exactly where the incremental decomposition
   moves placed them — correct workspace, natural (not necessarily
   original) Dwindle arrangement, nothing lost or re-scrambled.
5. **Floating windows stay physically untouched until tiled decomposition
   completes.** Already true by construction — floating `structure`/
   `geometry` clauses are built early but only ever *dispatched* (via the
   single final `hyprctl --batch` through `moveCursorProcess`) once the
   tiled path (resolved tree, unresolved fallback, or the trivial 0-1
   representative case) has finished building its own clauses. No
   intermediate dispatch of floating clauses on their own.
6. **Explicit purpose validation in `completeDecomposition()`.** Branch on
   `st.purpose` with an explicit whitelist (`st.purpose === "move" ?
   "move" : "stash"`), not an implicit truthy check — an unrecognized or
   missing `purpose` falls back to today's stash behavior rather than
   silently taking whichever branch happens to come first.

## Verification

1. `qmllint Service.qml` and `omarchy plugin validate .` clean.
2. `omarchy restart shell` to force-reload (the symlinked-plugin-directory
   reload quirk documented from the previous phase — automatic
   file-watching does not reliably pick up edits reached only through the
   plugin symlink).
3. Live smoke tests on a disposable workspace, mirroring the fixtures
   already proven for stash/restore, but exercised through `quickshell -p
   /usr/share/omarchy/shell ipc call workspace-stash moveTo <id>` instead:
   a plain 2-way split, a true 2x2 grid, a real Hyprland group, a nested
   pseudo-tiled window. Each: build on the source workspace, `moveTo` a
   fresh target workspace, confirm via `hyprctl -j clients` that the
   resulting geometry on the target workspace exactly matches the
   original. Also re-confirm the simple pre-existing cases are untouched:
   a single window, moving onto an already-occupied destination
   (`skipTiledResize`), and floating windows.
4. **Tree-replay-onto-already-relocated-clients check** (amendment 3): for
   at least the 2x2 grid case, confirm the resolved-tree walk actually
   re-establishes the correct split structure when every address it
   dispatches against is already sitting on `destination` — not just that
   the final geometry happens to look right by coincidence of where
   decomposition's raw moves left things.
5. **Interrupted `moveTo`**: start a move with 3+ tiled windows, close one
   mid-decomposition (same technique already proven for stash — kill a
   window between decompose steps), confirm no crash, no stranded window,
   and (per amendment 4) that surviving windows land safely on the
   destination even if reconstruction can't resolve around the gap.
6. **Repeated move into the same target**: call `moveTo` twice in a row
   into the same already-populated destination, confirming the second
   call's fresh `occupied` computation and `skipTiledResize` behavior both
   work correctly against a destination that now holds the first call's
   windows.
7. Present the diff and a proposed commit message before any `git commit`,
   per `docs/CLAUDE.md` priority #11 — no co-author trailer this time, per
   the user's standing instruction.
