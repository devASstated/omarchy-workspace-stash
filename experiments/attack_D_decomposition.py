#!/usr/bin/env python3
"""
Adversarial test of Approach D (destructive decomposition during stash),
run with explicit intent to falsify it against A's now-proven bar, per
the user's request: "attack D or E with intention to prove it won't
survive to the level of A."

Method: build a known tree live, then remove its windows one at a time
(each removal = one "stash" step), diffing captured geometry before/after
each removal to build a decomposition record -- exactly the mechanism
Approach D proposes. Then attempt to reconstruct the ORIGINAL tree purely
from that record (reversing it, as the design says restore would), and
compare against the known tree. Also measures real wall-clock cost
against a single Approach-A capture+parse on the same tree, since "does
this need equivalent geometric reasoning as Approach A anyway, plus extra
async steps" was the open question from the feasibility doc.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, capture_rects, bbox,
)
from partition import normalize, partition_tree


def remove_and_diff(addr, name, remaining_names, title_to_name, wait_s):
    # IMPORTANT: capture_rects() must only be asked for names still
    # expected to be on TEST_WS -- passing the full original title_to_name
    # after earlier removals makes it spin until its internal timeout
    # every single call, since the already-removed windows never appear.
    # (Found live: this bug was silently dominating every earlier timing
    # measurement in this file -- fixed here, re-measured properly.)
    live_titles_before = {t: n for t, n in title_to_name.items() if n in remaining_names}
    before = capture_rects(live_titles_before, TEST_WS)
    hyprctl("dispatch", 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
    if wait_s:
        time.sleep(wait_s)
    still_remaining = [n for n in remaining_names if n != name]
    live_titles_after = {t: n for t, n in title_to_name.items() if n in still_remaining}
    after = capture_rects(live_titles_after, TEST_WS)
    changed = [n for n in still_remaining if before.get(n) != after.get(n)]
    return before, after, changed


def naive_decompose(tree, addr, all_names, title_to_name, removal_order, wait_s=0.0):
    """Removes windows in removal_order, one at a time, recording
    (removed, compensating_cluster) at each step -- the raw material
    Approach D's decomposition record would consist of."""
    remaining = list(all_names)
    record = []
    for name in removal_order:
        before, after, changed = remove_and_diff(addr, name, remaining, title_to_name, wait_s)
        record.append((name, changed))
        remaining.remove(name)
        print(f"    removed {name}: compensating cluster = {changed}")
    return record


def reconstruct_from_record(record, original_leaf_names):
    """Naive reverse-the-steps reconstruction: rebuild a nested grouping
    from the decomposition record alone (no access to the original tree).
    Each step says "removing X only affected cluster C" -- reversing it
    means X was a sibling of whatever C represents. Returns the final
    grouping structure discovered, or None if the record is ambiguous
    (a cluster of size 0, or a cluster that doesn't correspond to any
    single coherent prior grouping)."""
    # group[name] = the current "supergroup" (frozenset of leaf names) that name belongs to
    group = {n: frozenset([n]) for n in original_leaf_names}
    # process the record in reverse (undoing removals = how restore would replay it)
    for removed, changed in reversed(record):
        if not changed:
            return None, f"step removing {removed} had an empty compensating cluster -- cannot attribute a sibling"
        # all `changed` windows must currently belong to the SAME supergroup for
        # this to be an unambiguous single sibling-subtree being "demoted" back
        changed_groups = set(group[c] for c in changed if c in group)
        if len(changed_groups) != 1:
            return None, f"step removing {removed}: compensating cluster {changed} spans more than one existing group ({changed_groups}) -- ambiguous"
        sibling_group = next(iter(changed_groups))
        new_group = sibling_group | {removed}
        for member in new_group:
            group[member] = new_group
    final_groups = set(group.values())
    return final_groups, None


def main():
    ensure_rule()

    F7 = Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    )
    names = F7.leaves()

    print("=== Full decomposition sequence on F7 ===")
    addr, titles = spawn_named(names, "attackD-full")
    place_tree(F7, addr, TEST_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}

    t0 = time.time()
    # removal order deliberately mixes a simple-sibling removal (F, whose
    # sibling is the subtree {D,E}) with subtree-promotion removals (A)
    # and leaf-vs-leaf removals (D vs E, B vs C) in the same sequence --
    # FULL decomposition, 5 removals down to exactly one survivor, needed
    # for a fair correctness check (see docs/RECONSTRUCTION-EXPERIMENTS.md
    # for why a partial decomposition isn't a fair test). wait_s=0: proven
    # safe by measure_settle_time.py/measure_settle_time_sequence.py --
    # the earlier 0.4s-per-step version was measuring a capture_rects()
    # bug (asking for already-removed windows, spinning to its internal
    # timeout), not genuine Hyprland settle time.
    removal_order = ["F", "D", "A", "B", "C"]
    record = naive_decompose(F7, addr, names, title_to_name, removal_order, wait_s=0.0)
    d_elapsed = time.time() - t0

    groups, error = reconstruct_from_record(record, names)
    if error:
        print(f"  DECOMPOSITION RECONSTRUCTION FAILED: {error}")
    else:
        print(f"  final reconstructed grouping: {groups}")
        expected = {frozenset(names)}
        ok = groups == expected
        print(f"  reconstructs to one full group spanning all leaves: {ok}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    print(f"\n  Approach D: {len(removal_order)} live removal round-trips, {d_elapsed:.2f}s wall-clock")

    print("\n=== Same tree, Approach A (single capture + parse) for comparison ===")
    addr2, titles2 = spawn_named(names, "attackD-compareA")
    place_tree(F7, addr2, TEST_WS)
    time.sleep(0.4)
    title_to_name2 = {v: k for k, v in titles2.items()}

    t0 = time.time()
    rects = capture_rects(title_to_name2, TEST_WS)
    R = normalize(rects)
    tree = partition_tree(set(names), R)
    a_elapsed = time.time() - t0
    print(f"  Approach A: 1 capture + 1 parse, {a_elapsed:.4f}s wall-clock, recovered {tree!r}")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    print(f"\n  Cost ratio (D / A): {d_elapsed / a_elapsed:.0f}x")


if __name__ == "__main__":
    main()
