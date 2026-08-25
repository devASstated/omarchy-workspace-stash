#!/usr/bin/env python3
"""
Measures the real minimum settle-wait needed after a window-removal
dispatch, for Approach D's attack numbers -- the 0.4s used everywhere in
this harness was a conservative guess, never actually measured. If it's
much larger than necessary, Approach D's ~1862x cost disadvantage against
Approach A shrinks accordingly (though it can't reach parity: D is
inherently N-1 live round-trips per stash op, A is one snapshot,
regardless of how fast each round-trip gets).

Method: for each candidate wait time, repeat a real removal (F4, remove
D, check B's rect compensates correctly) N times, and record whether the
captured geometry was already correct and stable at that wait -- not
assumed, checked against the known-correct final value from a generous
wait on the same operation.
"""
import time
from harness_common import (
    ensure_rule, spawn_named, kill_workspace, place_tree, Leaf, Split,
    HOLD_WS, TEST_WS, hyprctl, capture_rects,
)

F4 = Split("V", Split("H", Leaf("A"), Leaf("C")), Split("H", Leaf("B"), Leaf("D")))
NAMES = F4.leaves()


def one_removal_trial(wait_s):
    addr, titles = spawn_named(NAMES, f"settle-trial")
    place_tree(F4, addr, TEST_WS)
    time.sleep(0.3)
    title_to_name = {v: k for k, v in titles.items()}

    t0 = time.time()
    hyprctl("dispatch", 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (HOLD_WS, addr["D"]))
    time.sleep(wait_s)
    captured_at_wait = capture_rects(title_to_name, TEST_WS).get("B")
    elapsed = time.time() - t0

    # generous re-check to confirm ground truth (does it match what a long wait sees?)
    time.sleep(0.5)
    ground_truth = capture_rects(title_to_name, TEST_WS).get("B")

    kill_workspace(TEST_WS)
    kill_workspace(HOLD_WS)

    return captured_at_wait == ground_truth, elapsed, captured_at_wait, ground_truth


def main():
    ensure_rule()
    candidates_ms = [0, 10, 20, 50, 100, 400]
    repeats = 6

    print(f"{'wait(ms)':>10} | {'correct':>10} | {'avg elapsed(ms)':>16}", flush=True)
    for wait_ms in candidates_ms:
        wait_s = wait_ms / 1000.0
        results = []
        for i in range(repeats):
            ok, elapsed, captured, truth = one_removal_trial(wait_s)
            results.append((ok, elapsed))
            if not ok:
                print(f"    [wait={wait_ms}ms, trial {i}] MISMATCH: captured={captured} truth={truth}", flush=True)
        n_ok = sum(1 for ok, _ in results if ok)
        avg_elapsed = sum(e for _, e in results) / len(results)
        print(f"{wait_ms:>10} | {n_ok}/{repeats:<8} | {avg_elapsed*1000:>14.1f}", flush=True)


if __name__ == "__main__":
    main()
