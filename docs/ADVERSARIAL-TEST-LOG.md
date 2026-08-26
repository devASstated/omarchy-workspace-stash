# Adversarial testing of the unified D pipeline

Run against `experiment/d-unified-pipeline` (`50eda7a`), live, through the
real plugin (`quickshell ... ipc call workspace-stash ...`), not the
Python harness. Goal: try to trigger `plan.unresolved` synthetically
rather than wait for daily use to find one — daily use is expected to be
mild-to-moderate in window count/severity, unlikely to naturally exercise
D's failure modes. Temporary debug instrumentation
(`lastCompletionDebug`/`debugLastCompletion()`) was added for this
session and fully removed afterward — `Service.qml` is back to exactly
its last committed state (confirmed via `git status`).

## Result 1: D topology reconstruction held under every structural stress tried

- **8-window deeply nested/asymmetric grid** (natural insertion order,
  no manual placement): resolved, restored to exact geometry, including
  two 74×98px slivers the layout itself produced.
- **Double window-kill mid-decomposition** (two windows closed in rapid
  succession during one 6-window batch's decomposition): resolved
  correctly, no crash, correct 4-window survivor set, clean restore.

No topology failures from raw structural complexity or ordinary
mid-sequence interruption — consistent with the ~150+ prior runs this
project has accumulated.

## Result 2: `plan.unresolved` triggered for real — and it worked

**Trigger found**: killing the batch's *designated final survivor*
(`addresses[0]` — the one window never destructively removed during the
diff loop, only explicitly moved at the very end via
`finishDecompositionSurvivor()`) partway through decomposition, while
other removal steps are still in flight.

Reproduced twice, both times with the same failure signature:

```
{"resolved":false,"error":"step removing <last-address>: no valid compensating info","recordLength":5}
```

(6-window batch, 5 removal steps as expected — the failure is always on
the *last* step.)

**Mechanism**: the survivor is expected to be part of whichever cluster
"compensates" (visibly moves) when a sibling is removed. Once the
survivor is already gone, removing the final other window in the
sequence has no surviving neighbor left to observe a compensating
geometry change against — `changed` comes back empty, `axis` stays
null, and `reconstructTree()` correctly refuses to invent a relationship
it can't observe, per `inferAxisAndDirection()`'s comment on
`docs/D-ONLY-IMPLEMENTATION-PLAN.md`'s own design intent.

**What happened after, both times**: the unresolved batch restored via
`finishRestore()`'s natural-placement fallback (added in `50eda7a`) —
every surviving window landed on the destination workspace with no
slivers, no crash, no stranded window. Confirmed via `hyprctl -j
clients` after both stash-side and restore-side dispatch.

**Conclusion**: the fail-closed architecture (`D admits it doesn't know
→ natural placement`, no `peelOrder()` guessing) is no longer validated
only by reasoning-by-analogy to `moveWorkspaceTo()`'s equivalent branch —
it has now been triggered by a real failure mode and behaved exactly as
designed. This closes the verification gap flagged when `50eda7a` was
committed.

## Result 3: a separate, real geometry-precision bug — dual pseudo-tiled siblings

**Not a topology bug.** In every trial, the reconstructed tree was
correct: all 4 windows in the right relative positions/order, 3 of 4
matched their exact captured geometry. The defect is isolated to one of
the two pseudo-tiled siblings' final size after restore.

**Reproduced twice, consistent numbers both times:**

Fixture: `A` (full-height, non-pseudo) | `B` (top-right, non-pseudo)
over `C`/`D` (bottom-right, both pseudo-tiled, direct siblings of each
other under an H-split).

Captured (before stash), settled ≥0.4s after each pseudo-toggle:

| Window | x | y | width | height |
|---|---|---|---|---|
| C (pseudo) | 727 | 579 | 341 | **200** |
| D (pseudo) | 1087 | 475 | 336 | 408 |

After restore (both trials identical):

| Window | x | y | width | height |
|---|---|---|---|---|
| C (pseudo) | 727 | 481 | 341 | **396** |
| D (pseudo) | 1087 | 475 | 336 | 408 |

C's width and D's full rect are exact. C's height is wrong (200 →
396, roughly double) and its y shifts accordingly (579 → 481, moving up
to accommodate the taller-than-captured window). D — resized in the same
batch, same mechanism — comes out exact.

## Next step

Per review: investigate the dual-pseudo geometry bug on its own, without
touching decomposition/reconstruction/tree-walk topology code
(`beginDecomposition()`, `inferAxisAndDirection()`, `reconstructTree()`,
`validateTree()` all stay untouched — Result 1 and 2 above showed they're
sound). Investigation surface: `geometryClauses()`, resize dispatch
order, and how Hyprland's pseudo-tile sizing interacts with a sibling's
absolute resize. See `docs/DUAL-PSEUDO-GEOMETRY-INVESTIGATION.md` for the
controlled-variant experiment log.
