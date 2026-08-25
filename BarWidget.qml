import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "apollo.sessions"

  property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 10)))
  property int blockedThresholdSec: Math.max(10, Number(setting("blockedThresholdSec", 30)))
  readonly property string home: String(Quickshell.env("HOME") || "/home/apollo")
  readonly property string scriptPath: home + "/.config/omarchy/plugins/apollo.sessions/session-poll.sh"

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  property var sessions: []
  property var worktrees: []
  property int dataRevision: 0
  property bool polling: false

  readonly property int totalSessions: sessions.length
  readonly property int blockedSessions: {
    var n = 0
    for (var i = 0; i < sessions.length; i++)
      if (sessions[i] && sessions[i].status === "blocked") n++
    return n
  }
  readonly property bool hasBlocked: blockedSessions > 0
  readonly property bool hasSessions: totalSessions > 0

  readonly property string barLabel: {
    if (!hasSessions) return ""
    if (hasBlocked) return String(blockedSessions) + "/" + String(totalSessions)
    return String(totalSessions)
  }

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

  implicitWidth: hasSessions ? button.implicitWidth : 0
  implicitHeight: hasSessions ? button.implicitHeight : 0

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
    pollProcess.command = ["bash", root.scriptPath, String(root.blockedThresholdSec)]
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
    target: "apollo.sessions"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    tooltipText: {
      if (root.hasBlocked)
        return totalSessions + " session" + (totalSessions === 1 ? "" : "s") + " \u00b7 " + blockedSessions + " blocked"
      return totalSessions + " session" + (totalSessions === 1 ? "" : "s")
    }
    horizontalMargin: 6
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
