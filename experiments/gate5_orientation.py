#!/usr/bin/env python3
"""
Gate 5 (feasibility doc F5): mirrored / rotated tree variants, live.

A real gap in Gates 1-2: every fixture they ran used the same canonical
direction convention (direction_for()'s default: V -> second lands right
of first, H -> second lands below first). Nothing so far has ever told
Hyprland to preselect "l" or "u" at all. F5 closes that -- for each of
F4 (2x2) and F7 (two independently-deep branches), build all four
orientations (normal, left-right mirror, top-bottom mirror, 180-degree
rotation = both) via harness_common's flip_v/flip_h, driven straight
through Gate 1's proven representative-leaf expansion.

Two things get checked per run, not just adjacency (Gate 1's check_split
would pass regardless of which side each subtree landed on -- it isn't
strong enough to catch "the mirror silently didn't happen"):

  1. orientation: the correct SIDE, not just adjacency -- first-subtree's
     bbox is actually left/right (or top/bottom) of second-subtree's,
     matching the requested flip.
  2. round trip (matching the doc's own F5 pass criterion): discard the
     known tree, recover one from the built geometry via partition_tree(),
     replay it fresh, confirm the same per-window spatial result --
     i.e. Gate 2's methodology applied to every orientation, not just the
     one direction convention Gate 2 happened to test.
"""
import sys
import time

from harness_common import (
    HOLD_WS, TEST_WS,
    ensure_rule, spawn_named, kill_workspace,
    Leaf, Split, place_tree, capture_rects, bbox,
)
from partition import normalize, partition_tree

F4 = Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D")))
F7 = Split(
    "V",
    Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
    Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
)

ORIENTATIONS = {
    "normal": (False, False),
    "left_right_mirror": (True, False),
    "top_bottom_mirror": (False, True),
    "180_rotation": (True, True),
}

FIXTURES = {
    "F5_2x2": F4,
    "F5_deep_branches": F7,
}


def check_oriented(node, rects, flip_v, flip_h, tol=20):
    if isinstance(node, Leaf):
        return True, []
    b1 = bbox(rects, node.first.leaves())
    b2 = bbox(rects, node.second.leaves())
    x1, y1, w1, h1 = b1
    x2, y2, w2, h2 = b2
    ok, msgs = True, []
    if node.axis == "V":
        if abs(h1 - h2) > tol:
            ok = False
            msgs.append(f"V-split height mismatch: {h1} vs {h2}")
        gap = min(abs((x1 + w1) - x2), abs((x2 + w2) - x1))
        if gap > tol:
            ok = False
            msgs.append(f"V-split not adjacent: gap={gap}")
        expect_first_right_of_second = flip_v
        actually_right = x1 > x2
        if expect_first_right_of_second != actually_right:
            ok = False
            msgs.append(f"orientation wrong: flip_v={flip_v} but x1={x1} x2={x2}")
    else:
        if abs(w1 - w2) > tol:
            ok = False
            msgs.append(f"H-split width mismatch: {w1} vs {w2}")
        gap = min(abs((y1 + h1) - y2), abs((y2 + h2) - y1))
        if gap > tol:
            ok = False
            msgs.append(f"H-split not adjacent: gap={gap}")
        expect_first_below_second = flip_h
        actually_below = y1 > y2
        if expect_first_below_second != actually_below:
            ok = False
            msgs.append(f"orientation wrong: flip_h={flip_h} but y1={y1} y2={y2}")
    ok1, m1 = check_oriented(node.first, rects, flip_v, flip_h, tol)
    ok2, m2 = check_oriented(node.second, rects, flip_v, flip_h, tol)
    return ok and ok1 and ok2, msgs + m1 + m2


def rects_match(r1, r2, tol=20):
    msgs = []
    for name in r1:
        x1, y1, w1, h1 = r1[name]
        x2, y2, w2, h2 = r2.get(name, (None,) * 4)
        if x2 is None:
            msgs.append(f"{name}: missing after replay")
            continue
        if abs(x1 - x2) > tol or abs(y1 - y2) > tol or abs(w1 - w2) > tol or abs(h1 - h2) > tol:
            msgs.append(f"{name}: built={r1[name]} replayed={r2[name]}")
    return (len(msgs) == 0), msgs


def run_case(fixture_name, tree, orient_name, flip_v, flip_h, run_idx):
    leaf_names = tree.leaves()
    tag = f"{fixture_name}-{orient_name}-r{run_idx}"

    addr_a, titles_a = spawn_named(leaf_names, tag + "-a")
    place_tree(tree, addr_a, TEST_WS, flip_v=flip_v, flip_h=flip_h)
    time.sleep(0.4)
    title_to_name_a = {v: k for k, v in titles_a.items()}
    rects_a = capture_rects(title_to_name_a, TEST_WS)

    if set(rects_a) != set(leaf_names):
        print(f"  [{tag}] FAIL: capture incomplete: {rects_a.keys()} vs {leaf_names}")
        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)
        return False

    orient_ok, orient_msgs = check_oriented(tree, rects_a, flip_v, flip_h)

    kill_workspace(TEST_WS)
    time.sleep(0.15)

    R = normalize(rects_a)
    recovered = partition_tree(set(leaf_names), R)
    if recovered is None:
        print(f"  [{tag}] FAIL: partition_tree() could not recover a tree from this orientation")
        kill_workspace(HOLD_WS)
        return False

    addr_b, titles_b = spawn_named(leaf_names, tag + "-b")
    place_tree(recovered, addr_b, TEST_WS)  # replay in canonical orientation -- round trip only needs the SAME result, not the same build directions
    time.sleep(0.4)
    title_to_name_b = {v: k for k, v in titles_b.items()}
    rects_b = capture_rects(title_to_name_b, TEST_WS)

    replay_ok, replay_msgs = rects_match(rects_a, rects_b)

    ok = orient_ok and replay_ok
    status = "PASS" if ok else "FAIL"
    print(f"  [{tag}] {status}  orientation_ok={orient_ok} replay_ok={replay_ok}")
    for m in orient_msgs + replay_msgs:
        print(f"      - {m}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    time.sleep(0.15)
    return ok


def main():
    ensure_rule()
    repeats = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    results = {}
    for fixture_name, tree in FIXTURES.items():
        for orient_name, (flip_v, flip_h) in ORIENTATIONS.items():
            key = f"{fixture_name}-{orient_name}"
            print(f"=== {key} ===")
            outcomes = [run_case(fixture_name, tree, orient_name, flip_v, flip_h, i) for i in range(repeats)]
            results[key] = outcomes
            print(f"  -> {sum(outcomes)}/{len(outcomes)} passed")

    print("\n=== summary ===")
    all_ok = True
    for key, outcomes in results.items():
        ok = all(outcomes)
        all_ok = all_ok and ok
        print(f"  {key}: {'PASS' if ok else 'FAIL'} ({sum(outcomes)}/{len(outcomes)})")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
