# Reconstruction feasibility — experiment log (Gate 1 & Gate 2)

This document records what was actually run against a live Hyprland
session on `experiment/tree-bipartition-restore`, why, and what the
results were — written for independent cross-review, not as a design
document. For the design being tested, read `docs/RECONSTRUCTION.md`
first; for the fuller menu of approaches this picks from, read
`docs/workspace_stash_reconstruction_feasibility_plan.docx` (§0–§14; the
gate numbering below is that document's own).

No production code was touched. Everything here lives in `experiments/`,
which `manifest.json`'s `entryPoints` never reference, so none of it ships
with the plugin.

## Environment this ran on

- Hyprland `0.56.2`, commit `efb50993`, built 2026-08-05.
- Single monitor (`eDP-1`, 2880×1800).
- Arch Linux, kernel `7.1.8-arch1-3`.
- Two real windows present throughout, both required to stay undisturbed:
  Brave on workspace 1, a Ghostty terminal (running the Claude Code
  session doing this work) on workspace 2.

## Why this couldn't just use `hyprctl dispatch <name> <args>`

The first surprise, discovered empirically before any fixture ran: this
Hyprland build wraps every `hyprctl dispatch <X>` call as
`hl.dispatch(<X>)` and evaluates it as Lua — classic dispatcher strings
like `movecursor 584 728` fail to parse (`')' expected near '584'`).
`Service.qml` already works around this by calling into a `hl.dsp.*`
namespace (`hl.dsp.window.move({...})`, `hl.dsp.focus({...})`,
`hl.dsp.layout("preselect ...")`, `hl.dsp.cursor.move({...})`) — confirmed
by reading `Service.qml` directly, not assumed. All test/harness code
below calls the exact same `hl.dsp.*` functions, just issued from a
standalone Python script via `hyprctl dispatch`/`hyprctl --batch` instead
of through Quickshell's `Process`. Same effect, zero QML touched.

Two more pieces of this Lua API, undocumented and found by controlled
probing (`hyprctl repl 'return hl.exec_cmd()'` etc. to read the error
messages, then grepping the user's own Hyprland/Omarchy Lua config for
real call examples), turned out to be load-bearing for building a safe
harness:

- `hl.exec_cmd(cmdString)` — launches a command.
- `hl.window_rule({ match = { title = "..." }, workspace = "... silent" })`
  — confirmed against `/usr/share/omarchy/default/hypr/apps/browser.lua`'s
  own real usage (`o.window({ title = ".*is sharing.*" }, { workspace =
  "special silent" })` — this project's `o.window()` wraps
  `hl.window_rule`). This is what let every test window land directly on
  a hidden workspace at creation time, silently, with zero chance of ever
  becoming visible or focused.

## Harness safety design

Two runtime-only special workspaces, registered via a single
`hl.window_rule` call at harness start, never written to any config file
and gone the next time Hyprland restarts:

- `special:swx-hold` — every freshly spawned test window lands here first
  (matched by a `^swx-.*$` title prefix).
- `special:swx-test` — where a tree-under-test actually gets built, via
  explicit `hl.dsp.window.move` calls, one fixture at a time, always
  emptied before and after.

Test windows are `foot -T <unique-title> sleep 3600` — deliberately not an
interactive shell, so foot's own prompt-driven title escape sequences
can't stomp the `-T` title before the harness reads it back (this bit the
first attempt: an interactive shell's title flipped to the shell prompt
string within the first poll). Cleanup kills by the exact PID
`hyprctl -j clients` reports for that address — never by process name, so
a stray unrelated `foot` the user happens to have open is never at risk.

One real incident during setup, not a fixture failure: before the
`window_rule`/`hl.exec_cmd` mechanism was worked out, two probe spawns
landed on workspace 2 (briefly reflowing next to the Ghostty window and
stealing focus) because a bare `foot` subprocess opens on whichever
workspace currently has focus, and focus had just been set back to
workspace 2 between probes. Both were caught immediately, moved off with
`hl.dsp.window.move`, and focus was restored to the Ghostty window before
continuing. This is the reason the harness now spawns exclusively through
the `window_rule` + `hl.exec_cmd` path — it removes the failure mode
entirely rather than reacting to it.

## Files

- `experiments/harness_common.py` — shared plumbing: `hyprctl`/`hyprctl
  repl` wrappers, spawn/wait/kill, the `Leaf`/`Split` tree model, the
  representative-leaf step builder, and the atomic-batch dispatcher
  (`place_tree()`, one `hyprctl --batch` call per placement, mirroring
  `finishRestore()`/`finishMoveWorkspace()`'s single-combined-dispatch
  requirement).
- `experiments/partition.py` — Approach A itself: `normalize()` and the
  sweep-based `partition_tree()`, with no Hyprland dependency at all.
  Shared by Gate 2 (live round-trip) and Gate 13 (synthetic).
- `experiments/gate1_representative_leaf.py` — Gate 1.
- `experiments/gate2_geometry_partition.py` — Gate 2.
- `experiments/gate13_adversarial_geometry.py` — Gate 13, pure synthetic,
  no Hyprland involved.
- `experiments/gate5_orientation.py` — Gate 5 (mirrored/rotated
  orientations, live).
- `experiments/gate8_extreme_ratios.py` — Gate 8 (extreme split ratios via
  real Hyprland resize, live).
- `experiments/attack_D_decomposition.py` — first attack on Approach D
  (locality, grouping-level correctness, initial cost measurement — later
  corrected, see the D sections below).
- `experiments/attack_E_special_workspace.py` — attack on Approach E
  (batch separability, destructive decode).
- `experiments/measure_settle_time.py`,
  `experiments/measure_settle_time_sequence.py` — isolated the real
  minimum settle time after a removal dispatch (found: ~0, the original
  0.4s/16.2s figures were measuring a `capture_rects()` bug, not
  Hyprland).
- `experiments/hypr_socket.py` — raw Hyprland Unix-socket IPC transport,
  bypassing `hyprctl`'s per-call process-spawn overhead (confirmed
  8-45x per-call reduction).
- `experiments/attack_D_fast.py` — D vs A re-measured on the raw-socket
  transport, both sides, for a fair ratio.
- `experiments/attack_D_full_topology.py` — D held to A's actual
  correctness bar (exact tree `repr()`, not just leaf grouping); three
  more real bugs found and fixed here, documented inline and in the log
  below.
- `experiments/attack_D_stress.py` — random-order stress test of the
  corrected reconstruction across 4/6/8-window trees.
- `experiments/attack_D_vs_pseudo.py` — discriminatory test: D against
  Gate 14's real pseudo-tiled layouts (found and fixed a fourth D bug —
  wrong-axis, not just unresolvable).
- `experiments/attack_D_vs_groups.py` — discriminatory test: D against
  real Hyprland groups, collapsed via the `grouped` field.
- `experiments/attack_D_failure_injection.py` — discriminatory test: real
  process kills mid-decomposition (found and fixed the final-survivor
  -never-moved gap).
- `experiments/attack_D_large_n.py` — discriminatory test: D vs A timing
  at 12/16/20 windows.
- `experiments/hypr_socket_scoped.py` — workspace-scoped capture via
  `hl.get_workspace_windows()` over `repl`, chasing the large-N scaling
  hunch.
- `experiments/attack_D_scoped_large_n.py` — large-N timing re-measured
  on the scoped capture, up to 30 windows.
- `experiments/attack_D_dual_pseudo.py` — information-boundary attack:
  both sides of a split pseudo-tiled, 5 fixtures, unmodified algorithm.
- `experiments/seam_integration_test.py` — the actual hybrid
  orchestration (`hybrid_stash()`) under test, shaped like a real
  production implementation.
- `experiments/run_seam_test.py` — the three-path seam test runner.

## Gate 1 — can Hyprland be driven to build an arbitrary tree at all

**Question** (docx §4, Approach B): using only `focus` + `preselect` +
`move`, can a manually-authored binary V/H tree be materialized
deterministically? No geometry parsing is involved in this gate — the
tree is known upfront and never inferred.

**Method — "representative-leaf" preorder expansion**: every subtree is
represented by one deterministic leaf (`representative(Split(first,
second)) = representative(first)`). Expansion is preorder — place
`representative(first)` and `representative(second)` as a pair first
(focus the former, preselect a direction, move the latter into place),
*then* recurse into `first` and `second` to further split their own
representatives. Canonical convention: `V` → first=left, second=right;
`H` → first=top, second=bottom, so the direction sent to
`hl.dsp.layout("preselect ...")` is fixed (`"r"` for `V`, `"d"` for `H`)
rather than computed per fixture.

