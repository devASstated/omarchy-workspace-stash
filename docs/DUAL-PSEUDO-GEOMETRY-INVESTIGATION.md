# Dual pseudo-tiled sibling geometry bug — investigation

Per review: investigated without touching `beginDecomposition()`,
`inferAxisAndDirection()`, `reconstructTree()`, `validateTree()`, or any
tree-walk topology code — the adversarial pass already confirmed those
are sound (see `docs/ADVERSARIAL-TEST-LOG.md`). All experiments below
were raw `hyprctl dispatch` calls against a live fixture, isolating the
resize phase specifically, not full stash/restore cycles.

## Fixture

`A` (full-height) | `B` (top-right) over `H(C,D)` (bottom-right, C left
of D), both C and D pseudo-tiled, direct siblings of each other.

Captured/settled state, reproduced identically across 3 separate spawns:

| Window | x | y | width | height |
|---|---|---|---|---|
| C (pseudo) | 727 | 579 | 341 | **200** |
| D (pseudo) | 1087 | 475 | 336 | 408 |

(Slot geometry recovered from pseudo-centering math: C's slot is
`[727,470,341,418]`, D's is `[1082,470,346,418]` — both match the
windows' original pre-pseudo tiled rects exactly, confirming pseudo
renders centered within the unchanged Dwindle slot.)

## Experiments run

**Variant B (resize C only, D never touched):** dispatched
`hl.dsp.window.resize({x=341, y=200, window=C})` — i.e. re-asserting
C's *own already-current* captured size, no change requested.

Result: **C jumped to `[727,481] [341,396]`.** D, never touched,
stayed exact.

This alone rules out resize-order and any C↔D interaction as the cause
— D was never in the picture for this trial.

**Pseudo re-toggle, no resize at all:** toggled C's pseudo off then on
again (`hl.dsp.window.pseudo()` ×2), no explicit resize dispatch.

Result: **C's "natural" size is now permanently 396 on every subsequent
check** — re-toggling pseudo again doesn't recover 200. Whatever
recomputes C's natural pseudo size settled on a new answer and doesn't
revert.

**Control: lone pseudo window, non-pseudo sibling.** Same experiment —
direct `hl.dsp.window.resize()` re-asserting the window's own current
captured size — against a pseudo window whose sibling is a normal
(non-pseudo) tiled window.

Result: **exact, unchanged** — `[732,475][691,408]` before and after.
Confirmed stable; matches every single-pseudo case tested elsewhere
this session.

## Conclusion

**Not resize-order dependent** (variant B alone reproduces it with zero
D involvement). **Not caused by one sibling's resize changing the
other's slot** (D was untouched and stayed exact). The defect is
specific to a pseudo-tiled window whose *sibling is also pseudo-tiled*
— the moment **anything** touches that window (an absolute resize, even
to its own current value, or a bare pseudo re-toggle), its natural
pseudo size recomputes to a different, apparently-unrelated value and
stays there. A pseudo window with a normal sibling is completely inert
under the same operations.

This reads as a genuine Hyprland compositor behavior around how pseudo
-tile "natural size" is computed/cached when both windows sharing a
split are pseudo — not something fixable by reordering our own dispatch
clauses, and not a defect in `geometryClauses()`'s logic itself so much
as a case where forcing *any* resize on such a window is actively
harmful (worse than not resizing it at all), matching the existing
`skipTiledResize` philosophy already used for occupied-destination and
unresolved-batch cases elsewhere in this file.

## Decision: documented known limitation, not fixed

Discussed and decided (user + GPT review) not to implement a fix.
Reasoning:

- **Severity is low and qualitatively different from every other bug
  found this session.** Topology correctness, window safety, and
  operation completion are all preserved — the only defect is one
  pseudo-tiled window's surface settling to a different natural size.
  Not in the same class as a sliver/collapse, a lost window, a wrong
  tree, or a stranded client.
- **Not fixable by better replay ordering.** The investigation showed
  even *reasserting* the window's own already-correct captured size
  triggers the recompute — this is Hyprland's own pseudo-size caching
  behavior when both sides of a split are pseudo, not a defect in this
  file's dispatch sequencing.
- **The fix's own cost is exactly the kind of special-case machinery
  this project just spent effort eliminating** (see
  `docs/D-UNIFIED-PIPELINE-COMPARISON.md`): capturing and persisting
  pseudo state, establishing an authoritative pseudo signal, deriving
  direct-sibling pseudo relationships from the tree, threading a new
  resize-suppression reason through replay, and testing its interaction
  with groups, stale leaves, cross-batch restore, and occupied
  destinations — a lot of conceptual surface for a rare precondition
  (two windows must be *direct siblings* and *both* pseudo-tiled) whose
  failure mode is cosmetic.

**Known limitation, for the record:**

> Exact geometry restoration is not guaranteed when two directly
> sibling tiled windows are both pseudo-tiled. Hyprland may recompute a
> pseudo-tiled client's natural surface size when it is touched during
> replay (even by reasserting its own existing size). Structure
> replay remains correct and the operation remains safe — no crash, no
> lost or stranded window, no wrong topology — only that one pseudo
> window's exact captured surface size is not guaranteed to be
> reproduced when it has a pseudo sibling.

**Revisit only if**: real daily use hits this often enough to be
noticeable, or Hyprland exposes a clean authoritative logical-slot/
pseudo-state API that makes the fix nearly free. Otherwise the
architectural trade stays unfavorable.
