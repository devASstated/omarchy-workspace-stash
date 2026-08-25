#!/usr/bin/env python3
import time
from harness_common import ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split, TEST_WS, HOLD_WS, hyprctl
from seam_integration_test import (
    hybrid_stash, restore_and_verify, audit_addresses, capture_rects_fast, RESTORE_WS,
)


def pseudo_toggle(addr):
    hyprctl("dispatch", 'hl.dsp.focus({ window = "address:%s" })' % addr)
    time.sleep(0.05)
    hyprctl("dispatch", 'hl.dsp.window.pseudo()')
    time.sleep(0.2)


def path1():
    print("=== PATH 1: A succeeds, D must never be touched ===")
    tree = Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    )
    names = tree.leaves()
    addr, titles = spawn_named(names, "seam-p1")
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}

    report = hybrid_stash(addr, names, title_to_name, removal_order_for_d=list(reversed(names[1:])))
    print(f"  used_D: {report['used_D']}  (must be False)")
    print(f"  d_steps: {report['d_steps']}  (must be 0)")
    print(f"  elapsed: {report['elapsed']*1000:.2f}ms")
    print(f"  layout_tree: {report['layout_tree']!r}")

    audit = audit_addresses(names, addr, title_to_name)
    for n, s in audit.items():
        print(f"    {n}: {s}")

    result = restore_and_verify(report["layout_tree"], tree, names, "seam-p1-restore")
    print(f"  restore topology matches original: {result['topology_matches_original']}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    print()
    return report["used_D"] is False and report["d_steps"] == 0 and result["topology_matches_original"]


def path2():
    print("=== PATH 2: A fails (real pseudo layout) -> D escalation IS the stash ===")
    # NOTE: nested-branch mild pseudo (A|(B/C), pseudo on C) was tried first
    # and turned out to be the Gate-14 case where A *succeeds* fine (mild
    # shrink) -- my own fixture-selection bug, not an orchestration finding.
    # This is the confirmed-None case instead: simple 2-way split, pseudo
    # on the leaf itself, no normal sibling geometry to lean on.
    tree = Split("V", Leaf("A"), Leaf("B"))
    names = tree.leaves()
    addr, titles = spawn_named(names, "seam-p2")
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}
    pseudo_toggle(addr["A"])  # the exact Gate-14-proven "A returns None" case

    report = hybrid_stash(addr, names, title_to_name, removal_order_for_d=["B"])
    print(f"  used_D: {report['used_D']}  (must be True)")
    print(f"  d_steps: {report['d_steps']}")
    print(f"  elapsed: {report['elapsed']*1000:.2f}ms")
    for line in report["log"]:
        print(" ", line)
    print(f"  layout_tree: {report['layout_tree']!r}")
    print(f"  reconstruction_error: {report.get('reconstruction_error')}")

    audit = audit_addresses(names, addr, title_to_name)
    for n, s in audit.items():
        print(f"    {n}: {s}")

    result = restore_and_verify(report["layout_tree"], tree, names, "seam-p2-restore")
    print(f"  restore topology matches original: {result['topology_matches_original']}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    print()
    return report["used_D"] is True and result["topology_matches_original"]


def path3():
    print("=== PATH 3: A fails -> D escalation, window killed mid-escalation ===")
    tree = Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    )
    names = tree.leaves()
    addr, titles = spawn_named(names, "seam-p3")
    place_tree(tree, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}
    pseudo_toggle(addr["C"])  # force A to fail so D takes over

    removal_order = ["F", "D", "A", "B", "C"]
    report = hybrid_stash(
        addr, names, title_to_name, removal_order_for_d=removal_order,
        inject_kill_target="B", inject_before_step="A",
    )
    print(f"  used_D: {report['used_D']}")
    for line in report["log"]:
        print(" ", line)
    print(f"  layout_tree: {report.get('layout_tree')!r}")
    print(f"  reconstruction_error: {report.get('reconstruction_error')}")

    audit = audit_addresses(names, addr, title_to_name, killed="B")
    unaccounted = [n for n, s in audit.items() if "UNACCOUNTED" in s]
    for n, s in audit.items():
        print(f"    {n}: {s}")
    print(f"  unaccounted addresses: {unaccounted}  (must be empty)")

    if report.get("layout_tree") is not None:
        result = restore_and_verify(report["layout_tree"], None, report["surviving"], "seam-p3-restore")
        print(f"  restored {len(report['surviving'])} surviving windows, geometry: {result['restored_geometry']}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    print()
    return len(unaccounted) == 0


def main():
    ensure_rule()
    r1 = path1()
    r2 = path2()
    r3 = path3()
    print("=== SUMMARY ===")
    print(f"  Path 1 (A-only, D untouched): {'PASS' if r1 else 'FAIL'}")
    print(f"  Path 2 (D escalation, clean): {'PASS' if r2 else 'FAIL'}")
    print(f"  Path 3 (D escalation, kill injected, safety): {'PASS' if r3 else 'FAIL'}")


if __name__ == "__main__":
    main()
