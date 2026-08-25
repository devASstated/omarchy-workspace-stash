#!/usr/bin/env python3
"""
Re-measures D's large-N timing using the workspace-scoped capture
(hypr_socket_scoped.py) instead of the full-system-client-list capture
that attack_D_large_n.py used -- testing directly whether eliminating
the O(total-system-windows) payload per step brings D's scaling down
towards O(N) as hypothesized, rather than the O(N^2)-ish growth actually
measured (9.02ms/step at N=12 -> 14.82ms/step at N=20).
"""
import string
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split, TEST_WS, HOLD_WS, bbox,
)
from hypr_socket import raw_dispatch
from hypr_socket_scoped import capture_rects_scoped
from partition import normalize, partition_tree
from attack_D_full_topology import infer_axis_and_direction, rebuild_tree_from_full_record


def balanced_tree(leaf_names):
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
    return list(reversed(names[1:]))


def decompose_scoped(addr, all_names, title_to_name, removal_order):
    remaining = list(all_names)
    record = []
    prior = capture_rects_scoped(title_to_name, TEST_WS)
    for name in removal_order:
        removed_rect = prior.get(name)
        still_remaining = [n for n in remaining if n != name]
        raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
        after = capture_rects_scoped(title_to_name, TEST_WS)  # still workspace-scoped to TEST_WS; the moved one just won't appear
        after = {n: v for n, v in after.items() if n in still_remaining}
        changed = [n for n in still_remaining if prior.get(n) != after.get(n)]
        if changed and removed_rect is not None:
            axis, removed_is_first = infer_axis_and_direction(removed_rect, bbox(prior, changed), bbox(after, changed))
        else:
            axis, removed_is_first = None, None
        record.append((name, changed, axis, removed_is_first))
        remaining.remove(name)
        prior = after
    return record


def main():
    ensure_rule()

    for n in (12, 16, 20, 30):
        names = leaf_names(n)
        tree = balanced_tree(names)
        order = removal_order_for(names)

        print(f"=== N={n} (scoped capture) ===", flush=True)
        addr, titles = spawn_named(names, f"scopedN-{n}")
        place_tree(tree, addr, TEST_WS)
        time.sleep(0.5)
        title_to_name = {v: k for k, v in titles.items()}

        t0 = time.time()
        record = decompose_scoped(addr, names, title_to_name, order)
        d_elapsed = time.time() - t0

        rebuilt, err = rebuild_tree_from_full_record(record, names)
        ok = (err is None) and repr(rebuilt) == repr(tree)

        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)

        n_removals = len(order)
        print(f"  D (scoped): {d_elapsed*1000:.2f}ms total, {d_elapsed/n_removals*1000:.2f}ms/step ({n_removals} removals), correct={ok}", flush=True)
        print(flush=True)


if __name__ == "__main__":
    main()
