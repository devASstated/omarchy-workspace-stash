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

  // Which side (l/r/u/d) Dwindle's "preselect" needs so the *next* tiled
  // window lands where `meta` says it actually sat relative to `reference`
  // — the window it's about to split off (see structureClauses() below).
  // Whichever axis has the larger absolute offset is treated as the split
  // axis, the same assumption isSeparated() above makes about sibling
  // rectangles.
  function preselectDirection(meta, reference) {
    var dx = meta.x - reference.x
    var dy = meta.y - reference.y
    if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "l" : "r"
    return dy < 0 ? "u" : "d"
  }

  // Phase 1 of restoring one window: place it and, for a tiled window,
  // focus it so the *next* window's insertion splits against it (see
  // restoreOrder() below). Deliberately builds only the tree topology —
  // no sizing here. See geometryClauses() below for why that has to wait
  // until every window's structureClauses() has already run.
  //
  // `previousMeta` is the last tiled window placed before this one (null
  // for the first), used to preselect which side of it this window should
  // land on via `hl.dsp.layout("preselect ...")` — confirmed live to
  // control Dwindle's split direction for the next inserted window.
  // Without it, order and size reconstruct correctly but left/right or
  // top/bottom placement is whatever Dwindle's own default heuristic
  // picks, which doesn't necessarily match the captured layout (found from
  // a live report: topology and size were right, but a lone window and a
  // stacked pair could still come back mirrored to the opposite side).
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
  function structureClauses(address, destination, meta, previousMeta) {
    if (!address || !destination) return []
    var move = "hl.dsp.window.move({ workspace = " + JSON.stringify(destination)
      + ", window = " + JSON.stringify("address:" + address) + ", follow = false })"
    if (meta && meta.floating) return [move].map(root.dispatchClause)
    var focus = "hl.dsp.focus({ window = " + JSON.stringify("address:" + address) + " })"
    if (!previousMeta) return [move, focus].map(root.dispatchClause)
    var direction = root.preselectDirection(meta, previousMeta)
    var preselect = "hl.dsp.layout(" + JSON.stringify("preselect " + direction) + ")"
    return [preselect, move, focus].map(root.dispatchClause)
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
  //
  // skipTiledResize: when the destination already had other windows on
  // it, the incoming group lands one level deeper in the split tree than
  // whatever it was captured at (existing window, then the incoming
  // chain, rather than just the incoming chain alone) — captured absolute
  // sizes stop adding up for that deeper nesting, and forcing them anyway
  // produced windows squeezed down to a handful of pixels, confirmed
  // empirically. Tiled ratio-restore is skipped in that case and Hyprland
  // is left to size the merge naturally instead; floating restore is
  // unaffected either way, since a floating window's position/size never
  // depends on sibling tree structure.
  function geometryClauses(address, meta, monitor, skipTiledResize) {
    if (!address || !meta || !(meta.width > 0) || !(meta.height > 0)) return []
    var resize = "hl.dsp.window.resize({ x = " + Math.round(meta.width)
      + ", y = " + Math.round(meta.height)
      + ", window = " + JSON.stringify("address:" + address) + " })"
    if (!meta.floating) return skipTiledResize ? [] : [resize].map(root.dispatchClause)
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
  // tree from insertion order. structureClauses() can only ever build a
  // "caterpillar" tree — each insert splits off exactly one leaf from
  // whichever window was most recently placed — so the goal here isn't
  // full split-tree inference (docs/FEATURES.md §7.3-7.4 on why that's
  // hard and still out of scope), just finding the one insertion order
  // that reproduces the actual caterpillar shape when the layout is one.
  // Batches restore oldest first; within a batch, peelOrder() (below)
  // does the real ordering work. A window with no surviving meta (e.g. a
  // shell restart wiped it) sorts as batch 0 — i.e. today's unordered
  // behavior, the intended fallback when there's nothing to order by.
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
  // the same row. The same tolerance also absorbs it in isSeparated()
  // below, for the same reason.
  readonly property int rowTolerance: 40

  // Fallback/tie-break order: reading order (row, then column). Used to
  // seed peelOrder() below and to order whatever peelOrder can't resolve.
  function sortByRowThenX(list) {
    return list.slice().sort(function(a, b) {
      if (Math.abs(a.y - b.y) > root.rowTolerance) return a.y - b.y
      return a.x - b.x
    })
  }

  // True if `candidate` sits entirely to one side of every window in
  // `others` along either axis — i.e. a single full-span vertical or
  // horizontal line could separate it from the rest. That's exactly what
  // the *outermost* split of a caterpillar tree looks like (one lone
  // window against everything else, which is itself further split), so
  // it's the geometric signal peelOrder() uses to find what to place — and
  // therefore insert — next.
  function isSeparated(candidate, others) {
    var tol = root.rowTolerance
    var fullyLeft = true, fullyRight = true, fullyAbove = true, fullyBelow = true
    for (var i = 0; i < others.length; i++) {
      var o = others[i]
      if (candidate.x + candidate.width > o.x + tol) fullyLeft = false
      if (candidate.x < o.x + o.width - tol) fullyRight = false
      if (candidate.y + candidate.height > o.y + tol) fullyAbove = false
      if (candidate.y < o.y + o.height - tol) fullyBelow = false
    }
    return fullyLeft || fullyRight || fullyAbove || fullyBelow
  }

  // Repeatedly peels off one fully-separated window at a time, outermost
  // first, reconstructing the insertion order for any caterpillar-shaped
  // layout — including "one window alone, the rest grouped together",
  // which the old flat row/x sort got wrong whenever the lone window
  // happened to sort ahead of only part of the group (see
  // docs/DESIGN-JOURNEY.md §20 for the live repro that found this). Stops
  // the moment nothing left can be cleanly peeled off — a true grid layout
  // (docs/DESIGN-JOURNEY.md §17, e.g. two independently-split branches)
  // isn't a caterpillar, so whatever's still in `remaining` at that point
  // is returned separately as `unresolved`: those specific windows get a
  // reading-order placement rather than a structurally-correct one, and
  // the caller uses that to skip forcing their captured size (see
  // geometryClauses()'s skipTiledResize) rather than squeezing them to fit
  // a tree that no longer matches reality.
  function peelOrder(group) {
    var order = []
    var remaining = root.sortByRowThenX(group)
    var stalled = false
    while (remaining.length > 1) {
      var leafIndex = -1
      for (var i = 0; i < remaining.length; i++) {
        var others = remaining.slice(0, i).concat(remaining.slice(i + 1))
        if (root.isSeparated(remaining[i], others)) { leafIndex = i; break }
      }
      if (leafIndex === -1) { stalled = true; break }
      order.push(remaining[leafIndex])
      remaining.splice(leafIndex, 1)
    }
    // A single leftover leaf here is the normal end state for a fully
    // resolved caterpillar, not a failure — only mark `unresolved` when
    // the loop above actually stalled with 2+ windows still ungrouped.
    var trailing = root.sortByRowThenX(remaining)
    return { order: order.concat(trailing), unresolved: stalled ? trailing : [] }
  }

  // Sorts plain window descriptors, not addresses — the reusable half of
  // restoreOrder() below. Extracted so moveWorkspaceTo() (see below) can
  // apply the exact same best-effort ordering without ever touching
  // root.meta, since staying orthogonal to the stash is its whole premise.
  // Returns { order, unresolved } — unresolved is an address->true map of
  // windows peelOrder() couldn't place structurally (a true grid batch;
  // see peelOrder() above), for the caller to skip absolute resize on.
  function orderDescriptors(descriptors) {
    var byBatch = {}
    var batchIds = []
    for (var i = 0; i < descriptors.length; i++) {
      var d = descriptors[i]
      if (!byBatch[d.batchId]) { byBatch[d.batchId] = []; batchIds.push(d.batchId) }
      byBatch[d.batchId].push(d)
    }
    batchIds.sort(function(a, b) { return a - b })

    var order = []
    var unresolved = {}
    for (var b = 0; b < batchIds.length; b++) {
      var peeled = root.peelOrder(byBatch[batchIds[b]])
      order = order.concat(peeled.order)
      for (var u = 0; u < peeled.unresolved.length; u++) unresolved[peeled.unresolved[u].address] = true
    }
    return { order: order, unresolved: unresolved }
  }

  // Returns { addresses, unresolved } — see orderDescriptors() above.
  function restoreOrder(addresses) {
    var meta = root.meta
    var descriptors = addresses.map(function(address) {
      var m = meta[address] || null
      return {
        address: address,
        batchId: m ? m.batchId : 0,
        x: m ? m.x : 0,
        y: m ? m.y : 0,
        width: m ? m.width : 0,
        height: m ? m.height : 0
      }
    })
    var result = root.orderDescriptors(descriptors)
    return { addresses: result.order.map(function(d) { return d.address }), unresolved: result.unresolved }
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

  // Whether any live toplevel is already on `workspaceName` — read from the
  // reactive Hyprland.toplevels model, not a fresh query: unlike the
  // eligibility/geometry bugs this file has otherwise had to work around
  // (see finishStash() above), this only ever asks about windows the
  // current operation hasn't itself just touched, so the staleness that
  // mattered there doesn't apply here.
  function isWorkspaceOccupied(workspaceName) {
    var values = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      if (values[i] && values[i].workspace && values[i].workspace.name === workspaceName) return true
    }
    return false
  }

  property var pendingRestoreSnapshot: []
  property string pendingRestoreDestination: ""
  property var pendingRestoreMonitor: null

  // Restore the complete surviving stash — everything currently parked on
  // stashWorkspace, regardless of which stash() call put it there — onto
  // whatever workspace is focused right now. Eligibility/destination are
  // decided synchronously (stashedToplevels and Hyprland.focusedWorkspace
  // both track reliably for this); the actual dispatch waits on a fresh
  // cursor-position query first — see finishRestore() below for why.
  function restore() {
    var snapshot = root.stashedToplevels
      .map(function(t) { return root.normalizedAddress(t) })
      .filter(function(a) { return !!a })
    if (snapshot.length === 0) return "empty"

    var workspace = Hyprland.focusedWorkspace
    if (!workspace) return "no-workspace"
    if (restoreCursorProcess.running) return "busy"

    root.pendingRestoreSnapshot = snapshot
    root.pendingRestoreDestination = workspace.name
    root.pendingRestoreMonitor = workspace.monitor || null
    restoreCursorProcess.running = true
    return "ok"
  }

  Process {
    id: restoreCursorProcess
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      id: restoreCursorOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var cursor = null
      if (exitCode === 0) {
        var parts = String(restoreCursorOutput.text || "").trim().split(",")
        if (parts.length === 2) {
          var x = parseInt(parts[0], 10)
          var y = parseInt(parts[1], 10)
          if (!isNaN(x) && !isNaN(y)) cursor = { x: x, y: y }
        }
      }
      root.finishRestore(cursor)
    }
  }

  // structureClauses() focuses each tiled window as it's placed, to keep
  // Dwindle's split order correct (see restoreOrder() above) — but
  // Hyprland's default cursor-follows-focus behavior means every one of
  // those focus calls also warps the mouse cursor, landing it wherever the
  // *last* restored window ends up. Confirmed against the real compositor:
  // cursor position measurably changed after a restore with no physical
  // mouse movement involved. Changing that globally (cursor:no_warps) was
  // ruled out — this project never edits the user's own Hyprland config —
  // so instead the cursor position is captured before dispatching anything
  // and explicitly moved back as the last clause in the same batch, after
  // every focus call has already had its say.
  function finishRestore(cursor) {
    var snapshot = root.pendingRestoreSnapshot
    var destination = root.pendingRestoreDestination
    var monitor = root.pendingRestoreMonitor

    var occupied = root.isWorkspaceOccupied(destination)
    var restoreOrdered = root.restoreOrder(snapshot)
    var ordered = restoreOrdered.addresses
    var unresolved = restoreOrdered.unresolved
    var structure = []
    var geometry = []
    var previousMeta = null
    for (var i = 0; i < ordered.length; i++) {
      var address = ordered[i]
      var m = root.meta[address]
      structure = structure.concat(root.structureClauses(address, destination, m, previousMeta))
      geometry = geometry.concat(root.geometryClauses(address, m, monitor, occupied || unresolved[address]))
      if (m && !m.floating) previousMeta = m
    }
    var clauses = structure.concat(geometry)
    if (cursor) {
      clauses.push(root.dispatchClause(
        "hl.dsp.cursor.move({ x = " + cursor.x + ", y = " + cursor.y + " })"))
    }
    if (clauses.length > 0) {
      Quickshell.execDetached(["hyprctl", "--batch", clauses.join(" ; ")])
    }

    var nextMeta = {}
    for (var addr in root.meta) {
      if (snapshot.indexOf(addr) === -1) nextMeta[addr] = root.meta[addr]
    }
    root.meta = nextMeta
  }

  property string pendingMoveSourceWorkspace: ""
  property string pendingMoveTargetWorkspace: ""
  property var pendingMoveSourceMonitor: null

  // Bulk workspace-move: relocate every eligible window on the current
  // workspace onto workspace `targetWorkspaceId`, preserving layout
  // best-effort, without following focus there. Deliberately orthogonal to
  // the stash — never reads or writes root.meta, never touches
  // stashWorkspace, and runs through its own capture Process rather than
  // stashCaptureProcess, so a stash and a bulk-move triggered close
  // together can never cross wires. Same reasoning as stash() for reading
  // eligibility/geometry from a fresh hyprctl query rather than
  // Hyprland.toplevels — see finishStash() above.
  function moveWorkspaceTo(targetWorkspaceId) {
    var workspace = Hyprland.focusedWorkspace
    if (!workspace || String(workspace.name).indexOf("special:") === 0) return "no-workspace"
    if (String(workspace.name) === String(targetWorkspaceId)) return "same-workspace"
    if (moveCaptureProcess.running) return "busy"

    root.pendingMoveSourceWorkspace = workspace.name
    root.pendingMoveTargetWorkspace = String(targetWorkspaceId)
    root.pendingMoveSourceMonitor = workspace.monitor || null
    moveCaptureProcess.running = true
    return "ok"
  }

  Process {
    id: moveCaptureProcess
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: moveCaptureOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var clients = []
      if (exitCode === 0) {
        try { clients = JSON.parse(moveCaptureOutput.text || "[]") } catch (e) { clients = [] }
      }
      root.finishMoveWorkspace(clients)
    }
  }

  // Same fresh-query-is-ground-truth approach as finishStash(), but the
  // resulting descriptors live only in this function's local scope, never
  // root.meta — a bulk move has nothing to remember afterward, so there's
  // no bookkeeping to keep in sync with anything else.
  function finishMoveWorkspace(clients) {
    var descriptors = []
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.workspace || c.workspace.name !== root.pendingMoveSourceWorkspace) continue
      var address = root.normalizedAddress({ address: c.address })
      if (!address) continue
      descriptors.push({
        address: address,
        batchId: 0,
        x: Array.isArray(c.at) ? c.at[0] : 0,
        y: Array.isArray(c.at) ? c.at[1] : 0,
        width: Array.isArray(c.size) ? c.size[0] : 0,
        height: Array.isArray(c.size) ? c.size[1] : 0,
        floating: !!c.floating
      })
    }
    if (descriptors.length === 0) return

    var destination = root.pendingMoveTargetWorkspace
    var targetWorkspace = null
    var values = Hyprland.workspaces && Hyprland.workspaces.values ? Hyprland.workspaces.values : []
    for (var j = 0; j < values.length; j++) {
      if (values[j] && String(values[j].name) === destination) { targetWorkspace = values[j]; break }
    }
    // Target monitor if the workspace already exists; otherwise fall back
    // to the source monitor captured at invocation time (Hyprland creates
    // workspaces on first reference, so a brand-new target has no monitor
    // to look up yet — a known simplification for multi-monitor setups,
    // not solved further here).
    var monitor = (targetWorkspace && targetWorkspace.monitor) || root.pendingMoveSourceMonitor || null

    // Occupancy comes from this same fresh query, not a second one — it
    // already covers every workspace, source and target alike, so no
    // extra hyprctl round-trip is needed to answer this too.
    var occupied = clients.some(function(c) {
      return c && c.workspace && c.workspace.name === destination
    })

    var byAddress = {}
    for (var k = 0; k < descriptors.length; k++) byAddress[descriptors[k].address] = descriptors[k]
    var orderedResult = root.orderDescriptors(descriptors)
    var ordered = orderedResult.order.map(function(d) { return d.address })
    var unresolved = orderedResult.unresolved

    var structure = []
    var geometry = []
    var previousMeta = null
    for (var m = 0; m < ordered.length; m++) {
      var address = ordered[m]
      var d = byAddress[address]
      structure = structure.concat(root.structureClauses(address, destination, d, previousMeta))
      geometry = geometry.concat(root.geometryClauses(address, d, monitor, occupied || unresolved[address]))
      if (d && !d.floating) previousMeta = d
    }

    // Same cursor-warp issue restore() has, for the same reason
    // (structureClauses() focuses each tiled window it places) — see
    // finishRestore() above. Clauses are ready; hold them and query
    // cursor position before actually dispatching anything.
    root.pendingMoveClauses = structure.concat(geometry)
    if (root.pendingMoveClauses.length === 0) return
    moveCursorProcess.running = true
  }

  property var pendingMoveClauses: []

  Process {
    id: moveCursorProcess
    command: ["hyprctl", "cursorpos"]
    stdout: StdioCollector {
      id: moveCursorOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var cursor = null
      if (exitCode === 0) {
        var parts = String(moveCursorOutput.text || "").trim().split(",")
        if (parts.length === 2) {
          var x = parseInt(parts[0], 10)
          var y = parseInt(parts[1], 10)
          if (!isNaN(x) && !isNaN(y)) cursor = { x: x, y: y }
        }
      }
      var clauses = root.pendingMoveClauses
      if (cursor) {
        clauses = clauses.concat([root.dispatchClause(
          "hl.dsp.cursor.move({ x = " + cursor.x + ", y = " + cursor.y + " })")])
      }
      Quickshell.execDetached(["hyprctl", "--batch", clauses.join(" ; ")])
      root.pendingMoveClauses = []
    }
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
    function moveTo(workspaceId: string): string { return root.moveWorkspaceTo(workspaceId) }
    function ping(): string { return "ok" }
  }
}
