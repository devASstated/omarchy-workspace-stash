import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// State owner for Workspace Stash. Hyprland is the source of truth for which
// windows are currently stashed: a window is "in the stash" iff it is a live
// Hyprland toplevel parked on stashWorkspace. `meta` below is auxiliary V2
// bookkeeping (pre-move geometry, batch id, source workspace) only — it is
// pruned to whatever is actually parked and never consulted to decide
// membership, so it can never drift into a second authoritative state.
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

  // Drop auxiliary entries for windows no longer parked (restored or closed
  // while hidden). Keeps `meta` bounded by the current stash, never larger.
  function pruneMeta() {
    var live = {}
    for (var i = 0; i < stashedToplevels.length; i++) {
      live[root.normalizedAddress(stashedToplevels[i])] = true
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

  // Snapshot helper: reads the live Hyprland model once into a plain JS
  // array. Callers must finish reading before issuing any moves — never
  // iterate a live Hyprland collection while relocating its members.
  function eligibleWindowsOn(workspaceName) {
    var list = []
    var values = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      var t = values[i]
      if (!t || !t.workspace || t.workspace.name !== workspaceName) continue
      var ipc = t.lastIpcObject || null
      list.push({
        address: root.normalizedAddress(t),
        x: ipc && Array.isArray(ipc.at) ? ipc.at[0] : 0,
        y: ipc && Array.isArray(ipc.at) ? ipc.at[1] : 0,
        width: ipc && Array.isArray(ipc.size) ? ipc.size[0] : 0,
        height: ipc && Array.isArray(ipc.size) ? ipc.size[1] : 0,
        floating: !!(ipc && ipc.floating),
        appId: (t.wayland && t.wayland.appId) || (ipc && ipc.class) || "",
        title: t.title || ""
      })
    }
    return list
  }

  // Move every eligible window on the focused normal workspace into the
  // stash. Safe to call repeatedly: it appends to whatever is already
  // parked rather than replacing it.
  function stash() {
    var workspace = Hyprland.focusedWorkspace
    if (!workspace || String(workspace.name).indexOf("special:") === 0) return "no-workspace"

    var snapshot = root.eligibleWindowsOn(workspace.name)
    if (snapshot.length === 0) return "empty"

    var batchId = root.nextBatchId
    root.nextBatchId = batchId + 1

    var nextMeta = {}
    for (var addr in root.meta) nextMeta[addr] = root.meta[addr]

    for (var i = 0; i < snapshot.length; i++) {
      var w = snapshot[i]
      if (!w.address) continue
      nextMeta[w.address] = {
        batchId: batchId,
        sourceWorkspace: workspace.name,
        x: w.x, y: w.y, width: w.width, height: w.height,
        floating: w.floating, appId: w.appId, title: w.title
      }
      root.moveAddress(w.address, root.stashWorkspace, false)
    }
    root.meta = nextMeta
    return "ok"
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

    for (var i = 0; i < snapshot.length; i++) {
      root.moveAddress(snapshot[i], destination, false)
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
  //   3. No explicit refocus is issued afterward. Hyprland silently
  //      substitutes its own top-of-stack window for any focus request
  //      into an already-populated special workspace, and that
  //      substitution isn't recoverable from the IPC/event stream —
  //      forcing focus onto it would misrepresent it as the user's actual
  //      request.
  //
  // The whole stash restores through the one authoritative restore() every
  // other input path already uses. Deactivation only ever fires from the
  // confirmed-active check in finishCollisionRestore() below, so ordinary
  // stash()/restore() calls (swipe gestures, SUPER+M, SUPER+ALT+M) can
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
