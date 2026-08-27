import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// State owner for Workspace Stash. Hyprland is the source of truth for
// membership: a window is "in the stash" iff it's a live toplevel parked
// on stashWorkspace. `meta` is auxiliary bookkeeping only (geometry,
// batch id, source workspace) — never consulted to decide membership.
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

  // Title/app-id are set by whatever application owns the window, not by
  // Hyprland or this plugin — an unbounded string here would let a single
  // misbehaving window force this reactively-recomputed property to hold
  // and copy an arbitrarily large string on every toplevel-list change.
  // Clipped at the collector, before it ever reaches BarWidget.qml.
  readonly property int maxDisplayTextLength: 100

  function clipText(value, maxLength) {
    var str = String(value || "")
    return str.length > maxLength ? str.slice(0, maxLength) : str
  }

  // Bounds the raw "hyprctl -j clients" output itself, before parsing —
  // clipText() above only bounds what reaches QML after the fact. Enforced
  // at the pipe itself (see captureClientsCommand below), not by watching
  // StdioCollector's buffer after the fact: that buffer already holds
  // whatever the process wrote before any QML handler can react to it. A
  // real capture here runs ~2KB; this leaves generous headroom while
  // refusing pathological output.
  readonly property int maxCaptureBytes: 4194304

  // "head -c" enforces the cap in the pipe itself — hyprctl gets SIGPIPE
  // once head has read enough, so StdioCollector's buffer can never exceed
  // this regardless of how QML's event loop happens to batch onDataChanged.
  // The +1 keeps the length check below meaningful as an overflow signal.
  readonly property var captureClientsCommand: ["sh", "-c", "hyprctl -j clients | head -c " + (maxCaptureBytes + 1)]

  // Presentation-ready snapshot for the bar widget: identity and live display
  // fields come straight from Hyprland every time; batch/source come from the
  // auxiliary map when available.
  readonly property var items: stashedToplevels.map(function(t) {
    var address = root.normalizedAddress(t)
    var ipc = t.lastIpcObject || null
    var m = root.meta[address] || null
    return {
      address: address,
      title: root.clipText(t.title, root.maxDisplayTextLength),
      appId: root.clipText((t.wayland && t.wayland.appId) || (ipc && ipc.class) || "", root.maxDisplayTextLength),
      batchId: m ? m.batchId : 0,
      sourceWorkspace: m ? m.sourceWorkspace : ""
    }
  })

  // Drop meta entries for windows that no longer exist anywhere. Keyed on
  // "still a toplevel anywhere", not "still parked in the stash" — keying
  // on stashedToplevels pruned a freshly-stashed window's entry the
  // instant a sibling in the same batch landed first, wiping most of a
  // multi-window stash's data. Moving workspaces never drops a window
  // from the toplevel list, only closing it does.
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
    root.pruneBatchPlans()
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
  // axis.
  function preselectDirection(meta, reference) {
    var dx = meta.x - reference.x
    var dy = meta.y - reference.y
    if (Math.abs(dx) >= Math.abs(dy)) return dx < 0 ? "l" : "r"
    return dy < 0 ? "u" : "d"
  }

  // Place one window and, if tiled, focus it so the next insertion splits
  // against it — see walkAndDispatch() below. No sizing here (separate
  // pass, see geometryClauses()). `previousMeta` is the anchor to
  // preselect against (null for the first window) — without it,
  // left/right or top/bottom placement follows Dwindle's default instead
  // of the captured layout. Callers fire all clauses as ONE `hyprctl
  // --batch`, not per window — separate processes aren't guaranteed to
  // reach Hyprland in order. `previousAddress` is only needed to refocus a
  // window from several steps back (the tree-walk case); the flat case
  // never passes it since `previousMeta` is already the last dispatch.
  function structureClauses(address, destination, meta, previousMeta, previousAddress) {
    if (!address || !destination) return []
    var move = "hl.dsp.window.move({ workspace = " + JSON.stringify(destination)
      + ", window = " + JSON.stringify("address:" + address) + ", follow = false })"
    if (meta && meta.floating) return [move].map(root.dispatchClause)
    var focus = "hl.dsp.focus({ window = " + JSON.stringify("address:" + address) + " })"
    if (!previousMeta) return [move, focus].map(root.dispatchClause)
    var direction = root.preselectDirection(meta, previousMeta)
    var preselect = "hl.dsp.layout(" + JSON.stringify("preselect " + direction) + ")"
    if (previousAddress) {
      var refocus = "hl.dsp.focus({ window = " + JSON.stringify("address:" + previousAddress) + " })"
      return [refocus, preselect, move, focus].map(root.dispatchClause)
    }
    return [preselect, move, focus].map(root.dispatchClause)
  }

  // Restore captured size (and, for floating, position) — one absolute
  // resize dispatch for tiled and floating alike. Must run only after
  // every structureClauses() in this restore has dispatched: Dwindle
  // re-splits evenly on each insertion, so resizing window N before
  // inserting N+1 would just get reset. skipTiledResize: forcing captured
  // sizes when merging onto an occupied destination (or unrelated batch)
  // squeezes windows to a handful of pixels — skipped in that case, and
  // Hyprland settles the merge naturally instead.
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

  // ============================================================
  // D reconstruction: destructive decomposition during stash,
  // representative-leaf replay during restore. Every tiled batch goes
  // through this pipeline; a batch it can't resolve uses natural
  // placement (see finishRestore()) rather than a weaker fallback
  // guessing an order. Design/evidence: docs/D-RECONSTRUCTION.md.
  // ============================================================

  // Batch-level reconstructed trees live here, not in root.meta — a tree
  // has no natural single "owning" window among a batch's per-window meta
  // entries, and duplicating it across every window in the batch would
  // risk drift if one copy got updated and others didn't. Keyed the same
  // way batches already are.
  property var batchPlans: ({})

  // Held for the *entire* decomposition sequence, not just the initial
  // capture — the sequencer can run for many async steps, and a second
  // stash/restore/move triggered mid-sequence must be rejected as "busy",
  // not race against in-flight state.
  property bool decompositionInFlight: false

  function isAddressLive(address) {
    var values = Hyprland.toplevels && Hyprland.toplevels.values ? Hyprland.toplevels.values : []
    for (var i = 0; i < values.length; i++) {
      if (root.normalizedAddress(values[i]) === address) return true
    }
    return false
  }

  // A group leaf's chosen representative address can close while its
  // groupmates survive — resolve to whichever member is still alive
  // instead of failing the whole leaf. Confirmed live: moving or resizing
  // any surviving group member carries the whole group for move/resize
  // purposes, so any live member is an equally valid dispatch target.
  function resolveLiveAddress(leafNode) {
    if (!leafNode) return null
    if (root.isAddressLive(leafNode.address)) return leafNode.address
    var members = leafNode.groupMembers || [leafNode.address]
    for (var i = 0; i < members.length; i++) {
      if (root.isAddressLive(members[i])) return members[i]
    }
    return null
  }

  function makeLeaf(address, groupMembers) {
    return { isLeaf: true, address: address, groupMembers: groupMembers || [address] }
  }

  function makeSplit(axis, first, second) {
    return { isLeaf: false, axis: axis, first: first, second: second }
  }

  // Collapses each Hyprland group (the `grouped` field already present in
  // `hyprctl -j clients` — no new query) to one deterministic
  // representative address per group. Returns
  // { representativeOf: {repAddr: [members...]}, memberOf: {addr: repAddr} }.
  function collapseGroups(clients) {
    var memberOf = {}
    var representativeOf = {}
    var seen = {}
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      var address = root.normalizedAddress({ address: c.address })
      if (!address || seen[address]) continue
      var groupRaw = Array.isArray(c.grouped) ? c.grouped : []
      var members = [address]
      for (var j = 0; j < groupRaw.length; j++) {
        var m = root.normalizedAddress({ address: groupRaw[j] })
        if (m && members.indexOf(m) === -1) members.push(m)
      }
      members.sort()
      var rep = members[0]
      representativeOf[rep] = members
      for (var k = 0; k < members.length; k++) {
        memberOf[members[k]] = rep
        seen[members[k]] = true
      }
    }
    return { representativeOf: representativeOf, memberOf: memberOf }
  }

  // Any deterministic order works (proven order-independent by a 15/15
  // random-order live sweep) — leaves the first-captured address as the
  // implicit final survivor, moved explicitly once the loop finishes (see
  // finishDecompositionSurvivor() below — the N-1 diffing steps alone
  // never touch it).
  function partitionRemovalOrder(addresses) {
    return addresses.slice(1)
  }

  function unionBbox(rects, addresses) {
    var x0 = null, y0 = null, x1 = null, y1 = null
    for (var i = 0; i < addresses.length; i++) {
      var r = rects[addresses[i]]
      if (!r) continue
      if (x0 === null || r.x < x0) x0 = r.x
      if (y0 === null || r.y < y0) y0 = r.y
      if (x1 === null || r.x + r.width > x1) x1 = r.x + r.width
      if (y1 === null || r.y + r.height > y1) y1 = r.y + r.height
    }
    if (x0 === null) return null
    return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
  }

  // Infers which axis a removed window was adjacent to the surviving
  // cluster along, from the BEFORE snapshot alone — doesn't depend on the
  // cluster resizing afterward (comparing size deltas instead broke on
  // pseudo-tiled windows, which can re-center without resizing).
  function inferAxisAndDirection(removedRect, clusterBbox) {
    var xOverlap = Math.min(removedRect.x + removedRect.width, clusterBbox.x + clusterBbox.width) - Math.max(removedRect.x, clusterBbox.x)
    var yOverlap = Math.min(removedRect.y + removedRect.height, clusterBbox.y + clusterBbox.height) - Math.max(removedRect.y, clusterBbox.y)
    if (xOverlap >= yOverlap) {
      return { axis: "H", removedIsFirst: removedRect.y < clusterBbox.y }
    }
    return { axis: "V", removedIsFirst: removedRect.x < clusterBbox.x }
  }

  function groupKey(addressList) {
    return addressList.slice().sort().join(",")
  }

  // Worklist reconstruction: resolve whichever pending record entry has
  // all its `changed` addresses in one already-built group, restarting
  // the scan after every merge (load-bearing — a single pass can resolve
  // a later entry first and lock in a wrong tree). Returns { tree } or
  // { error }, never a best-guess wrong tree.
  function reconstructTree(record, addresses, groupMembersByAddress) {
    var node = {}
    var groupOf = {}
    for (var i = 0; i < addresses.length; i++) {
      var a = addresses[i]
      node[root.groupKey([a])] = root.makeLeaf(a, groupMembersByAddress[a] || [a])
      groupOf[a] = [a]
    }

    var pending = record.slice()
    var idx = 0
    while (pending.length > 0) {
      if (idx >= pending.length) {
        return { tree: null, error: "stuck: " + pending.length + " step(s) never became resolvable" }
      }
      var entry = pending[idx]
      if (!entry.changed || entry.changed.length === 0 || entry.axis === null) {
        return { tree: null, error: "step removing " + entry.removed + ": no valid compensating info" }
      }
      var changedGroups = []
      var changedKeys = {}
      var ok = true
      for (var c = 0; c < entry.changed.length; c++) {
        var g = groupOf[entry.changed[c]]
        if (!g) { ok = false; break }
        var k = root.groupKey(g)
        if (!changedKeys[k]) { changedKeys[k] = true; changedGroups.push(g) }
      }
      var removedGroup = groupOf[entry.removed]
      if (!ok || !removedGroup || changedGroups.length !== 1
          || root.groupKey(removedGroup) === root.groupKey(changedGroups[0])) {
        idx += 1
        continue
      }
      var siblingGroup = changedGroups[0]
      var siblingNode = node[root.groupKey(siblingGroup)]
      var removedNode = node[root.groupKey(removedGroup)]
      var newNode = entry.removedIsFirst
        ? root.makeSplit(entry.axis, removedNode, siblingNode)
        : root.makeSplit(entry.axis, siblingNode, removedNode)
      var newGroup = siblingGroup.concat(removedGroup)
      var newKey = root.groupKey(newGroup)
      node[newKey] = newNode
      for (var m = 0; m < newGroup.length; m++) groupOf[newGroup[m]] = newGroup
      pending.splice(idx, 1)
      idx = 0
    }

    var finalNode = node[root.groupKey(addresses)]
    if (!finalNode) return { tree: null, error: "reconstruction incomplete" }
    return { tree: finalNode, error: null }
  }

  function collectLeafAddresses(node, out) {
    if (!node) return
    if (node.isLeaf) { out.push(node.address); return }
    root.collectLeafAddresses(node.first, out)
    root.collectLeafAddresses(node.second, out)
  }

  // Structural self-check run before a reconstructed tree is ever stored
  // or dispatched: live testing could compare against ground truth,
  // production has none, so this confirms the tree's own leaf set exactly
  // matches what was actually captured — no duplicates, nothing missing.
  function validateTree(tree, expectedAddresses) {
    if (!tree) return false
    var collected = []
    root.collectLeafAddresses(tree, collected)
    if (collected.length !== expectedAddresses.length) return false
    var expected = {}
    for (var i = 0; i < expectedAddresses.length; i++) expected[expectedAddresses[i]] = true
    var seen = {}
    for (var j = 0; j < collected.length; j++) {
      var a = collected[j]
      if (!expected[a] || seen[a]) return false
      seen[a] = true
    }
    return true
  }

  function representativeOfNode(node) {
    return node.isLeaf ? node : root.representativeOfNode(node.first)
  }

  // Representative-leaf preorder expansion: place a subtree's two
  // representatives as a pair before recursing into either side.
  // `incomingMeta`/`incomingAddress` are the cross-batch anchor (null for
  // the first batch). `metaMap` defaults to root.meta when omitted —
  // moveWorkspaceTo() passes its own local snapshot instead. Returns
  // { structure, geometry, lastMeta, lastAddress }, the last two being
  // the outgoing anchor for the next batch.
  function walkAndDispatch(tree, destination, monitor, skipTiledResizeFor, incomingMeta, incomingAddress, metaMap) {
    var meta = metaMap || root.meta
    var structure = []
    var geometry = []
    var lastMeta = incomingMeta
    var lastAddress = incomingAddress

    function dispatchOne(leafNode, focusAddress, focusMeta) {
      var address = root.resolveLiveAddress(leafNode)
      if (!address) return
      var m = meta[address]
      structure = structure.concat(root.structureClauses(address, destination, m, focusMeta, focusAddress))
      geometry = geometry.concat(root.geometryClauses(address, m, monitor, skipTiledResizeFor(address)))
      if (m && !m.floating) { lastMeta = m; lastAddress = address }
    }

    function expand(node) {
      if (node.isLeaf) return
      var repA = root.representativeOfNode(node.first)
      var repB = root.representativeOfNode(node.second)
      var addrA = root.resolveLiveAddress(repA)
      dispatchOne(repB, addrA, addrA ? meta[addrA] : null)
      expand(node.first)
      expand(node.second)
    }

    dispatchOne(root.representativeOfNode(tree), incomingAddress, incomingMeta)
    expand(tree)

    return { structure: structure, geometry: geometry, lastMeta: lastMeta, lastAddress: lastAddress }
  }

  // Stale-tree pruning: a stashed window can close before restore() is
  // ever called, leaving a stored tree referencing a dead address. Hooked
  // into the same trigger pruneMeta() uses. A genuine tree edit, not a
  // blanket invalidation: find the dead leaf, replace its parent Split
  // with the leaf's sibling subtree (standard binary-tree leaf removal).
  function pruneNodeForDeadAddress(node) {
    // Returns { node, removed } — removed is true if this call's own
    // level found and excised a dead leaf (caller promotes the sibling).
    if (!node) return { node: node, removed: false }
    if (node.isLeaf) {
      var live = root.resolveLiveAddress(node)
      if (!live) return { node: null, removed: true }
      if (live !== node.address) return { node: root.makeLeaf(live, node.groupMembers), removed: false }
      return { node: node, removed: false }
    }
    var firstResult = root.pruneNodeForDeadAddress(node.first)
    if (firstResult.removed) return { node: firstResult.node === null ? node.second : root.makeSplit(node.axis, firstResult.node, node.second), removed: firstResult.node === null }
    var secondResult = root.pruneNodeForDeadAddress(node.second)
    if (secondResult.removed) return { node: secondResult.node === null ? firstResult.node : root.makeSplit(node.axis, firstResult.node, secondResult.node), removed: secondResult.node === null }
    return { node: root.makeSplit(node.axis, firstResult.node, secondResult.node), removed: false }
  }

  function pruneBatchPlans() {
    var next = {}
    var changed = false
    for (var batchId in root.batchPlans) {
      var plan = root.batchPlans[batchId]
      if (!plan || plan.unresolved || !plan.tree) { next[batchId] = plan; continue }
      var result = root.pruneNodeForDeadAddress(plan.tree)
      if (result.node !== plan.tree) {
        changed = true
        if (result.node === null) {
          next[batchId] = { tree: null, unresolved: true }
        } else {
          var remaining = []
          root.collectLeafAddresses(result.node, remaining)
          var stillValid = root.validateTree(result.node, remaining)
          next[batchId] = stillValid ? { tree: result.node, unresolved: false } : { tree: null, unresolved: true }
        }
      } else {
        next[batchId] = plan
      }
    }
    if (changed) root.batchPlans = next
  }

  function extractRectsForWorkspace(clients, workspaceName, addresses) {
    var rects = {}
    var wanted = {}
    for (var i = 0; i < addresses.length; i++) wanted[addresses[i]] = true
    for (var j = 0; j < clients.length; j++) {
      var c = clients[j]
      if (!c || !c.workspace || c.workspace.name !== workspaceName) continue
      var address = root.normalizedAddress({ address: c.address })
      if (!address || !wanted[address]) continue
      rects[address] = {
        x: Array.isArray(c.at) ? c.at[0] : 0,
        y: Array.isArray(c.at) ? c.at[1] : 0,
        width: Array.isArray(c.size) ? c.size[0] : 0,
        height: Array.isArray(c.size) ? c.size[1] : 0
      }
    }
    return rects
  }

  property var pendingDecomposition: null

  // Kicks off D's destructive decomposition for one batch's tiled,
  // group-collapsed representatives — the moves themselves ARE the stash.
  // Every destructive move always transits through root.stashWorkspace,
  // regardless of caller: replaying directly against windows already on
  // the real final destination scrambles order (docs/D-RECONSTRUCTION.md).
  // `destinationWorkspace` is therefore the real final target, used only
  // by finishMoveDecomposition() to chain one cross-workspace replay once
  // decomposition finishes — for stash() it's just root.stashWorkspace
  // again (no separate replay). `extra` merges into the pending state for
  // completeDecomposition() to read.
  function beginDecomposition(batchId, sourceWorkspace, addresses, groupMembersByAddress, destinationWorkspace, extra) {
    root.decompositionInFlight = true
    var state = {
      batchId: batchId,
      sourceWorkspace: sourceWorkspace,
      destinationWorkspace: destinationWorkspace,
      addresses: addresses,
      groupMembersByAddress: groupMembersByAddress,
      removalOrder: root.partitionRemovalOrder(addresses),
      stepIndex: 0,
      remaining: addresses.slice(),
      record: [],
      beforeRects: null,
      pendingRemoval: "",
      phase: "before",
      purpose: "stash"
    }
    if (extra) for (var k in extra) state[k] = extra[k]
    root.pendingDecomposition = state
    decomposeCaptureProcess.running = true
  }

  Process {
    id: decomposeCaptureProcess
    command: root.captureClientsCommand
    stdout: StdioCollector {
      id: decomposeCaptureOutput
      // Same reasoning as stashCaptureOutput/moveCaptureOutput above.
      waitForEnd: false
      onDataChanged: {
        if (text.length > root.maxCaptureBytes) decomposeCaptureProcess.running = false
      }
    }
    onExited: function(exitCode) {
      var clients = []
      if (exitCode === 0) {
        try { clients = JSON.parse(decomposeCaptureOutput.text || "[]") } catch (e) { clients = [] }
      }
      root.onDecomposeCapture(clients)
    }
  }

  // Not Quickshell.execDetached() — a dispatch Process only exits once
  // Hyprland has actually applied it, so chaining the next step on
  // onExited needs no explicit settle-wait.
  Process {
    id: decomposeDispatchProcess
    property string luaExpr: ""
    command: ["hyprctl", "dispatch", luaExpr]
    onExited: function(exitCode) {
      decomposeCaptureProcess.running = true
    }
  }

  // Two-phase-per-step state machine: "before" is both a missing-window
  // check (a real SIGTERM mid-sequence is detected here, proven live in
  // the seam integration test — never crashes, never strands a window)
  // and this step's before-snapshot; "after" diffs against it once the
  // move has actually landed.
  function onDecomposeCapture(clients) {
    var st = root.pendingDecomposition
    if (!st) return
    var rects = root.extractRectsForWorkspace(clients, st.sourceWorkspace, st.remaining)

    if (st.phase === "before") {
      var missing = []
      for (var i = 0; i < st.remaining.length; i++) {
        if (!(st.remaining[i] in rects)) missing.push(st.remaining[i])
      }
      for (var m = 0; m < missing.length; m++) {
        var idx = st.remaining.indexOf(missing[m])
        if (idx !== -1) st.remaining.splice(idx, 1)
      }

      if (st.stepIndex >= st.removalOrder.length) {
        root.finishDecompositionSurvivor(rects)
        return
      }
      var name = st.removalOrder[st.stepIndex]
      if (st.remaining.indexOf(name) === -1) {
        st.stepIndex += 1
        decomposeCaptureProcess.running = true
        return
      }
      st.beforeRects = rects
      st.pendingRemoval = name
      st.phase = "after"
      decomposeDispatchProcess.luaExpr = "hl.dsp.window.move({ workspace = " + JSON.stringify(root.stashWorkspace)
        + ", window = " + JSON.stringify("address:" + name) + ", follow = false })"
      decomposeDispatchProcess.running = true
      return
    }

    // phase === "after"
    var removedName = st.pendingRemoval
    var stillRemaining = st.remaining.filter(function(a) { return a !== removedName })
    var afterRects = root.extractRectsForWorkspace(clients, st.sourceWorkspace, stillRemaining)
    var changed = []
    for (var k = 0; k < stillRemaining.length; k++) {
      var a2 = stillRemaining[k]
      var b = st.beforeRects[a2]
      var af = afterRects[a2]
      var sameRect = b && af && b.x === af.x && b.y === af.y && b.width === af.width && b.height === af.height
      if (!sameRect) changed.push(a2)
    }
    var axis = null, removedIsFirst = null
    if (changed.length > 0 && st.beforeRects[removedName]) {
      var clusterBbox = root.unionBbox(st.beforeRects, changed)
      if (clusterBbox) {
        var inferred = root.inferAxisAndDirection(st.beforeRects[removedName], clusterBbox)
        axis = inferred.axis
        removedIsFirst = inferred.removedIsFirst
      }
    }
    st.record.push({ removed: removedName, changed: changed, axis: axis, removedIsFirst: removedIsFirst })
    st.remaining = stillRemaining
    st.stepIndex += 1
    st.phase = "before"
    decomposeCaptureProcess.running = true
  }

  // The N-1 diffing steps alone never touch the final survivor — found
  // live in the seam integration test (it was left stranded on the
  // source workspace, never stashed). Explicit final move here, guarded
  // on it actually still being present.
  function finishDecompositionSurvivor(lastRects) {
    var st = root.pendingDecomposition
    var survivor = st.remaining.length > 0 ? st.remaining[0] : null
    if (survivor && (survivor in lastRects)) {
      root.moveAddress(survivor, root.stashWorkspace, false)
    }
    root.completeDecomposition()
  }

  // Branches on st.purpose with an explicit whitelist, not an implicit
  // truthy check — a missing/unrecognized purpose falls back to stash
  // behavior rather than silently taking whichever branch comes first.
  function completeDecomposition() {
    var st = root.pendingDecomposition
    var result = root.reconstructTree(st.record, st.addresses, st.groupMembersByAddress)
    var resolved = !!(result.tree && root.validateTree(result.tree, st.addresses))

    if (st.purpose === "move") {
      root.finishMoveDecomposition(st, resolved ? result.tree : null)
    } else {
      var plan = resolved ? { tree: result.tree, unresolved: false } : { tree: null, unresolved: true }
      var nextPlans = {}
      for (var b in root.batchPlans) nextPlans[b] = root.batchPlans[b]
      nextPlans[st.batchId] = plan
      root.batchPlans = nextPlans
    }

    root.pendingDecomposition = null
    root.decompositionInFlight = false
  }

  property string pendingStashWorkspace: ""
  property int pendingStashBatchId: 0

  // Move every eligible window on the focused workspace into the stash.
  // Safe to call repeatedly — appends rather than replaces. Eligibility
  // and geometry come from finishStash() off one fresh hyprctl query, not
  // Hyprland.toplevels, whose cached workspace membership can briefly
  // read as stale under fast repeated cycling.
  function stash() {
    var workspace = Hyprland.focusedWorkspace
    if (!workspace || String(workspace.name).indexOf("special:") === 0) return "no-workspace"
    if (stashCaptureProcess.running || root.decompositionInFlight) return "busy"

    root.pendingStashWorkspace = workspace.name
    root.pendingStashBatchId = root.nextBatchId
    root.nextBatchId = root.pendingStashBatchId + 1
    stashCaptureProcess.running = true
    return "ok"
  }

  Process {
    id: stashCaptureProcess
    command: root.captureClientsCommand
    stdout: StdioCollector {
      id: stashCaptureOutput
      // waitForEnd: false so dataChanged fires per chunk, letting the
      // guard below cut off a runaway capture before it grows unbounded.
      // Full text is still available in onExited either way. The real
      // ceiling is captureClientsCommand's "head -c" — this is a fallback.
      waitForEnd: false
      onDataChanged: {
        if (text.length > root.maxCaptureBytes) stashCaptureProcess.running = false
      }
    }
    onExited: function(exitCode) {
      var clients = []
      if (exitCode === 0) {
        try { clients = JSON.parse(stashCaptureOutput.text || "[]") } catch (e) { clients = [] }
      }
      root.finishStash(clients)
    }
  }

  // Determines eligibility and captures geometry from the same fresh
  // query. Meta is recorded for every eligible window unconditionally
  // (floating and group members alike). Floating windows get a simple
  // independent move; tiled windows are group-collapsed then handed to
  // the decomposition sequencer, whose destructive moves ARE the stash.
  function finishStash(clients) {
    var nextMeta = {}
    for (var addr in root.meta) nextMeta[addr] = root.meta[addr]

    var batchClients = []
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
      batchClients.push(c)
    }
    if (batchClients.length === 0) return
    root.meta = nextMeta

    var floatingAddresses = []
    var tiledClients = []
    for (var j = 0; j < batchClients.length; j++) {
      var bc = batchClients[j]
      var bAddr = root.normalizedAddress({ address: bc.address })
      if (nextMeta[bAddr].floating) floatingAddresses.push(bAddr)
      else tiledClients.push(bc)
    }

    for (var f = 0; f < floatingAddresses.length; f++) {
      root.moveAddress(floatingAddresses[f], root.stashWorkspace, false)
    }
    if (tiledClients.length === 0) return

    // Every tiled batch enters beginDecomposition() unconditionally, no
    // representative-count special-casing — it already degrades correctly
    // to one quick capture + one survivor move + a trivial identity tree
    // when there's only one representative (removalOrder is empty, so the
    // first capture callback finishes immediately with zero destructive
    // steps).
    var grouped = root.collapseGroups(tiledClients)
    var representatives = Object.keys(grouped.representativeOf)
    root.beginDecomposition(root.pendingStashBatchId, root.pendingStashWorkspace, representatives, grouped.representativeOf, root.stashWorkspace)
  }

  // Whether any live toplevel is already on `workspaceName` — reads the
  // reactive Hyprland.toplevels model rather than a fresh query, safe here
  // since this only ever asks about windows the current operation hasn't
  // itself just touched.
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
    if (restoreCursorProcess.running || root.decompositionInFlight) return "busy"

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

  // structureClauses() focuses each window as it's placed, which also
  // warps the cursor via Hyprland's cursor-follows-focus — cursor
  // position is captured before dispatching and restored as the batch's
  // last clause, rather than editing the user's Hyprland config globally.
  //
  // Batches restore oldest-first. A resolved tree walks via
  // walkAndDispatch(); anything unresolved falls back to natural
  // placement. anchorMeta/anchorAddress thread the cross-batch anchor
  // continuously across every batch either way.
  function finishRestore(cursor) {
    var snapshot = root.pendingRestoreSnapshot
    var destination = root.pendingRestoreDestination
    var monitor = root.pendingRestoreMonitor
    var occupied = root.isWorkspaceOccupied(destination)

    var byBatch = {}
    var batchIds = []
    for (var i = 0; i < snapshot.length; i++) {
      var addr = snapshot[i]
      var bm = root.meta[addr]
      var batchId = bm ? bm.batchId : 0
      if (!byBatch[batchId]) { byBatch[batchId] = []; batchIds.push(batchId) }
      byBatch[batchId].push(addr)
    }
    batchIds.sort(function(a, b) { return a - b })

    // Each batch's sizes are only valid relative to their own source
    // workspace — forcing two independent batches' sizes into one
    // destination collapses one (confirmed: squeezed one to a sliver).
    // isWorkspaceOccupied() only catches pre-existing content, not this
    // restore merging 2+ batches. Counted by TILED-only batch IDs — a
    // floating-only batch shouldn't suppress a tiled batch's resize.
    var tiledBatchCount = 0
    for (var tb = 0; tb < batchIds.length; tb++) {
      var tbAddrs = byBatch[batchIds[tb]]
      var hasTiled = false
      for (var ta = 0; ta < tbAddrs.length; ta++) {
        var tm = root.meta[tbAddrs[ta]]
        if (!tm || !tm.floating) { hasTiled = true; break }
      }
      if (hasTiled) tiledBatchCount++
    }
    var multiTiledBatchMerge = tiledBatchCount > 1
    var effectiveOccupied = occupied || multiTiledBatchMerge

    var structure = []
    var geometry = []
    var anchorMeta = null
    var anchorAddress = null

    for (var b = 0; b < batchIds.length; b++) {
      var batchId2 = batchIds[b]
      var batchAddresses = byBatch[batchId2]

      var floatingAddrs = []
      var tiledAddrs = []
      for (var j = 0; j < batchAddresses.length; j++) {
        var a2 = batchAddresses[j]
        var mm = root.meta[a2]
        if (mm && mm.floating) floatingAddrs.push(a2)
        else tiledAddrs.push(a2)
      }

      for (var f = 0; f < floatingAddrs.length; f++) {
        var fa = floatingAddrs[f]
        structure = structure.concat(root.structureClauses(fa, destination, root.meta[fa], null, null))
        geometry = geometry.concat(root.geometryClauses(fa, root.meta[fa], monitor, occupied))
      }

      var plan = root.batchPlans[batchId2]
      if (plan && !plan.unresolved && plan.tree && tiledAddrs.length > 0) {
        var skipResizeFor = function(addr2) { return effectiveOccupied }
        var walked = root.walkAndDispatch(plan.tree, destination, monitor, skipResizeFor, anchorMeta, anchorAddress)
        structure = structure.concat(walked.structure)
        geometry = geometry.concat(walked.geometry)
        anchorMeta = walked.lastMeta
        anchorAddress = walked.lastAddress
      } else if (tiledAddrs.length > 0) {
        // No resolved tree — a genuine D failure (see
        // docs/D-RECONSTRUCTION.md) or a stash predating BatchPlan.
        // Placed independently: no preselect chaining, no forced resize,
        // same as finishMoveDecomposition()'s equivalent fallback.
        for (var n = 0; n < tiledAddrs.length; n++) {
          var nAddr = tiledAddrs[n]
          var nMeta = root.meta[nAddr]
          structure = structure.concat(root.structureClauses(nAddr, destination, nMeta, null, null))
          geometry = geometry.concat(root.geometryClauses(nAddr, nMeta, monitor, true))
          if (nMeta && !nMeta.floating) { anchorMeta = nMeta; anchorAddress = nAddr }
        }
      }
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
    for (var addr3 in root.meta) {
      if (snapshot.indexOf(addr3) === -1) nextMeta[addr3] = root.meta[addr3]
    }
    root.meta = nextMeta

    var nextPlans = {}
    for (var pid in root.batchPlans) {
      if (byBatch[pid] === undefined) nextPlans[pid] = root.batchPlans[pid]
    }
    root.batchPlans = nextPlans
  }

  property string pendingMoveSourceWorkspace: ""
  property string pendingMoveTargetWorkspace: ""
  property var pendingMoveSourceMonitor: null

  // Bulk workspace-move: relocate every eligible window on the current
  // workspace onto `targetWorkspaceId`, preserving layout best-effort.
  // Orthogonal to the stash: never reads/writes root.meta or
  // root.batchPlans. Internally, 2+ tiled representatives share the same
  // decomposition sequencer stash() uses, transiting through
  // root.stashWorkspace like a real stash — replaying directly against
  // the real destination scrambles order (docs/D-RECONSTRUCTION.md). The
  // transit is momentary, coexisting safely with an unrelated real stash.
  function moveWorkspaceTo(targetWorkspaceId) {
    var workspace = Hyprland.focusedWorkspace
    if (!workspace || String(workspace.name).indexOf("special:") === 0) return "no-workspace"
    if (String(workspace.name) === String(targetWorkspaceId)) return "same-workspace"
    if (moveCaptureProcess.running || root.decompositionInFlight) return "busy"

    root.pendingMoveSourceWorkspace = workspace.name
    root.pendingMoveTargetWorkspace = String(targetWorkspaceId)
    root.pendingMoveSourceMonitor = workspace.monitor || null
    moveCaptureProcess.running = true
    return "ok"
  }

  Process {
    id: moveCaptureProcess
    command: root.captureClientsCommand
    stdout: StdioCollector {
      id: moveCaptureOutput
      // Same reasoning as stashCaptureOutput above — see there for why
      // waitForEnd is false and what the guard does.
      waitForEnd: false
      onDataChanged: {
        if (text.length > root.maxCaptureBytes) moveCaptureProcess.running = false
      }
    }
    onExited: function(exitCode) {
      var clients = []
      if (exitCode === 0) {
        try { clients = JSON.parse(moveCaptureOutput.text || "[]") } catch (e) { clients = [] }
      }
      root.finishMoveWorkspace(clients)
    }
  }

  // Same fresh-query-is-ground-truth approach as finishStash(), but
  // metaMap lives only in this call's local scope, never root.meta — a
  // bulk move has nothing to remember afterward. Built once, never
  // mutated: walkAndDispatch() reads geometry from it exactly as
  // restore() reads root.meta, reflecting each window's original
  // source-workspace geometry even after decomposition relocates it.
  function finishMoveWorkspace(clients) {
    var metaMap = {}
    var sourceClients = []
    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      if (!c || !c.workspace || c.workspace.name !== root.pendingMoveSourceWorkspace) continue
      var address = root.normalizedAddress({ address: c.address })
      if (!address) continue
      metaMap[address] = {
        x: Array.isArray(c.at) ? c.at[0] : 0,
        y: Array.isArray(c.at) ? c.at[1] : 0,
        width: Array.isArray(c.size) ? c.size[0] : 0,
        height: Array.isArray(c.size) ? c.size[1] : 0,
        floating: !!c.floating
      }
      sourceClients.push(c)
    }
    if (sourceClients.length === 0) return

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

    // Frozen occupancy snapshot: computed once, before anything moves,
    // never recomputed mid-operation — decomposition's own moves land
    // windows on `destination` partway through, so this must keep
    // reflecting pre-existing content, not current state.
    var occupied = clients.some(function(c) {
      return c && c.workspace && c.workspace.name === destination
    })

    var floatingAddresses = []
    var tiledClients = []
    for (var t = 0; t < sourceClients.length; t++) {
      var tc = sourceClients[t]
      var tAddr = root.normalizedAddress({ address: tc.address })
      if (metaMap[tAddr].floating) floatingAddresses.push(tAddr)
      else tiledClients.push(tc)
    }

    // Floating windows' clauses are built now but never dispatched on
    // their own — held until the tiled path resolves, then dispatched
    // together as one combined batch. Floating windows stay physically
    // untouched until then, same as finishStash()'s own separation.
    var floatingStructure = []
    var floatingGeometry = []
    for (var f = 0; f < floatingAddresses.length; f++) {
      var fa = floatingAddresses[f]
      floatingStructure = floatingStructure.concat(root.structureClauses(fa, destination, metaMap[fa], null, null))
      floatingGeometry = floatingGeometry.concat(root.geometryClauses(fa, metaMap[fa], monitor, occupied))
    }

    if (tiledClients.length === 0) {
      root.pendingMoveClauses = floatingStructure.concat(floatingGeometry)
      if (root.pendingMoveClauses.length === 0) return
      moveCursorProcess.running = true
      return
    }

    // Every tiled batch hands off to the same decomposition sequencer
    // stash() uses, no representative-count special-casing.
    // destinationWorkspace is the real target; internal moves always
    // transit through root.stashWorkspace regardless (see
    // finishMoveDecomposition() for the resulting replay).
    var grouped = root.collapseGroups(tiledClients)
    var representatives = Object.keys(grouped.representativeOf)
    root.beginDecomposition(0, root.pendingMoveSourceWorkspace, representatives, grouped.representativeOf, destination, {
      purpose: "move",
      metaMap: metaMap,
      monitor: monitor,
      occupied: occupied,
      floatingStructure: floatingStructure,
      floatingGeometry: floatingGeometry
    })
  }

  // "move" completion callback. Every tiled representative has already
  // been relocated onto root.stashWorkspace by the sequencer, exactly
  // like a real stash — never onto st.destinationWorkspace directly (see
  // beginDecomposition()). The resolved-tree case below is therefore a
  // genuine cross-workspace replay, matching restore()'s own mechanism.
  function finishMoveDecomposition(st, tree) {
    var structure = st.floatingStructure.slice()
    var geometry = st.floatingGeometry.slice()

    if (tree) {
      var walked = root.walkAndDispatch(tree, st.destinationWorkspace, st.monitor,
        function(addr) { return st.occupied }, null, null, st.metaMap)
      structure = structure.concat(walked.structure)
      geometry = geometry.concat(walked.geometry)
    } else {
      // Reconstruction failed. Unlike stash()'s unresolved case (safe to
      // leave parked — restore() sorts it out later), a "move" batch has
      // no root.batchPlans entry to ever recover it, so every survivor is
      // moved onto the real destination individually instead — no
      // preselect chaining, no forced resize.
      for (var i = 0; i < st.addresses.length; i++) {
        var repAddr = st.addresses[i]
        var liveAddr = root.resolveLiveAddress(root.makeLeaf(repAddr, st.groupMembersByAddress[repAddr]))
        if (!liveAddr) continue
        var m = st.metaMap[liveAddr]
        structure = structure.concat(root.structureClauses(liveAddr, st.destinationWorkspace, m, null, null))
        geometry = geometry.concat(root.geometryClauses(liveAddr, m, st.monitor, true))
      }
    }

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

  // External-focus collision safeguard: an external "launch or focus"
  // command (e.g. a stock Omarchy binding) matches windows by class/title
  // system-wide — if the match is parked in the stash, Hyprland reveals
  // that workspace even though Hyprland.focusedWorkspace never changes.
  //
  // Three invariants, each from a failed first attempt (docs/DESIGN-JOURNEY.md):
  //   1. Detection reads the raw event stream (Hyprland.rawEvent,
  //      "activespecial"), never Quickshell's cached workspace properties.
  //   2. Deactivation is gated on a fresh `hyprctl -j monitors` query, not
  //      that same event stream — Hyprland doesn't reliably emit a clean
  //      "deactivated" event when the workspace empties on its own.
  //   3. No explicit refocus chases what the external shortcut wanted —
  //      Hyprland's own substitution isn't recoverable from the event
  //      stream, and forcing focus would misrepresent the user's intent.
  //
  // Restores through the one authoritative restore(); deactivation only
  // fires from finishCollisionRestore()'s confirmed-active check.
  property bool collisionRestoreInFlight: false

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "activespecial") return
      var workspaceName = String(event.data || "").split(",")[0]
      if (workspaceName === root.stashWorkspace) root.handleExposedStash()
    }
  }

  // Reentrancy guard: Hyprland may still report the workspace active
  // until the last window leaves, so further activespecial events can
  // arrive mid-transition — ignored while one is already in flight.
  function handleExposedStash() {
    if (root.collisionRestoreInFlight) return
    if (!root.hasStash) return

    root.collisionRestoreInFlight = true
    root.restore()

    // restore() only fires detached moves; completion is deferred to
    // onStashedToplevelsChanged above. This fallback covers only the case
    // where restore() found nothing to move despite hasStash reading
    // true, so the flag can't get stuck.
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
