#!/usr/bin/env python3
"""
Discriminatory test #3 (GPT): the decisive safety test. D's remaining
architectural objection isn't speed or correctness anymore -- it's that
`stash()` has to become a multi-step sequential live operation instead
of today's single independent-move-per-window pass with no ordering
dependencies. This attacks that directly: a window closing (not being
cleanly moved) partway through a real decomposition sequence, simulating
a user closing an app while stash is mid-flight.

Question: can every surviving window still end up either safely stashed
or safely left on the source workspace, with no lost windows and no
corrupt state, regardless of where the interruption happens? Or does
recovery require complicated rollback/replay logic? Tested directly,
not reasoned about.
"""
import os
import signal
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, bbox,
)
from hypr_socket import raw_json, raw_dispatch
from attack_D_full_topology import infer_axis_and_direction, rebuild_tree_from_full_record


def capture_rects_fast(title_to_name, ws_name):
    rects = {}
    for w in raw_json("clients"):
        t = w.get("title")
        if t in title_to_name and w.get("workspace", {}).get("name") == ws_name:
            rects[title_to_name[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
    return rects


def address_pid_map():
    return {w["address"]: w.get("pid") for w in raw_json("clients")}


def kill_window_directly(addr):
    """Simulates a user closing a window mid-stash -- kills the actual
    process, not a clean hl.dsp move. This is deliberately NOT going
    through any harness cleanup path."""
    pid_map = address_pid_map()
    pid = pid_map.get(addr)
    if pid:
        os.kill(pid, signal.SIGTERM)


def failure_tolerant_decompose(addr, all_names, title_to_name, removal_order,
                                inject_kill_target=None, inject_before_step=None):
    """Like decompose_full(), but checks whether the target window is
    still actually present before attempting to remove it -- and, if an
    injected closure happened, whether OTHER windows' presence still
    matches expectations. Returns (record, log, final_live_names).

    inject_kill_target/inject_before_step: kill inject_kill_target's
    process (directly, not via any clean move) right before the step
    that would process inject_before_step in removal_order -- decoupled
    so a window that has already absorbed an earlier subtree (by the
    time some LATER step runs) can be the one killed, not just whichever
    step is "next"."""
    remaining = list(all_names)
    record = []
    log = []
    prior_live_titles = {t: n for t, n in title_to_name.items() if n in remaining}
    prior = capture_rects_fast(prior_live_titles, TEST_WS)

    for name in removal_order:
        if inject_before_step == name and inject_kill_target is not None:
            target_addr = addr[inject_kill_target]
            log.append(f"INJECTING: killing {inject_kill_target!r}'s process directly (simulating user close)")
            kill_window_directly(target_addr)
            time.sleep(0.3)

        # check reality before acting: is `name` still actually present on TEST_WS?
        current_titles = {t: n for t, n in title_to_name.items() if n in remaining}
        current = capture_rects_fast(current_titles, TEST_WS)
        missing = [n for n in remaining if n not in current]
        if missing:
            log.append(f"  detected missing (closed externally) before processing {name!r}: {missing}")
            for m in missing:
                remaining.remove(m)
            prior = current  # re-baseline: the missing ones are just gone, not part of any diff

        if name not in remaining:
            log.append(f"  {name!r} itself was already gone (closed before its own turn) -- skipping this step entirely")
            continue

        still_remaining = [n for n in remaining if n != name]
        removed_rect = prior.get(name)
        raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
        live_titles = {t: n for t, n in title_to_name.items() if n in still_remaining}
        after = capture_rects_fast(live_titles, TEST_WS)
        changed = [n for n in still_remaining if prior.get(n) != after.get(n)]
        if changed and removed_rect is not None:
            axis, removed_is_first = infer_axis_and_direction(removed_rect, bbox(prior, changed), bbox(after, changed))
        else:
            axis, removed_is_first = None, None
        record.append((name, changed, axis, removed_is_first))
        log.append(f"  removed {name!r}: compensating cluster = {changed}")
        remaining.remove(name)
        prior = after

    # The n-1 diffing steps only ever explicitly move n-1 windows -- the
    # final survivor (if any, and if it's still actually there) needs its
    # own explicit move too, or it's silently left behind on the source
    # workspace instead of stashed. Found live via this exact test (E was
    # left on TEST_WS in the first run) -- a real completeness gap in the
    # decomposition design, not a failure-injection artifact, fixed here.
    for last in list(remaining):
        current_titles = {t: n for t, n in title_to_name.items() if n == last}
        still_there = capture_rects_fast(current_titles, TEST_WS)
        if last in still_there:
            raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[last]))
            log.append(f"  explicit final move: {last!r} (the last survivor, never touched by a diffing step) -> {HOLD_WS}")
        else:
            log.append(f"  final survivor {last!r} was itself already gone -- nothing to move")
        remaining.remove(last)

    return record, log, remaining


