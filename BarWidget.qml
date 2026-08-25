import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "apollo.agent-cockpit"

  property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)))
  property int stuckAfterSec: Math.max(60, Number(setting("stuckAfterSec", 600)))
  readonly property string worktreeRoots: String(setting("worktreeRoots", "~/Work/repos"))

  // Resolved against this file rather than a fixed plugin path, so the plugin
  // keeps working whatever its install directory is named.
  function localPath(name) {
    return String(Qt.resolvedUrl(name)).replace(/^file:\/\//, "")
  }
  readonly property string scriptPath: localPath("session-poll.sh")

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  property var sessions: []
  property var worktrees: []
  property int dataRevision: 0
  property bool polling: false

  readonly property int totalSessions: sessions.length

  function countState(state) {
    var n = 0
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i] && sessions[i].status === state) n++
    return n
  }

  // Only "blocked" lights the bar. An agent that merely finished its turn is
  // not something to interrupt you for, which is what made the old
  // any-session-not-working badge cry wolf.
  readonly property int blockedSessions: countState("blocked")
  readonly property bool hasBlocked: blockedSessions > 0
  readonly property bool hasSessions: totalSessions > 0

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("sessionsData" in target) target.sessionsData = root.sessions
    if ("worktreesData" in target) target.worktreesData = root.worktrees
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  // Always present, like the other status icons. Collapsing to zero width when
  // no agent happened to be running took the worktree list with it -- the panel
  // became unclickable exactly when there was nothing else going on -- and left
  // a freshly installed plugin looking like it had not installed at all.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onDataRevisionChanged: injectPanel()

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.rescanSessions()
  }

  Process {
    id: pollProcess
    running: false
    onRunningChanged: root.polling = pollProcess.running
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = text.trim()
        if (err !== "") console.warn("sessions stderr:", err)
      }
    }
  }

  function rescanSessions() {
    if (pollProcess.running) return
    pollProcess.command = ["bash", root.scriptPath,
                           String(root.stuckAfterSec), root.worktreeRoots]
    pollProcess.running = true
  }

  function parseOutput(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      root.sessions = Array.isArray(parsed.sessions) ? parsed.sessions : []
      root.worktrees = Array.isArray(parsed.worktrees) ? parsed.worktrees : []
      root.dataRevision++
    } catch (e) {
      console.warn("sessions parse error:", e)
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "apollo.agent-cockpit"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // An icon rather than a count, matching the other bar widgets. `active` tints
  // it with bar.urgent, and the bar animates that colour over 420ms, so an
  // agent needing you arrives as a gentle shift rather than a new glyph.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A terminal prompt, not a robot: the neighbouring agents widget already
    // owns the robot glyph, and U+F544 (fa-robot) is absent from the bar font
    // and renders as tofu.
    text: "\uf120"
    slotSize: Style.bar.statusSlot
    active: root.hasBlocked
    tooltipText: {
      if (root.totalSessions === 0) {
        var trees = root.worktrees.length
        return trees > 0
          ? "No agent sessions \u00b7 " + trees + " worktree" + (trees === 1 ? "" : "s")
          : "No agent sessions"
      }
      var parts = []
      if (root.blockedSessions > 0) parts.push(root.blockedSessions + " blocked")
      var working = root.countState("working")
      if (working > 0) parts.push(working + " working")
      var idle = root.countState("idle")
      if (idle > 0) parts.push(idle + " idle")
      var stuck = root.countState("stuck")
      if (stuck > 0) parts.push(stuck + " stuck")
      var head = totalSessions + " agent session" + (totalSessions === 1 ? "" : "s")
      return parts.length > 0 ? head + " \u00b7 " + parts.join(", ") : head
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
