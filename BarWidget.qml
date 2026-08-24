import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Presentation only. All state comes from Service.qml via bar.shell.serviceFor();
// this widget never keeps its own copy of the stashed-window list.
BarWidget {
  id: root
  moduleName: "io.github.devASstated.workspace-stash"

  readonly property var service: (root.bar && root.bar.shell)
    ? root.bar.shell.serviceFor("io.github.devASstated.workspace-stash") : null
  readonly property var items: service ? service.items : []
  readonly property int count: service ? service.count : 0
  readonly property bool hasStash: count > 0

  readonly property string displayMode: setting("displayMode", "count")
  readonly property int maxNames: Math.max(1, Number(setting("maxNames", 2)))
  readonly property int maxIcons: Math.max(1, Number(setting("maxIcons", 3)))
  readonly property string overflowStyle: setting("overflowStyle", "badge")
  readonly property string overflowCountMode: setting("overflowCountMode", "leftover")

  // Primary click action: the same state-driven toggle SUPER+M already
  // uses, not restore() directly. Identical result once something's
  // stashed (toggle() resolves to restore() whenever hasStash is true) —
  // the only thing this changes is the empty case, which used to be a
  // silent no-op and now actually stashes the current workspace. That's
  // what makes the widget usable on a fresh install with no keybindings
  // configured yet: it's now the one guaranteed entry point.
  function primaryAction() {
    if (root.service) root.service.toggle()
  }

  // Right-click menu: display style, overflow presentation, the two
  // overflow limits, a keybindings reference, and a reset action. All
  // setters below write through PluginRegistry.setBarWidget (reached via
  // bar.shell.pluginRegistry) — the exact function the `omarchy bar set
  // <id> <key> <value>` CLI path calls, confirmed by reading
  // shell.qml/PluginRegistry.qml rather than guessed. Persisted result is
  // byte-for-byte equivalent to using the CLI; there is no second settings
  // store, and no IPC round-trip needed since this is a same-process call.
  function writeSetting(key, value) {
    if (!root.bar || !root.bar.shell || !root.bar.shell.pluginRegistry) return
    root.bar.shell.pluginRegistry.setBarWidget(root.moduleName, key, value, {})
  }

  property bool menuOpen: false
  // "main" | "keybindings" — always resets to "main" whenever the menu is
  // freshly opened (see the MouseArea below), so a previous drill-down
  // never lingers into the next open.
  property string menuPage: "main"
  property bool confirmResetOpen: false

  function close() { menuOpen = false }

  readonly property var displayModeOptions: [
    { value: "count", label: "Count" },
    { value: "names", label: "Names" },
    { value: "icons", label: "Icons" }
  ]
  readonly property var overflowStyleOptions: [
    { value: "badge", label: "+N" },
    { value: "ellipsis", label: "..N" }
  ]
  readonly property var overflowCountModeOptions: [
    { value: "leftover", label: "Leftover" },
    { value: "total", label: "Total" }
  ]

  function selectDisplayMode(mode) {
    if (mode !== root.displayMode) root.writeSetting("displayMode", mode)
  }
  function setMaxNames(value) { root.writeSetting("maxNames", Math.round(value)) }
  function setMaxIcons(value) { root.writeSetting("maxIcons", Math.round(value)) }
  function setOverflowStyle(value) {
    if (value !== root.overflowStyle) root.writeSetting("overflowStyle", value)
  }
  function setOverflowCountMode(value) {
    if (value !== root.overflowCountMode) root.writeSetting("overflowCountMode", value)
  }

  // Resets every setting this plugin exposes back to its manifest default.
  // Confirmed first (see ConfirmDialog below) since it touches five
  // settings at once — one misclick shouldn't undo careful tuning.
  function resetDefaults() {
    root.writeSetting("displayMode", "count")
    root.writeSetting("maxNames", 2)
    root.writeSetting("maxIcons", 3)
    root.writeSetting("overflowStyle", "badge")
    root.writeSetting("overflowCountMode", "leftover")
  }

  readonly property string tooltipSummary: root.displayMode === "count"
    ? root.count + " stashed"
    : root.namesLabel
  readonly property string tooltipText: root.hasStash
    ? (root.tooltipSummary + "\nLeft-click to restore all\nRight-click for settings")
    : "Nothing stashed yet\nLeft-click to stash this workspace\nRight-click for settings"

  function appLabel(item) {
    if (!item) return "Window"
    if (item.appId) {
      var entry = DesktopEntries.heuristicLookup(item.appId)
      if (entry && entry.name) return entry.name
    }
    return item.appId || item.title || "Window"
  }

  readonly property var names: items.map(appLabel)
  readonly property var shownNames: names.slice(0, maxNames)
  readonly property int nameOverflow: names.length - shownNames.length
  readonly property string namesShownText: shownNames.join(", ")

  readonly property var shownIcons: items.slice(0, maxIcons)
  readonly property int iconOverflow: items.length - shownIcons.length

  // Builds the trailing overflow indicator text for either names or icons:
  // nothing when everything fits; otherwise a prefix ("…" or "+", per
  // overflowStyle) followed by a count (how many are hidden, or the full
  // stashed total, per overflowCountMode) — the two settings are fully
  // independent, so all four combinations ("…3", "…7", "+3", "+7" for a
  // 3-hidden/7-total example) are reachable.
  function overflowIndicatorFor(overflowCount, totalCount) {
    if (overflowCount <= 0) return ""
    var prefix = root.overflowStyle === "ellipsis" ? ".." : "+"
    var count = root.overflowCountMode === "total" ? totalCount : overflowCount
    return prefix + count
  }

  // Tooltip-only: full summary with the overflow indicator folded in as
  // text, since the tooltip bubble has no width cap to fight (see Bar.qml
  // — it sizes itself around whatever text it's given). The on-bar
  // rendering below never uses this — it keeps the shown-names text and
  // the overflow indicator as separate elements so eliding a too-long name
  // list can never swallow the indicator.
  readonly property string namesLabel: {
    var indicator = root.overflowIndicatorFor(root.nameOverflow, root.names.length)
    return indicator === "" ? root.namesShownText : (root.namesShownText + " " + indicator)
  }

  function resolveIcon(appId) {
    if (!appId) return Quickshell.iconPath("application-x-executable", true)
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = entry && entry.icon ? entry.icon : ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  readonly property bool showNames: displayMode === "names" && !vertical
  readonly property bool showIcons: displayMode === "icons"
  readonly property real maxNamesWidth: Style.space(240)

  // Always visible, even with an empty stash (dimmed — see the glyph
  // below): on a fresh install there are no keybindings configured yet
  // either (this plugin never touches user config automatically), so an
  // invisible-until-non-empty widget left no discoverable way in at all
  // beyond the CLI. See docs/FEATURES.md §2 and docs/DESIGN-JOURNEY.md for
  // the fuller reasoning.
  visible: true
  implicitWidth: content.implicitWidth + Style.space(12)
  implicitHeight: barSize

  // Resolves this QML file's own directory regardless of where the plugin
  // is actually installed/symlinked — same technique io.github.ilyazar.btop
  // uses for its own keybindings-file launcher.
  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    return decodeURIComponent(value)
  }
  readonly property string openScript: localPath(Qt.resolvedUrl("open-config-file.sh"))

  function copySnippet(text) {
    Quickshell.execDetached(["wl-copy", text])
  }
  function openBindingsFile() {
    Quickshell.execDetached(["bash", root.openScript,
      Quickshell.env("HOME") + "/.config/hypr/bindings.lua", "workspace-stash",
      "io.github.devASstated.workspace-stash-bindings"])
  }
  function openInputFile() {
    Quickshell.execDetached(["bash", root.openScript,
      Quickshell.env("HOME") + "/.config/hypr/input.lua", "workspace-stash",
      "io.github.devASstated.workspace-stash-input"])
  }

  // Exact text of examples/bindings.lua's own blocks — kept in sync by
  // hand when that file changes, the same way displayModeOptions etc.
  // above are hand-maintained rather than parsed from anywhere.
  readonly property var keyboardBindings: [
    {
      name: "Toggle stash",
      keys: "SUPER + M",
      snippet: "hl.bind(\n"
        + "  \"SUPER + M\",\n"
        + "  hl.dsp.exec_cmd([[omarchy-shell -q workspace-stash toggle]]),\n"
        + "  { description = \"Toggle workspace stash\" }\n"
        + ")"
    },
    {
      name: "Cumulative stash",
      keys: "SUPER + CTRL + M",
      snippet: "hl.bind(\n"
        + "  \"SUPER + CTRL + M\",\n"
        + "  hl.dsp.exec_cmd([[omarchy-shell -q workspace-stash stash]]),\n"
        + "  { description = \"Stash current workspace (cumulative)\" }\n"
        + ")"
    },
    {
      name: "Move to workspace",
      keys: "SUPER + CTRL + SHIFT + 1-9",
      snippet: "for workspace = 1, 10 do\n"
        + "  local key = \"code:\" .. tostring(workspace + 9)\n"
        + "  hl.bind(\n"
        + "    \"SUPER + CTRL + SHIFT + \" .. key,\n"
        + "    hl.dsp.exec_cmd(\"omarchy-shell -q workspace-stash moveTo \" .. tostring(workspace)),\n"
        + "    { description = \"Move workspace to workspace \" .. workspace }\n"
        + "  )\n"
        + "end"
    }
  ]

  readonly property var gestureBindings: [
    {
      name: "Stash (swipe down)",
      keys: "3 fingers",
      snippet: "hl.gesture({\n"
        + "  fingers = 3,\n"
        + "  direction = \"down\",\n"
        + "  action = function() hl.dispatch(hl.dsp.exec_cmd(\"omarchy-shell -q workspace-stash stash\")) end,\n"
        + "})"
    },
    {
      name: "Restore (swipe up)",
      keys: "3 fingers",
      snippet: "hl.gesture({\n"
        + "  fingers = 3,\n"
        + "  direction = \"up\",\n"
        + "  action = function() hl.dispatch(hl.dsp.exec_cmd(\"omarchy-shell -q workspace-stash restore\")) end,\n"
        + "})"
    }
  ]

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Stack glyph: a small drawn pictogram rather than a font icon, so the
    // widget doesn't depend on a specific Nerd Font codepoint being
    // present. Three filled bars, leaning diagonally — reads as a small
    // stack of layers (git's own stash is a LIFO stack) without the
    // bordered-box version's visual weight. Dimmed while the stash is
    // empty, full opacity once something's stashed; same shape either way.
    Item {
      width: Style.space(12)
      height: Style.space(7)
      anchors.verticalCenter: parent.verticalCenter
      opacity: root.hasStash ? 1.0 : 0.38
      Behavior on opacity { NumberAnimation { duration: 120 } }

      Repeater {
        model: [
          { x: 2, y: 0 },
          { x: 1, y: 3 },
          { x: 0, y: 6 }
        ]
        Rectangle {
          x: Style.spaceReal(modelData.x)
          y: Style.spaceReal(modelData.y)
          width: Style.space(10)
          height: Math.max(1, Style.spaceReal(1))
          radius: 0
          color: root.bar ? root.bar.barForeground : Color.foreground
        }
      }
    }

    Text {
      visible: (root.displayMode === "count" || root.vertical) && root.hasStash
      anchors.verticalCenter: parent.verticalCenter
      text: String(root.count)
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Row {
      visible: root.showNames && root.hasStash
      spacing: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(root.maxNamesWidth, implicitWidth)
        text: root.namesShownText
        elide: Text.ElideRight
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
      }

      Text {
        readonly property string indicator: root.overflowIndicatorFor(root.nameOverflow, root.names.length)
        visible: indicator !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: indicator
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      visible: root.showIcons && !root.vertical && root.hasStash
      spacing: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter

      Repeater {
        model: root.shownIcons

        Image {
          required property var modelData
          width: Style.space(14)
          height: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          source: root.resolveIcon(modelData.appId)
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          asynchronous: true
        }
      }

      Text {
        readonly property string indicator: root.overflowIndicatorFor(root.iconOverflow, root.items.length)
        visible: indicator !== ""
        anchors.verticalCenter: parent.verticalCenter
        text: indicator
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Bar.qml's showTooltip() independently re-checks target.tooltipHovered
  // before displaying anything (both immediately and again inside its own
  // deferred Qt.callLater) rather than trusting the onEntered call alone —
  // confirmed by reading Bar.qml directly. Without this property the check
  // always reads undefined !== true and showTooltip silently no-ops, which
  // is exactly why the tooltip never appeared. Same convention WidgetButton
  // uses: a plain hover-derived bool on the target itself.
  readonly property bool tooltipHovered: root.visible && mouseArea.containsMouse

  // showTooltip() only snapshots `text` at the moment it's called — it does
  // not keep displaying a live-updating value on its own. onEntered alone
  // is therefore not enough here: count/names change incrementally as
  // Hyprland applies each window's move individually (not atomically), and
  // this widget's own visible/width toggling as count changes can refire
  // `entered` under a stationary cursor and snapshot a transient,
  // not-yet-settled value. Re-issuing showTooltip whenever tooltipText
  // itself changes, but only while genuinely still hovered, keeps the
  // shown text live instead of frozen at whatever it happened to be at
  // first entry.
  onTooltipTextChanged: if (root.tooltipHovered && root.bar) root.bar.showTooltip(root, root.tooltipText)

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) {
        if (!root.menuOpen) root.menuPage = "main"
        root.menuOpen = !root.menuOpen
      } else if (mouse.button === Qt.LeftButton) {
        root.primaryAction()
      }
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText)
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: menuPopup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.menuOpen
    // fittedContentWidth() only ever shrinks this to fit the screen, it
    // never grows to fit content — has to be a generous guess up front.
    // 170 (carried over from the original single-section menu) clipped the
    // ButtonGroup/stepper rows; 240 then clipped ConfirmDialog's own
    // Cancel/Reset button row, which has no width constraint of its own
    // (two 88-unit buttons plus spacing, sized well past 240 once
    // ConfirmDialog's own internal padding is subtracted from it).
    contentWidth: menuPopup.fittedContentWidth(Style.space(300))
    contentHeight: menuPopup.fittedContentHeight(
      root.menuPage === "main" ? mainColumn.implicitHeight : keybindingsColumn.implicitHeight)

    Column {
      id: mainColumn
      visible: root.menuPage === "main"
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(2)

      PanelSectionHeader {
        text: "Display"
        width: parent.width
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      ButtonGroup {
        width: parent.width
        options: root.displayModeOptions
        value: root.displayMode
        foreground: root.bar ? root.bar.foreground : Color.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: Color.accent
        onChanged: function(value) { root.selectDisplayMode(value) }
      }

      Item { width: 1; height: Style.space(8) }

      Item {
        width: parent.width
        height: Style.space(30)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Max names shown"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          PanelActionButton {
            iconText: "−"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.setMaxNames(Math.max(1, root.maxNames - 1))
          }
          Text {
            width: Style.space(16)
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
            text: String(root.maxNames)
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: "+"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.setMaxNames(Math.min(10, root.maxNames + 1))
          }
        }
      }

      Item {
        width: parent.width
        height: Style.space(30)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Max icons shown"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Row {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          PanelActionButton {
            iconText: "−"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.setMaxIcons(Math.max(1, root.maxIcons - 1))
          }
          Text {
            width: Style.space(16)
            horizontalAlignment: Text.AlignHCenter
            anchors.verticalCenter: parent.verticalCenter
            text: String(root.maxIcons)
            color: root.bar ? root.bar.foreground : Color.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: "+"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.setMaxIcons(Math.min(12, root.maxIcons + 1))
          }
        }
      }

      // The whole Overflow section only means anything in Names/Icons mode
      // — Count mode is always a bare number, it never truncates anything,
      // so there's nothing for these controls to affect there.
      Item { width: 1; height: Style.space(6); visible: root.displayMode !== "count" }
      PanelSeparator {
        visible: root.displayMode !== "count"
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }
      Item { width: 1; height: Style.space(6); visible: root.displayMode !== "count" }

      PanelSectionHeader {
        visible: root.displayMode !== "count"
        text: "Overflow"
        width: parent.width
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      ButtonGroup {
        visible: root.displayMode !== "count"
        width: parent.width
        options: root.overflowStyleOptions
        value: root.overflowStyle
        foreground: root.bar ? root.bar.foreground : Color.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: Color.accent
        onChanged: function(value) { root.setOverflowStyle(value) }
      }

      // Independent of overflowStyle — leftover/total picks what the
      // number *is*, "…"/"+" (above) picks what comes before it. Both
      // styles show a count now, so this row applies to either one.
      ButtonGroup {
        visible: root.displayMode !== "count"
        width: parent.width
        options: root.overflowCountModeOptions
        value: root.overflowCountMode
        foreground: root.bar ? root.bar.foreground : Color.foreground
        background: root.bar ? root.bar.background : Color.background
        accent: Color.accent
        onChanged: function(value) { root.setOverflowCountMode(value) }
      }

      Item { width: 1; height: Style.space(6) }
      PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }
      Item { width: 1; height: Style.space(6) }

      Item {
        id: keybindingsNavRow
        width: parent.width
        height: Style.space(24)
        readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          color: keybindingsNavHover.containsMouse
            ? Style.hoverFillFor(keybindingsNavRow.foreground, Color.accent) : "transparent"
        }

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(6)
          text: "Keybindings"
          color: keybindingsNavRow.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.space(6)
          text: "›"
          color: Qt.darker(keybindingsNavRow.foreground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
        MouseArea {
          id: keybindingsNavHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.menuPage = "keybindings"
        }
      }

      Item { width: 1; height: Style.space(4) }

      Item {
        id: resetRow
        width: parent.width
        height: Style.space(20)
        readonly property color foreground: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(6)
          spacing: Style.space(5)

          Text {
            text: "↺"
            color: resetRow.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            text: "Reset to defaults"
            color: resetRow.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.confirmResetOpen = true
        }
      }
    }

    Column {
      id: keybindingsColumn
      visible: root.menuPage === "keybindings"
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(2)

      Item {
        id: backRow
        width: parent.width
        height: Style.space(22)
        readonly property color foreground: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.3)

        Row {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)
          Text {
            text: "‹ Back"
            color: backRow.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.menuPage = "main"
        }
      }

      PanelSectionHeader {
        text: "Keyboard"
        width: parent.width
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Repeater {
        model: root.keyboardBindings
        delegate: Item {
          required property var modelData
          width: keybindingsColumn.width
          height: Style.space(30)

          Column {
            anchors.left: parent.left
            anchors.right: copyButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              text: modelData.name
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              text: modelData.keys
              elide: Text.ElideRight
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelActionButton {
            id: copyButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "⧉"
            tooltipText: "Copy Lua snippet"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.copySnippet(modelData.snippet)
          }
        }
      }

      Item { width: 1; height: Style.space(2) }

      Item {
        id: openBindingsRow
        width: parent.width
        height: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "↗ Open bindings.lua"
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openBindingsFile()
        }
      }

      Item { width: 1; height: Style.space(6) }
      PanelSeparator { foreground: root.bar ? root.bar.foreground : Color.foreground }
      Item { width: 1; height: Style.space(6) }

      PanelSectionHeader {
        text: "Gestures"
        width: parent.width
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Repeater {
        model: root.gestureBindings
        delegate: Item {
          required property var modelData
          width: keybindingsColumn.width
          height: Style.space(30)

          Column {
            anchors.left: parent.left
            anchors.right: gestureCopyButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            Text {
              width: parent.width
              text: modelData.name
              elide: Text.ElideRight
              color: root.bar ? root.bar.foreground : Color.foreground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
            }
            Text {
              width: parent.width
              text: modelData.keys
              elide: Text.ElideRight
              color: Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          PanelActionButton {
            id: gestureCopyButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "⧉"
            tooltipText: "Copy Lua snippet"
            size: Style.space(24)
            bordered: true
            foreground: root.bar ? root.bar.foreground : Color.foreground
            onClicked: root.copySnippet(modelData.snippet)
          }
        }
      }

      Item { width: 1; height: Style.space(2) }

      Item {
        width: parent.width
        height: Style.space(20)

        Text {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "↗ Open input.lua"
          color: Color.accent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.openInputFile()
        }
      }
    }

    ConfirmDialog {
      anchors.fill: parent
      opened: root.confirmResetOpen
      message: "Reset all Workspace Stash settings to their defaults?"
      cancelText: "Cancel"
      confirmText: "Reset"
      foreground: root.bar ? root.bar.foreground : Color.foreground
      background: root.bar ? root.bar.background : Color.background
      onCanceled: root.confirmResetOpen = false
      onConfirmed: {
        root.resetDefaults()
        root.confirmResetOpen = false
      }
    }
  }
}
