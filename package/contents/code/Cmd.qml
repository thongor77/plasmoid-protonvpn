import QtQuick
import org.kde.plasma.plasma5support as P5Support

// Fire-and-forget command execution, replacing Quickshell.execDetached().
// Same argv-quoting as CliProcess, no result is read back.
Item {
  id: root

  property int _seq: 0

  function _quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function _toShellCommand(argv) {
    var parts = []
    for (var i = 0; i < argv.length; i++) parts.push(root._quote(argv[i]))
    return parts.join(" ")
  }

  P5Support.DataSource {
    id: source
    engine: "executable"
    onNewData: function(sourceName, data) { disconnectSource(sourceName) }
  }

  function execDetached(argv) {
    if (!argv || argv.length === 0) return
    // Same source-name collision concern as CliProcess (see its comment):
    // make every invocation unique so two calls with identical argv don't
    // get coalesced into one.
    root._seq += 1
    var nonce = Date.now() + "-" + root._seq + "-" + Math.random().toString(36).slice(2, 8)
    source.connectSource(root._toShellCommand(argv) + " # " + nonce)
  }
}
