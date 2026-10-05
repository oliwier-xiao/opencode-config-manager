import QtQuick
import Quickshell
import Quickshell.Io

// One run of one of this plugin's helpers. Every process the panel starts is one of
// these, so what is asked of each of them is written down once, here:
//
//   the program      /usr/bin/bash on bin/run-bounded, which runs the helper in bin/
//                    named by `helper` — a fixed name, never a path — under a
//                    deadline (/usr/bin/timeout, the whole process group) and a byte
//                    cap on stdout and stderr (/usr/bin/head -c), at the end the
//                    bytes come out of rather than after this shell has buffered them
//   the environment  cleared, then exactly `env`: a fixed PATH of the system's own
//                    directories, HOME and the XDG folders. Nothing else the shell
//                    was started with — LD_PRELOAD, BASH_ENV, PYTHONPATH, a longer
//                    PATH — reaches the helper or anything it starts
//   the folder       HOME, never wherever the shell happened to be started from
//   the input        `input`, written to stdin and then closed. What the user typed
//                    or a file holds never goes on the command line, which every
//                    account on the machine can read through /proc
//   a second clock   a watchdog that kills it if it outlives its own deadline
//   a start failure  reported as one. Quickshell says nothing but runningChanged
//                    when a child cannot be started, and a caller waiting for an
//                    answer would otherwise wait for good
Process {
  id: proc

  property string pluginDir: ""
  property string helper: "oc-profiles"
  property var args: []
  property int seconds: 40
  property int maxBytes: 4194304
  property var env: ({})
  property string home: ""
  property string input: ""

  property bool settled: true
  property bool overflowed: false
  property bool killed: false

  // code: the exit status, or -1 when the helper never started. out: what it printed,
  // or "" when that was more than maxBytes — never a prefix of a longer answer.
  signal answered(int code, string out)

  function launch() {
    if (proc.running) return false
    proc.settled = false
    proc.overflowed = false
    proc.killed = false
    proc.stdinEnabled = true
    proc.running = true
    return true
  }

  command: ["/usr/bin/bash", proc.pluginDir + "/bin/run-bounded",
            String(proc.seconds), String(proc.maxBytes), proc.helper].concat(proc.args)
  clearEnvironment: true
  environment: proc.env
  workingDirectory: proc.home

  stdout: StdioCollector { id: outCollector; waitForEnd: true }
  // No stderr parser: Quickshell then discards what the helper writes there. Its
  // text is never logged — a jq or Python error can quote a fragment of the config
  // it was reading, and the shell's log is the journal.

  onStarted: {
    watchdog.restart()
    if (proc.input !== "") proc.write(proc.input)
    // Closing stdin is what tells the helper the input is complete.
    proc.stdinEnabled = false
  }

  onExited: function (code) {
    watchdog.stop()
    proc.settled = true
    // Counted in bytes, as the cap is: a string's length counts UTF-16 units, and a
    // prefix of a longer answer can be shorter in those than the cap is in bytes.
    var bytes = outCollector.data ? outCollector.data.byteLength : 0
    proc.overflowed = bytes > proc.maxBytes
    if (code !== 0) console.warn("opencode-configs:", proc.helper, "exited with status", code)
    proc.answered(proc.killed ? 137 : code, proc.overflowed ? "" : String(outCollector.text || ""))
  }

  onRunningChanged: {
    if (proc.running || proc.settled) return
    // Stopped without ever exiting: it was never started.
    watchdog.stop()
    proc.settled = true
    proc.answered(-1, "")
  }

  property Timer watchdog: Timer {
    interval: (proc.seconds + 5) * 1000
    repeat: false
    onTriggered: {
      if (!proc.running) return
      proc.killed = true
      proc.signal(9)
    }
  }
}