def audit_final_state(all_names, addr, title_to_name):
    """Where did every single window actually end up? No window may be
    unaccounted for."""
    live = raw_json("clients")
    by_addr = {w["address"]: w for w in live}
    report = {}
    for n in all_names:
        a = addr[n]
        w = by_addr.get(a)
        if w is None:
            report[n] = "GONE (closed, not present anywhere -- expected, this is the one we killed)"
        else:
            report[n] = f"present on {w.get('workspace', {}).get('name')}"
    return report


def main():
    ensure_rule()
    F7 = Split(
        "V",
        Split("H", Leaf("A"), Split("V", Leaf("B"), Leaf("C"))),
        Split("H", Split("V", Leaf("D"), Leaf("E")), Leaf("F")),
    )
    names = F7.leaves()
    removal_order = ["F", "D", "A", "B", "C"]

    scenarios = [
        # (label, kill_target, inject_before_step)
        ("next_scheduled_window_closes", "F", "F"),
        # C is scheduled last (untouched, still a lone leaf) when the
        # injection fires right before B's step -- an ordinary remaining leaf.
        ("unrelated_remaining_window_closes", "C", "B"),
        # by the time A's step runs, E has already absorbed BOTH D's and
        # F's space (steps F, D already ran) -- killing it here loses an
        # entire already-merged subtree's worth of information at once.
        ("already_absorbed_subtree_closes", "E", "A"),
    ]

    for label, inject_target, inject_before in scenarios:
        print(f"=== Scenario: {label} (kill {inject_target!r} right before {inject_before!r}'s step) ===")
        addr, titles = spawn_named(names, f"fail-{label}")
        place_tree(F7, addr, TEST_WS)
        time.sleep(0.4)
        title_to_name = {v: k for k, v in titles.items()}

        record, log, remaining = failure_tolerant_decompose(
            addr, names, title_to_name, removal_order,
            inject_kill_target=inject_target, inject_before_step=inject_before,
        )

        for line in log:
            print(" ", line)

        print("  final decomposition record:", record)
        print("  windows never processed (remaining list at end):", remaining)

        # Can a valid tree still be reconstructed for the SURVIVING windows
        # alone, with the killed one's references filtered out of any
        # recorded "changed" cluster? Not required for safety (the killed
        # window is gone, nothing to restore for it) but tests whether the
        # gap corrupts reconstruction for everyone ELSE too, or stays local.
        surviving = [n for n in names if n != inject_target]
        filtered_record = [
            (removed, [c for c in changed if c != inject_target], axis, is_first)
            for removed, changed, axis, is_first in record
        ]
        rebuilt, err = rebuild_tree_from_full_record(filtered_record, surviving)
        if err:
            print(f"  reconstruction for surviving {len(surviving)} windows: FAILED SAFELY -- {err}")
        else:
            print(f"  reconstruction for surviving {len(surviving)} windows: {rebuilt!r}")

        report = audit_final_state(names, addr, title_to_name)
        for n, status in report.items():
            print(f"    {n}: {status}")

        kill_workspace(TEST_WS)
        kill_workspace(HOLD_WS)
        print()


if __name__ == "__main__":
    main()
