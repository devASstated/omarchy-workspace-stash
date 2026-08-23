import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// State owner for Workspace Stash. Hyprland is the source of truth for which
// windows are currently stashed: a window is "in the stash" iff it is a live
// Hyprland toplevel parked on stashWorkspace. `meta` below is auxiliary V2
// bookkeeping (pre-move geometry, batch id, source workspace) only — it is
// never consulted to decide membership, so it can never drift into a second
// authoritative state. Entries are removed explicitly, not by polling "is
// this still parked": restore() drops an address's entry the moment it
// restores it, and pruneMeta() drops one only once its window is gone for
// good (closed) — see pruneMeta() for why "currently parked" specifically
// was the wrong condition to key that on.
Item {
  id: root

  readonly property string stashWorkspace: "special:workspace-stash"

  property var meta: ({})
  property int nextBatchId: 1

  function normalizedAddress(toplevel) {
    if (!toplevel || !toplevel.address) return ""
    var address = String(toplevel.address)
    return address.indexOf("0x") === 0 ? address : "0x" + address
  }

  function isStashed(toplevel) {
    return toplevel !== null && toplevel.workspace !== null
      && toplevel.workspace.name === root.stashWorkspace
  }

  readonly property var stashedToplevels: (Hyprland.toplevels && Hyprland.toplevels.values
    ? Hyprland.toplevels.values : []).filter(function(t) { return root.isStashed(t) })

  readonly property int count: stashedToplevels.length
  readonly property bool hasStash: count > 0

  // Presentation-ready snapshot for the bar widget: identity and live display
  // fields come straight from Hyprland every time; batch/source come from the
  // auxiliary map when available.
  readonly property var items: stashedToplevels.map(function(t) {
    var address = root.normalizedAddress(t)
    var ipc = t.lastIpcObject || null
    var m = root.meta[address] || null
    return {
      address: address,
      title: t.title || "",
      appId: (t.wayland && t.wayland.appId) || (ipc && ipc.class) || "",
      batchId: m ? m.batchId : 0,
      sourceWorkspace: m ? m.sourceWorkspace : ""
    }
  })

  // Drop auxiliary entries for windows that no longer exist at all (closed
  // while hidden). Deliberately keyed on "does this window still exist
  // anywhere" (root.meta vs. the full toplevel list), not "is it currently
  // parked in the stash" (root.meta vs. stashedToplevels): stash()'s own
  // moveAddress() calls land in Hyprland one at a time, asynchronously, so
  // stashedToplevels updates window-by-window as each move is actually
  // applied. Keying prune on stashedToplevels pruned a freshly-stashed
  // window's own meta entry the instant a *different* window in the same
  // batch happened to land first — confirmed in testing to silently wipe
  // 2 of 3 windows' captured geometry/order data on every multi-window
  // stash. A window only needs pruning once it's gone for good, i.e. no
  // longer a toplevel anywhere — moving between workspaces never removes
  // it from that list, only closing it does.
  function pruneMeta() {
    var live = {}
    var values = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      live[root.normalizedAddress(values[i])] = true
    }
    var next = {}
    for (var addr in root.meta) {
      if (live[addr]) next[addr] = root.meta[addr]
    }
    root.meta = next
  }

  onStashedToplevelsChanged: {
    root.pruneMeta()
    if (root.collisionRestoreInFlight && stashedToplevels.length === 0) root.finishCollisionRestore()
  }

  function moveAddress(address, workspace, follow) {
    if (!address || !workspace) return
    var request = "hl.dsp.window.move({ workspace = " + JSON.stringify(workspace)
      + ", window = " + JSON.stringify("address:" + address)
      + ", follow = " + (follow ? "true" : "false") + " })"
    Quickshell.execDetached(["hyprctl", "dispatch", request])
  }

  // Builds one "dispatch <expr>" clause for hyprctl --batch. Never fired
  // standalone during restore() — see structureClauses()/geometryClauses()
  // below for why.
  function dispatchClause(luaExpr) {
    return "dispatch " + luaExpr
  }

  // Phase 1 of restoring one window: place it and, for a tiled window,
  // focus it so the *next* window's insertion splits against it (see
  // restoreOrder() below). Deliberately builds only the tree topology —
  // no sizing here. See geometryClauses() below for why that has to wait
  // until every window's structureClauses() has already run.
  //
  // Returns clauses to be collected and fired as ONE combined `hyprctl
  // --batch` call across the *whole* restore (see restore() below), not
  // dispatched per window: separate per-window processes, even each
  // individually batched, aren't guaranteed to reach Hyprland in the
  // order they were spawned in — OS process scheduling doesn't promise
  // that — so under fast repeated restores a later window's move could
  // land before an earlier one's focus, silently reassigning which
  // window ends up in which split. One process for the entire sequence
  // removes that cross-window ordering gap. (stash() doesn't need this —
  // moveAddress() alone is enough there, since park order in the hidden
  // workspace is never read back.)
  function structureClauses(address, destination, meta) {
    if (!address || !destination) return []
    var move = "hl.dsp.window.move({ workspace = " + JSON.stringify(destination)
      + ", window = " + JSON.stringify("address:" + address) + ", follow = false })"
    if (meta && meta.floating) return [move].map(root.dispatchClause)
    var focus = "hl.dsp.focus({ window = " + JSON.stringify("address:" + address) + " })"
    return [move, focus].map(root.dispatchClause)
  }

  // Phase 2: restore captured size (and, for floating, position) — for
  // every window, tiled or not, using the exact same absolute resize
  // dispatch either way (confirmed empirically: Dwindle accepts an
  // absolute { x = width, y = height } resize on a tiled window the same
  // as a floating one, adjusting its sibling to compensate). This has to
  // run only after ALL of this restore's structureClauses() have already
  // been dispatched, not interleaved per window: Dwindle re-splits evenly
  // whenever a new window is inserted, so resizing window N to its
  // captured ratio and *then* inserting window N+1 would just reset N
  // back to an even split. Building the whole tree first and sizing
  // everything after avoids that.
  function geometryClauses(address, meta, monitor) {
    if (!address || !meta || !(meta.width > 0) || !(meta.height > 0)) return []
    var resize = "hl.dsp.window.resize({ x = " + Math.round(meta.width)
      + ", y = " + Math.round(meta.height)
      + ", window = " + JSON.stringify("address:" + address) + " })"
    if (!meta.floating) return [resize].map(root.dispatchClause)
    var pos = root.clampToMonitor(meta.x, meta.y, meta.width, meta.height, monitor)
    var position = "hl.dsp.window.move({ x = " + Math.round(pos.x)
      + ", y = " + Math.round(pos.y)
      + ", relative = false, window = " + JSON.stringify("address:" + address) + " })"
    return [resize, position].map(root.dispatchClause)
  }

  // Keeps a restored floating window on-screen when the destination
  // monitor is smaller than the one its geometry was captured on.
  function clampToMonitor(x, y, width, height, monitor) {
    if (!monitor) return { x: x, y: y }
    var maxX = monitor.x + Math.max(monitor.width - width, 0)
    var maxY = monitor.y + Math.max(monitor.height - height, 0)
    return {
      x: Math.min(Math.max(x, monitor.x), maxX),
      y: Math.min(Math.max(y, monitor.y), maxY)
    }
  }

  // Best-effort restore order for tiled windows: Dwindle derives its split
  // tree from insertion order, so restoring in an order that approximates
  // the original spatial arrangement lands materially closer to the
  // original layout than an arbitrary order — without the failure-prone
  // work of actually inferring the split tree from geometry alone (see
  // docs/FEATURES.md §7.3-7.4 on why that's hard and out of scope here).
  // Batches restore oldest first; within a batch, windows sort in reading
  // order. A window with no surviving meta (e.g. a shell restart wiped it)
  // sorts as batch 0 — i.e. today's unordered behavior, the intended
  // fallback when there's nothing to order by.
  //
  // Order alone isn't enough, though: Dwindle splits whichever tiled
  // window is currently *active*, not just "the last one inserted", so
  // restore() also has to focus each tiled window right after moving it
  // in (see structureClauses() above) to keep that active-window chain
  // matching what it was during the original stash. Tested without that
  // focus step, order alone reproduced the original layout for 2 windows
  // but reliably scrambled it for 3+. It also doesn't touch size at all —
  // see geometryClauses() above for why ratio restoration has to be a
  // fully separate pass, run only after every window's structure is
  // already in place.
  //
  // Windows sharing a tile don't always report exactly the same y — a
  // grouped/tabbed window's captured y sits a bit lower than an ungrouped
  // neighbor at the same visual row, because the group's tab bar pushes
  // its content down (confirmed empirically: ~28px for a 2-tab group).
  // Treating that as "a different row" ranked the group after a window
  // that was actually to its right, swapping their left/right placement
  // on restore even though the group itself stayed intact. rowTolerance
  // absorbs that kind of minor chrome offset (tab bars, borders, gaps)
  // without being wide enough to blur two genuinely stacked windows into
  // the same row.
  readonly property int rowTolerance: 40

  function restoreOrder(addresses) {
    var meta = root.meta
    return addresses.slice().sort(function(a, b) {
      var ma = meta[a] || null
      var mb = meta[b] || null
      var batchA = ma ? ma.batchId : 0
      var batchB = mb ? mb.batchId : 0
      if (batchA !== batchB) return batchA - batchB
      var yA = ma ? ma.y : 0
      var yB = mb ? mb.y : 0
      if (Math.abs(yA - yB) > root.rowTolerance) return yA - yB
      var xA = ma ? ma.x : 0
      var xB = mb ? mb.x : 0
      return xA - xB
    })
  }

  property string pendingStashWorkspace: ""
  property int pendingStashBatchId: 0

  // Move every eligible window on the focused normal workspace into the
  // stash. Safe to call repeatedly: it appends to whatever is already
  // parked rather than replacing it. Both *which* windows are eligible and
  // their geometry come from finishStash() below, off one fresh hyprctl
  // query — not from Hyprland.toplevels. That cache was tried for
  // eligibility first (geometry alone was fixed this way earlier), but
  // under fast repeated stash/restore cycling a window's cached workspace
  // membership can still briefly read as wherever it was *before* the
  // previous cycle's move, not after — silently grabbing the wrong subset
  // and leaving stale geometry/order data behind for whatever got missed.
  // Only the workspace identity to stash *from* is read synchronously
  // here, from Hyprland.focusedWorkspace — that tracked reliably in
  // testing; only per-window state was the unreliable part.
  function stash() {
    var workspace = Hyprland.focusedWorkspace
    if (!workspace || String(workspace.name).indexOf("special:") === 0) return "no-workspace"
    if (stashCaptureProcess.running) return "busy"

    root.pendingStashWorkspace = workspace.name
    root.pendingStashBatchId = root.nextBatchId
    root.nextBatchId = root.pendingStashBatchId + 1
    stashCaptureProcess.running = true
    return "ok"
  }

  Process {
    id: stashCaptureProcess
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: stashCaptureOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var clients = []
      if (exitCode === 0) {
        try { clients = JSON.parse(stashCaptureOutput.text || "[]") } catch (e) { clients = [] }
      }
      root.finishStash(clients)
    }
  }

  // Determines eligibility *and* captures geometry from the same fresh
  // query, then issues the moves — one ground-truth source for both,
  // instead of letting them potentially disagree.
  function finishStash(clients) {
    var nextMeta = {}
    for (var addr in root.meta) nextMeta[addr] = root.meta[addr]

    var movedAny = false
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.workspace || c.workspace.name !== root.pendingStashWorkspace) continue
      var address = root.normalizedAddress({ address: c.address })
      if (!address) continue
      nextMeta[address] = {
        batchId: root.pendingStashBatchId,
        sourceWorkspace: root.pendingStashWorkspace,
        x: Array.isArray(c.at) ? c.at[0] : 0,
        y: Array.isArray(c.at) ? c.at[1] : 0,
        width: Array.isArray(c.size) ? c.size[0] : 0,
        height: Array.isArray(c.size) ? c.size[1] : 0,
        floating: !!c.floating,
        appId: c.class || "",
        title: c.title || ""
      }
      root.moveAddress(address, root.stashWorkspace, false)
      movedAny = true
    }
    if (movedAny) root.meta = nextMeta
  }

  // Restore the complete surviving stash — everything currently parked on
  // stashWorkspace, regardless of which stash() call put it there — onto
  // whatever workspace is focused right now.
  function restore() {
    var snapshot = root.stashedToplevels
      .map(function(t) { return root.normalizedAddress(t) })
      .filter(function(a) { return !!a })
    if (snapshot.length === 0) return "empty"

    var workspace = Hyprland.focusedWorkspace
    if (!workspace) return "no-workspace"
    var destination = workspace.name

    var monitor = workspace.monitor || null
    var ordered = root.restoreOrder(snapshot)
    var structure = []
    var geometry = []
    for (var i = 0; i < ordered.length; i++) {
      var address = ordered[i]
      var m = root.meta[address]
      structure = structure.concat(root.structureClauses(address, destination, m))
      geometry = geometry.concat(root.geometryClauses(address, m, monitor))
    }
    var clauses = structure.concat(geometry)
    if (clauses.length > 0) {
      Quickshell.execDetached(["hyprctl", "--batch", clauses.join(" ; ")])
    }

    var nextMeta = {}
    for (var addr in root.meta) {
      if (snapshot.indexOf(addr) === -1) nextMeta[addr] = root.meta[addr]
    }
    root.meta = nextMeta
    return "ok"
  }

  function toggle() {
    return root.hasStash ? root.restore() : root.stash()
  }

  // External-focus collision safeguard: special:workspace-stash must never
  // surface as a user-facing scratchpad. An external "launch or focus"
  // command (e.g. Omarchy's stock SUPER+SHIFT+M Spotify binding, or any
  // similar omarchy-launch-or-focus script) matches windows by class/title
  // system-wide with no workspace awareness. If the match is parked here,
  // Hyprland reveals this workspace to satisfy the focus request even
  // though Hyprland.focusedWorkspace itself never changes, so nothing else
  // in this file would notice on its own.
  //
  // Three invariants below were each the product of a failed first attempt
  // — see docs/DESIGN-JOURNEY.md for the full investigation. A change here
  // should not violate any of them:
  //   1. Detection reads the raw Hyprland event stream (Hyprland.rawEvent,
  //      "activespecial"), never Quickshell's cached monitor/workspace
  //      properties — those read back wrong values here, not just a
  //      missing change signal, even sampled synchronously at the right
  //      instant.
  //   2. Deactivation (once the stash empties) is gated on a fresh
  //      `hyprctl -j monitors` query, not on tracking that same event
  //      stream — Hyprland does not reliably emit a clean "deactivated"
  //      event when a special workspace empties out on its own, so a
  //      purely event-driven flag can race and skip deactivation on
  //      exactly the case this exists to catch.
  //   3. No explicit refocus is issued afterward chasing what the external
  //      shortcut was trying to reach. Hyprland silently substitutes its
  //      own top-of-stack window for any focus request into an
  //      already-populated special workspace, and that substitution isn't
  //      recoverable from the IPC/event stream — forcing focus onto it
  //      would misrepresent it as the user's actual request. (restore()
  //      does focus each tiled window as it's placed, for Dwindle
  //      ordering — see restoreOrder() — which leaves the last restored
  //      tiled window focused when this collision path finishes. That's
  //      an unrelated, intentional side effect of getting the layout
  //      right, not a refocus attempt aimed at the collision itself.)
  //
  // The whole stash restores through the one authoritative restore() every
  // other input path already uses. Deactivation only ever fires from the
  // confirmed-active check in finishCollisionRestore() below, so ordinary
  // stash()/restore() calls (swipe gestures, SUPER+M, SUPER+CTRL+M) can
  // never accidentally open the special workspace themselves.
  property bool collisionRestoreInFlight: false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "activespecial") return
      var workspaceName = String(event.data || "").split(",")[0]
      if (workspaceName === root.stashWorkspace) root.handleExposedStash()
    }
  }

  // Reentrancy guard: while our own collision-triggered restore is moving
  // windows out, Hyprland may still report the workspace as active until
  // the last window leaves, and further activespecial events can arrive
  // mid-transition. Ignore them entirely while one is already in flight
  // instead of stacking redundant restore cycles. Not considered complete
  // until the special workspace is confirmed inactive too, not just an
  // empty stash — see finishCollisionRestore().
  function handleExposedStash() {
    if (root.collisionRestoreInFlight) return
    if (!root.hasStash) return

    root.collisionRestoreInFlight = true
    root.restore()

    // restore() only fires detached moves; it does not guarantee Hyprland
    // has applied them by the time it returns. Completion is deferred to
    // onStashedToplevelsChanged above, which fires from the same live
    // Hyprland toplevel model the bar/count already rely on. This fallback
    // only covers the case where restore() found nothing to move despite
    // hasStash just reading true, so the flag can't get stuck.
    if (root.stashedToplevels.length === 0) root.finishCollisionRestore()
  }

  function finishCollisionRestore() {
    if (!specialVisibilityProcess.running) specialVisibilityProcess.running = true
  }

  // toggle_special() takes the special workspace name without its
  // "special:" prefix — stashWorkspace above keeps the prefixed form
  // because that's how Hyprland reports it everywhere else (toplevel
  // .workspace.name, the activespecial event, hyprctl monitors -j).
  readonly property string stashWorkspaceBareName: "workspace-stash"

  Process {
    id: specialVisibilityProcess
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      id: specialVisibilityOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var stillActive = false
      if (exitCode === 0) {
        try {
          var monitors = JSON.parse(specialVisibilityOutput.text || "[]")
          for (var i = 0; i < monitors.length; i++) {
            var special = monitors[i] ? monitors[i].specialWorkspace : null
            if (special && special.name === root.stashWorkspace) { stillActive = true; break }
          }
        } catch (e) {
          stillActive = false
        }
      }
      if (stillActive) {
        Quickshell.execDetached(["hyprctl", "dispatch",
          "hl.dsp.workspace.toggle_special(" + JSON.stringify(root.stashWorkspaceBareName) + ")"])
      }
      root.collisionRestoreInFlight = false
    }
  }

  IpcHandler {
    target: "workspace-stash"

    function stash(): string { return root.stash() }
    function restore(): string { return root.restore() }
    function toggle(): string { return root.toggle() }
    function ping(): string { return "ok" }
  }
}
