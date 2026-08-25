"""
Approach A: recursive guillotine-cut partitioning (feasibility docx §3.2,
Gate 2). Pure geometry logic, no Hyprland dependency at all -- shared by
gate2_geometry_partition.py (live round-trip against real captures) and
gate13_adversarial_geometry.py (synthetic parser-safety unit tests, no
live windows involved).
"""
from harness_common import Leaf, Split


def normalize(rects):
    """name -> (x,y,w,h)  =>  name -> (left, top, right, bottom).

    Raises ValueError on non-positive width/height rather than silently
    building an inverted interval and feeding it to the sweep -- malformed
    input has to be rejected at the boundary, not discovered later as a
    confusing downstream failure."""
    out = {}
    for n, (x, y, w, h) in rects.items():
        if w <= 0 or h <= 0:
            raise ValueError(f"malformed rect for {n!r}: w={w} h={h} (must be > 0)")
        out[n] = (x, y, x + w, y + h)
    return out


def _span_matches(a_lo, a_hi, b_lo, b_hi, tol):
    return abs(a_lo - b_lo) <= tol and abs(a_hi - b_hi) <= tol


def find_axis_cuts(names, R, tol, lo_idx, hi_idx, cross_lo_idx, cross_hi_idx):
    """Sweep sorted by the low edge on the split axis, tracking the running
    max of the high edge -- the standard interval-merge gap sweep. A
    candidate is accepted only if, ADDITIONALLY, the two groups' CROSS-axis
    extents match within tolerance -- i.e. this is a genuine full-span cut
    (both sides span the same range on the other axis), not merely "there
    happens to be a gap in sorted order on this axis."

    That second check is not optional: without it, a T-shaped arrangement
    where one side of a plausible-looking cut doesn't actually reach the
    full extent of the other (leaving part of the bounding box uncovered
    by any window) gets silently accepted as a clean split. Found and
    fixed via gate13_adversarial_geometry.py's cross_axis_span_mismatch
    case -- every fixture Gate 2 actually ran against came from real
    Dwindle output, which is always fully covered, so this gap in the
    original sweep never surfaced there."""
    order = sorted(names, key=lambda n: R[n][lo_idx])
    cuts = []
    running_max = R[order[0]][hi_idx]
    for i in range(1, len(order)):
        n = order[i]
        gap = R[n][lo_idx] - running_max
        if gap >= -tol:
            g1, g2 = order[:i], order[i:]
            g1_cross = (min(R[m][cross_lo_idx] for m in g1), max(R[m][cross_hi_idx] for m in g1))
            g2_cross = (min(R[m][cross_lo_idx] for m in g2), max(R[m][cross_hi_idx] for m in g2))
            if _span_matches(g1_cross[0], g1_cross[1], g2_cross[0], g2_cross[1], tol):
                cuts.append((g1, g2, gap))
        running_max = max(running_max, R[n][hi_idx])
    return cuts


def find_vertical_cuts(names, R, tol):
    return find_axis_cuts(names, R, tol, 0, 2, 1, 3)  # split on x, cross-check y


def find_horizontal_cuts(names, R, tol):
    return find_axis_cuts(names, R, tol, 1, 3, 0, 2)  # split on y, cross-check x


def partition_tree(names, R, tol=20, memo=None):
    if memo is None:
        memo = {}
    names = frozenset(names)
    if len(names) == 1:
        return Leaf(next(iter(names)))
    if names in memo:
        return memo[names]

    candidates = []
    for axis, cuts in (("V", find_vertical_cuts(names, R, tol)), ("H", find_horizontal_cuts(names, R, tol))):
        for g1, g2, gap in cuts:
            candidates.append((abs(gap), axis, frozenset(g1), frozenset(g2)))
    candidates.sort(key=lambda c: -c[0])  # strongest separation first

    for _, axis, g1, g2 in candidates:
        left = partition_tree(g1, R, tol, memo)
        right = partition_tree(g2, R, tol, memo)
        if left is not None and right is not None:
            result = Split(axis, left, right)
            memo[names] = result
            return result

    memo[names] = None
    return None
