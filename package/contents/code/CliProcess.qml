import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Runs one external command and reports its result, replacing Quickshell's
// `Process` (argv-list, no shell involved) on top of
// `Plasma5Support.DataSource` (the KF6 way to exec from pure QML), which only
// accepts a single shell string.
//
// Every argv element is single-quote escaped before being joined, so a call
// site that sets `command: ["protonvpn", "connect", userSuppliedName]` gets
// the same "never crosses a shell unescaped" guarantee the upstream code
// relies on for its one deliberately-quoted case (the sign-in username) —
// here it's automatic for every argument, at every call site.
Item {
  id: root

  property var command: []
  property bool running: false
  property string stdoutText: ""
  property string stderrText: ""
  property int exitCode: -1
  property int _seq: 0
  property string _sourceName: ""
  // Plasma5Support's "executable" DataSource has been observed to silently
  // drop a connectSource() call's response on rare occasions (seen in
  // practice as a plasmoid-wide loader stuck on "Loading…" forever, only
  // recoverable by fully restarting plasmashell — since `running` staying
  // true forever blocks every call site's own re-entrancy guard, e.g.
  // `if (citiesProcess.running) return` in Service.qml). This watchdog caps
  // how long any single call waits, so a lost response degrades to an
  // ordinary failure (exitCode -1) that the next retry/poll can recover
  // from, instead of a permanent hang. Generous default since some real
  // commands (e.g. `protonvpn connect`) legitimately take a while; call
  // sites expecting something slower can override it.
  property int timeoutMs: 20000

  signal exited(int exitCode)

  function _quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function _toShellCommand(argv) {
    var parts = []
    for (var i = 0; i < argv.length; i++) parts.push(root._quote(argv[i]))
    return parts.join(" ")
  }

  Timer {
    id: watchdog
    interval: root.timeoutMs
    repeat: false
    onTriggered: {
      if (!root.running) return
      source.disconnectSource(root._sourceName)
      root.stdoutText = ""
      root.stderrText = "Timed out waiting for a response"
      root.exitCode = -1
      root.running = false
      root.exited(root.exitCode)
    }
  }

  P5Support.DataSource {
    id: source
    engine: "executable"
    onNewData: function(sourceName, data) {
      disconnectSource(sourceName)
      watchdog.stop()
      root.stdoutText = data["stdout"] !== undefined ? String(data["stdout"]) : ""
      root.stderrText = data["stderr"] !== undefined ? String(data["stderr"]) : ""
      root.exitCode = data["exit code"] !== undefined ? Number(data["exit code"]) : -1
      root.running = false
      root.exited(root.exitCode)
    }
  }

  onRunningChanged: {
    if (!running) return
    var argv = command || []
    if (argv.length === 0) { running = false; return }
    // The "executable" engine keys sources by the literal command string, so
    // two widget instances (or two overlapping polls) issuing the exact same
    // command collide: one connectSource() call can be swallowed as "already
    // connected", silently starving that caller of a result. A trailing
    // shell comment makes every invocation's source name unique without
    // changing what runs (everything after # is a no-op to /bin/sh, even
    // when an earlier quoted argument contains a literal newline, since that
    // newline sits inside an still-open quote as far as the shell parser is
    // concerned).
    root._seq += 1
    var nonce = Date.now() + "-" + root._seq + "-" + Math.random().toString(36).slice(2, 8)
    var shellCmd = root._toShellCommand(argv) + " # " + nonce
    root._sourceName = shellCmd
    watchdog.restart()
    source.connectSource(shellCmd)
  }
}
