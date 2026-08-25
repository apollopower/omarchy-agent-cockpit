import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "apollo.agent-cockpit"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  property var sessionsData: []
  property var worktreesData: []

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accentColor: Style.selectedStateColor(foreground, Color.accent)
  // Resolved against this file rather than a fixed plugin path -- see
  // BarWidget.localPath().
  readonly property string focusScript:
    String(Qt.resolvedUrl("focus-session.sh")).replace(/^file:\/\//, "")
  // Terminal used to open a worktree outside tmux. Empty means "ask the
  // system", since Omarchy ships Alacritty while this plugin was written
  // against foot.
  readonly property string terminal: String(setting("terminal", ""))
  readonly property color selectFill: Qt.rgba(accentColor.r, accentColor.g, accentColor.b, 0.15)

  readonly property real panelWidth: Style.space(520)
  readonly property real rowHeight: Style.font.body + Style.space(16)
  readonly property real headerHeight: Style.space(28)
  readonly property int totalItems: sessionsData.length + worktreesData.length
  readonly property int sessionCount: sessionsData.length

  readonly property real computedContentHeight: {
    var h = Style.space(8)
    if (sessionsData.length > 0) {
      h += headerHeight + Style.space(8)
      h += sessionsData.length * rowHeight + (sessionsData.length - 1) * Style.space(3)
    } else {
      h += Style.space(36)
    }
    if (worktreesData.length > 0) {
      h += Style.space(16)
      h += headerHeight + Style.space(8)
      h += worktreesData.length * rowHeight + (worktreesData.length - 1) * Style.space(3)
    }
    return h
  }

  readonly property real maxPanelHeight: Style.space(640)
  readonly property real minPanelHeight: Style.space(100)
  property real animatedHeight: 0
  property int selectedIndex: -1
  property bool closing: false

  Behavior on animatedHeight {
    NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
  }

  function clampSelected() {
    if (totalItems === 0) { selectedIndex = -1; return }
    selectedIndex = Math.max(0, Math.min(selectedIndex, totalItems - 1))
  }

  function selectNext() {
    if (totalItems === 0) return
    selectedIndex = selectedIndex < 0 ? 0 : (selectedIndex + 1) % totalItems
    ensureVisible()
  }

  function selectPrev() {
    if (totalItems === 0) return
    selectedIndex = selectedIndex < 0 ? totalItems - 1 : (selectedIndex === 0 ? totalItems - 1 : selectedIndex - 1)
    ensureVisible()
  }

  function ensureVisible() {
    if (selectedIndex < 0) return
    var itemTop = 0
    if (sessionsData.length > 0) itemTop = Style.space(8) + headerHeight + Style.space(8)
    else itemTop = Style.space(8)
    if (selectedIndex >= sessionCount) {
      if (sessionsData.length > 0) itemTop += Style.space(16) + headerHeight + Style.space(8)
      itemTop += (selectedIndex - sessionCount) * (rowHeight + Style.space(3))
    } else {
      itemTop += selectedIndex * (rowHeight + Style.space(3))
    }
    var itemBottom = itemTop + rowHeight
    if (itemTop < panelFlick.contentY)
      panelFlick.contentY = itemTop
    else if (itemBottom > panelFlick.contentY + panelFlick.height)
      panelFlick.contentY = itemBottom - panelFlick.height
  }

  function activateSelected() {
    if (selectedIndex < 0 || totalItems === 0) return
    if (selectedIndex < sessionCount)
      focusSession(sessionsData[selectedIndex])
    else
      openWorktree(worktreesData[selectedIndex - sessionCount])
  }

  function open() {
    closing = false
    root.controller.show()
  }

  function close() {
    if (closing) return
    closing = true
    root.animatedHeight = 0
    closeTimer.restart()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Timer {
    id: closeTimer
    interval: 200
    repeat: false
    onTriggered: root.controller.hide()
  }

  onOpenedChanged: {
    if (opened) {
      root.animatedHeight = Math.min(root.computedContentHeight, root.maxPanelHeight)
      if (totalItems > 0 && selectedIndex < 0) selectedIndex = 0
      clampSelected()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      closing = false
    }
  }

  function runCmd(cmd) {
    if (root.bar && typeof root.bar.run === "function") root.bar.run(cmd)
  }

  // Both activation paths hand off to focus-session.sh identically: close the
  // panel, then run the script a beat later. The script verifies and retries
  // its own focus dispatch, so this delay only has to get out of the panel's
  // way -- it does not have to win the race against the layer surface
  // unmapping, which is what the earlier per-path delays were guessing at.
  // Arguments are single-quoted so an empty one stays a separate empty
  // argument instead of shifting the next one into its place.
  function runFocusScript(arg1, arg2) {
    root.controller.hide()
    focusTimer.script = "bash '" + root.focusScript + "' '" + arg1 + "' '" + arg2 + "'"
    focusTimer.restart()
  }

  function focusSession(session) {
    runFocusScript(String(session.tmux_pane || ""), String(session.window_addr || ""))
  }

  function openWorktreeInTmux(worktree) {
    runFocusScript("tmux-new", String(worktree.path || ""))
  }

  Timer {
    id: focusTimer
    interval: 80
    repeat: false
    property string script: ""
    onTriggered: root.runCmd(script)
  }

  function openWorktree(worktree) {
    // Terminal selection and each terminal's working-directory flag live in
    // focus-session.sh; the panel only says which worktree and which preference.
    runCmd("bash '" + root.focusScript + "' open-term '"
         + String(worktree.path || "") + "' '" + root.terminal + "'")
    root.controller.hide()
  }

  function activateSelectedInTmux() {
    if (selectedIndex < 0 || totalItems === 0) return
    if (selectedIndex < sessionCount)
      focusSession(sessionsData[selectedIndex])
    else
      openWorktreeInTmux(worktreesData[selectedIndex - sessionCount])
  }

  function isSessionSelected(index) { return index === selectedIndex && index < sessionCount }
  function isWorktreeSelected(index) { return (index + sessionCount) === selectedIndex }

  // ---- row layout helpers: compute widths from panelWidth ----
  readonly property real rowInnerWidth: panelWidth - Style.space(28) - Style.space(12)
  readonly property real iconColWidth: Style.space(20)
  readonly property real agentColWidth: Style.space(80)

  function sessionStatusWidth() { return Style.space(104) }

  // Four states, each meaning something different. Only "blocked" -- an agent
  // stopped on a question it asked -- actually needs the user now, so it is the
  // only one that reads as urgent. "Idle" deliberately claims nothing about
  // whether the agent finished or is waiting: the signal cannot tell them apart.
  function stateIcon(state) {
    if (state === "blocked") return "\uf059"   // question mark: awaiting your answer
    if (state === "stuck")   return "\uf071"   // warning: loop died mid-flight
    if (state === "idle")    return "\uf111"   // dot: stopped, nothing to do
    return "\uf021"                            // arrows: mid loop
  }

  function stateColor(state) {
    if (state === "blocked" || state === "stuck") return root.urgent
    if (state === "idle") return root.dim
    return root.accentColor
  }

  function stateLabel(state, stale) {
    if (state === "blocked") return "Blocked " + root.formatStale(stale)
    if (state === "stuck")   return "Stuck " + root.formatStale(stale)
    if (state === "idle")    return "Idle " + root.formatStale(stale)
    return "Working"
  }

  // "Blocked 74929s" neither fits the status column nor reads as a duration.
  function formatStale(seconds) {
    var s = Math.max(0, Number(seconds) || 0)
    if (s < 60) return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m"
    if (s < 86400) return Math.floor(s / 3600) + "h"
    return Math.floor(s / 86400) + "d"
  }
  function worktreeBranchWidth() { return Style.space(130) }
  function worktreeDirtyWidth() { return Style.space(60) }

  function sessionRepoWidth() {
    return rowInnerWidth - iconColWidth - agentColWidth - sessionStatusWidth() - Style.space(4)
  }

  function worktreeRepoWidth() {
    return rowInnerWidth - iconColWidth - worktreeBranchWidth() - worktreeDirtyWidth() - Style.space(24) - Style.space(4)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(root.panelWidth)
    contentHeight: Math.max(root.minPanelHeight, root.animatedHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy > 0) root.selectNext()
        else if (dy < 0) root.selectPrev()
      }
      onActivateRequested: root.activateSelected()
      onTextKey: function(t) {
        if (t === "t") root.activateSelectedInTmux()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: Math.max(panelFlick.height, root.computedContentHeight)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: true
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SESSIONS"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.sessionsData.length > 0
          }

          Column {
            id: sessionsSection
            visible: root.sessionsData.length > 0
            width: parent.width
            spacing: Style.space(3)

            Repeater {
              model: root.sessionsData

              Item {
                id: sessionEntry
                required property var modelData
                required property int index

                width: parent.width
                implicitHeight: root.rowHeight

                readonly property var session: modelData
                readonly property string state: String(session.status || "working")
                readonly property bool needsAttention: state === "blocked" || state === "stuck"
                readonly property bool sel: root.isSessionSelected(index)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: sessionMouse.containsMouse
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                    : (sel ? root.selectFill : "transparent")
                  border.width: sel ? Math.max(1, Style.spacing.hairline + 1) : 0
                  border.color: sel ? root.accentColor : "transparent"
                }

                Row {
                  id: sessionRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(20)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stateIcon(sessionEntry.state)
                    color: root.stateColor(sessionEntry.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: root.iconColWidth
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(session.repo || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: root.sessionRepoWidth()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(session.agent || "").charAt(0).toUpperCase() + String(session.agent || "").slice(1)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: root.agentColWidth
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stateLabel(sessionEntry.state, session.stale)
                    color: root.stateColor(sessionEntry.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: root.sessionStatusWidth()
                  }
                }

                MouseArea {
                  id: sessionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectedIndex = index
                    root.focusSession(session)
                  }
                  onEntered: root.selectedIndex = index
                }
              }
            }
          }

          Text {
            visible: root.sessionsData.length === 0
            width: parent.width
            topPadding: Style.space(8)
            text: "No active agent sessions"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }

          PanelSeparator {
            visible: root.worktreesData.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            text: "WORKTREES"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.worktreesData.length > 0
          }

          Column {
            id: worktreesSection
            visible: root.worktreesData.length > 0
            width: parent.width
            spacing: Style.space(3)

            Repeater {
              model: root.worktreesData

              Item {
                id: worktreeEntry
                required property var modelData
                required property int index

                width: parent.width
                implicitHeight: root.rowHeight

                readonly property var wt: modelData
                readonly property bool dirty: Number(wt.dirty || 0) > 0
                readonly property bool sel: root.isWorktreeSelected(index)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: wtMouse.containsMouse
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
                    : (sel ? root.selectFill : "transparent")
                  border.width: sel ? Math.max(1, Style.spacing.hairline + 1) : 0
                  border.color: sel ? root.accentColor : "transparent"
                }

                Row {
                  id: worktreeRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(20)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: worktreeEntry.dirty ? "\uf071" : "\uf4a7"
                    color: worktreeEntry.dirty ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: root.iconColWidth
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(wt.repo || "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    width: root.worktreeRepoWidth()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(wt.branch || "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: root.worktreeBranchWidth()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Number(wt.dirty || 0) > 0
                    text: String(wt.dirty || 0) + " dirty"
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: root.worktreeDirtyWidth()
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: wt.session_attached === true
                    text: "\u26a1"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: Style.space(20)
                  }
                }

                MouseArea {
                  id: wtMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.selectedIndex = index + root.sessionCount
                    root.openWorktree(wt)
                  }
                  onEntered: root.selectedIndex = index + root.sessionCount
                }
              }
            }
          }
        }
      }
    }
  }
}
