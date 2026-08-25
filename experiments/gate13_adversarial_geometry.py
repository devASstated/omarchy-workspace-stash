#!/usr/bin/env python3
"""
Gate 13 (GPT's addendum to the feasibility direction, F13): parser-safety
unit tests for partition_tree(). Pure synthetic geometry -- no live
Hyprland involved at all, nothing spawned, nothing to clean up.

The goal is explicitly NOT to make partition_tree() handle malformed
geometry. It's to prove that malformed / non-sliceable geometry is
rejected deterministically and safely: no crash, no fabricated
plausible-looking wrong tree. Positive controls run alongside the
negative fixtures so a clean run can't just mean the parser became too
conservative and started rejecting everything.

Every case's expected outcome below was hand-verified against
partition_tree()'s actual sweep logic before being written down (not
guessed) -- see the reasoning trail in the conversation this was built
in. One case (cross_axis_span_mismatch) is the fixture that actually
found a real gap in Gate 2's original implementation: the original sweep
only checked for a gap on the split axis, never that both sides
genuinely spanned the same range on the OTHER axis. A T-shaped
uncovered-region layout exploited exactly that and was silently accepted
as a clean split. partition.py's find_axis_cuts() now checks both; this
suite is what caught it and is what should catch any regression of it.
"""
import sys

from partition import normalize, partition_tree

NEGATIVE_CASES = [
    (
        "corner_overlap",
        {"A": (0, 0, 100, 100), "B": (50, 50, 100, 100)},
        20,
        "two rectangles overlapping diagonally at a corner -- no guillotine cut exists",
    ),
    (
        "straddling_rectangle",
        {
            "A": (0, 0, 50, 100),
            "B": (50, 0, 50, 50),
            "C": (50, 50, 50, 50),
            "D": (25, 0, 50, 100),
        },
        20,
        "D spans x=25..75, straddling the otherwise-plausible x=50 cut between A and B/C",
    ),
    (
        "pinwheel_non_guillotine",
        {
            "A": (0, 0, 70, 30),
            "B": (70, 0, 30, 70),
            "C": (30, 70, 70, 30),
            "D": (0, 30, 30, 70),
            "E": (30, 30, 40, 40),
        },
        20,
        "classic 5-rectangle windmill: no straight full-span line avoids crossing a rectangle",
    ),
    (
        "cross_axis_span_mismatch",
        {"A": (0, 0, 100, 50), "B": (0, 50, 50, 50), "C": (50, 50, 50, 20)},
        20,
        "A|{B,C} looks like a clean top/bottom split, but within {B,C} C is short "
        "(height 20 vs B's 50) -- a 30x30 region goes uncovered by any window. "
        "THE case that found the missing cross-axis check in Gate 2's original sweep.",
    ),
    (
        "duplicated_fully_overlapping",
        {"A": (0, 0, 50, 100), "B": (0, 0, 50, 100), "C": (50, 0, 50, 100)},
        20,
        "A and B are pixel-identical (F9 group precursor). The outer cut against C is "
        "findable, but {A,B} alone has no separating cut -- correctly fails until a "
        "Group node exists, matching F9's own open question.",
    ),
    (
        "excessive_overlap_beyond_tolerance",
        {"A": (0, 0, 50, 100), "B": (44, 0, 50, 100)},
        5,
        "6px overlap with tol=5 -- real overlap, not border noise, must not be treated as adjacent",
    ),
]

POSITIVE_CASES = [
    (
        "two_way_split",
        {"A": (0, 0, 50, 100), "B": (50, 0, 50, 100)},
        20,
        None,
    ),
    (
        "true_2x2_grid",
        {"A": (0, 0, 50, 50), "C": (0, 50, 50, 50), "B": (50, 0, 50, 50), "D": (50, 50, 50, 50)},
        20,
        None,
    ),
    (
        "extreme_ratio_90_10",
        {"A": (0, 0, 90, 100), "B": (90, 0, 10, 100)},
        20,
        "imbalanced split -- cross-axis span still matches exactly, must not be penalized for it",
    ),
    (
        "overlap_just_within_tolerance",
        {"A": (0, 0, 50, 100), "B": (46, 0, 50, 100)},
        5,
        "4px overlap with tol=5 -- within tolerance, must still be accepted",
    ),
    (
        "pseudo_tiled_shrink",
        {"A": (0, 0, 40, 100), "B": (50, 0, 50, 100)},
        20,
        "A doesn't fill its slot, leaving a 10px internal gap -- still one real boundary "
        "to find; a positive gap is never penalized regardless of size, only overlap is tolerance-bound",
    ),
    (
        "deep_asymmetric_six_window",
        {  # ((A/(B|C))|((D|E)/F)) -- same shape as live Gate 2's F7
            "A": (0, 0, 50, 40),
            "B": (0, 40, 25, 60),
            "C": (25, 40, 25, 60),
            "D": (50, 0, 25, 55),
            "E": (75, 0, 25, 55),
            "F": (50, 55, 50, 45),
        },
        20,
        None,
    ),
]

MALFORMED_CASES = [
    ("zero_width", {"A": (0, 0, 0, 100), "B": (0, 0, 50, 100)}),
    ("negative_width", {"A": (0, 0, -10, 100), "B": (0, 0, 50, 100)}),
    ("zero_height", {"A": (0, 0, 50, 0), "B": (0, 0, 50, 100)}),
]


def run_negative(name, rects, tol, note):
    R = normalize(rects)
    try:
        tree = partition_tree(set(rects.keys()), R, tol=tol)
    except Exception as e:
        print(f"  [{name}] FAIL: partition_tree() raised {type(e).__name__}: {e} (must never crash)")
        return False
    if tree is None:
        print(f"  [{name}] PASS (correctly rejected) -- {note}")
        return True
    print(f"  [{name}] FAIL: expected rejection, got tree={tree!r}  -- {note}")
    return False


def run_positive(name, rects, tol, note):
    R = normalize(rects)
    try:
        tree = partition_tree(set(rects.keys()), R, tol=tol)
    except Exception as e:
        print(f"  [{name}] FAIL: partition_tree() raised {type(e).__name__}: {e} (must never crash)")
        return False
    if tree is None:
        print(f"  [{name}] FAIL: expected a valid tree, got None" + (f"  -- {note}" if note else ""))
        return False
    recovered = set(tree.leaves())
    expected = set(rects.keys())
    if recovered != expected:
        print(f"  [{name}] FAIL: leaf set mismatch: {recovered} vs {expected}")
        return False
    suffix = f"  -- {note}" if note else ""
    print(f"  [{name}] PASS  tree={tree!r}{suffix}")
    return True


def run_malformed(name, rects):
    try:
        normalize(rects)
    except ValueError as e:
        print(f"  [{name}] PASS (rejected at input boundary: {e})")
        return True
    print(f"  [{name}] FAIL: normalize() should have rejected this, it didn't")
    return False


def main():
    print("=== negative fixtures (must be rejected, never crash) ===")
    neg = [run_negative(*c) for c in NEGATIVE_CASES]

    print("\n=== positive controls (must succeed) ===")
    pos = [run_positive(*c) for c in POSITIVE_CASES]

    print("\n=== malformed input (must be rejected at the boundary) ===")
    mal = [run_malformed(*c) for c in MALFORMED_CASES]

    print("\n=== summary ===")
    print(f"  negative:  {sum(neg)}/{len(neg)} correctly rejected")
    print(f"  positive:  {sum(pos)}/{len(pos)} correctly accepted")
    print(f"  malformed: {sum(mal)}/{len(mal)} correctly rejected at input boundary")

    ok = all(neg) and all(pos) and all(mal)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
