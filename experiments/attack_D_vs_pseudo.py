#!/usr/bin/env python3
"""
Discriminatory test #1 (GPT, highest priority): does D recover exact
topology on the SAME real pseudo-tiled layouts where A necessarily loses
the logical slot and returns None (Gate 14)? Reuses Gate 14's exact
scenarios: mild shrink, drastic shrink, drastic-shrink-plus-extreme-ratio.

D's mechanism is fundamentally different here and could plausibly do
better: A infers structure from a single static snapshot, so a
pseudo-tiled window's shrunk rectangle just looks like bad data. D
instead observes an actual TRANSITION (before/after one specific
window's removal) -- if a pseudo-tiled window's SLOT still gets resized
correctly by Dwindle when a sibling leaves (even though the window's own
DISPLAYED size stays smaller/centered), the diff might still correctly
attribute compensation to the right neighbor. Testing directly rather
than assuming either way.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, fire_resizes, bbox,
)
from hypr_socket import raw_json, raw_dispatch
from partition import normalize, partition_tree
from attack_D_full_topology import decompose_full, rebuild_tree_from_full_record


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def pseudo_toggle(addr):
    hyprctl("dispatch", 'hl.dsp.focus({ window = "address:%s" })' % addr)
    time.sleep(0.05)
    hyprctl("dispatch", 'hl.dsp.window.pseudo()')
    time.sleep(0.2)


def run_case(name, tree, pseudo_on, removal_order, resize_before_pseudo=None):
    names = tree.leaves()
    addr, titles = spawn_named(names, f"pseudoD-{name}")
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}

    if resize_before_pseudo:
        target, w, h = resize_before_pseudo
        fire_resizes([(addr[target], w, h)])
        time.sleep(0.4)

    for p in pseudo_on:
        pseudo_toggle(addr[p])

    baseline = capture_rects_fast(title_to_name, TEST_WS)
    print(f"  [{name}] geometry after pseudo-toggle: {baseline}")

    # What does A do on this exact geometry? (should match Gate 14's findings)
    R = normalize(baseline)
    a_result = partition_tree(set(names), R)
    print(f"  [{name}] Approach A on this geometry: {a_result!r}")

    # What does D do, decomposing this exact live layout?
    record = decompose_full(tree, addr, names, title_to_name, removal_order)
    print(f"  [{name}] D's decomposition record: {record}")
    rebuilt, err = rebuild_tree_from_full_record(record, names)

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    if err:
        print(f"  [{name}] D result: FAILED SAFELY -- {err}")
        d_outcome = "safe_fail"
    elif repr(rebuilt) == repr(tree):
        print(f"  [{name}] D result: EXACT MATCH -- {rebuilt!r}")
        d_outcome = "exact_match"
    else:
        print(f"  [{name}] D result: WRONG TREE -- known={tree!r} rebuilt={rebuilt!r}")
        d_outcome = "wrong_tree"

    print(f"  [{name}] SUMMARY: A={'None (safe fail)' if a_result is None else 'exact' if repr(a_result)==repr(tree) else 'WRONG'}  D={d_outcome}\n")
    return d_outcome


def main():
    ensure_rule()

    print("=== Case 1: simple 2-way split, mild/dramatic pseudo shrink on one leaf ===")
    tree1 = Split("V", Leaf("A"), Leaf("B"))
    run_case("simple_pseudo_A", tree1, pseudo_on=["A"], removal_order=["B"])
    run_case("simple_pseudo_A_reverse", tree1, pseudo_on=["A"], removal_order=["A"])

    print("=== Case 2: nested branch, mild pseudo shrink (Gate 14's 'works fine' case) ===")
    tree2 = Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C")))
    run_case("nested_mild_pseudo_C", tree2, pseudo_on=["C"], removal_order=["C", "B"])
    run_case("nested_mild_pseudo_C_alt_order", tree2, pseudo_on=["C"], removal_order=["B", "C"])

    print("=== Case 3: nested branch + extreme ratio, drastic pseudo shrink (Gate 14's None case) ===")
    tree3 = Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C")))
    run_case(
        "drastic_pseudo_C_extreme_ratio", tree3,
        pseudo_on=["C"], removal_order=["C", "B"],
        resize_before_pseudo=("B", 704, 728),  # push B to ~85% of the column height first
    )


if __name__ == "__main__":
    main()