**Fixtures** (naming matches the docx's F1–F4):

| id | tree | shape |
|---|---|---|
| F1 | `(A｜B)` | two-way split |
| F2 | `(A｜(B/C))` | right-nested caterpillar |
| F3 | `((A/B)｜C)` | left-nested caterpillar |
| F4 | `((A/C)｜(B/D))` | true 2×2 — the documented accepted-limitation case |

**Pass criterion**: after firing one atomic batch of clauses, recursively
verify that at every internal node, the bounding box of the first
subtree's windows and the second subtree's windows are (a) adjacent
(gap ≤ 20px tolerance) along the correct axis, and (b) equal in extent on
the other axis (a true full-span cut, not a partial overlap).

**Result**: `40/40` — 10 repeats × 4 fixtures, byte-identical geometry on
every single run, including F4.

```
F1  rects={'A': (9, 35, 704, 856), 'B': (727, 35, 704, 856)}
F2  rects={'A': (9, 35, 704, 856), 'B': (727, 35, 704, 421), 'C': (727, 470, 704, 421)}
F3  rects={'A': (9, 35, 704, 421), 'B': (9, 470, 704, 421), 'C': (727, 35, 704, 856)}
F4  rects={'A': (9, 35, 704, 421), 'C': (9, 470, 704, 421), 'B': (727, 35, 704, 421), 'D': (727, 470, 704, 421)}
```
(identical across all 10 repeats of each)

## Gate 2 — can the tree be recovered from geometry alone

**Question** (docx §3, Approach A): given *only* final rectangles — no
known tree — can a parser recover a tree that reproduces the original
layout when replayed?

**Deliberate framing choice**: this does **not** just check "does the
recovered tree structurally equal the original tree." A symmetric 2×2
grid has more than one valid guillotine slicing of the identical
rectangle set (row-first vs. column-first) — `docs/RECONSTRUCTION.md`
already claims correctness is about the *final visual result*, not which
of several equally-valid trees gets picked. So each run is a real round
trip:

1. Build a **known** tree live (batch A), via Gate 1's proven placement.
2. Capture batch A's rectangles.
3. Kill batch A. **Discard the known tree entirely** from this point on.
4. Run `partition_tree()` on the captured rectangles alone.
5. Spawn a **fresh** batch B, replay the **recovered** tree.
6. Capture batch B's rectangles.
7. Compare batch B to batch A, per window name.

**Method — recursive guillotine-cut partition** (`partition_tree()` in
`gate2_geometry_partition.py`, per docx §3.2): sort windows by their low
edge on a candidate axis, sweep while tracking the running max of the
high edge; every point where the running max doesn't reach the next
window's low edge (within tolerance) is a candidate cut, splitting the
group into two non-empty parts. This is done on both axes, all candidates
are collected, and ranked by strongest separation first (same bias the
existing `isSeparated()` in `Service.qml` already uses). The strongest
candidate that lets *both* halves themselves fully partition (recursively,
memoized by leaf-set) wins; a group of one window is the base case.

**Fixtures**: F1–F4 above, plus two deeper cases beyond what Gate 1 alone
tested:

| id | tree | shape |
|---|---|---|
| F6 | `(A｜(B/(C｜D)))` | deep, asymmetric-depth, 4 windows |
| F7 | `((A/(B｜C))｜((D｜E)/F))` | two independently-deep branches, 6 windows |

**Pass criterion**: batch B's rectangle for every window matches batch
A's (position and size, 20px tolerance).

**Result**: `30/30` — 5 repeats × 6 fixtures, all passed. Notably, the
recovered topology was **structurally identical** to the known original
on every single run, not merely visually equivalent — the ambiguity case
this test was specifically designed to tolerate never actually had to be
relied on:

```
F1  known=(A|B)                      recovered=(A|B)                      same topology: True
F2  known=(A|(B/C))                  recovered=(A|(B/C))                  same topology: True
F3  known=((A/B)|C)                  recovered=((A/B)|C)                  same topology: True
F4  known=((A/C)|(B/D))              recovered=((A/C)|(B/D))              same topology: True
F6  known=(A|(B/(C|D)))              recovered=(A|(B/(C|D)))              same topology: True
F7  known=((A/(B|C))|((D|E)/F))      recovered=((A/(B|C))|((D|E)/F))      same topology: True
```
(identical across all 5 repeats of each)

## Gate 13 — parser safety on malformed / adversarial geometry

Added after a second-opinion review of Gates 1–2 (via GPT, cross-checking
this log) flagged a real gap: every fixture above came from geometry
Dwindle itself actually produced, which is always fully covering and
sliceable by construction. None of it says anything about what
`partition_tree()` does when handed geometry that *isn't* — and "the
parser fabricates a plausible-looking wrong tree instead of failing" is a
strictly worse outcome than "the parser crashes," since the former can
silently reach a production `hyprctl --batch` dispatch. `partition_tree()`
already had a defined failure path (`None`, treated as a hard failure by
both gate scripts) — this gate is what actually exercises it.

**Method**: pure synthetic unit tests, no live Hyprland involved at all —
`gate13_adversarial_geometry.py` calls `partition.py`'s `normalize()`/
`partition_tree()` directly on hand-built coordinate sets. Negative cases
(must be rejected, never crash), positive controls (must still succeed,
so a pass can't just mean the parser got too conservative), and malformed
-input cases (must be rejected at the `normalize()` boundary, before ever
reaching the sweep).

**A real bug found and fixed while building this**: the original
`find_axis_cuts()` (written for Gate 2) only checked for a gap on the
axis being cut — it never confirmed the two resulting groups actually
spanned the *same* range on the other axis. A T-shaped layout (a
full-width strip on top; underneath, two columns where one is short)
produces exactly this: the outer cut looks clean, but the inner "cut"
between the two columns leaves real uncovered space, because one column
doesn't reach as far down as the other. The old sweep accepted it anyway.
Fixed in `partition.py`'s `find_axis_cuts()` — the two groups' cross-axis
extents (min and max) must now match within tolerance before a candidate
cut is accepted at all, not just checked for a gap on the primary axis.
`gate2_geometry_partition.py` now imports `partition_tree()`/`normalize()`
from this shared module rather than carrying its own copy, and was
re-run afterward to confirm no regression (below).

**Cases** (`gate13_adversarial_geometry.py`):

| case | expect | what it's testing |
|---|---|---|
| `corner_overlap` | reject | two rectangles overlapping diagonally, no cut exists |
| `straddling_rectangle` | reject | a rectangle spanning across an otherwise-plausible cut line |
| `pinwheel_non_guillotine` | reject | classic 5-rectangle windmill — genuinely not sliceable |
| `cross_axis_span_mismatch` | reject | the T-shaped case above — the one that found the bug |
| `duplicated_fully_overlapping` | reject | two pixel-identical rectangles (F9 group precursor) — correctly fails until a `Group` node exists |
| `excessive_overlap_beyond_tolerance` | reject | 6px overlap at `tol=5` — real overlap, not border noise |
| `two_way_split`, `true_2x2_grid`, `deep_asymmetric_six_window` | accept | positive controls matching Gate 2's own shapes |
| `extreme_ratio_90_10` | accept | imbalance alone must not be penalized |
| `overlap_just_within_tolerance` | accept | 4px overlap at `tol=5` — inside tolerance, must still pass |
| `pseudo_tiled_shrink` | accept | a window not filling its slot — a positive gap is never penalized, only overlap is tolerance-bound |
| `zero_width` / `negative_width` / `zero_height` | reject (input boundary) | malformed bounds must never reach the sweep at all |

**Result**: `15/15` — 6/6 negative, 6/6 positive, 3/3 malformed-input, all
correct. Zero crashes across any case.

**Gate 2 regression check after the fix**: re-ran all 6 live fixtures × 3
repeats against the fixed `partition.py` — `18/18`, all still exact
topology matches, no change in behavior on real Dwindle-produced geometry.

## Gate 5 — mirrored / rotated orientations, live

A real gap in every fixture up to this point: Gates 1 and 2 always used
the same canonical direction convention (`direction_for()`'s default —
`V` → second lands right of first, `H` → second lands below first).
Nothing had ever told Hyprland to preselect `"l"` or `"u"` at all, so
nothing so far actually confirmed the mirrored directions work, only that
one fixed orientation does.

**Method**: `harness_common.py`'s `direction_for()`/`build_steps()` gained
optional `flip_v`/`flip_h` parameters (default `False`, so Gates 1/2/13
are unaffected). `gate5_orientation.py` builds all four orientations
(normal, left-right mirror, top-bottom mirror, both = 180° rotation) of
both `F4` (2×2) and `F7` (two independently-deep branches, 6 windows).

Two checks per run, not just adjacency — Gate 1's `check_split()` doesn't
care which side each subtree landed on, so it would pass even if a mirror
silently failed to happen:

1. **orientation** — the correct *side* (not just "adjacent"): a flipped
   `V`-split's first subtree must actually be right of, not left of, its
   second.
2. **round trip** — matching the feasibility doc's own F5 pass criterion:
   discard the known tree, recover one from the built (possibly mirrored)
   geometry via `partition_tree()`, replay it fresh, confirm the same
   per-window spatial result. `partition_tree()` itself is orientation
   -agnostic (it only reads final positions, never how they got built),
   so this also confirms recovery doesn't secretly depend on the one
   direction convention Gate 2 happened to test.

**Result**: `32/32` — 4 repeats × 4 orientations × 2 tree shapes, all
passed, both checks, every run.

## Gate 8 — extreme split ratios, live

Gate 13's synthetic `extreme_ratio_90_10` already showed the parser
itself doesn't penalize imbalance. What it couldn't show: whether real
Dwindle resize/compensation, at multiple nesting depths simultaneously,
actually produces the kind of geometry the parser then has to cope with.

**Method** (`gate8_extreme_ratios.py`): build a known tree at its default
near-even split, capture that as a baseline to learn the real working
-area dimensions, then fire one absolute-resize batch — mirroring
`geometryClauses()`'s own resize-only, position-untouched pattern for
tiled windows — pushing several windows at *different nesting depths* to
extreme target sizes at once, deliberately leaving their siblings
unresized so Dwindle has to compensate them itself (rather than every
target being independently pre-computed to sum correctly). Capture what
actually happened — never assumed — then run `partition_tree()` on the
real resulting geometry. Per the doc's own framing, this gate is about
topology surviving extreme skew, not ratio precision — exact sizing stays
the separate, already-proven geometry pass's job.

**Fixtures**:

- `F8_2x2_nested_extreme` — the 2×2 shape, root V-split and both nested
  H-splits pushed to contrasting extremes in one batch.
- `F8_deep_nested_extreme` — the 6-window `F7` shape, three different
  splits at three different nesting depths pushed at once.

**Result**: `8/8` — 4 repeats × 2 fixtures, all passed, exact topology
recovered every time despite real measured skews like `0.96`/`0.04` and
`0.92`/`0.08` at nested nodes (logged per run, not assumed — see
`measure_skew()`'s output in the script for the actual per-split ratios
achieved).

## Gate 9 — real Hyprland groups, investigated live

Not a fixture run — GPT's own framing for this one ("observe first, model
second") called for live inspection before touching any code, so this is
exactly that: ad-hoc probes against a real group, run interactively, not
a checked-in gate script. Findings, in the order GPT asked for:

**1-2. What `hyprctl -j clients` reports, and whether members are
distinguishable.** Grouped two plain windows live (`hl.dsp.group.toggle()`
on the focused one, then `hl.dsp.window.move({ into_group = "l" })` from
the other — this took two tries; a bare `into_group` on an ungrouped
neighbor is a silent no-op, group membership has to already exist on one
side first). Every group member's `hyprctl -j clients` entry carries a
`grouped` field — an array of every member's address, present on each
member's own entry — and, confirmed directly: **both members reported
identical `at`/`size`** (`[9, 63]`/`[1422, 828]` for both, in the run
that produced this). Only one is actually visible at a time (tab-like),
but both are independently addressable, non-floating client entries with
the same tile geometry. The `[9, 63]` vs. an ungrouped window's `[9, 35]`
at the same row is the exact ~28px chrome offset `DESIGN-JOURNEY.md` §16
already documented from a user repro — now reproduced directly, on
purpose, rather than found via a bug report.

**3. Movement semantics.** Moved *only* one member's address to another
workspace (`hl.dsp.window.move({ workspace = ... })`, naming just that
one address) — **the other member came along automatically**, both
landing on the destination workspace together, group still intact
(`grouped` still listing both). Then, the more important test: simulated
today's *actual* production dispatch pattern — a flat sequence that has
no concept of "group" at all and treats every captured address as an
independent leaf needing its own focus+preselect+move — against a real
group's second member. Result: **no corruption**. The group's first
member's move already dragged the second one along; the "extra"
move+focus issued for the second member (which today's flat loop would
always issue, unaware it's redundant) landed on a window that was already
exactly where it needed to be, and was absorbed as a no-op rather than
splitting the group apart into two tiles. Confirmed reproducible, not a
one-off — re-run to check.

**4. What the project's own history already established.** `DESIGN-JOURNEY.md`
§16: a prior live bug hunt already concluded "the group itself was never
the problem... the group itself stayed correctly intact throughout" —
the actual bug there was `restoreOrder()`'s row-tolerance being too tight
for the chrome offset, already fixed with a 40px `rowTolerance`. That
finding is now directly corroborated by #3 above, with the movement
mechanics behind *why* it held made explicit for the first time.

**5. Fed real captured group geometry into `partition_tree()` unchanged**
(GPT: "if it returns `None`... that is not yet a parser bug"). Three
real numbers captured live — `C: (9,35,704,856)`, `A: (727,63,704,828)`,
`B: (727,63,704,828)` (A and B pixel-identical, real group, real
capture) — fed straight in: **`None`**, exactly as Gate 13's synthetic
`duplicated_fully_overlapping` case predicted, now confirmed on real
data rather than inferred. This is the correct, safe outcome for
*unprocessed* group geometry, not a bug.

**Follow-up finding, not one of GPT's five questions but load-bearing for
the decision below**: pre-collapsing the group to one representative
(dropping B, keeping only `A: (727,63,704,828)` alongside `C`) *still*
returned `None` at the default `tol=20` — the ~28px chrome offset on the
cross-axis (`y`) exceeds it. Succeeds cleanly at `tol=28` and above.
Checked the obvious concern this raises head-on: does widening tolerance
to absorb this offset let the *raw, uncollapsed* duplicate pair
(`A`/`B` both present) slip through instead? No — re-tested the raw
three-rectangle capture at `tol=40` and even `tol=100`: still `None`.
The two concerns are different magnitudes and don't interact: a group's
chrome offset is a few tens of pixels; two literally-identical rectangles
overlap by their *entire* width, hundreds of pixels — no reasonable
tolerance bridges that gap by accident.

**Decision, evidence-weighted per GPT's own preference order (A > B > C)**:
closer to **A** than either named alternative, but not exactly A as
stated — "no special handling" undersells it slightly, because
`partition_tree()` still needs to *not be handed* two identical
rectangles in the first place (confirmed by #5). The actual smallest
justified change is lighter than the `SpatialGroup`/`Group`-node models
GPT sketched as B/C:

- **No new node type in `LayoutTree` at all.** A group only ever needs
  to be *one* leaf to the parser and to the tree-walk/dispatch driver —
  confirmed by #3, moving (and, by the same mechanism, very likely
  resizing — not separately tested, but there's no reason to expect
  different behavior) the representative carries the rest of the group
  for free.
- **A capture-time preprocessing step, not a geometric heuristic.**
  Don't detect "these rectangles look like a group" by proximity or
  near-equality — `hyprctl -j clients`'s own `grouped` field already
  says so unambiguously. Collapse each batch's captured windows using
  that field: pick one representative address per group, drop the rest
  from what gets handed to `partition_tree()`.
- **Reuse the existing 40px `rowTolerance` for the parser's cross-axis
  span-match**, not a new or wider knob — it was already sized for
  exactly this chrome offset once, empirically, by a different piece of
  code (`isSeparated()`'s row comparison). This is the same constant
  doing the same job in a new location, not tolerance creep.

Not yet verified: whether the *dropped* (non-representative) members
need their own explicit resize dispatch during the geometry pass, or
whether that's also free by the same mechanism proven for move. Low risk
either way — today's flat per-address loop would issue it regardless,
redundant at worst — but flagged rather than assumed.

## Gate 14 — real pseudo-tiled windows, live

Also observation, not a checked-in gate script — same "observe first"
framing, and the same reason: `docs/RECONSTRUCTION.md` named pseudo
-tiling as *the* remaining geometry-vs-logical-tree risk, and Gate 13's
synthetic `pseudo_tiled_shrink` case proved only that the parser *can*
parse *some* gapped geometry, never that real pseudo-tiling produces
that kind of geometry. `hl.dsp.window.pseudo()` toggles it on the
focused window (found the same way as the group dispatchers — grepped
Omarchy's own Lua bindings rather than guessing).

**Simple 2-way split, pseudo on one leaf**: baseline `A: (9,35,704,856)`,
`B: (727,35,704,856)`. Pseudo-toggled on `A` alone: `A` became
`(9,252,704,422)` — **same width** (704, unchanged — its content didn't
need to shrink horizontally), **height collapsed by exactly half** (856
→ 422) and **re-centered vertically inside its old slot** (`y`: 35 → 252,
and `252 = 35 + (856-422)/2` exactly). Confirms the named risk directly:
the reported rectangle is the client's actual (smaller) surface, not its
logical Dwindle slot — the slot boundary information is simply gone from
`hyprctl -j clients`, not obscured by some fixed, absorbable offset.
Fed into `partition_tree()`: `None` at every tolerance up to `100`;
"succeeds" only at `tol=250`, which is not a fix — 250px is an order of
magnitude past the group case's legitimate ~28-40px chrome offset, and
treating that as a viable tolerance would be exactly the "widen it until
overlaps happen to pass" trap flagged for Gate 9 too. Correct outcome
here is the `None` at any sane tolerance, not the 250 case.

**Nested branch, pseudo on the deeper leaf**: `A|(B/C)`, pseudo-toggled
on `C`. Shrink here was much milder — `(727,470,704,421)` →
`(732,475,694,411)`, a 10px-scale change, re-centered the same way.
`partition_tree()` recovered the exact correct tree, `(A|(B/C))`, at the
default `tol=20`. **Pseudo-tile shrinkage is content-dependent, not a
fixed penalty** — `foot`'s natural terminal size quantizes to its
character grid, so how much a pseudo window shrinks depends on how close
its slot already was to a natural size for that content. Sometimes
negligible, sometimes drastic — confirmed by direct contrast between
this case and the one above, not assumed from either alone.

**Combined with an extreme asymmetric ratio** (the F8 methodology, one
tree): resized `B` to an 85% share of the column first, *then*
pseudo-toggled `C` in the now-much-smaller remaining slot. `C` shrank
drastically — `(727,470,704,421)` → `(982,777,194,114)`, both position
and size barely resembling its nominal slot. `partition_tree()`: `None`
— correct, safe failure, no fabricated tree.

**Interpretation, per GPT's own framework**: this is squarely the middle
case — "if parser fails safely, preserve fallback" — not the first
("works unchanged," which the mild nested case came close to but the
other two didn't) and not the third ("returns a wrong tree," which never
happened in any of these runs, including the most drastic shrink).
`partition_tree()` never once fabricated a plausible-looking incorrect
tree for pseudo-tiled geometry — every failure was a clean `None`. This
is the same fallback the project's existing `unresolved` → natural
-Hyprland-sizing path already exists for today, not a new mechanism.

**Not investigated**: whether Hyprland exposes the logical slot geometry
anywhere else (a different `hyprctl` query, or a field this capture
missed) — GPT's suggested next step if the parser-fails-safely outcome
needed strengthening. Given the fallback already exists and behaves
correctly, this doesn't block anything; it would only be worth chasing
if pseudo-tiled *exact* restoration became a stated goal later, not for
closing this gate.

## Gate 9 follow-up — resize semantics on a grouped representative

One question Gate 9 left open, cheap enough to check directly rather than
infer from move behavior (as instructed): does resizing *only* the
representative address also resize the group's whole shared tile, the
same way moving it does?

First attempt gave a false negative worth recording: grouped a pair with
nothing else on the workspace, resized the representative, saw no change
at all. Cause understood immediately, not a mystery — an absolute
tiled resize needs a *sibling* to compensate against, and the group
filled the entire workspace alone, same as trying to resize any single
window that already fills its whole workspace.

Redone with a third window present (`C | Group(A,B)`, group confirmed
first via matching `at`/`size`), then resized *only* `A`'s address to
roughly 1.6× its width: **both `A` and `B` reported the identical new,
larger size afterward** — `B` updated without ever being individually
addressed. Confirms Gate 9's conclusion holds for geometry, not just
movement: a group only ever needs to be one leaf, for both structure
*and* sizing. No fallback to per-member resize dispatch is needed.

## Gate 10 — mixed tiled + floating in one batch

**Method**: one batch containing a full `F4` (2×2) tiled tree plus two
floating windows — one deliberately positioned near the monitor's right
edge (`x=2700` on a 2880-wide monitor). Built via one truly combined
`hyprctl --batch` call: `F4`'s representative-leaf structure clauses
followed by the floating windows' clauses (workspace move → `hl.dsp.window
.float({action="on"})` → absolute position), exactly mirroring
`geometryClauses()`'s existing plain-move-only floating branch alongside
`structureClauses()`'s tiled branch in the same dispatch.

**Result**: tiled structure recovered exactly (`((A/C)|(B/D))`), both
floating windows landed at their exact intended positions, `floating`
flags correctly distinguished all six windows, no cross-contamination in
either direction from sharing one atomic batch.

**Negative control, the actual point of this gate**: fed the *full*
mixed set (tiled + floating rectangles together) into `partition_tree()`
— `None`. This isn't a bug to fix; it's confirmation that "do not allow
floating windows into `partition_tree()`" is a load-bearing filtering
step, not a precaution against something that was never going to happen.
Production already tags every captured window with `meta.floating`
(existing, unchanged) — that's the correct, already-available signal to
split the batch on before calling the parser, not a new field to invent.

## Gate 11 — occupied destination

**Method**: placed a pre-existing window `E` on the destination first
(focused, as if the user had been using it), *then* placed a fresh `F4`
tree into the same destination via the same `place_tree()` used
everywhere else — deliberately with **no special-casing** for the
occupied case, because reading `Service.qml` directly first showed none
is needed: `finishRestore()`/`finishMoveWorkspace()` already seed
`previousMeta = null` for the very first incoming window regardless of
whether the destination is occupied (only `geometryClauses()`'s
`skipTiledResize` flag reacts to occupancy, never `structureClauses()`'s
preselect logic) — meaning the incoming tree's root already relies on
Dwindle's own default focus-based insertion next to whatever's focused,
identically whether that's empty space or an existing window. The
representative-leaf root placement (`(representative(tree), None, None)`
as the first step, unconditionally) already matches this exactly, with
zero new code.

**Result**: all five windows present, zero slivers or collapsed
dimensions (`E` compressed from filling the whole workspace to `704×856`
to make room, never to a sliver), and the incoming subtree's internal
structure recovered exactly (`((A/C)|(B/D))`) despite landing in a
squeezed, non-default absolute region — confirming relative structure
survives independent of the absolute space available. (As a bonus,
informational-only check: feeding `E` *and* the incoming batch together
into `partition_tree()` also happened to succeed here, `(E|((A/C)|(B/D)))`
— but production correctly doesn't rely on this; `skipTiledResize`'s
existing behavior of not forcing exact resize into an occupied
destination stays exactly as-is and untouched, matching the doc's own
"there was never an original combined tree" framing.)

## Gate 12 — multiple stash batches

**Method**: read `Service.qml` first rather than assume — `orderDescriptors()`
concatenates every batch's ordering into one flat list, and critically,
`previousMeta` is initialized **once**, before the whole loop, in both
`finishRestore()` and `finishMoveWorkspace()` — it is *not* reset between
batches. So today's shipped behavior already chains batch 2's first
window against batch 1's *last-placed* window via the normal
focus+preselect+move mechanism, not by coincidence but by construction.
Replicated that exactly with representative-leaf: batch A
(`A|(B/C)`, chosen so its own last-dispatched leaf ends up being `C`) and
batch B (`(D|E)/F`), with batch B's root chained onto batch A's
last-dispatched leaf, fired as one combined atomic batch.

**Result**: all six windows present, zero slivers or collapsed
dimensions. Batch B's internal structure recovered exactly:
`((D|E)/F)`. Batch A's did **not** — `partition_tree()` returned `None`
for `{A,B,C}`, because `C` (the leaf batch B's root got chained onto) was
itself further subdivided to make room, changing its geometry from what
`A|(B/C)` alone would have produced.

**This is not a regression, and not new** — it's the concrete
manifestation of something already true, and already correctly not
promised, before this work started: `FEATURES.md` §7.1 already states
there's no single original combined layout across batches, and inserting
a new subtree into a workspace can *only* ever happen by splitting some
existing leaf's region — that's how Dwindle itself works, and it's true
regardless of which ordering mechanism (today's `peelOrder()`-based flat
list, or representative-leaf) chose which leaf gets split. Given
`previousMeta` carries across batch boundaries identically in the
shipped code today, the *same* leaf-gets-resplit outcome would happen
with the current `peelOrder()` path too — confirmed by reading the
mechanism directly, not re-run as a separate live comparison, since the
dispatch pattern (`focus` the anchor, `preselect`, `move` the next
window) is identical either way and is what necessarily causes it.
No sliver, no collapse, no crash — exactly the "best-effort only, never
destructive" bar `FEATURES.md` §7.5 sets, not a stronger one.

## What this does and doesn't establish

**Established, with real live-compositor evidence (128/128 runs, 0
failures) plus 15/15 synthetic parser-safety cases**: the two mechanisms
`docs/RECONSTRUCTION.md`'s design depends on — deterministic tree-driven
placement via representative-leaf expansion, and tree recovery from pure
geometry via recursive guillotine-cut partitioning — both work, including
on the exact 2×2-grid case that's currently documented as an accepted
limitation, on trees deeper/wider than the design's own minimum bar,
in all four mirror/rotation orientations (not just the one canonical
direction convention every earlier fixture happened to use), and under
real extreme resize skew at multiple simultaneous nesting depths.
`partition_tree()` now has verified evidence (not just a hopeful `None`
branch) that it fails closed rather than fabricating a wrong tree on
geometry it has no business succeeding on.

(128 = 40 Gate 1 + 30 Gate 2 + 18 Gate 2 regression re-run after the
Gate 13 fix + 32 Gate 5 + 8 Gate 8. Gates 9 and 14 were live investigation,
not counted fixture runs — see their sections above for what was
directly confirmed on real Hyprland state.)

**Also established, from Gates 9/9-follow-up and 14's live investigation**:
a real Hyprland group only ever needs to be one leaf to both the parser
and the dispatch driver — moving *or resizing* only the representative
address carries the rest of the group along for free, both confirmed by
direct dispatch testing, not inferred — the smallest justified change is
a capture-time preprocessing step keyed off `hyprctl`'s own `grouped`
field, not a new tree node type. Real pseudo-tiled windows, by contrast,
are a genuine, content-dependent risk exactly as `docs/RECONSTRUCTION.md`
predicted — `partition_tree()` never fabricated a wrong tree in any
pseudo-tiled case tried, always either succeeded correctly (mild shrink)
or failed cleanly to `None` (drastic shrink), meaning the existing
`unresolved`-fallback safety net is confirmed sufficient without needing
a pseudo-tiling-specific mechanism.

**Established from Gates 10-12**: mixing floating windows into the same
batch as a tiled tree works cleanly under one atomic dispatch, *provided*
floating windows are filtered out (via the already-existing
`meta.floating` flag) before anything reaches `partition_tree()` — confirmed
both as the correct path (works) and as load-bearing (feeding the mixed
set in directly returns `None`, a real negative control, not assumed).
Placing a tree into an occupied destination needs zero special-casing —
representative-leaf's unconditional first-step (`(representative(tree),
None, None)`) already matches `structureClauses()`'s existing
`previousMeta = null`-regardless-of-occupancy behavior exactly, confirmed
by reading the mechanism first, not by trial and error. Chaining multiple
batches onto one destination reproduces a real, pre-existing, non
-regressive property of the shipped code (confirmed by reading
`orderDescriptors()`/`finishRestore()` directly: `previousMeta` already
carries across batch boundaries today, unconditionally) — whichever leaf
a new batch's root attaches to necessarily gets further subdivided,
because that's how Dwindle itself works, not a flaw introduced by
switching to representative-leaf. No sliver, no collapse, no crash in
any of these — the existing "best-effort, never destructive" bar, not a
stronger one.

**One architectural note carried forward from this round of review,
worth remembering when the production plan gets written**: if
`LayoutTree`/representative-leaf expansion ends up replacing
`peelOrder()`/`previousMeta` as the normal path, the old *mechanism* can
disappear, but the old *safety principle* — fall back to natural,
unresolved Hyprland sizing rather than force a guess — must not. It just
gets re-triggered by `partition_tree()` returning `None` (now with actual
evidence behind that path) instead of by `isSeparated()` failing to peel.
This is also the standing interpretation for `None` itself: not an
exceptional software failure handled defensively as an afterthought, but
an expected, load-bearing safety result — the failure path is part of
the feature, not error handling bolted onto it.

**All fixtures from the feasibility doc, plus the two added mid-review
(F13, F14), are now closed.** Per GPT's own instruction: stop adding
experiments unless one of them exposes a new structural uncertainty —
none of F9-F12 did. See "Final evidence-based implementation plan" below
for what this adds up to and what's next.

**Deliberately not pursued**, matching both the feasibility doc's own
confidence ranking and my independent read of it (see the assistant's
prior message in this conversation for the reasoning): Approach C
(stash-time tree caching), Approach D (destructive decomposition during
stash), Approach E (special workspace as lossless tree storage). None of
the results above depend on any of them, and nothing found so far
motivates spending time on them.

## Final evidence-based implementation plan

Not yet built — this is the plan itself, written now that every gate
GPT's review named is closed, per the explicit instruction to produce it
before touching any production code. `docs/RECONSTRUCTION.md` has been
updated alongside this to describe the algorithm actually tested
(representative-leaf preorder expansion) rather than the untested
subtree-anchor design it previously described — read that document for
the idea/flow/function-level design; this section is the checklist of
what the evidence supports and what remains true unchanged.

**What gets replaced**: `peelOrder()`/`isSeparated()` as `orderDescriptors()`'s
normal reconstruction path, and the flat `previousMeta`-threaded loop in
`finishRestore()`/`finishMoveWorkspace()`. Both retired *as the default*,
not deleted outright — see fallback note below.

**What the replacement is, backed by evidence**:
1. **Group preprocessing** (new, small): before anything else, collapse
   each captured window using `hyprctl`'s own `grouped` field — one
   representative address per group, others dropped from what reaches
   the parser. (Gate 9, Gate 9-follow-up.)
2. **`partition_tree()`** (new, `experiments/partition.py`, to be ported
   into `Service.qml`): recursive guillotine-cut partitioning over the
   tiled subset only — floating windows excluded via the existing
   `meta.floating` flag before this step (Gate 10). Cross-axis span-match
   tolerance reuses the existing 40px `rowTolerance` constant, not a new
   one (Gate 9). Returns `None` on ungapped, non-guillotine, or malformed
   geometry rather than a wrong tree — verified, not hoped for (Gate 13,
   Gate 9, Gate 14).
3. **Representative-leaf preorder expansion** (new): walks the recovered
   tree, dispatching `structureClauses()`-shaped move/focus/preselect
   clauses exactly as today, just driven by a tree walk instead of a
   flat loop. (Gates 1, 5, 8.)
4. **Multi-batch chaining** (unchanged in shape): `previousMeta` — or its
   representative-leaf equivalent, whichever leaf a batch's expansion
   dispatched last — still carries across batch boundaries exactly as
   today. No new mechanism; same property, same limits (Gate 12).
5. **`partition_tree()` returning `None`**: triggers the *existing*
   `unresolved` → skip-absolute-resize → natural Hyprland sizing
   fallback, unchanged in destination (Gates 13, 9, 14).

**What stays exactly as-is, with evidence it doesn't need to change**:
`structureClauses()`, `geometryClauses()` (including `skipTiledResize`,
Gate 11), `preselectDirection()`, `clampToMonitor()`, floating-window
handling (Gate 10), cursor capture/restore (never touched by any gate —
every harness dispatch used the same `hl.dsp.*` primitives production
already wraps cursor restoration around), the single atomic
`hyprctl --batch` dispatch (Gates 10, 12), and stash membership/staleness
handling (`Hyprland.toplevels`-driven `pruneMeta()`, never touched).

**Explicitly not introduced**: persistence, polling, a daemon, a Rust or
any native helper, a `Group`/`SpatialGroup` tree node type. All
considered (Gate 9's evidence directly ruled out the node type; the
others were never indicated by anything found).

**Fallback posture during integration**: keep `peelOrder()` reachable
(not necessarily wired to anything) until the new path has passed a full
regression pass against real Hyprland — matching GPT's own instruction
and this project's existing "best-effort, never destructive" bar. Not
built yet; a decision for whenever implementation actually starts.

**Still explicitly not done, correctly**: no `Service.qml` edits. This
plan is the artifact this round of review asked for, not a green light
to start implementing — that's a separate decision for whenever it's
made.

## Adversarial re-check of the deprioritized approaches (C/D/E)

Before committing to Approach A in production, the two approaches that
had only ever been reasoned about — never tested — were deliberately
attacked, with explicit intent to falsify them against A's now-proven
bar (user's request: "attack D or E with intention to prove it won't
survive to the level of A"). Approach C wasn't attacked separately: it
isn't a different mechanism, it would reuse the exact same
`partition_tree()` already tested 128 times, just called at a different
moment — nothing new to falsify.

### Attacking Approach D (destructive decomposition during stash)

`experiments/attack_D_decomposition.py`. Targeted the core assumption
head-on: does removing one window from a live tree reveal a clean,
*local* parent/sibling relationship, the way the approach requires?

**Locality — held up, in both the easy and hard case.** Removed a leaf
whose sibling was a single window (`F4`, removing `D`): only its true
sibling `B` changed, `A`/`C` untouched. Removed a leaf whose sibling was
a whole *subtree*, not a single window (`F7`, removing `A`, sibling
`V(B,C)`): both `B` and `C` changed together (the promoted subtree),
everything in the unrelated right branch untouched. Both cases clean —
this assumption is more solid than the feasibility doc gave it credit
for.

**End-to-end correctness — also held up, once tested fairly.** A first
attempt stopped decomposition early (4 removals for a 6-window tree,
leaving 2 windows' relationship unrecorded) and predictably failed to
reconstruct one connected tree — not a finding, just an unfair test,
caught and corrected. Redone as a *full* decomposition (5 removals, down
to exactly one survivor, mixing simple-sibling and subtree-promotion
steps in one sequence): reversing the recorded steps correctly
reconstructed a single group spanning all 6 leaves. Caveat: this only
verifies *grouping* correctness (which leaves belong together), not full
V/H-axis-and-direction topology — a real implementation would need to
extract and record more from each diff than this test did, which makes
this a generous test of D, not a stacked one.

**Cost — first measurement was wrong, corrected below.** The original
pass through this section reported a **16.2 second**, **~1862×** cost
disadvantage and called it decisive. That number was **wrong** — not a
Hyprland limitation, a bug in the measurement itself, found and fixed
after the user asked to specifically dig into whether the settle time
could be improved. `remove_and_diff()` was calling `capture_rects()`
with the *full original* set of window titles at every step, including
ones already removed in earlier steps — since a removed window can never
reappear on `TEST_WS`, that function's internal polling loop spun until
its own 2-second timeout on almost every single call, every step. That
timeout, not genuine compositor settle time, was what "16.2 seconds"
actually measured.

Fixed (`experiments/measure_settle_time.py` first isolated it: a single
removal was already correct with **zero** added wait, 6/6 trials,
confirming Hyprland's reflow is complete by the time the dispatch call
returns — the real settle time is close to zero, not hundreds of
milliseconds) and re-measured properly
(`experiments/attack_D_decomposition.py`, zero-wait, correctness still
verified at every step):

| tree | removals | avg D time | avg A time | ratio |
|---|---|---|---|---|
| `F4` (4 windows) | 3 | 82.5ms | 8.9ms | 9.3× |
| `F7` (6 windows) | 5 | 123.2ms | 7.9ms | 15.5× |

Correctness held in every trial at both sizes, zero wait. The corrected
picture is materially different from the first pass: **D is genuinely
slower than A, and the gap grows linearly with window count** (D is
*N-1* IPC round-trips, A is O(1) regardless of size — confirmed
directly by the ~25ms-per-removal-step scaling above) — but in absolute
terms, for realistic stash batch sizes, that's tens to low hundreds of
milliseconds, not multiple seconds. This is not the kind of cost that
obviously disqualifies a UI action like "stash workspace" on its own.

**Corrected verdict: cost alone no longer decisively rules D out — the
real objections are architectural, not raw speed.** What still favors A,
honestly stated:

- **D still needs `stash()` to become a multi-step, sequential live
  operation** (N-1 move-and-capture round-trips), instead of today's
  single independent-move-per-window pass with no ordering dependency
  between steps. That's a real complexity and failure-surface increase
  (partial-decomposition state if interrupted, the docx's own
  unaddressed "window closes mid-decomposition" question) that A simply
  doesn't have, independent of wall-clock cost.
- **The cost gap still grows with window count**, and while sub-200ms
  is fine, this hasn't been tested at the tail (a stash of 15-20
  windows) where it could become perceptible.
- **This test only proved grouping correctness**, not full axis
  -and-direction topology recovery — a complete D implementation needs
  to extract more from each diff than this test did, which is
  unquantified added complexity on top of the timing numbers above.
- A is already fully proven end-to-end (128 runs, adversarial-tested,
  investigated across every realistic complication) with none of this
  residual complexity. D would still need all of that built and tested
  from scratch.

Net: D survived the cost attack far better than first (wrongly) reported
— worth recording honestly rather than leaving the original number
standing. It doesn't overtake A, but "prohibitively expensive" was never
the right reason; "meaningfully more complex for a smaller and shrinking
advantage" is.

### D, round two — the user's instruction to keep testing until it breaks
or wins, taken seriously

The above was the first correction. The user pushed further, on two
fronts: verify the speed hunch harder (transport, not algorithm, was
suspected as the real bottleneck), and stop stopping at grouping
-correctness — hold D to the *exact same* bar A was held to (Gate 2's
`repr()` match), not a weaker one, since D had not yet actually broken
under attack.

**Speed, chased to ground.** `experiments/hypr_socket.py`: talks to
Hyprland's own Unix socket (`$XDG_RUNTIME_DIR/hypr/$INSTANCE/.socket.sock`)
directly instead of shelling out to the `hyprctl` binary per call.
Measured directly: a raw `j/clients` query averages **0.13ms** against
that socket versus **6.0ms** through a `hyprctl` subprocess — process
-spawn overhead, not IPC or compositor latency, confirmed by a real
dispatch round-trip too (`0.34ms` raw vs the earlier `~7-9ms` subprocess
figures used everywhere else in this log). Re-ran the corrected D-vs-A
comparison on this fast transport, both sides, so the ratio stays fair:

| tree | D (raw socket) | A (raw socket) | ratio |
|---|---|---|---|
| `F4` (4 windows) | 5.51ms | 0.845ms | 6.5× |
| `F7` (6 windows) | 6.93ms | 0.892ms | 7.8× |

Per-removal-step cost dropped to **~1.4-1.8ms**. The user's hunch was
exactly right: the earlier "9-15×" (itself already a correction of the
first, badly wrong "1862×") was still substantially inflated by harness
transport overhead having nothing to do with the algorithm.

**Topology correctness, held to A's actual bar — broke twice more before
it actually passed, and both breaks were real, not cosmetic.** Extended
the reconstruction (`experiments/attack_D_full_topology.py`) to infer
axis (from which dimension of the compensating cluster's bounding box
changed) and direction (from the removed window's position relative to
the cluster) at each step, then rebuild an actual `Leaf`/`Split` tree and
compare its `repr()` to the known original — exactly Gate 2's own
correctness bar, not the weaker grouping-only check used before.

- **First attempt** rebuilt by processing the record in reverse (matching
  a literal reading of "restore replays the record reversed"). Wrong:
  that's true for *dispatch* order, not for how the abstract tree has to
  be assembled bottom-up. Silently merged the wrong groups on 3 of 4
  fixtures.
- **Second attempt**, processing forward, still failed: it assumed the
  *removed* window in any step is always a fresh leaf. Wrong — a window
  removed later in a sequence can have already silently absorbed an
  earlier sibling's freed space (it visibly expanded into that space when
  the earlier sibling left), so by the time it's removed itself it may
  already represent a whole subtree, not a single leaf.
- **Third issue, found live on `F4`'s 2×2 with removal order
  `[D,B,A]`**: even correct per-step bookkeeping isn't enough — removing
  `B` produces a compensating cluster `{A,C}` that are still two
  *separate* unmerged groups at that point, because `A` and `C`'s own
  sibling relationship only gets established by a *later* step. Fixed
  with a worklist that defers unresolvable steps and retries.
- **Fourth issue, found live on `F7`'s deep tree**: a plain retry-worklist
  can resolve a *later-recorded* step before an *earlier-recorded* one
  gets a chance at the same group, silently locking in a structurally
  wrong (but entirely plausible-looking) tree — confirmed concretely: `C`
  removing directly merged `{B,C}` with `{D,E}`, skipping `A` and `F`
  entirely, because both sides of that step happened to look
  "resolvable" before the earlier `F→{D,E}` and `A→{B,C}` steps got their
  turn. Fixed by restarting the scan from the beginning of the pending
  list after every successful merge, so earlier-recorded steps always
  get first claim on a newly-available group.

After all four fixes: **all 4 hand-picked fixtures passed with exact
`repr()` match**, then a stress pass
(`experiments/attack_D_stress.py`) — 5 *random* (not hand-picked)
removal orders each on 4-, 6-, and 8-window trees — **15/15 exact
matches**, no exceptions. Timing at the larger size: 8 windows averaged
**45.4ms** total (**6.5ms/step**, up from ~1.5ms/step at 4-6 windows —
real, not noise: consistent across all 5 trials at that size, likely
`raw_json("clients")` cost growing with total open-window JSON payload
size, worth knowing about but still small in absolute terms).

**Where this leaves D, honestly, after being tested as hard as A was**:
the correctness gap is closed — D now provably recovers exact topology,
not just grouping, verified against 19 total trials (4 fixed + 15
random) with zero failures once the reconstruction algorithm was
actually correct. The cost gap shrank from "disqualifying" to "single
-digit milliseconds, a few times slower than A, growing somewhat faster
than linearly at 8 windows." What's left, genuinely: `stash()` would
still need to become a multi-step sequential live operation instead of
today's single independent-move pass (real new failure surface — a
window closing mid-decomposition is still untested), and the
reconstruction algorithm that makes this work is meaningfully more
intricate than Approach A's `partition_tree()` — four real bugs deep
before it was actually correct, versus A's one bug (Gate 13's cross-axis
fix) found through deliberate adversarial testing. D did not break. It
also didn't win. It became a legitimate, fully-verified second option
whose remaining cost is architectural complexity, not speed or
correctness.

### D, round three — the discriminatory test series (does D buy anything
A can't do)

Round two left D and A "equally capable" on ordinary layouts — at that
point the honest tie-breaker was A's simplicity. GPT's next message
reopened the decision explicitly: run one final series aimed not at
"does D still work" but at "does D do something A structurally cannot."
Four tests, in priority order.

**Test 1 — D vs real pseudo-tiling (highest priority).** Reused Gate 14's
exact three scenarios (mild shrink, drastic shrink, drastic-shrink
-plus-extreme-ratio) — the cases where A necessarily loses the logical
slot and returns `None`. Ran D's full decomposition on the identical
live geometry, held to the same exact-`repr()` bar.

First pass: **3 of 4 sub-cases were exact matches where A safely
returned `None`** — a real functional advantage, mechanistically
explicable: D observes an actual *transition* (does window X's rect
change when its neighbor leaves), never needing to interpret a
pseudo-tiled window's own potentially-misleading static geometry as
primary evidence. But the 4th sub-case (`nested_mild_pseudo_C_alt_order`)
produced **exactly the dangerous outcome GPT named as the worst
possible result: D confidently reconstructed the wrong tree**
(`(A|(B/C))` known vs `(A|(B|C))` rebuilt — wrong axis).

Diagnosed precisely, not patched blindly: `infer_axis_and_direction()`
inferred axis from which dimension of the *compensating* window's
bounding box changed more — but a pseudo-tiled window doesn't resize to
fill a larger slot, it just re-centers within it. Confirmed directly:
removing `B`, `C`'s rect went from `(732,475,691,408)` to
`(732,259,691,408)` — **identical width and height, only the Y position
moved**. Both size deltas were zero, so the heuristic's tie-break
silently picked the wrong axis. Fixed with a strictly more robust
signal that doesn't depend on the surviving side resizing at all: compare
the *removed* window's position to the surviving cluster's position, in
the *before* snapshot alone (whichever axis they overlap most on is the
axis they're adjacent along) — well-defined regardless of what the
compensating side does afterward.

Re-ran with the fix: regression-checked against all previously-passing
fixtures (no change), then the full pseudo suite again —
**5/5 exact matches, including all 3 of Gate 14's `None` cases.** Clean
Outcome A, no remaining wrong-tree risk found. Files:
`experiments/attack_D_vs_pseudo.py`, fix landed in
`experiments/attack_D_full_topology.py`.

**Test 2 — D vs real groups.** Built `C | Group(A,B)` and a group
embedded inside a deeper tree (`X | (Group(A,B) / Y)`), using Gate 9's
already-proven group-collapse strategy (one representative address from
Hyprland's own `grouped` field, no geometric detection). First attempt's
setup itself was broken (grouping silently never took effect because `B`
was moved in with a bare, unpreselected move instead of being placed
properly adjacent first — the same setup mistake Gate 9 already warned
about, reproduced here as a reminder of how easy it is to get wrong).
Fixed the setup, re-ran: confirmed live that moving the representative
carries the whole group cleanly (`B`'s workspace correctly followed `A`
to the stash side every time), the diff correctly attributes the
parent/sibling relationship, and **exact topology recovered in both
cases**. The group's ~28px chrome offset did *not* confuse the new
before-only-overlap axis inference at all. One honesty check: A *also*
succeeds on this same geometry once its own already-known fix from Gate
9 is applied (`tol=40` instead of the default 20) — confirmed directly,
not assumed. So this test confirms D handles groups correctly, but isn't
a *new* advantage over A specifically; A already had this covered.
File: `experiments/attack_D_vs_groups.py`.

**Test 3 — mid-decomposition failure injection (the decisive safety
test).** D's real remaining objection was never speed or correctness by
this point — it's that `stash()` becomes a multi-step sequential live
operation. Attacked that directly: three scenarios, each killing a real
window process (not a clean move — simulating a user closing an app)
partway through a 6-window decomposition: the *next*-scheduled window,
an *unrelated remaining* window, and (hardest) a window that had
*already silently absorbed* two other windows' worth of compensation
history before being killed.

First run surfaced a real, independent design gap, not a
failure-injection artifact: the decomposition-as-designed only explicitly
moves *N-1* windows (one per diffing step) — **the final survivor was
never moved anywhere, left stranded on the source workspace** in every
scenario. Found live, not theoretical. Fixed with an explicit final
step: move whatever survives the diffing loop, unconditionally (skipped
only if that survivor is itself already gone).

With that fixed, across all three injected-failure scenarios:
**every single surviving window ended up safely accounted for** — either
correctly stashed, or (the intentionally-killed one) correctly and only
gone. Zero stranded, zero lost, zero corrupted state, confirmed by an
explicit audit of every window's final location, not inferred. Structural
reconstruction is a separable concern, exactly like Approach A's
`unresolved` fallback: in the two easier scenarios, a valid tree was
still reconstructed for every surviving window (with the killed window's
references filtered out of any recorded cluster) — the tree just
adapts sensibly around the gap (e.g. `D` and `E` pair directly once `F`
is gone, instead of via `F`). In the hardest scenario (killing a window
that had already absorbed a subtree), reconstruction correctly **failed
closed** for the specific relationship that depended on the lost
window's diff signal — a clean, safe error, not a wrong tree, and it
didn't corrupt anything unrelated. This directly answers GPT's framing:
physical safety and structural reconstruction can be treated as
separable in D's design too, the same way they already are in A's — D
doesn't need "complicated rollback/replay logic" for physical safety,
only for exact-topology completeness in the worst case, and it fails
safely there rather than needing it. File:
`experiments/attack_D_failure_injection.py`.

**Test 4 — large-N timing (12/16/20 windows).** This is where the
picture turns genuinely unfavorable for D, and matters as much as the
pseudo-tiling win. Per-step cost, which looked roughly flat at 1.4-1.8ms
for 4-6 windows (round two) and had already risen to 6.5ms at 8 windows,
**keeps climbing**:

| N | D total | D ms/step | A total | ratio |
|---|---|---|---|---|
| 12 | 99.2ms | 9.02ms | 1.00ms | 98.8× |
| 16 | 193.3ms | 12.88ms | 1.23ms | 156.8× |
| 20 | 281.5ms | 14.82ms | 1.94ms | 145.2× |

A stayed fast and correct throughout (all three sizes recovered the
correct tree). D's absolute cost (up to ~280ms at 20 windows) is
probably still tolerable for a "stash the whole workspace" action, but
the *trend* is the real finding: the ratio to A didn't stay near the
6-15× seen at small sizes, it grew roughly an order of magnitude further
by 16-20 windows. This is consistent with D's cost compounding two ways
at once — *both* the round-trip count (N-1) *and* the per-call JSON
payload (all currently-open windows, not just the test ones) grow with
N, while A pays the payload cost once and its actual partitioning stays
fast. Confirms GPT's suspicion directly rather than leaving it
unmeasured: this is real scaling, not noise, and it's the kind of thing
that would eventually matter for a power user with many windows stashed
at once. File: `experiments/attack_D_large_n.py`.

**Where this leaves the decision, honestly, against GPT's own rule**
("choose D only if it buys something concrete over A... strongest reason
would be exact topology on pseudo-tiled layouts AND simple, demonstrably
safe interruption handling"): **both conditions are now met.** D
recovers exact topology on pseudo-tiled layouts A cannot (5/5, after a
real bug was found and fixed). Interruption handling was demonstrated
safe, not just argued (19/19-style — every failure-injection scenario
ended with zero lost/stranded windows), at the cost of one extra
explicit step, itself a small, well-understood fix now that it's been
found. What's new and unresolved from this round: the large-N timing gap
is real, growing, and untested past 20 windows — a genuine cost D pays
that A does not, and it's the one open question that could still tip the
decision back toward A depending on how much window-count headroom this
project wants to guarantee.

### Attacking Approach E (special workspace as lossless tree storage)

`experiments/attack_E_special_workspace.py`. Two separate attacks.

**First, re-confirmed live** (this had only been established once,
earlier in the session, from reading Hyprland's C++ plugin headers —
worth re-checking directly rather than trusting memory): neither
`hyprctl -j clients` nor the richer Lua `hl.get_windows()` scripting API
exposes any tree/node/split/parent field — probed `parent`,
`splitRatio`, `dwindleNode`, `axis`, `children`, and others directly;
all `nil`. Only flat geometry is available anywhere. This means E's own
"decode" step, however it's implemented, can only ever be geometry-based
inference — the *same* mechanism A already uses, just pointed at a
different workspace. E does not avoid the problem A solves; it
relocates it.

**Second, and more decisive: tested E's actual distinguishing claim —
batch separability without metadata — and it failed directly, not
theoretically.** Gave E the most generous version of itself: assumed
`stash()` had been changed to deliberately encode structure onto the
stash workspace via the same proven representative-leaf technique
(today's real `stash()` does no such thing — it just moves each address
independently). Placed two different known trees (`A|(B/C)` and
`(D|E)/F`) onto one shared stash workspace this way, then tried to
decode with zero batch metadata, exactly as E's own success criterion
requires:

- `partition_tree()` on the full shared workspace: **`(A|(B/(C|((D|E)/F))))`**
  — one merged tree, with batch B's entire structure silently absorbed
  as a nested subtree inside batch A's. Not two separable trees; not a
  clean failure either — a single, plausible-looking, *wrong* tree.
- Destructive decode (pulling batch A's windows out one at a time, as a
  real `restore()` does) made this worse, not better: at every
  intermediate step, the remaining geometry still parsed to *some*
  coherent-looking tree — but each one kept conflating whatever was left
  of batch A with batch B's untouched structure, silently, every step.

**This is the dangerous failure mode, not the safe one.** Every gate run
against Approach A went out of its way to confirm the parser fails
*closed* — `None`, never a plausible wrong answer (Gates 13, 9, 14). Here,
tested directly, Approach E's core mechanism does the opposite: it always
produces *a* tree, and that tree is silently wrong the moment two batches
share the workspace, which is the exact scenario multi-batch stash
guarantees will happen. E would still need the batch metadata this
project already tracks (`batchId`) to work correctly — meaning it doesn't
even deliver its own stated headline benefit ("eliminating historical
structural metadata").

**Verdict: does not survive to the level of A — on correctness, and by a
wider margin than D.** Its inference mechanism gains nothing A doesn't
already have (confirmed: no real tree data exists to read), and its one
distinguishing claim, tested directly rather than assumed, produces
silently wrong trees in exactly the situation (multiple batches) the
project already knows happens routinely.

### What this round adds up to

Neither deprioritized approach was dismissed on reasoning alone. E was
tested against its own stated core claim and failed it outright:
produces confidently wrong, silently-merged trees the instant more than
one batch is involved, and gains nothing over A's own information source
(no real tree data exists anywhere to read). D was tested harder than
originally planned, at the user's explicit insistence ("if D/E were to
stand strong against the odds, test them deeper until it breaks or it
proves to be the new winner") — and it kept surviving. Final, fully
-verified state: cost is single-digit milliseconds on a fair transport
(6.5-7.8× A, not the originally-reported-in-error 1862×), and
correctness now matches A's own bar exactly — full tree topology, not
just grouping, verified on 19/19 trials including random (not
hand-picked) removal orders up to 8 windows. Getting there took four
real, found-live bugs in the reconstruction algorithm — documented in
detail above because the *sequence* of failures is informative about
what a correct D implementation actually has to handle, not just the
final fix.

D did not break under sustained, deliberate attack. It also did not
overtake A. What remains, honestly: `stash()` would still need to become
a multi-step sequential live operation (today it's a single independent
-move pass per window, with no ordering dependencies at all) — real new
failure surface (a window closing mid-decomposition is still untested),
and the reconstruction algorithm needed four bug-fix iterations to reach
correctness versus A's one (Gate 13's cross-axis fix). Both are now
legitimate, evidenced options; A remains the recommended default because
it's simpler and has a longer, more thoroughly adversarial track record
end-to-end (128 live runs plus the F9-F14 investigations), not because D
was shown to be worse. Files: `experiments/attack_D_decomposition.py`,
`experiments/attack_E_special_workspace.py`,
`experiments/measure_settle_time.py`,
`experiments/measure_settle_time_sequence.py`,
`experiments/hypr_socket.py`, `experiments/attack_D_fast.py`,
`experiments/attack_D_full_topology.py`,
`experiments/attack_D_stress.py` — all live-Hyprland except
`hypr_socket.py` itself, all safe to re-run, same isolation/cleanup
discipline as every other script in this directory.

## Chasing the large-N scaling hunch (event socket / scoped query)

Before committing to the hybrid architecture GPT proposed, the user
asked to validate the cheaper option first: could D's large-N cost
(Test 4 above) be substantially reduced, closer to the O(N) the
algorithm's shape suggests rather than the super-linear growth actually
measured (9.02 → 12.88 → 14.82 ms/step from 12 → 20 windows)?

**Hypothesis, precisely stated first**: the per-step capture
(`raw_json("clients")`) re-fetches and re-parses Hyprland's *entire
system* client list on every single step, not just the target
workspace's — so both the round-trip count (N-1) and the per-call
payload grow with N, compounding into worse-than-linear scaling.

**Investigated two mechanisms, both live, neither assumed:**

- Hyprland's event socket (`.socket2.sock`): confirmed it pushes real
  -time notifications (`movewindowv2>>address,workspaceid,name` etc.) —
  but only for workspace-membership changes, not intra-workspace
  geometry/reflow changes, which is exactly what D's diff needs to
  observe. Not useful for this specific problem.
- `hl.get_workspace_windows(ws)`: a Lua API call, found by enumerating
  `hl`'s members again (same technique as finding `window_rule`/
  `exec_cmd` earlier), that returns only the windows on one workspace.
  Confirmed it returns correct, matching data
  (`experiments/hypr_socket_scoped.py`) against the known-correct full
  -fetch capture. Also had to find the right way to *retrieve* its
  return value over the raw socket: `eval <code>` acks `"ok"` and
  discards the result; `repl <code>` returns it directly, same as the
  `hyprctl repl` CLI subcommand — not documented, found by trying both.

**Re-ran the large-N sweep on this scoped capture**
(`experiments/attack_D_scoped_large_n.py`), up to 30 windows:

| N | full-fetch (earlier) | scoped |
|---|---|---|
| 12 | 9.02ms/step | 10.53ms/step |
| 16 | 12.88ms/step | 9.36ms/step |
| 20 | 14.82ms/step | 9.93ms/step |
| 30 | *(not tested)* | 14.27ms/step |

**Real but partial win, and an honest surprise**: the growth curve did
flatten noticeably (12→20 windows stayed roughly 9-10.5ms/step instead
of climbing to 14.82ms) — the hypothesis about payload growth was
directionally correct. But the *floor* itself didn't drop to anything
close to the ~1.4-1.8ms/step seen at small N (4-6 windows) in round two
— scoping the query didn't unlock the improvement its own logic
predicted. Chased down why rather than accepting the mixed result:

**Isolated dispatch cost from capture cost directly**
(measured separately, 10 reps each, at N=4 and N=20): a plain `focus`
dispatch alone went from **1.53ms → 2.56ms** as N grew; the real
`window.move` dispatch used in actual decomposition went from **0.74ms
average → 3.83ms average**, with individual steps at N=20 ranging
wildly from 0.46ms to **13.11ms**. Meanwhile *both* capture methods
stayed fast throughout (well under 1.3ms even at N=20, full-fetch
included). **The capture side was never the dominant cost at these
sizes in this environment — the dispatch itself is**, and it grows with
N because moving a window and triggering Dwindle's reflow is a real
compositor-side operation whose cost scales with how many other windows
are involved in that reflow. This is not a transport-layer inefficiency
my query choice could fix; it's Hyprland doing real work.

**Conclusion on the speed hunch**: partially right, and worth having
tested rather than assumed either way. The *first* speed correction
(raw sockets over `hyprctl` subprocesses, round two) was a genuine,
large, transport-layer win — 1862× down to single digits — because that
really was avoidable process-spawn overhead. This *second* attempt
found a smaller, real, but bounded win (a flatter curve, not a lower
floor) because the remaining cost is compositor-side reflow, not query
overhead — not the same kind of problem, and not fixable the same way.
D's true floor at realistic window counts (10-15, per the user's own
estimate of what people actually use) looks like roughly 100-150ms of
unavoidable, mostly-compositor-side cost, not the few milliseconds an
O(N) read of already-fast operations would suggest.

**Why this matters for the hybrid decision**: it strengthens the case
for running D only as an escalation path, not unconditionally. A never
pays this cost at all (single capture, no live compositor round-trips).
D's cost floor, now understood precisely rather than hoped away, is a
real, load-bearing reason to keep it off the common path — exactly the
shape the hybrid GPT proposed already assumes.

## D's information-boundary attack: both sides pseudo-tiled

Requested before the seam integration test, attacking exactly the gap
flagged (but not tested) in the hybrid discussion: every earlier pseudo
-tiling win (Gates 14, and the pseudo discriminatory test) had one
pseudo leaf compensated by a *normal* neighbor that visibly resized. The
open question: does D's advantage survive when *neither* side
necessarily expands into the freed slot — both sides pseudo-tiled?

**Explicit constraint followed**: observe first, do not patch the
algorithm to make a fixture pass. `experiments/attack_D_dual_pseudo.py`
runs the *existing, unmodified* `decompose_full()`/
`infer_axis_and_direction()`/`rebuild_tree_from_full_record()` pipeline
against five fixtures, logging the raw before/after geometry and an
explicit per-window classification (moved / resized / moved+resized /
unchanged) for every remaining window at every step, before any
reconstruction is attempted.

**Fixtures**: `pseudo(A)｜pseudo(B)`; `A｜(pseudo(B)/pseudo(C))`;
`pseudo(A)｜(pseudo(B)/C)`; a 2×2-shaped tree with pseudo leaves on
opposite sides of the root split (`pseudo(A)｜(A/B)` and
`pseudo(C)｜(C/D)`); and dual-pseudo combined with an extreme split
ratio (`B` resized to ~85% before both `B` and `C` were pseudo-toggled).

**Result: 5/5 exact matches — Outcome A on every fixture, no
algorithm changes needed.** The mechanistic reason, visible directly in
the raw logs: Hyprland **re-centers a window within its slot whenever
the slot's bounds change, regardless of whether that window is itself
pseudo-tiled** — and that re-centering reliably produces an observable
position and/or size change. In every single step across all 5
fixtures, the window that was *actually* the compensating sibling showed
at least a position change (several also resized substantially — one
pseudo window's width went from 701px to 1406px, contradicting the
assumption from the single-pseudo tests that pseudo windows "don't
resize to fill a larger slot," which turns out to depend on which
dimension is changing, not on pseudo status generally). Every window
correctly logged `UNCHANGED` was one that legitimately wasn't part of
the relevant relationship (a different, unaffected branch) — never a
false negative on the window that should have compensated.

This directly refutes the caveat raised when the hybrid was first
discussed ("D's advantage may specifically depend on at least one
normal side") — at least for the topologies and pseudo-placements
tested here. Not claimed as exhaustive: a perfectly symmetric
before/after slot (where re-centering coincidentally produces zero
detectable shift) remains theoretically possible and untested, and only
2-3 leaf pseudo placements were tried, not deep chains of consecutive
pseudo leaves. But the specific, previously-unfounded worry that
motivated this test is now answered with direct evidence, not
reasoning. File: `experiments/attack_D_dual_pseudo.py`.

## Seam integration test — the real hybrid orchestration, not A and D in isolation

Everything above tested A and D as separate mechanisms. This is the first
test of the actual *seam* — one `hybrid_stash()` orchestration
(`experiments/seam_integration_test.py`), shaped the way a real
`Service.qml` implementation would be: fresh capture → try A →
escalate to D only on `None` → restore always through the same
representative-leaf backend regardless of which path produced the tree.
Three paths, run via `experiments/run_seam_test.py`.

**Path 1 — A succeeds, D must never run.** A known 6-window deep tree,
ordinary geometry. `used_D: False`, `d_steps: 0` — confirmed by
instrumentation counting actual D steps taken, not inferred from timing.
Simple independent-move stash (today's real behavior), full restore via
representative-leaf, exact topology match. **4.17-5.39ms end-to-end**
across runs (this is `capture_rects` + `partition_tree` + N independent
move dispatches + restore — realistic full-path latency, not just the
parse-alone numbers quoted earlier).

**Path 2 — A fails, D escalation *is* the stash.** First attempt used
the wrong fixture (nested-branch mild pseudo shrink, which — per Gate 14
— is a case A already handles correctly) and predictably showed
`used_D: False` where `True` was expected: a fixture-selection mistake,
caught immediately by the instrumentation itself, not a finding about
the orchestration. Corrected to the confirmed-`None` case (simple 2-way
split, pseudo-toggled leaf, no normal sibling to lean on): `used_D:
True`, one D step, and — the specific thing GPT flagged as important —
**the destructive move that discovers the sibling relationship is the
literal same dispatch that stashes the window**, not a probe followed by
a separate stash pass. Exact topology restored. **2.72ms** end-to-end
for this small case (the D escalation path's cost scales with batch
size the way Test 4 already characterized — this fixture was
deliberately small to isolate correctness of the seam itself, not to
re-measure scaling).

**Path 3 — escalation with a real kill mid-flight.** Same 6-window tree
as Path 1, pseudo-toggled to force A's failure, escalated to D, and `B`
killed (real `SIGTERM`, not a clean move) partway through — reusing the
failure-tolerance and final-survivor-move fixes found in the earlier
discriminatory test, now exercised through the actual orchestration
rather than a standalone script. Full address audit: **zero
unaccounted-for addresses** — `A`, `C`, `D`, `E`, `F` all correctly
stashed, `B` correctly and only closed. Reconstruction for the 5
survivors succeeded (`((A/C)|((D|E)/F))`), and those 5 restored
correctly. Confirms the safety property holds through the *actual* seam,
not just the isolated decomposition loop.

**All three paths pass.** The seam itself introduced no new problem —
every fix found in earlier, narrower tests (final-survivor move,
failure-tolerant missing-window detection, filtered reconstruction)
carried over cleanly into the real orchestration shape without needing
anything new. Per GPT's instruction, this is the stopping point for
experiments unless the seam itself had revealed something new — it
didn't, so the next section is the two concrete production alternatives,
not further testing.

## Two concrete production alternatives: Hybrid vs D-only

Grounded in the actual `Service.qml` functions (re-read directly for
this, not recalled), not abstract algorithm comparison, per GPT's
explicit instruction. One correction made *before* writing this,
because it changes the real cost picture: Quickshell ships a QML-native
`Socket` type (`quickshell/src/io/socket.hpp`, same `DataStream` base
class `StdioCollector` already uses in this file) — a raw Unix socket
client. The fast IPC transport this session built in Python
(`experiments/hypr_socket.py`) is therefore **not** a new native
dependency for production — it's an existing Quickshell primitive this
project hasn't used yet, not a "second IPC stack" requiring new C++.
It's still new *pattern* surface, though: nothing in this codebase talks
to Hyprland's raw socket protocol today (every existing `Process` block
shells out to the `hyprctl` binary), and that raw protocol is
undocumented — its exact framing (`j/<query>` for JSON, `dispatch
<expr>`, `repl <code>` returning a value where `eval` doesn't) was only
ever discovered this session through direct experimentation, not
Hyprland's own docs.

**The real architectural cost, surfaced only by actually thinking through
`Service.qml`, not Python**: every `Process` in this codebase today
(`stashCaptureProcess`, `moveCaptureProcess`, etc.) is asynchronous —
fire, then react to `onExited`. There is no blocking call anywhere in
this file, by design (`QProcess` under Quickshell's hood is inherently
async). D's live decomposition loop needs N sequential
capture-dispatch-capture steps, each depending on the previous one's
result — in Python this was a trivial blocking `for` loop; in real
`Service.qml` it requires either a chain of N `Process`/`Socket`
callbacks (manual continuation-passing, verbose) or a small new
queue-based step-sequencer abstraction. **This exists identically in
both alternatives below** — it is not a hybrid-specific cost, it's a
D-specific one, paid in full the moment D is used at all.

### Alternative A — Hybrid (A-first, D-on-`None`)

| Piece | Status | Notes |
|---|---|---|
| `partitionTree()` | New, ~80-100 lines | Direct port of `experiments/partition.py`; pure function, no Process/Socket involvement, cheapest piece to port and the only piece already fully proven end-to-end (128 live runs + 15 synthetic) |
| `collapseGroups(descriptors)` | New, ~20-30 lines | Reads the existing `grouped` field from the same capture already happening; small |
| Representative-leaf tree-walk driver | New, ~40-60 lines | Replaces `finishRestore()`/`finishMoveWorkspace()`'s flat `previousMeta` loop; same clause vocabulary (`structureClauses()`) either way |
| D's async step-sequencer | New, ~80-150 lines | Only exercised when `partitionTree()` returns `None`; net-new infrastructure for this codebase either way |
| D's axis/direction inference + worklist reconstruction | New, ~120-160 lines | The single most bug-prone piece found this session (4 real bugs before correct); ported from `experiments/attack_D_full_topology.py` |
| `finishStash()` | Modified | Gains a branch: `partitionTree()` succeeds → **today's exact code, unchanged, zero new cost** → simple independent-move loop; `None` → hand off to the sequencer |
| `structureClauses()`, `geometryClauses()`, `preselectDirection()`, `clampToMonitor()`, cursor handling, `skipTiledResize` | Unchanged | Confirmed unchanged and correct under every condition tested (Gates 10, 11; seam Path 1-3) |
| **Estimated new/changed surface** | **~350-450 lines** | Touches `stash()`'s call graph and both restore paths; A's simple path is provably untouched when it succeeds (seam Path 1: `d_steps: 0`, instrumented, not assumed) |

### Alternative B — D-only

Removes `partitionTree()`/`collapseGroups()`-as-a-first-line-filter, but
**every other piece above is still required** — the sequencer, the axis
inference, the worklist reconstruction, all identical. The only code
genuinely *saved* versus the hybrid is the ~100-130 lines of
`partitionTree()` + wiring — and even that's arguably still worth
keeping around as validation tooling (D's own group/pseudo/attack test
suites all cross-check against it).

What's *not* saved, and is the real problem with this option: **every
stash operation, including the simplest 2-window split A already solves
perfectly, now pays D's sequencer + N sequential live round-trips.**
Seam Path 1's 6-window ordinary tree took 4-5ms end-to-end through A;
the same tree through D's mechanism (Test 4, scaled down) would cost
tens of milliseconds at minimum, for a case that gains nothing from the
extra work — A's tree was already exactly correct.

### Comparison, against GPT's four stated criteria

- **Implementation complexity**: roughly equal in raw surface — D-only
  doesn't meaningfully shrink the code, it just removes the (small,
  cheap, already-fully-proven) fast path guarding it. The hard, bug
  -prone 60% of the surface (sequencer + reconstruction) is identical
  either way.
- **Maintainability**: hybrid means two coexisting mental models (read a
  snapshot vs. interpret a live sequence) — a real, honest cost GPT's
  own brief already named. But D-only doesn't remove that model, it just
  makes it the *only* one, without gaining A's much smaller, much more
  thoroughly-proven surface as an offsetting simplicity anywhere in the
  system. One model, but it's the harder one, used unconditionally.
- **Behavioral completeness**: identical between the two — both recover
  pseudo-tiled layouts A cannot (proven, 5/5 including dual-pseudo).
  A-only alone would not.
- **Normal-path latency**: this is where they diverge sharply. Hybrid
  preserves A's existing, already-shipped-quality speed for the common
  case (seam Path 1, instrumented at `d_steps: 0`). D-only pays the
  sequencer + live round-trip cost on *every* stash, unconditionally,
  including the ordinary cases that make up the overwhelming majority of
  real usage — a real, user-facing regression with no corresponding
  benefit for those cases.

**Recommendation: Hybrid.** D-only's only advantage — avoiding two
mental models — doesn't actually materialize, because D-only still
needs the exact same hard machinery, and gives up A's proven cheap path
for the common case in exchange for nothing. The "two engines for minor
ms improvements" concern that motivated this question is answered by the
numbers themselves: it was never about ms improvements — A's path stays
essentially free (seam-tested, not estimated), and D is reserved
strictly for the case (pseudo-tiling) A structurally cannot solve at
all. That is a capability trade, not a speed one.

## Reproducing this

```bash
cd experiments
python3 gate1_representative_leaf.py    [repeats]   # default 3, live Hyprland
python3 gate2_geometry_partition.py     [repeats]   # default 3, live Hyprland
python3 gate13_adversarial_geometry.py              # synthetic, no Hyprland needed
python3 gate5_orientation.py            [repeats]   # default 2, live Hyprland
python3 gate8_extreme_ratios.py         [repeats]   # default 2, live Hyprland
```

The two live-Hyprland scripts are idempotent and safe to re-run — they
only ever touch `special:swx-hold`/`special:swx-test`, clean up after
every fixture (kill by exact PID), and print a per-fixture and overall
pass/fail summary. Gate 13 touches nothing outside the Python process.
Exit code is `0` iff every case passed.
