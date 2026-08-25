#!/usr/bin/env python3
"""
Stress test for the now-fully-correct D reconstruction
(attack_D_full_topology.py): many random removal orders across several
tree shapes including a larger 8-window tree, checking exact-topology
correctness AND timing at scale (raw socket transport) -- does the fix
generalize, and does the ~1.5-1.8ms/step cost found earlier hold up at
bigger sizes.
"""
import random
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split, TEST_WS, HOLD_WS,
)
from attack_D_full_topology import decompose_full, rebuild_tree_from_full_record
from partition import normalize, partition_tree
from hypr_socket import raw_json

F4 = Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D")))
F7 = Split(
    "V",
    Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
    Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
)
# 8-window tree: two independently-deep 4-window branches
F8W = Split(
    "V",
    Split("H", Split("V", Leaf("A"), Leaf("B")), Split("V", Leaf("C"), Leaf("D"))),
    Split("H", Split("V", Leaf("E"), Leaf("F")), Split("V", Leaf("G"), Leaf("H"))),
)


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def run_one(tree, removal_order, tag):
    names = tree.leaves()
    addr, titles = spawn_named(names, tag)
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.3)
    title_to_name = {v: k for k, v in titles.items()}

    t0 = time.time()
    record = decompose_full(tree, addr, names, title_to_name, removal_order)
    elapsed = time.time() - t0

    rebuilt, err = rebuild_tree_from_full_record(record, names)

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    if err:
        return False, elapsed, f"reconstruction error: {err}"
    ok = repr(rebuilt) == repr(tree)
    return ok, elapsed, None if ok else f"known={tree!r} rebuilt={rebuilt!r}"


def main():
    ensure_rule()
    random.seed(20260825)

    results = []
    for tree, label in [(F4, "F4"), (F7, "F7"), (F8W, "F8W")]:
        names = tree.leaves()
        for trial in range(5):
            order = names[:]
            random.shuffle(order)
            order = order[:-1]  # leave exactly one survivor
            ok, elapsed, err = run_one(tree, order, f"stress-{label}-{trial}")
            results.append((label, trial, ok, elapsed, order, err))
            status = "PASS" if ok else "FAIL"
            print(f"{label} trial {trial} order={order}: {status} ({elapsed*1000:.2f}ms)"
                  + (f"  -- {err}" if err else ""), flush=True)

    n_ok = sum(1 for r in results if r[2])
    print(f"\n{n_ok}/{len(results)} random-order trials correct", flush=True)

    # per-tree-size average step cost
    for label, n_leaves in [("F4", 4), ("F7", 6), ("F8W", 8)]:
        times = [r[3] for r in results if r[0] == label]
        avg = sum(times) / len(times)
        print(f"{label} ({n_leaves} windows, {n_leaves-1} removals): avg {avg*1000:.2f}ms total, {avg/(n_leaves-1)*1000:.2f}ms/step", flush=True)


if __name__ == "__main__":
    main()
