#!/usr/bin/env python3
"""
Seam integration test (GPT): exercises the ACTUAL hybrid orchestration
end-to-end, not A and D in isolation. Three paths:

  1. A succeeds -> D never touched, confirmed by instrumentation, not assumed.
  2. A fails (None) -> D's destructive moves ARE the stash itself, not a
     separate probe-then-stash step -> restore via representative-leaf.
  3. Path 2, with a real window killed mid-escalation -> full address audit.

`hybrid_stash()` below is the orchestration under test -- shaped the way
a real Service.qml implementation would be, not a test harness
convenience: fresh capture, try A, escalate to D only on None, D's moves
double as the actual stash, restore always goes through the same
representative-leaf replay regardless of which path produced the tree.
"""
import os
import signal
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl,
)
from hypr_socket import raw_json, raw_dispatch
from partition import normalize, partition_tree
from attack_D_full_topology import infer_axis_and_direction, rebuild_tree_from_full_record

RESTORE_WS = "special:swx-restore"


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
    pid = address_pid_map().get(addr)
    if pid:
        os.kill(pid, signal.SIGTERM)


def bbox(rects, names):
    xs0 = [rects[n][0] for n in names]
    ys0 = [rects[n][1] for n in names]
    xs1 = [rects[n][0] + rects[n][2] for n in names]
    ys1 = [rects[n][1] + rects[n][3] for n in names]
    return (min(xs0), min(ys0), max(xs1) - min(xs0), max(ys1) - min(ys0))


def d_escalation_stash(addr, all_names, title_to_name, removal_order,
                        inject_kill_target=None, inject_before_step=None):
    """D's destructive decomposition -- the moves themselves ARE the stash,
    not a separate step. Failure-tolerant: detects externally-closed
    windows and adapts rather than crashing. Returns (record, log,
    unaccounted_for)."""
    remaining = list(all_names)
    record = []
    log = []
    prior = capture_rects_fast({t: n for t, n in title_to_name.items() if n in remaining}, TEST_WS)

    for name in removal_order:
        if inject_before_step == name and inject_kill_target is not None:
            log.append(f"INJECTING: killing {inject_kill_target!r} mid-escalation")
            kill_window_directly(addr[inject_kill_target])
            time.sleep(0.3)

        current = capture_rects_fast({t: n for t, n in title_to_name.items() if n in remaining}, TEST_WS)
        missing = [n for n in remaining if n not in current]
        if missing:
            log.append(f"  detected missing before {name!r}: {missing}")
            for m in missing:
                remaining.remove(m)
            prior = current

        if name not in remaining:
            log.append(f"  {name!r} already gone -- skip")
            continue

        still_remaining = [n for n in remaining if n != name]
        removed_rect = prior.get(name)
        raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[name]))
        after = capture_rects_fast({t: n for t, n in title_to_name.items() if n in still_remaining}, TEST_WS)
        changed = [n for n in still_remaining if prior.get(n) != after.get(n)]
        if changed and removed_rect is not None:
            axis, is_first = infer_axis_and_direction(removed_rect, bbox(prior, changed), bbox(after, changed))
        else:
            axis, is_first = None, None
        record.append((name, changed, axis, is_first))
        log.append(f"  removed {name!r}: compensating cluster = {changed}")
        remaining.remove(name)
        prior = after

    for last in list(remaining):
        still_there = capture_rects_fast({t: n for t, n in title_to_name.items() if n == last}, TEST_WS)
        if last in still_there:
            raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[last]))
            log.append(f"  explicit final move: {last!r} -> {HOLD_WS}")
        else:
            log.append(f"  final survivor {last!r} already gone")
        remaining.remove(last)

    return record, log


def hybrid_stash(addr, all_names, title_to_name, removal_order_for_d,
                  inject_kill_target=None, inject_before_step=None, tol=20):
    """The orchestration under test. Returns a report dict."""
    t0 = time.time()
    baseline = capture_rects_fast(title_to_name, TEST_WS)
    R = normalize(baseline)
    a_tree = partition_tree(set(all_names), R, tol=tol)

    if a_tree is not None:
        # PATH 1: A succeeded. Simple stash -- move every window
        # independently, exactly like today's real stash(), zero D steps.
        for n in all_names:
            raw_dispatch('hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr[n]))
        elapsed = time.time() - t0
        return {"used_D": False, "layout_tree": a_tree, "d_steps": 0, "log": [], "elapsed": elapsed}

    # PATH 2/3: A returned None. D's destructive moves ARE the stash.
    record, log = d_escalation_stash(
        addr, all_names, title_to_name, removal_order_for_d,
        inject_kill_target=inject_kill_target, inject_before_step=inject_before_step,
    )
    surviving = [n for n in all_names if n != inject_kill_target] if inject_kill_target else all_names
    filtered_record = [
        (r, [c for c in ch if c != inject_kill_target], ax, f)
        for r, ch, ax, f in record
    ]
    d_tree, err = rebuild_tree_from_full_record(filtered_record, surviving)
    elapsed = time.time() - t0
    return {
        "used_D": True, "layout_tree": d_tree, "reconstruction_error": err,
        "d_steps": len(record), "log": log, "elapsed": elapsed, "surviving": surviving,
    }


def restore_and_verify(layout_tree, expected_tree, surviving_names, tag):
    """Spawns a fresh set of windows for the surviving names and replays
    layout_tree via the proven representative-leaf backend -- the SAME
    restore path regardless of whether A or D produced the tree."""
    from harness_common import spawn_named, place_tree as _place_tree
    addr, titles = spawn_named(surviving_names, tag)
    _place_tree(layout_tree, addr, RESTORE_WS)
    time.sleep(0.4)
    title_to_name = {v: k for k, v in titles.items()}
    final = capture_rects_fast(title_to_name, RESTORE_WS)
    kill_workspace(RESTORE_WS)

    match = repr(layout_tree) == repr(expected_tree) if expected_tree is not None else None
    return {"restored_geometry": final, "topology_matches_original": match}


def audit_addresses(all_names, addr, title_to_name, killed=None):
    live = raw_json("clients")
    by_addr = {w["address"]: w for w in live}
    report = {}
    for n in all_names:
        a = addr[n]
        w = by_addr.get(a)
        if w is None:
            report[n] = "CLOSED" if n == killed else "!!UNACCOUNTED FOR!!"
        else:
            report[n] = f"present on {w.get('workspace', {}).get('name')}"
    return report
