"""
Shared plumbing for the reconstruction-feasibility gate scripts (Gate 1:
gate1_representative_leaf.py, Gate 2: gate2_geometry_partition.py). Nothing
in here is production code -- it's disposable test harness, kept in
experiments/ specifically because manifest.json's entryPoints only ever
reference Service.qml/BarWidget.qml, so nothing here can accidentally ship.

All Hyprland interaction goes through the same hl.dsp.* Lua dispatch
vocabulary Service.qml itself uses (confirmed by reading Service.qml
directly, not assumed), issued via plain `hyprctl`/`hyprctl --batch` calls
instead of Quickshell's Process/StdioCollector -- same effect, no QML
touched. Test windows only ever live on two runtime-only special
workspaces (never written to any config file, gone on the next Hyprland
restart) and are spawned/killed in a way that never touches the user's
real workspaces or windows -- see gate1's module docstring for the exact
mechanics and why each choice was made.
"""
import json
import os
import signal
import subprocess
import sys
import time

HOLD_WS = "special:swx-hold"
TEST_WS = "special:swx-test"
TITLE_PREFIX = "swx"


def hyprctl(*args):
    return subprocess.run(["hyprctl", *args], capture_output=True, text=True)


def repl(lua_code):
    r = hyprctl("repl", lua_code)
    if r.returncode != 0 or "error" in r.stdout.lower():
        print(f"  [repl warning] {lua_code!r} -> {r.stdout.strip()} {r.stderr.strip()}", file=sys.stderr)
    return r.stdout.strip()


def clients():
    r = hyprctl("-j", "clients")
    return json.loads(r.stdout)


def ensure_rule():
    repl(
        'hl.window_rule({ match = { title = "^%s-.*$" }, workspace = "%s silent" })'
        % (TITLE_PREFIX, HOLD_WS)
    )


def spawn(title):
    repl('hl.exec_cmd("foot -T %s sleep 3600")' % title)


def wait_for_titles(titles, timeout=4.0):
    deadline = time.time() + timeout
    found = {}
    while time.time() < deadline and len(found) < len(titles):
        for w in clients():
            t = w.get("title")
            if t in titles and t not in found:
                found[t] = w
        if len(found) < len(titles):
            time.sleep(0.1)
    missing = set(titles) - set(found)
    if missing:
        raise RuntimeError("windows never appeared: %s" % missing)
    return found


def kill_workspace(ws_name):
    for w in clients():
        if w.get("workspace", {}).get("name") == ws_name:
            pid = w.get("pid")
            try:
                os.kill(pid, signal.SIGTERM)
            except (ProcessLookupError, TypeError):
                pass


def spawn_named(names, run_tag):
    """Spawns one window per logical name, returns {name: address} once all
    have appeared. Titles are unique per call so repeated runs never collide
    with stale windows from a previous run."""
    titles = {n: f"{TITLE_PREFIX}-{run_tag}-{n}" for n in names}
    for t in titles.values():
        spawn(t)
    found = wait_for_titles(set(titles.values()))
    return {n: found[t]["address"] for n, t in titles.items()}, titles


# ---- tree model ------------------------------------------------------------

class Leaf:
    def __init__(self, name):
        self.name = name

    def leaves(self):
        return [self.name]

    def __repr__(self):
        return self.name


class Split:
    def __init__(self, axis, first, second):
        assert axis in ("V", "H")
        self.axis = axis
        self.first = first
        self.second = second

    def leaves(self):
        return self.first.leaves() + self.second.leaves()

    def __repr__(self):
        sep = "|" if self.axis == "V" else "/"
        return f"({self.first!r}{sep}{self.second!r})"


def representative(node):
    return node.name if isinstance(node, Leaf) else representative(node.first)


