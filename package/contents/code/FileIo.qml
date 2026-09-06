import QtQuick

// Minimal file read/write over CliProcess, replacing Quickshell's FileView.
// Write is atomic the same way FileView's atomicWrites is: write to a
// sibling temp file, then rename over the target.
Item {
  id: root

  signal loaded(string content, bool ok)
  signal written(bool ok)

  function _quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function readFile(path) {
    reader.command = ["cat", "--", path]
    reader.running = true
  }

  function writeFile(path, content) {
    var tmp = path + ".tmp." + Date.now()
    var script = "printf '%s' " + root._quote(content) + " > " + root._quote(tmp)
                 + " && mv -f " + root._quote(tmp) + " " + root._quote(path)
    writer.command = ["sh", "-c", script]
    writer.running = true
  }

  // Directory must exist before the first write (mkdir -p, not part of the
  // atomic write itself so a failure here is easy to tell apart from one).
  function ensureDir(path) {
    mkdirProc.command = ["mkdir", "-p", path]
    mkdirProc.running = true
  }

  CliProcess {
    id: reader
    onExited: function(code) { root.loaded(code === 0 ? stdoutText : "", code === 0) }
  }

  CliProcess {
    id: writer
    onExited: function(code) { root.written(code === 0) }
  }

  CliProcess { id: mkdirProc }
}
