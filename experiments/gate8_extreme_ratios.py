#!/usr/bin/env python3
"""
Gate 8 (feasibility doc F8): extreme split ratios, using real live
Hyprland resizing -- not fabricated geometry (Gate 13's synthetic
extreme_ratio_90_10 already covered the synthetic side of this; this is
the same question against real Dwindle resize/compensation behavior).

Method: build a known tree at its default near-even split (Gate 1
territory), capture that as a baseline to learn the real working-area
dimensions, then fire one absolute-resize batch (mirroring
geometryClauses()'s own resize-only, position-untouched pattern for
tiled windows) pushing SEVERAL different windows -- at different nesting
depths -- to extreme sizes at once, deliberately leaving their siblings
unresized so Dwindle has to compensate them itself. Capture what
actually happened (never assume the target ratio landed exactly), then
run partition_tree() on the real resulting geometry.

Pass criterion, per the doc: this is about topology, not ratio precision.
partition_tree() must recover the SAME leaf grouping as the known tree
despite the extreme skew -- exact final sizing remains the separate,
already-proven geometry pass's job, not this gate's.
"""
import sys
import time

from harness_common import (
    HOLD_WS, TEST_WS,
    ensure_rule, spawn_named, kill_workspace,
    Leaf, Split, place_tree, capture_rects, bbox, fire_resizes,
)
from partition import normalize, partition_tree

F8_2X2 = Split("V", Split("H", Leaf("A"), Leaf("B")), Split("H", Leaf("C"), Leaf("D")))
F8_DEEP = Split(
    "V",
    Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
    Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
)


def resize_plan_2x2(baseline, addr_of):
    x0, y0, w, h = bbox(baseline, ["A", "B", "C", "D"])
    return [
        (addr_of["A"], 0.85 * w, 0.80 * h),  # root V-skew (A's column width) + A/B H-skew
        (addr_of["C"], 0.15 * w, 0.20 * h),  # other column's width + opposite C/D H-skew
    ], (w, h)


def resize_plan_deep(baseline, addr_of):
    x0, y0, w, h = bbox(baseline, ["A", "B", "C", "D", "E", "F"])
    return [
        (addr_of["A"], 0.5 * w, 0.85 * h),   # A/{B,C} H-skew, left column
        (addr_of["B"], 0.9 * (0.5 * w), 0.5 * h),  # B/C V-skew, nested two levels deep
        (addr_of["F"], 0.5 * w, 0.85 * h),   # {D,E}/F H-skew, right column, opposite side
    ], (w, h)


FIXTURES = {
    "F8_2x2_nested_extreme": (F8_2X2, resize_plan_2x2),
    "F8_deep_nested_extreme": (F8_DEEP, resize_plan_deep),
}


def measure_skew(rects, node, path=""):
    """Prints the actual measured ratio at every internal split, so a run
    can be inspected for whether real extremity was achieved, not assumed."""
    if isinstance(node, Leaf):
        return
    b1 = bbox(rects, node.first.leaves())
    b2 = bbox(rects, node.second.leaves())
    if node.axis == "V":
        total = b1[2] + b2[2]
        ratio = b1[2] / total if total else 0
    else:
        total = b1[3] + b2[3]
        ratio = b1[3] / total if total else 0
    print(f"      split[{path or 'root'}] axis={node.axis} first_share={ratio:.2f}")
    measure_skew(rects, node.first, path + ".first")
    measure_skew(rects, node.second, path + ".second")


def run_fixture(name, tree, resize_plan_fn, run_idx):
    leaf_names = tree.leaves()
    tag = f"{name}-r{run_idx}"

    addr, titles = spawn_named(leaf_names, tag)
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}
    baseline = capture_rects(title_to_name, TEST_WS)

    if set(baseline) != set(leaf_names):
        print(f"  [{tag}] FAIL: baseline capture incomplete")
        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)
        return False

    plan, (w, h) = resize_plan_fn(baseline, addr)
    fire_resizes(plan)
    time.sleep(0.4)

    final = capture_rects(title_to_name, TEST_WS)
    if set(final) != set(leaf_names):
        print(f"  [{tag}] FAIL: post-resize capture incomplete")
        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)
        return False

    print(f"  [{tag}] measured skew after resize:")
    measure_skew(final, tree)

    R = normalize(final)
    recovered = partition_tree(set(leaf_names), R)

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    time.sleep(0.15)

    if recovered is None:
        print(f"  [{tag}] FAIL: partition_tree() could not recover a tree from the skewed geometry")
        return False

    known_repr = repr(tree)
    recovered_repr = repr(recovered)
    ok = known_repr == recovered_repr
    status = "PASS" if ok else "FAIL"
    print(f"  [{tag}] {status}  known={known_repr}  recovered={recovered_repr}")
    return ok


def main():
    ensure_rule()
    repeats = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    results = {}
    for name, (tree, plan_fn) in FIXTURES.items():
        print(f"=== {name} ===")
        outcomes = [run_fixture(name, tree, plan_fn, i) for i in range(repeats)]
        results[name] = outcomes
        print(f"  -> {sum(outcomes)}/{len(outcomes)} passed")

    print("\n=== summary ===")
    all_ok = True
    for name, outcomes in results.items():
        ok = all(outcomes)
        all_ok = all_ok and ok
        print(f"  {name}: {'PASS' if ok else 'FAIL'} ({sum(outcomes)}/{len(outcomes)})")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