def direction_for(axis, flip_v=False, flip_h=False):
    # Canonical ordering: V -> first=left, second=right; H -> first=top,
    # second=bottom. flip_v/flip_h invert that per axis (right->left,
    # bottom->top) -- Gate 5 uses this to test the mirrored/rotated
    # orientations Gate 1/2 never exercised (every prior fixture used the
    # un-flipped default). Preselect controls where the SECOND
    # (about-to-be-inserted) window lands relative to the currently
    # focused (first) one.
    if axis == "V":
        return "l" if flip_v else "r"
    return "u" if flip_h else "d"


def build_steps(tree, flip_v=False, flip_h=False):
    """Preorder representative-substitution expansion (Approach B, proven
    live by Gate 1). Returns [(window_name, direction_or_None,
    focus_target_or_None), ...]."""
    steps = [(representative(tree), None, None)]

    def expand(node):
        if isinstance(node, Leaf):
            return
        rep_a = representative(node.first)
        rep_b = representative(node.second)
        steps.append((rep_b, direction_for(node.axis, flip_v, flip_h), rep_a))
        expand(node.first)
        expand(node.second)

    expand(tree)
    return steps


# ---- dispatch, mirroring structureClauses() exactly -------------------------

def dispatch_clause(lua_expr):
    return "dispatch " + lua_expr


def build_batch(steps, addr_of, dest_ws):
    clauses = []
    for window_name, direction, focus_target in steps:
        addr = addr_of[window_name]
        move = 'hl.dsp.window.move({ workspace = "%s", window = "address:%s", follow = false })' % (dest_ws, addr)
        focus = 'hl.dsp.focus({ window = "address:%s" })' % addr
        if focus_target is None:
            clauses += [move, focus]
        else:
            focus_prev = 'hl.dsp.focus({ window = "address:%s" })' % addr_of[focus_target]
            preselect = 'hl.dsp.layout("preselect %s")' % direction
            clauses += [focus_prev, preselect, move, focus]
    return [dispatch_clause(c) for c in clauses]


def fire_batch(clauses):
    hyprctl("--batch", " ; ".join(clauses))


def place_tree(tree, addr_of, dest_ws=TEST_WS, flip_v=False, flip_h=False):
    """Drives Hyprland to build `tree` out of the windows in addr_of, via one
    atomic hyprctl --batch call, exactly mirroring finishRestore()/
    finishMoveWorkspace()'s single-combined-dispatch approach."""
    steps = build_steps(tree, flip_v, flip_h)
    clauses = build_batch(steps, addr_of, dest_ws)
    fire_batch(clauses)


def resize_clause(addr, width, height):
    return 'hl.dsp.window.resize({ x = %d, y = %d, window = "address:%s" })' % (
        round(width), round(height), addr,
    )


def fire_resizes(addr_width_height):
    """addr_width_height: [(address, width, height), ...]. One atomic batch,
    mirroring geometryClauses()'s single separate resize pass -- structure
    is always fully built first, sizing always happens after, never
    interleaved (see Service.qml's own comment on why)."""
    clauses = [dispatch_clause(resize_clause(a, w, h)) for a, w, h in addr_width_height]
    fire_batch(clauses)


def capture_rects(names_by_title, ws_name=TEST_WS, timeout=2.0):
    """names_by_title: {title: logical_name}. Returns {logical_name: (x,y,w,h)}."""
    deadline = time.time() + timeout
    rects = {}
    while time.time() < deadline and len(rects) < len(names_by_title):
        for w in clients():
            t = w.get("title")
            if t in names_by_title and w.get("workspace", {}).get("name") == ws_name:
                rects[names_by_title[t]] = (w["at"][0], w["at"][1], w["size"][0], w["size"][1])
        if len(rects) < len(names_by_title):
            time.sleep(0.1)
    return rects


# ---- geometry helpers --------------------------------------------------------

def bbox(rects, names):
    xs0 = [rects[n][0] for n in names]
    ys0 = [rects[n][1] for n in names]
    xs1 = [rects[n][0] + rects[n][2] for n in names]
    ys1 = [rects[n][1] + rects[n][3] for n in names]
    x0, y0, x1, y1 = min(xs0), min(ys0), max(xs1), max(ys1)
    return (x0, y0, x1 - x0, y1 - y0)
