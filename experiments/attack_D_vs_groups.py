#!/usr/bin/env python3
"""
Discriminatory test #2 (GPT): D vs real Hyprland groups. Uses the group
-collapse strategy Gate 9 already established for Approach A (one
representative address per group, from Hyprland's own `grouped` field --
no geometric group detection invented here either) and asks whether D's
decomposition, operating on that same collapsed representative, still
correctly recovers exact topology -- including whether the group's
~28px chrome offset (Gate 9, corroborating DESIGN-JOURNEY.md #16)
confuses the (now position-overlap-based, not size-delta-based) axis
inference.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, dispatch_clause, fire_batch,
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


def group_together(addr_a, addr_b):
    """A becomes a group of one, B moves into it from the right --
    exactly the recipe Gate 9 confirmed live."""
    hyprctl("dispatch", 'hl.dsp.focus({ window = "address:%s" })' % addr_a)
    time.sleep(0.1)
    hyprctl("dispatch", 'hl.dsp.group.toggle()')
    time.sleep(0.2)
    hyprctl("dispatch", 'hl.dsp.focus({ window = "address:%s" })' % addr_b)
    time.sleep(0.1)
    hyprctl("dispatch", 'hl.dsp.window.move({ into_group = "l" })')
    time.sleep(0.3)


def check_grouped(addr_a, addr_b):
    for w in raw_json("clients"):
        if w.get("address") == addr_a:
            return addr_b in (w.get("grouped") or [])
    return False


def main():
    ensure_rule()

    print("=== Case 1: C | Group(A,B) -- simple two-way split, one side is a group ===")
    tree = Split("V", Leaf("C"), Leaf("A"))  # A represents Group(A,B) once grouped
    names_live = ["C", "A", "B"]
    addr, titles = spawn_named(names_live, "groupD-simple")

    # build a clean C | A | B caterpillar first (proven recipe from Gate 9),
    # THEN group A and B together -- into_group is a silent no-op unless A
    # and B are already properly adjacent tiles, confirmed the hard way in
    # Gate 9 and reconfirmed here (a naive "just move B in" first attempt
    # let Dwindle's default insertion split A instead of placing B beside
    # it, and grouping silently never took effect).
    clauses = [
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr["C"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr["C"]),
        dispatch_clause('hl.dsp.layout("preselect r")'),
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr["A"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr["A"]),
        dispatch_clause('hl.dsp.layout("preselect r")'),
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr["B"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr["B"]),
    ]
    fire_batch(clauses)
    time.sleep(0.3)
    group_together(addr["A"], addr["B"])

    grouped_ok = check_grouped(addr["A"], addr["B"])
    print(f"  group formed cleanly (A.grouped includes B): {grouped_ok}")

    title_to_name = {v: k for k, v in titles.items() if k in ("C", "A")}  # B dropped -- collapsed to A's representative
    collapsed_names = ["C", "A"]

    baseline = capture_rects_fast(title_to_name, TEST_WS)
    print(f"  collapsed geometry (B dropped, A represents the group): {baseline}")

    R = normalize(baseline)
    a_result = partition_tree(set(collapsed_names), R)
    print(f"  Approach A on collapsed geometry: {a_result!r}")

    # D: does moving/removing the representative (A) remove the whole group cleanly?
    before_members = raw_json("clients")
    record = decompose_full(tree, {n: addr[n] for n in collapsed_names}, collapsed_names, title_to_name, ["A"])
    print(f"  D's decomposition record: {record}")
    # confirm B actually left TEST_WS along with A (group stayed intact through the move)
    after_members = raw_json("clients")
    b_workspace = next((w.get("workspace", {}).get("name") for w in after_members if w.get("address") == addr["B"]), None)
    print(f"  B's workspace after removing A (should be {HOLD_WS}, following the group): {b_workspace}")

    rebuilt, err = rebuild_tree_from_full_record(record, collapsed_names)
    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    if err:
        print(f"  D result: FAILED SAFELY -- {err}")
    else:
        ok = repr(rebuilt) == repr(tree)
        print(f"  D result: {'EXACT MATCH' if ok else 'WRONG TREE'} -- known={tree!r} rebuilt={rebuilt!r}")

    print()
    print("=== Case 2: grouped tile embedded inside a deeper tree: X | (Group(A,B) / Y) ===")
    tree2 = Split("V", Leaf("X"), Split("H", Leaf("A"), Leaf("Y")))  # A represents Group(A,B)
    names_live2 = ["X", "A", "Y", "B"]
    addr2, titles2 = spawn_named(names_live2, "groupD-deep")

    clauses2 = [
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr2["X"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr2["X"]),
        dispatch_clause('hl.dsp.layout("preselect r")'),
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr2["A"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr2["A"]),
        dispatch_clause('hl.dsp.layout("preselect d")'),
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr2["Y"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr2["Y"]),
        # place B directly beside A (splitting A's own slot temporarily)
        # so into_group has an actual adjacent tile to merge with
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr2["A"]),
        dispatch_clause('hl.dsp.layout("preselect r")'),
        dispatch_clause('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (TEST_WS, addr2["B"])),
        dispatch_clause('hl.dsp.focus({ window = "address:%s" })' % addr2["B"]),
    ]
    fire_batch(clauses2)
    time.sleep(0.3)
    group_together(addr2["A"], addr2["B"])
    print(f"  group formed cleanly: {check_grouped(addr2['A'], addr2['B'])}")

    title_to_name2 = {v: k for k, v in titles2.items() if k in ("X", "A", "Y")}
    collapsed_names2 = ["X", "A", "Y"]
    baseline2 = capture_rects_fast(title_to_name2, TEST_WS)
    print(f"  collapsed geometry: {baseline2}")

    R2 = normalize(baseline2)
    a_result2 = partition_tree(set(collapsed_names2), R2)
    print(f"  Approach A on collapsed geometry: {a_result2!r}")

    record2 = decompose_full(tree2, {n: addr2[n] for n in collapsed_names2}, collapsed_names2, title_to_name2, ["Y", "A"])
    print(f"  D's decomposition record: {record2}")
    rebuilt2, err2 = rebuild_tree_from_full_record(record2, collapsed_names2)

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    if err2:
        print(f"  D result: FAILED SAFELY -- {err2}")
    else:
        ok2 = repr(rebuilt2) == repr(tree2)
        print(f"  D result: {'EXACT MATCH' if ok2 else 'WRONG TREE'} -- known={tree2!r} rebuilt={rebuilt2!r}")


if __name__ == "__main__":
    main()
