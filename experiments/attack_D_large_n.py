#!/usr/bin/env python3
"""
Discriminatory test #4 (GPT): large-N timing, now that the raw socket
transport removes harness distortion. 12/16/20 windows -- does the ~8
-window rise to ~6.5ms/step (attack_D_fast.py) keep growing, and if so
how, versus A's parse time on the same layout?
"""
import string
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split, TEST_WS, HOLD_WS,
)
from hypr_socket import raw_json
from partition import normalize, partition_tree
from attack_D_full_topology import decompose_full


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def balanced_tree(leaf_names):
    """Builds a balanced binary tree over leaf_names, alternating V/H
    axis by depth -- not testing any particular shape's specialness here,
    just need a real, deep, wide tree at a given N."""
    def build(names, depth):
        if len(names) == 1:
            return Leaf(names[0])
        mid = len(names) // 2
        axis = "V" if depth % 2 == 0 else "H"
        return Split(axis, build(names[:mid], depth + 1), build(names[mid:], depth + 1))
    return build(leaf_names, 0)


def leaf_names(n):
    letters = list(string.ascii_uppercase)
    if n <= 26:
        return letters[:n]
    return [f"W{i}" for i in range(n)]


def removal_order_for(names):
    # simple deterministic order: reverse of build order, leaving the
    # first leaf as the final survivor
    return list(reversed(names[1:]))


def main():
    ensure_rule()

    for n in (12, 16, 20):
        names = leaf_names(n)
        tree = balanced_tree(names)
        order = removal_order_for(names)

        print(f"=== N={n} ===", flush=True)

        # D
        addr, titles = spawn_named(names, f"largeN-D-{n}")
        place_tree(tree, addr, TEST_WS)
        time.sleep(0.5)
        title_to_name = {v: k for k, v in titles.items()}

        t0 = time.time()
        record = decompose_full(tree, addr, names, title_to_name, order)
        d_elapsed = time.time() - t0
        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)

        # A, same tree
        addr2, titles2 = spawn_named(names, f"largeN-A-{n}")
        place_tree(tree, addr2, TEST_WS)
        time.sleep(0.5)
        title_to_name2 = {v: k for k, v in titles2.items()}

        t0 = time.time()
        rects = capture_rects_fast(title_to_name2, TEST_WS)
        R = normalize(rects)
        a_tree = partition_tree(set(names), R)
        a_elapsed = time.time() - t0
        kill_workspace(TEST_WS)

        n_removals = len(order)
        print(f"  D: {d_elapsed*1000:.2f}ms total, {d_elapsed/n_removals*1000:.2f}ms/step ({n_removals} removals)", flush=True)
        print(f"  A: {a_elapsed*1000:.3f}ms total (A correct: {a_tree is not None})", flush=True)
        print(f"  ratio: {d_elapsed/a_elapsed:.1f}x", flush=True)
        print(flush=True)


if __name__ == "__main__":
    main()
