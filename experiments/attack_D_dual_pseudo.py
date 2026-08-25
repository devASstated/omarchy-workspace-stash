#!/usr/bin/env python3
"""
D's information-boundary attack (GPT): does destructive decomposition
still expose the sibling/subtree relationship when BOTH sides of a split
are pseudo-tiled -- so neither one necessarily expands into the freed
slot? This is the exact boundary flagged (but not tested) after the
pseudo-tiling win: every prior pseudo case had one pseudo leaf compensated
by a NORMAL neighbor that visibly responded. This tests what happens when
there's no normal side to fall back on.

Explicit instruction: observe first, do not patch the algorithm to make
a fixture pass. This script only OBSERVES and RECORDS -- it runs the
existing (unmodified) decompose_full()/infer_axis_and_direction() and
reports the raw signal, classified into GPT's A/B/C outcomes. Any fix
is a separate, later step if warranted.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, fire_resizes,
)
from hypr_socket import raw_json
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


def classify_change(before, after):
    if before is None or after is None:
        return "MISSING"
    bx, by, bw, bh = before
    ax, ay, aw, ah = after
    pos_changed = (bx, by) != (ax, ay)
    size_changed = (bw, bh) != (aw, ah)
    if pos_changed and size_changed:
        return "moved+resized"
    if pos_changed:
        return "moved only"
    if size_changed:
        return "resized only"
    return "UNCHANGED"


def run_fixture(label, tree, pseudo_on, removal_order):
    names = tree.leaves()
    addr, titles = spawn_named(names, f"dualpseudo-{label}")
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}

    for p in pseudo_on:
        pseudo_toggle(addr[p])

    baseline = capture_rects_fast(title_to_name, TEST_WS)
    print(f"\n=== {label} ===")
    print(f"  pseudo on: {pseudo_on}")
    print(f"  baseline geometry: {baseline}")

    R = normalize(baseline)
    a_result = partition_tree(set(names), R)
    print(f"  Approach A on this geometry: {a_result!r}")

    # Manually walk the decomposition, printing the raw before/after/classification
    # for every step BEFORE any reconstruction is attempted (observe first).
    remaining = list(names)
    prior = baseline
    raw_log = []
    for name in removal_order:
        still_remaining = [n for n in remaining if n != name]
        hyprctl("dispatch", 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
        time.sleep(0.2)
        live_titles = {t: n for t, n in title_to_name.items() if n in still_remaining}
        after = capture_rects_fast(live_titles, TEST_WS)
        print(f"  removed {name!r}:")
        for n in still_remaining:
            cls = classify_change(prior.get(n), after.get(n))
            print(f"    {n}: before={prior.get(n)} after={after.get(n)}  [{cls}]")
        remaining.remove(name)
        prior = after
        raw_log.append((name, still_remaining))

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    # Now run the actual (unmodified) reconstruction pipeline for the record.
    addr2, titles2 = spawn_named(names, f"dualpseudo2-{label}")
    place_tree(tree, addr2, TEST_WS)
    time.sleep(0.4)
    title_to_name2 = {v: k for k, v in titles2.items()}
    for p in pseudo_on:
        pseudo_toggle(addr2[p])
    time.sleep(0.2)

    record = decompose_full(tree, addr2, names, title_to_name2, removal_order)
    print(f"  D's decomposition record: {record}")
    rebuilt, err = rebuild_tree_from_full_record(record, names)

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    if err:
        outcome = "B (failed closed)"
        print(f"  D result: FAILED SAFELY -- {err}")
    else:
        ok = repr(rebuilt) == repr(tree)
        if ok:
            outcome = "A (correct despite dual-pseudo)"
            print(f"  D result: EXACT MATCH -- {rebuilt!r}")
        else:
            outcome = "C (WRONG TREE -- serious)"
            print(f"  D result: WRONG TREE -- known={tree!r} rebuilt={rebuilt!r}")

    print(f"  OUTCOME: {outcome}")
    return outcome


def main():
    ensure_rule()
    outcomes = {}

    # 1. pseudo(A) | pseudo(B)
    outcomes["1_both_pseudo_simple"] = run_fixture(
        "1_both_pseudo_simple",
        Split("V", Leaf("A"), Leaf("B")),
        pseudo_on=["A", "B"],
        removal_order=["B"],
    )

    # 2. A | (pseudo(B) / pseudo(C))
    outcomes["2_nested_both_pseudo"] = run_fixture(
        "2_nested_both_pseudo",
        Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C"))),
        pseudo_on=["B", "C"],
        removal_order=["C", "B"],
    )

    # 3. pseudo(A) | (pseudo(B) / C)
    outcomes["3_mixed_pseudo"] = run_fixture(
        "3_mixed_pseudo",
        Split("V", Leaf("A"), Split("H", Leaf("B"), Leaf("C"))),
        pseudo_on=["A", "B"],
        removal_order=["C", "B"],
    )

    # 4. deeper independently-branching tree, pseudo leaves on both sides of one split
    outcomes["4_deep_both_sides_pseudo"] = run_fixture(
        "4_deep_both_sides_pseudo",
        Split("V", Split("H", Leaf("A"), Leaf("B")), Split("H", Leaf("C"), Leaf("D"))),
        pseudo_on=["A", "C"],  # both "first" leaves of each branch, on opposite sides of the root split
        removal_order=["B", "D", "A"],
    )

    print("\n\n=== SUMMARY ===")
    for label, outcome in outcomes.items():
        print(f"  {label}: {outcome}")


if __name__ == "__main__":
    main()
