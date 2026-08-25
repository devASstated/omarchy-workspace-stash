#!/usr/bin/env python3
"""
Completes the gap flagged in every earlier D test: correctness was only
ever checked at the GROUPING level (which leaves end up together), never
full axis+direction topology -- the same bar Approach A was held to in
Gate 2 (exact repr() match against the known tree). This closes that gap:
infers axis (V/H) and direction (which side the removed window was on)
from each step's before/after geometry, builds an actual Leaf/Split tree
from the reversed decomposition record, and compares its repr() to the
known original -- not just "did the leaves end up in one group."
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, bbox,
)
from hypr_socket import raw_json, raw_dispatch


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def infer_axis_and_direction(removed_rect_before, cluster_bbox_before, cluster_bbox_after):
    """Returns (axis, removed_is_first) -- removed_is_first means the
    removed window occupies the canonical "first" slot (left for V, top
    for H) relative to the surviving cluster.

    First version compared the cluster's bbox before vs. after (which
    dimension grew more) -- broke on a real pseudo-tiled window: it
    doesn't resize to fill a taller/wider slot at all, it just re-centers
    within it, so both size deltas can be zero even though the window
    plainly moved. That produced a wrong-but-confident axis (found live,
    F2 case, nested pseudo-tiled leaf -- see docs/RECONSTRUCTION-EXPERIMENTS.md).

    Fixed to use a strictly more robust signal that doesn't depend on the
    surviving side resizing at all: the removed window's position
    RELATIVE TO the cluster, in the BEFORE snapshot alone -- whichever
    axis they overlap on the MOST is the axis they're adjacent along
    (stacked windows share x-range, side-by-side windows share y-range).
    This is well-defined regardless of what the surviving side does
    afterward, so it isn't fooled by a compensating window that just
    repositions instead of resizing."""
    rx, ry, rw, rh = removed_rect_before
    cx, cy, cw, ch = cluster_bbox_before
    x_overlap = min(rx + rw, cx + cw) - max(rx, cx)
    y_overlap = min(ry + rh, cy + ch) - max(ry, cy)
    if x_overlap >= y_overlap:
        # significant horizontal overlap -> stacked vertically -> H split
        axis = "H"
        removed_is_first = ry < cy
    else:
        # significant vertical overlap -> side-by-side -> V split
        axis = "V"
        removed_is_first = rx < cx
    return axis, removed_is_first


def decompose_full(tree, addr, all_names, title_to_name, removal_order):
    """Like naive_decompose(), but records enough (axis, direction) at
    each step to rebuild an actual Leaf/Split tree, not just a grouping."""
    remaining = list(all_names)
    record = []
    prior = capture_rects_fast(title_to_name, TEST_WS)
    for name in removal_order:
        removed_rect = prior[name]
        still_remaining = [n for n in remaining if n != name]
        raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
        live_titles = {t: n for t, n in title_to_name.items() if n in still_remaining}
        after = capture_rects_fast(live_titles, TEST_WS)
        changed = [n for n in still_remaining if prior.get(n) != after.get(n)]

        if changed:
            cluster_before = bbox(prior, changed)
            cluster_after = bbox(after, changed)
            axis, removed_is_first = infer_axis_and_direction(removed_rect, cluster_before, cluster_after)
        else:
            axis, removed_is_first = None, None

        record.append((name, changed, axis, removed_is_first))
        remaining.remove(name)
        prior = after
    return record


def rebuild_tree_from_full_record(record, all_names):
    """node[frozenset] = the Leaf/Split subtree currently representing
    that group of leaves.

    Two earlier attempts and why they broke, kept as history because the
    failures are informative about Approach D's real shape, not just bugs
    to silently erase:

    1. Processed the record in reverse order (on the assumption that
       "restore replays the record reversed" -- true for DISPATCH order,
       not for how the abstract tree has to be assembled bottom-up).
       Silently merged the wrong groups.
    2. Processed forward, but treated `removed` as always a fresh Leaf --
       broke because a window removed LATER may have already silently
       absorbed an EARLIER sibling's space (it expanded into that space
       when the earlier sibling left), so it can itself already represent
       a built subtree, not a single leaf, by the time it's removed.

    This third version fixes a THIRD, more fundamental issue forward
    -order processing alone can't handle: a compensating cluster can span
    TWO STILL-SEPARATE groups if the chosen removal order didn't happen
    to establish their relationship yet (e.g. removing the "outer" pair
    before the "inner" pair that a LATER step would otherwise link) --
    confirmed live, not hypothetical (F4's 2x2 with removal order
    [D,B,A]: removing B produces a compensating cluster {A,C} that are
    still two separate groups, because A and C's own sibling
    relationship only gets recorded by the LATER step that removes A).
    Fixed with a worklist/fixpoint pass: repeatedly process whichever
    still-pending steps have become resolvable (their whole cluster now
    belongs to one group), skip the rest, repeat until nothing more
    resolves or every step is done."""
    node = {frozenset([n]): Leaf(n) for n in all_names}
    group_of = {n: frozenset([n]) for n in all_names}

    # Third refinement, found by hand-tracing a real failure (F7_deep):
    # a plain worklist that processes ANY resolvable step, in whatever
    # order it scans them, can resolve a LATER-recorded step before an
    # EARLIER-recorded one gets a chance at the same group -- even though
    # the earlier one, discovered when more of the tree was still intact,
    # has the rightful first claim. Concretely: once {D,E} became one
    # group, a later step ("removing C changes E") was just as
    # "resolvable" as an earlier one ("removing F changes D,E") that was
    # SUPPOSED to consume {D,E} first by pairing it with F -- letting the
    # later one go first merged {B,C} directly with {D,E}, skipping F and
    # A entirely, producing a structurally wrong (but plausible-looking)
    # tree. Fixed by restarting the scan from the BEGINNING of the
    # pending list after every successful merge, so earlier-recorded
    # steps always get first claim on a newly-available group.
    pending = list(record)
    i = 0
    while pending:
        if i >= len(pending):
            return None, f"stuck: {len(pending)} step(s) never became resolvable: {pending}"
        removed, changed, axis, removed_is_first = pending[i]
        if not changed or axis is None:
            return None, f"step removing {removed}: no valid compensating info"
        changed_groups = set(group_of[c] for c in changed if c in group_of)
        removed_key = group_of[removed]
        if len(changed_groups) != 1 or next(iter(changed_groups)) == removed_key:
            i += 1
            continue
        sibling_key = next(iter(changed_groups))
        sibling_node = node[sibling_key]
        removed_node = node[removed_key]
        if removed_is_first:
            new_node = Split(axis, removed_node, sibling_node)
        else:
            new_node = Split(axis, sibling_node, removed_node)
        new_key = sibling_key | removed_key
        node[new_key] = new_node
        for m in new_key:
            group_of[m] = new_key
        del pending[i]
        i = 0  # restart: give earlier-recorded steps first claim on the newly-available group

    final_key = frozenset(all_names)
    return node.get(final_key), None


def main():
    ensure_rule()

    fixtures = {
        "F4_2x2": (
            Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D"))),
            ["D", "B", "A"],
        ),
        "F7_deep": (
            Split("V", Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))), Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F"))),
            ["F", "D", "A", "B", "C"],
        ),
        "F2_caterpillar": (
            Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C"))),
            ["C", "B"],
        ),
        "F3_caterpillar": (
            Split("V", Split("H", Leaf("A"), Leaf("B")), Leaf("C")),
            ["A", "B"],
        ),
    }

    all_ok = True
    for name, (tree, order) in fixtures.items():
        names = tree.leaves()
        addr, titles = spawn_named(names, f"topo-{name}")
        place_tree(tree, addr, TEST_WS)
        time.sleep(0.3)
        title_to_name = {v: k for k, v in titles.items()}

        record = decompose_full(tree, addr, names, title_to_name, order)
        rebuilt, err = rebuild_tree_from_full_record(record, names)

        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)

        if err:
            print(f"{name}: FAIL -- {err}")
            all_ok = False
            continue

        known_repr, rebuilt_repr = repr(tree), repr(rebuilt)
        ok = known_repr == rebuilt_repr
        all_ok = all_ok and ok
        print(f"{name}: {'PASS' if ok else 'FAIL'}  known={known_repr}  rebuilt={rebuilt_repr}")

    print(f"\n{'ALL PASSED' if all_ok else 'SOME FAILED'}")


if __name__ == "__main__":
    main()
