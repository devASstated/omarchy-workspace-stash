#!/usr/bin/env python3
"""
Re-measures Approach D vs Approach A on raw Hyprland IPC sockets instead
of shelling out to the hyprctl binary per call -- confirmed (hypr_socket.py)
an 8-45x per-call overhead reduction. Directly tests the user's hunch that
D's cost was dominated by harness/process overhead rather than anything
inherent to the algorithm. Both D and A are re-measured on the same fast
transport, so the ratio stays a fair comparison, not just "D got faster."

Setup (spawning windows, building the initial tree, cleanup) still uses
the normal subprocess-based harness_common -- only the actual timed hot
loop (the remove+diff steps for D, the single capture+parse for A) uses
the raw socket.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS,
)
from hypr_socket import raw_json, raw_dispatch
from partition import normalize, partition_tree
from attack_D_decomposition import reconstruct_from_record


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def remove_and_diff_fast(addr, name, remaining_names, title_to_name, prior_capture):
    """prior_capture: the capture from the END of the previous step (or the
    initial baseline for the first step) -- reused as this step's "before"
    instead of re-querying, cutting one IPC call per step versus the naive
    version (which always re-captured "before" separately)."""
    before = prior_capture
    raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
    still_remaining = [n for n in remaining_names if n != name]
    live_titles_after = {t: n for t, n in title_to_name.items() if n in still_remaining}
    after = capture_rects_fast(live_titles_after, TEST_WS)
    changed = [n for n in still_remaining if before.get(n) != after.get(n)]
    return after, changed


def run_D_fast(tree, removal_order, tag):
    names = tree.leaves()
    addr, titles = spawn_named(names, tag)
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.3)
    title_to_name = {v: k for k, v in titles.items()}

    remaining = list(names)
    t0 = time.time()
    baseline = capture_rects_fast(title_to_name, TEST_WS)
    record = []
    prior = baseline
    for name in removal_order:
        prior, changed = remove_and_diff_fast(addr, name, remaining, title_to_name, prior)
        record.append((name, changed))
        remaining.remove(name)
    elapsed = time.time() - t0

    groups, err = reconstruct_from_record(record, names)
    ok = (err is None) and groups == {frozenset(names)}

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    return elapsed, ok, record


def run_A_fast(tree, tag):
    names = tree.leaves()
    addr, titles = spawn_named(names, tag)
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.3)
    title_to_name = {v: k for k, v in titles.items()}

    t0 = time.time()
    rects = capture_rects_fast(title_to_name, TEST_WS)
    R = normalize(rects)
    tree_r = partition_tree(set(names), R)
    elapsed = time.time() - t0

    kill_workspace(TEST_WS)
    return elapsed, tree_r is not None, tree_r


def main():
    ensure_rule()

    F4 = Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D")))
    F7 = Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    )
    F4_ORDER = ["D", "B", "A"]
    F7_ORDER = ["F", "D", "A", "B", "C"]

    for tree, order, label in [(F4, F4_ORDER, "F4 (4 windows, 3 removals)"), (F7, F7_ORDER, "F7 (6 windows, 5 removals)")]:
        print(f"=== {label} -- raw socket transport ===", flush=True)
        names = tree.leaves()
        d_times, a_times = [], []
        for i in range(6):
            e, ok, record = run_D_fast(tree, order, f"fastD-{label[:2]}-{i}")
            d_times.append(e)
            print(f"  D trial {i}: {e*1000:.2f}ms correct={ok}", flush=True)
        for i in range(6):
            e, ok, t = run_A_fast(tree, f"fastA-{label[:2]}-{i}")
            a_times.append(e)
            print(f"  A trial {i}: {e*1000:.3f}ms correct={ok}", flush=True)
        avg_d, avg_a = sum(d_times) / len(d_times), sum(a_times) / len(a_times)
        print(f"  {label}: avg D={avg_d*1000:.2f}ms avg A={avg_a*1000:.3f}ms ratio={avg_d/avg_a:.1f}x", flush=True)
        print(f"  D per-removal-step cost: {avg_d/len(order)*1000:.2f}ms", flush=True)
        print()


if __name__ == "__main__":
    main()
