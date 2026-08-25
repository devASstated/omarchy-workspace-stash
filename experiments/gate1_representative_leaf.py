#!/usr/bin/env python3
"""
Gate 1 (docs/workspace_stash_reconstruction_feasibility_plan.docx §8 Gate 1,
§4 Approach B): can Hyprland be driven, via the same hl.dsp.* dispatch
vocabulary Service.qml already uses (window.move / focus / layout
preselect), to build an arbitrary, manually-authored binary V/H tree,
deterministically, using "representative-leaf" preorder expansion? No
geometry parsing involved here at all -- that's Gate 2, which depends on
this one having passed first.

See harness_common.py's module docstring for the shared spawn/cleanup
mechanics and why they're safe to run against a live desktop.

Result (2026-08-25, this machine, Hyprland 0.56.2): 40/40 runs passed
across F1-F4 (two-way split, both caterpillar directions, and the true
2x2 grid), byte-identical geometry every time. Gate 1: cleared.
"""
import sys
import time

from harness_common import (
    HOLD_WS, TEST_WS,
    ensure_rule, spawn_named, kill_workspace,
    Leaf, Split, place_tree, capture_rects, bbox,
)

FIXTURES = {
    "F1_two_way_split": Split("V", Leaf("A"), Leaf("B")),
    "F2_right_nested_caterpillar": Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C"))),
    "F3_left_nested_caterpillar": Split("V", Split("H", Leaf("A"), Leaf("B")), Leaf("C")),
    "F4_true_2x2_grid": Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D"))),
}


def check_split(node, rects, tol=20):
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
            msgs.append(f"V-split height mismatch: {h1} vs {h2} (tol {tol})")
        gap = min(abs((x1 + w1) - x2), abs((x2 + w2) - x1))
        if gap > tol:
            ok = False
            msgs.append(f"V-split not horizontally adjacent: gap={gap}")
    else:
        if abs(w1 - w2) > tol:
            ok = False
            msgs.append(f"H-split width mismatch: {w1} vs {w2} (tol {tol})")
        gap = min(abs((y1 + h1) - y2), abs((y2 + h2) - y1))
        if gap > tol:
            ok = False
            msgs.append(f"H-split not vertically adjacent: gap={gap}")
    ok1, m1 = check_split(node.first, rects, tol)
    ok2, m2 = check_split(node.second, rects, tol)
    return ok and ok1 and ok2, msgs + m1 + m2


def run_fixture(name, tree, run_idx):
    leaf_names = tree.leaves()
    run_tag = f"{name}-r{run_idx}"
    addr_of, titles = spawn_named(leaf_names, run_tag)

    place_tree(tree, addr_of, TEST_WS)
    time.sleep(0.4)

    title_to_name = {v: k for k, v in titles.items()}
    rects = capture_rects(title_to_name, TEST_WS)

    missing = set(leaf_names) - set(rects)
    if missing:
        print(f"  [{run_tag}] FAIL: windows missing from {TEST_WS} after batch: {missing}")
        ok = False
    else:
        ok, msgs = check_split(tree, rects)
        status = "PASS" if ok else "FAIL"
        print(f"  [{run_tag}] {status}  rects={rects}")
        for m in msgs:
            print(f"      - {m}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    time.sleep(0.15)
    return ok


def main():
    ensure_rule()
    repeats = int(sys.argv[1]) if len(sys.argv) > 1 else 3
    results = {}
    for name, tree in FIXTURES.items():
        print(f"=== {name} ===")
        outcomes = [run_fixture(name, tree, i) for i in range(repeats)]
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
