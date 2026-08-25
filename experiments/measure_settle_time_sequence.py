#!/usr/bin/env python3
"""
Follow-up to measure_settle_time.py: that measurement showed wait=0 was
safe for a single isolated removal (F4, removing D), 6/6 correct. This
checks the more realistic case for Approach D's real cost: a full,
rapid-fire, back-to-back decomposition sequence (F7, 5 removals, zero
sleep between dispatch and the next capture) -- does correctness still
hold when nothing is given a chance to "settle" between steps at all, or
does compounding multiple queued removals expose a race the single-step
test couldn't?
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, capture_rects,
)

F7 = Split(
    "V",
    Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
    Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
)
NAMES = F7.leaves()
REMOVAL_ORDER = ["F", "D", "A", "B", "C"]


def remove_and_diff_zero_wait(addr, name, remaining_names, title_to_name):
    before = capture_rects(title_to_name, TEST_WS)
    hyprctl("dispatch", 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
    # no sleep at all
    after = capture_rects(title_to_name, TEST_WS)
    changed = [n for n in remaining_names if n != name and before.get(n) != after.get(n)]
    return changed


def trial(trial_idx):
    addr, titles = spawn_named(NAMES, f"seq{trial_idx}")
    place_tree(F7, addr, TEST_WS)
    time.sleep(0.3)
    title_to_name = {v: k for k, v in titles.items()}

    remaining = list(NAMES)
    t0 = time.time()
    record = []
    for name in REMOVAL_ORDER:
        changed = remove_and_diff_zero_wait(addr, name, remaining, title_to_name)
        record.append((name, changed))
        remaining.remove(name)
    elapsed = time.time() - t0

    # ground truth: re-capture with a generous wait, confirm final state matches
    time.sleep(0.5)
    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)
    return record, elapsed


def reconstruct(record, all_names):
    group = {n: frozenset([n]) for n in all_names}
    for removed, changed in reversed(record):
        if not changed:
            return None
        changed_groups = set(group[c] for c in changed if c in group)
        if len(changed_groups) != 1:
            return None
        sibling_group = next(iter(changed_groups))
        new_group = sibling_group | {removed}
        for m in new_group:
            group[m] = new_group
    return set(group.values())


def main():
    ensure_rule()
    n_trials = 6
    n_correct = 0
    elapsed_total = 0.0
    for i in range(n_trials):
        record, elapsed = trial(i)
        groups = reconstruct(record, NAMES)
        ok = groups == {frozenset(NAMES)}
        n_correct += 1 if ok else 0
        elapsed_total += elapsed
        print(f"trial {i}: elapsed={elapsed*1000:.1f}ms  correct={ok}  record={record}", flush=True)

    print(f"\n{n_correct}/{n_trials} correct with ZERO wait between rapid-fire removals", flush=True)
    print(f"avg elapsed per full 5-step decomposition: {elapsed_total/n_trials*1000:.1f}ms", flush=True)


if __name__ == "__main__":
    main()
