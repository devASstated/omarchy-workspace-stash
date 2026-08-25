#!/usr/bin/env python3
"""
Adversarial test of Approach E (special workspace as lossless tree
storage), run with explicit intent to falsify it against A's proven bar.

Already established, live, before this script (not assumed): neither
`hyprctl -j clients` nor the richer Lua `hl.get_windows()` API exposes
any tree/node/split field -- only flat geometry, everywhere. So E's own
"decode" step, whatever it looks like, can only ever be geometry-based
inference -- the same mechanism Approach A already uses, just pointed at
a different workspace. This script tests E's actual distinguishing
claims: does a deliberately-encoded special workspace survive (a) two
batches sharing it without metadata, and (b) DESTRUCTIVE decode -- windows
leaving one at a time, as a real restore() naturally does.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, capture_rects,
)
from partition import normalize, partition_tree

STASH_WS = "special:swx-stash-sim"


def main():
    ensure_rule()

    batch_a = Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C")))
    batch_b = Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F"))
    names_a, names_b = batch_a.leaves(), batch_b.leaves()
    all_names = names_a + names_b

    addr, titles = spawn_named(all_names, "attackE")
    title_to_name = {v: k for k, v in titles.items()}

    print("=== Encoding: deliberately place BOTH batches onto one 'stash' workspace ===")
    # This already requires stash() to gain the same deliberate
    # representative-leaf placement logic restore() uses -- today's real
    # stash() just does independent moveAddress() calls, no encoding at
    # all. Giving E the most generous version of itself here: assume that
    # bigger change was made, and both batches get properly encoded.
    place_tree(batch_a, {n: addr[n] for n in names_a}, STASH_WS)
    time.sleep(0.3)
    place_tree(batch_b, {n: addr[n] for n in names_b}, STASH_WS)
    time.sleep(0.4)

    encoded = capture_rects(title_to_name, STASH_WS)
    print("encoded geometry on the shared stash workspace:", encoded)

    print("\n=== Decode attempt 1: no metadata, are the two batches even separable? ===")
    R_all = normalize(encoded)
    tree_all = partition_tree(set(all_names), R_all)
    print("partition_tree() on the FULL shared stash workspace (no batch metadata used):", tree_all)

    print("\n=== Decode attempt 2: destructive, one window leaving at a time (real restore behavior) ===")
    # Pull out batch A's windows one at a time, as a real restore() would,
    # and check at each step whether the REMAINING windows on the stash
    # workspace are still correctly parseable/attributable.
    remaining = list(all_names)
    pull_order = ["A", "B", "C"]  # batch A leaving first, oldest-first
    for name in pull_order:
        before = capture_rects(title_to_name, STASH_WS)
        hyprctl("dispatch", 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr[name]))
        time.sleep(0.4)
        remaining.remove(name)
        after = {k: v for k, v in capture_rects(title_to_name, STASH_WS).items() if k in remaining}
        R = normalize(after)
        tree = partition_tree(set(remaining), R)
        print(f"  after pulling {name}: remaining stash geometry parses to: {tree}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    kill_workspace(STASH_WS)


if __name__ == "__main__":
    main()
