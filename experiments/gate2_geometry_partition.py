#!/usr/bin/env python3
"""
Gate 2 (feasibility doc §8 Gate 2, §3 Approach A): given ONLY the final
captured rectangles (no known tree), can a recursive guillotine-cut parser
recover a tree that -- when replayed through Gate 1's now-proven
representative-leaf expansion -- reproduces the same visual layout?

This is deliberately NOT "does the recovered tree structurally equal the
original tree" -- for a symmetric grid (F4) there can be more than one
valid slicing of the same rectangle set (row-first vs column-first), and
per docs/RECONSTRUCTION.md that's expected and fine: correctness is about
the final visual result, not which of several equally-valid trees was
picked. So each run does a real round trip:

  1. build a KNOWN tree live (batch A, via Gate 1's place_tree)
  2. capture its rectangles
  3. kill batch A, discard the known tree completely
  4. run partitionTree() on the captured rectangles alone
  5. spawn a FRESH batch B, replay the RECOVERED tree
  6. capture batch B's rectangles
  7. compare batch B's geometry to batch A's, per window name

If they match, geometry alone was sufficient -- independent of which
specific tree topology partitionTree() happened to pick.
"""
import sys
import time

from harness_common import (
    HOLD_WS, TEST_WS,
    ensure_rule, spawn_named, kill_workspace,
    Leaf, Split, place_tree, capture_rects,
)
from partition import normalize, partition_tree

FIXTURES = {
    "F1_two_way_split": Split("V", Leaf("A"), Leaf("B")),
    "F2_right_nested_caterpillar": Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C"))),
    "F3_left_nested_caterpillar": Split("V", Split("H", Leaf("A"), Leaf("B")), Leaf("C")),
    "F4_true_2x2_grid": Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D"))),
    "F6_deep_asymmetric": Split("V", Leaf("A"), Split("H", Leaf("B"), Split("V", Leaf("C"), Leaf("D")))),
    "F7_two_independent_deep_branches": Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    ),
}


# ---- round-trip test ---------------------------------------------------------

def rects_match(r1, r2, tol=20):
    msgs = []
    for name in r1:
        x1, y1, w1, h1 = r1[name]
        x2, y2, w2, h2 = r2.get(name, (None,) * 4)
        if x2 is None:
            msgs.append(f"{name}: missing after replay")
            continue
        if abs(x1 - x2) > tol or abs(y1 - y2) > tol or abs(w1 - w2) > tol or abs(h1 - h2) > tol:
            msgs.append(f"{name}: original={r1[name]} replayed={r2[name]}")
    return (len(msgs) == 0), msgs


def run_fixture(name, known_tree, run_idx):
    leaf_names = known_tree.leaves()
    run_tag = f"{name}-r{run_idx}"

    # 1-2: build the known tree, capture its geometry.
    addr_a, titles_a = spawn_named(leaf_names, run_tag + "-a")
    place_tree(known_tree, addr_a, TEST_WS)
    time.sleep(0.4)
    title_to_name_a = {v: k for k, v in titles_a.items()}
    rects_a = capture_rects(title_to_name_a, TEST_WS)

    # 3: discard the known tree from here on -- only rects_a's numbers feed partition_tree().
    kill_workspace(TEST_WS)
    time.sleep(0.15)

    if set(rects_a) != set(leaf_names):
        print(f"  [{run_tag}] FAIL: capture incomplete before parsing: {rects_a.keys()} vs {leaf_names}")
        kill_workspace(HOLD_WS)
        return False

    # 4: recover a tree from geometry alone.
    R = normalize(rects_a)
    recovered = partition_tree(set(leaf_names), R)
    if recovered is None:
        print(f"  [{run_tag}] FAIL: partition_tree() could not fully partition {rects_a}")
        kill_workspace(HOLD_WS)
        return False

    # 5-6: replay the RECOVERED tree on a fresh batch, capture its geometry.
    addr_b, titles_b = spawn_named(leaf_names, run_tag + "-b")
    place_tree(recovered, addr_b, TEST_WS)
    time.sleep(0.4)
    title_to_name_b = {v: k for k, v in titles_b.items()}
    rects_b = capture_rects(title_to_name_b, TEST_WS)

    # 7: compare.
    ok, msgs = rects_match(rects_a, rects_b)
    status = "PASS" if ok else "FAIL"
    same_topology = repr(recovered) == repr(known_tree)
    print(f"  [{run_tag}] {status}  known={known_tree!r}  recovered={recovered!r}"
          f"  (same topology: {same_topology})")
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
