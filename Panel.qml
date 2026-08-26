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

  // `w` collapses the worktree list to one row per repository and expands it
  // again. Filtering here rather than in the poll script keeps it instant --
  // no re-poll, no wait for the next tick. The setting only decides where the
  // panel starts; assigning showLinked breaks the binding, so a later data
  // refresh cannot silently undo the user's choice.
  property bool linkedDefault: true
  property bool showLinked: linkedDefault
  readonly property var worktreeRows: {
    if (showLinked) return worktreesData
    var rows = []
    for (var i = 0; i < worktreesData.length; i++)
      if (worktreesData[i] && worktreesData[i].main === true) rows.push(worktreesData[i])
    return rows
  }

  function toggleLinkedWorktrees() {
    showLinked = !showLinked
    clampSelected()
    ensureVisible()
  }

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

  // Pinned key legend. The panel is keyboard-driven and `w` in particular has
  // no other affordance, so the keys have to be stated somewhere. It sits
  // outside the Flickable: a legend that scrolls away with a long worktree
  // list would be worse than none.
  readonly property var legendKeys: [
    { key: "j/k", label: "move" },
    { key: "enter", label: "open" },
    { key: "t", label: "tmux" },
    { key: "w", label: root.showLinked ? "repos" : "worktrees" },
    { key: "esc", label: "close" }
  ]
  readonly property real legendHeight: Style.font.caption + Style.space(18)

  readonly property real panelWidth: Style.space(520)
  readonly property real rowHeight: Style.font.body + Style.space(16)
  readonly property real headerHeight: Style.space(28)
  readonly property int totalItems: sessionsData.length + worktreeRows.length
  readonly property int sessionCount: sessionsData.length

  readonly property real computedContentHeight: {
    var h = Style.space(8)
    if (sessionsData.length > 0) {
      h += headerHeight + Style.space(8)
      h += sessionsData.length * rowHeight + (sessionsData.length - 1) * Style.space(3)
    } else {
      h += Style.space(36)
    }
    if (worktreeRows.length > 0) {
      h += Style.space(16)
      h += headerHeight + Style.space(8)
      h += worktreeRows.length * rowHeight + (worktreeRows.length - 1) * Style.space(3)
    }
    h += legendHeight
    return h
  }

  readonly property real maxPanelHeight: Style.space(640)
  readonly property real minPanelHeight: Style.space(100)
  property real animatedHeight: 0
  property int selectedIndex: -1
  property bool closing: false

  // Height the panel settles at while open. The minimum keeps a nearly empty
  // panel from looking degenerate, and applying it *here* rather than to the
  // rendered height is what lets the roll-up reach zero: clamping the rendered
  // height meant closing stalled at minPanelHeight -- 79% of the way down on a
  // full panel -- and the leftover box then vanished separately via
  // KeyboardPanel's card fade, which reads as a stutter rather than one motion.
  readonly property real openHeight:
    Math.max(root.minPanelHeight, Math.min(root.computedContentHeight, root.maxPanelHeight))

  // KeyboardPanel fades the card over cardFadeMs once `open` goes false, and
  // keeps the surface mapped until that finishes. Handing it the hide early, so
  // the fade ends exactly as the collapse reaches zero, makes the two overlap
  // into a single movement instead of running back to back.
  readonly property int collapseMs: 200
  readonly property int cardFadeMs: 140

  Behavior on animatedHeight {
    NumberAnimation { duration: root.collapseMs; easing.type: Easing.OutCubic }
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
      openWorktree(worktreeRows[selectedIndex - sessionCount])
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

  // A session appearing or ending while the panel is open used to leave the
  // card at the height it opened with, quietly turning the list scrollable.
  onOpenHeightChanged: if (opened && !closing) root.animatedHeight = root.openHeight

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  Timer {
    id: closeTimer
    interval: Math.max(0, root.collapseMs - root.cardFadeMs)
    repeat: false
    onTriggered: root.controller.hide()
  }

  onOpenedChanged: {
    if (opened) {
      root.animatedHeight = root.openHeight
      if (totalItems > 0 && selectedIndex < 0) selectedIndex = 0
      clampSelected()
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    } else {
      closing = false
    }
  }

  // Every argument here is a path, a branch or a tmux handle that came off the
  // filesystem, so none of it may be pasted into a shell command line: a
  // worktree directory is free to contain a quote, and pasting one in would end
  // the quoting and start a command. Util.execArgv runs `exec "$@"`, so the
  // arguments only ever land in positional parameters and are never re-parsed.
  function runArgv(argv) {
    Util.execArgv(argv)
  }

  // Both activation paths hand off to focus-session.sh identically: close the
  // panel, then run the script a beat later. The script verifies and retries
  // its own focus dispatch, so this delay only has to get out of the panel's
  // way -- it does not have to win the race against the layer surface
  // unmapping, which is what the earlier per-path delays were guessing at.
  function runFocusScript(arg1, arg2) {
    root.controller.hide()
    focusTimer.argv = ["bash", root.focusScript, arg1, arg2]
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
    property var argv: []
    onTriggered: root.runArgv(argv)
  }

  function openWorktree(worktree) {
    // Terminal selection and each terminal's working-directory flag live in
    // focus-session.sh; the panel only says which worktree and which preference.
    runArgv(["bash", root.focusScript, "open-term",
             String(worktree.path || ""), root.terminal])
    root.controller.hide()
  }

  function activateSelectedInTmux() {
    if (selectedIndex < 0 || totalItems === 0) return
    if (selectedIndex < sessionCount)
      focusSession(sessionsData[selectedIndex])
    else
      openWorktreeInTmux(worktreeRows[selectedIndex - sessionCount])
  }

  function isSessionSelected(index) { return index === selectedIndex && index < sessionCount }
  function isWorktreeSelected(index) { return (index + sessionCount) === selectedIndex }

  // ---- row layout helpers: compute widths from panelWidth ----
  readonly property real rowInnerWidth: panelWidth - Style.space(28) - Style.space(12)
  readonly property real iconColWidth: Style.space(20)
  readonly property real agentColWidth: Style.space(80)

  function sessionStatusWidth() { return Style.space(104) }

  // Five states, each meaning something different. Only "blocked" -- an agent
  // stopped on a question it asked -- actually needs the user now, so it is the
  // only one that reads as urgent. "Idle" deliberately claims nothing about
  // whether the agent finished or is waiting: the signal cannot tell them apart.
  // Capitalising the first letter turned "opencode" into "Opencode", which is
  // not what the project calls itself. Names are spelled the way their owners
  // spell them.
  function agentLabel(agent) {
    var name = String(agent || "")
    if (name === "claude") return "Claude"
    if (name === "opencode") return "opencode"
    return name
  }

  function stateIcon(state) {
    if (state === "blocked") return "\uf059"   // question mark: awaiting your answer
    if (state === "stuck")   return "\uf071"   // warning: loop died mid-flight
    if (state === "idle")    return "\uf111"   // dot: stopped, nothing to do
    if (state === "unknown") return "\uf141"   // ellipsis: no reading available
    return "\uf021"                            // arrows: mid loop
  }

  function stateColor(state) {
    if (state === "blocked" || state === "stuck") return root.urgent
    if (state === "idle" || state === "unknown") return root.dim
    return root.accentColor
  }

  function stateLabel(state, stale) {
    if (state === "blocked") return "Blocked " + root.formatStale(stale)
    if (state === "stuck")   return "Stuck " + root.formatStale(stale)
    if (state === "idle")    return "Idle " + root.formatStale(stale)
    if (state === "unknown") return "Unknown"
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
    contentHeight: root.animatedHeight

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
        else if (t === "w") root.toggleLinkedWorktrees()
      }

      Flickable {
        id: panelFlick
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: legend.top
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
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stateIcon(sessionEntry.state)
                    color: root.stateColor(sessionEntry.state)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: root.iconColWidth
                  }

                  Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.agentLabel(session.agent)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: root.agentColWidth
                  }

                  Text {
                    textFormat: Text.PlainText
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
            textFormat: Text.PlainText
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
            visible: root.worktreeRows.length > 0
            foreground: root.foreground
          }

          PanelSectionHeader {
            // Says which mode the list is in, since `w` is the only way to tell.
            text: root.showLinked ? "WORKTREES" : "REPOSITORIES"
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.worktreeRows.length > 0
          }

          Column {
            id: worktreesSection
            visible: root.worktreeRows.length > 0
            width: parent.width
            spacing: Style.space(3)

            Repeater {
              model: root.worktreeRows

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
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: worktreeEntry.dirty ? "\uf071" : "\uf4a7"
                    color: worktreeEntry.dirty ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: root.iconColWidth
                  }

                  Text {
                    textFormat: Text.PlainText
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
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(wt.branch || "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: root.worktreeBranchWidth()
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    visible: Number(wt.dirty || 0) > 0
                    text: String(wt.dirty || 0) + " dirty"
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: root.worktreeDirtyWidth()
                  }

                  Text {
                    textFormat: Text.PlainText
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

      Item {
        id: legend
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.legendHeight

        PanelSeparator {
          anchors.top: parent.top
          width: parent.width
          foreground: root.foreground
        }

        Row {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: Style.space(3)
          spacing: Style.space(12)

          Repeater {
            model: root.legendKeys

            Row {
              required property var modelData
              spacing: Style.space(4)

              Text {
                textFormat: Text.PlainText
                text: modelData.key
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: modelData.label
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
