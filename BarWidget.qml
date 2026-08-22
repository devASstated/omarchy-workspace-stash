import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

// Presentation only. All state comes from Service.qml via bar.shell.serviceFor();
// this widget never keeps its own copy of the stashed-window list.
BarWidget {
  id: root
  moduleName: "io.github.REPLACE_ME.workspace-stash"

  readonly property var service: (root.bar && root.bar.shell)
    ? root.bar.shell.serviceFor("io.github.REPLACE_ME.workspace-stash") : null
  readonly property var items: service ? service.items : []
  readonly property int count: service ? service.count : 0

  readonly property string displayMode: setting("displayMode", "count")
  readonly property int maxNames: Math.max(1, Number(setting("maxNames", 4)))
  readonly property int maxIcons: Math.max(1, Number(setting("maxIcons", 6)))

  // Left-click: restore the whole stash via the one authoritative service
  // method — no logic lives here beyond the call itself.
  function restoreAll() {
    if (root.service) root.service.restore()
  }

  // Right-click menu: display style + the two overflow limits. All three
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
  function close() { menuOpen = false }

  readonly property var displayModeOptions: [
    { value: "count", label: "Count" },
    { value: "names", label: "Names" },
    { value: "icons", label: "Icons" }
  ]

  function selectDisplayMode(mode) {
    root.menuOpen = false
    if (mode !== root.displayMode) root.writeSetting("displayMode", mode)
  }

  function setMaxNames(value) { root.writeSetting("maxNames", Math.round(value)) }
  function setMaxIcons(value) { root.writeSetting("maxIcons", Math.round(value)) }

  readonly property string tooltipSummary: root.displayMode === "count"
    ? root.count + " stashed"
    : root.namesLabel
  readonly property string tooltipText: root.tooltipSummary
    + "\nLeft-click to restore all\nRight-click to change display style"

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

  // Tooltip-only: full summary with the overflow count folded in as text,
  // since the tooltip bubble has no width cap to fight (see Bar.qml — it
  // sizes itself around whatever text it's given). The on-bar rendering
  // below never uses this — it keeps the shown-names text and the overflow
  // badge as separate elements so eliding a too-long name list can never
  // swallow the badge.
  readonly property string namesLabel: root.nameOverflow > 0
    ? root.namesShownText + " +" + root.nameOverflow : root.namesShownText

  function resolveIcon(appId) {
    if (!appId) return Quickshell.iconPath("application-x-executable", true)
    var entry = DesktopEntries.heuristicLookup(appId)
    var icon = entry && entry.icon ? entry.icon : ""
    if (icon.indexOf("file://") === 0 || icon.indexOf("image://") === 0) return icon
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    return Quickshell.iconPath(icon || "application-x-executable", true)
  }

  readonly property var shownIcons: items.slice(0, maxIcons)
  readonly property int iconOverflow: items.length - shownIcons.length

  readonly property bool showNames: displayMode === "names" && !vertical
  readonly property bool showIcons: displayMode === "icons"
  readonly property real maxNamesWidth: Style.space(240)

  visible: count > 0
  implicitWidth: count > 0 ? content.implicitWidth + Style.space(12) : 0
  implicitHeight: barSize

  Row {
    id: content
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Tray glyph: a small drawn pictogram rather than a font icon, so the
    // widget doesn't depend on a specific Nerd Font codepoint being present.
    Item {
      width: Style.space(14)
      height: Style.space(11)
      anchors.verticalCenter: parent.verticalCenter

      Rectangle {
        width: parent.width
        height: Math.max(1, Style.spaceReal(1.5))
        anchors.bottom: parent.bottom
        radius: height / 2
        color: root.bar ? root.bar.barForeground : Color.foreground
      }

      Rectangle {
        width: Math.max(1, Style.spaceReal(1.5))
        height: parent.height - Style.space(3)
        anchors.left: parent.left
        color: root.bar ? root.bar.barForeground : Color.foreground
      }

      Rectangle {
        width: Math.max(1, Style.spaceReal(1.5))
        height: parent.height - Style.space(3)
        anchors.right: parent.right
        color: root.bar ? root.bar.barForeground : Color.foreground
      }
    }

    Text {
      visible: root.displayMode === "count" || root.vertical
      anchors.verticalCenter: parent.verticalCenter
      text: String(root.count)
      color: root.bar ? root.bar.barForeground : Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    Row {
      visible: root.showNames
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
        visible: root.nameOverflow > 0
        anchors.verticalCenter: parent.verticalCenter
        text: "+" + root.nameOverflow
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      visible: root.showIcons && !root.vertical
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
        visible: root.iconOverflow > 0
        anchors.verticalCenter: parent.verticalCenter
        text: "+" + root.iconOverflow
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
      if (mouse.button === Qt.RightButton) root.menuOpen = !root.menuOpen
      else if (mouse.button === Qt.LeftButton) root.restoreAll()
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
    contentWidth: menuPopup.fittedContentWidth(Style.space(150))
    contentHeight: menuPopup.fittedContentHeight(menuColumn.implicitHeight)

    Column {
      id: menuColumn
      anchors.fill: parent
      spacing: Style.space(2)

      Text {
        text: "Display style"
        color: Qt.darker(root.bar ? root.bar.foreground : Color.foreground, 1.4)
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
        width: parent.width
        bottomPadding: Style.space(4)
      }

      Repeater {
        model: root.displayModeOptions

        Rectangle {
          id: modeRow
          required property var modelData
          readonly property bool active: modelData.value === root.displayMode

          width: menuColumn.width
          height: Style.space(24)
          radius: Style.cornerRadius
          color: modeRowHover.hovered ? Style.hoverFillFor(root.bar ? root.bar.foreground : Color.foreground, Color.accent) : "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(6)
            text: (modeRow.active ? "✓ " : "   ") + modelData.label
            color: modeRow.active ? Color.accent : (root.bar ? root.bar.foreground : Color.foreground)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: modeRow.active
            elide: Text.ElideRight
          }

          MouseArea {
            id: modeRowHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            onClicked: root.selectDisplayMode(modeRow.modelData.value)
          }
        }
      }

      Item {
        width: 1
        height: Style.space(6)
      }

      PanelSeparator {
        foreground: root.bar ? root.bar.foreground : Color.foreground
      }

      Item {
        width: 1
        height: Style.space(6)
      }

      NumberField {
        label: "Max names shown"
        value: root.maxNames
        from: 1
        to: 10
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fieldWidth: Style.space(70)
        onModified: function(value) { root.setMaxNames(value) }
      }

      Item {
        width: 1
        height: Style.space(6)
      }

      NumberField {
        label: "Max icons shown"
        value: root.maxIcons
        from: 1
        to: 12
        foreground: root.bar ? root.bar.foreground : Color.foreground
        fieldWidth: Style.space(70)
        onModified: function(value) { root.setMaxIcons(value) }
      }
    }
  }
}
