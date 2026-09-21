#!/usr/bin/env bash
# The QML the other suites cannot reach. Everything else here runs lib/*.js under
# node, which is fine for the writers but says nothing about the call sites — and
# the one config this plugin could write that loads and then fails came from a call
# site, not from a writer.
#
# So the functions under test are spliced verbatim out of the .qml files and run in
# a real QML engine against the real lib/Model.js and lib/Catalog.js. Editing
# ProfileEditor.qml changes what this executes. Renaming what it looks for fails the
# extraction rather than quietly testing nothing.
#
# console.log from `qml` does not survive the pipe, so each case is its own process
# and the exit code carries the verdict: 0 passed, n>0 failed, 99 threw.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }

QMLBIN=""
for c in qml6 qml; do
  command -v "$c" >/dev/null 2>&1 || continue
  # Qt5's `qml` cannot load a versionless `import QtQuick`, which every file here uses.
  case "$("$c" --version 2>&1)" in *" 6."*) QMLBIN="$c"; break ;; esac
done
if [ -z "$QMLBIN" ]; then
  echo "  skip the QML suite (no Qt6 qml runtime on this machine)"
  echo
  echo "0 passed"
  exit 0
fi

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/lib"
cp "$REPO/lib/Model.js" "$REPO/lib/Catalog.js" "$T/lib/"

# ---- extract the real source ------------------------------------------------

extract_fn() { # <file> <name> -> the whole function, braces balanced
  python3 - "$1" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.find("function " + sys.argv[2])
if i < 0:
    sys.stderr.write("not found: " + sys.argv[2] + "\n"); sys.exit(1)
d = 0; started = False
for j, ch in enumerate(s[i:], i):
    if ch == '{': d += 1; started = True
    elif ch == '}':
        d -= 1
        if started and d == 0:
            print(s[i:j+1]); sys.exit(0)
sys.stderr.write("unbalanced: " + sys.argv[2] + "\n"); sys.exit(1)
PY
}

APPLY="$(extract_fn "$REPO/ProfileEditor.qml" applyRowModel)" || {
  no "ProfileEditor.applyRowModel can be found" "extraction failed — was it renamed?"
  printf '\n%d passed, %d FAILED\n' "$pass" "$fail"; exit 1
}
ok "ProfileEditor.applyRowModel extracted from the shipped file"

INTERVAL="$(grep -oE 'interval: Math\.min\([0-9]+, root\.catalogRefreshHours \* 3600 \* 1000\)' "$REPO/Panel.qml" | head -1)"
[ -n "$INTERVAL" ] \
  && ok "Panel's refresh interval expression extracted" \
  || no "Panel's refresh interval expression extracted" "the clamped form is no longer in Panel.qml"

# ---- harness ----------------------------------------------------------------

write_case() { # <name> <body>
  cat > "$T/Case_$1.qml" <<QML
import QtQuick
import "lib/Model.js" as Model
import "lib/Catalog.js" as Catalog

Item {
  id: root
  property var profile: null
  property var catalogIndex: ({
    "anthropic/claude-opus-5": { id: "anthropic/claude-opus-5", variants: ["low","medium","high","max"] },
    "openai/gpt-5-nano":       { id: "openai/gpt-5-nano",       variants: [] },
    "google/gemini-3-flash":   { id: "google/gemini-3-flash",   variants: ["low","medium"] }
  })
  readonly property var rows: root.profile ? Model.rowsFor(root.profile) : []
  property var lastEdit: null
  signal profileEdited(var next)
  onProfileEdited: function (next) { root.lastEdit = next }

$APPLY

  property int failed: 0
  function check(c) { if (!c) root.failed++ }
  function ocProfile() {
    return { id: "p", name: "P", targets: [
      { file: "opencode", shape: "opencode", manages: ["model","small_model","agent"],
        payload: { model: "anthropic/claude-sonnet-5", small_model: "anthropic/claude-haiku-4-5",
                   agent: { build: { model: "anthropic/claude-sonnet-5" } } } } ] }
  }
  function omProfile() {
    return { id: "o", name: "O", targets: [
      { file: "ohmy", shape: "oh-my-openagent", manages: ["agents","categories"],
        payload: { agents: { librarian: { model: "anthropic/claude-haiku-4-5" } }, categories: {} } } ] }
  }
  function rowKey(p, k, file) {
    var rs = Model.rowsFor(p)
    for (var j = 0; j < rs.length; j++) if (rs[j].key === k && rs[j].file === file) return j
    return -1
  }

  Component.onCompleted: {
    var p, i
    try {
$2
    } catch (err) { root.failed = 99 }
    Qt.exit(root.failed)
  }
}
QML
}

run_case() { QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/Case_$1.qml" >/dev/null 2>&1; }

# ---- an effort never survives onto a model that cannot take it ---------------

echo "=== the real applyRowModel, in a real QML engine ==="

write_case drops '
    p = ocProfile(); i = rowKey(p, "build", "opencode")
    root.profile = Model.setRowVariant(p, Model.rowsFor(p)[i], "max")
    check(root.profile.targets[0].payload.agent.build.variant === "max")
    root.applyRowModel(rowKey(root.profile, "build", "opencode"), "openai/gpt-5-nano")
    var e = root.lastEdit.targets[0].payload.agent.build
    check(e.model === "openai/gpt-5-nano")
    check(e.variant === undefined && e.reasoning === undefined)'
run_case drops && ok "an opencode agent drops an effort the new model does not offer" \
               || no "an opencode agent drops an effort the new model does not offer" "rc=$?"

write_case steps '
    p = ocProfile(); i = rowKey(p, "build", "opencode")
    root.profile = Model.setRowVariant(p, Model.rowsFor(p)[i], "max")
    root.applyRowModel(rowKey(root.profile, "build", "opencode"), "google/gemini-3-flash")
    check(root.lastEdit.targets[0].payload.agent.build.variant === "medium")'
run_case steps && ok "and steps down to the nearest one it does" \
               || no "and steps down to the nearest one it does" "rc=$?"

write_case keeps '
    p = ocProfile(); i = rowKey(p, "build", "opencode")
    root.profile = Model.setRowVariant(p, Model.rowsFor(p)[i], "high")
    root.applyRowModel(rowKey(root.profile, "build", "opencode"), "anthropic/claude-opus-5")
    check(root.lastEdit.targets[0].payload.agent.build.variant === "high")'
run_case keeps && ok "an effort the new model does offer is kept as it was" \
               || no "an effort the new model does offer is kept as it was" "rc=$?"

write_case ohmy '
    p = omProfile(); i = rowKey(p, "librarian", "ohmy")
    root.profile = Model.setRowVariant(p, Model.rowsFor(p)[i], "max")
    root.applyRowModel(rowKey(root.profile, "librarian", "ohmy"), "openai/gpt-5-nano")
    var o = root.lastEdit.targets[0].payload.agents.librarian
    check(o.variant === undefined && o.reasoning === undefined)'
run_case ohmy && ok "an oh-my-openagent row steps down as it always did" \
              || no "an oh-my-openagent row steps down as it always did" "rc=$?"

write_case none '
    root.profile = ocProfile()
    root.applyRowModel(rowKey(root.profile, "build", "opencode"), "anthropic/claude-opus-5")
    var n = root.lastEdit.targets[0].payload.agent.build
    check(n.variant === undefined && n.reasoning === undefined)'
run_case none && ok "a row with no effort is given none" \
              || no "a row with no effort is given none" "rc=$?"

echo "=== and it would notice if that were undone ==="
# A test that cannot fail proves nothing. This re-runs the same assertion against
# the pre-fix line and requires it to fail.
sed -i 's/var wanted = root\.rows\[index\]\.variant$/var wanted = root.rows[index].file === "ohmy" ? root.rows[index].variant : ""/' "$T/Case_drops.qml"
if grep -qF 'file === "ohmy" ? root.rows[index].variant' "$T/Case_drops.qml"; then
  run_case drops \
    && no "the pre-fix call site fails this suite" "it passed — the assertion does not test the fix" \
    || ok "the pre-fix call site fails this suite"
else
  no "the pre-fix call site fails this suite" "could not construct the pre-fix variant"
fi

# ---- the refresh timer at the setting's own maximum --------------------------

echo "=== the refresh interval at every value the settings slider allows ==="
# manifest.json offers up to 720 hours. 720 * 3600 * 1000 is 2.59e9, past a signed
# 32-bit int, where a Qt interval wraps negative: the timer never fires and restarts
# itself hundreds of times a second instead.
MAXH="$(jq -r '[.barWidget.schema[] | select(.key=="catalogRefreshHours") | .max] | first' "$REPO/manifest.json" 2>/dev/null)"
[ -n "$MAXH" ] && [ "$MAXH" != null ] \
  && ok "the manifest states a maximum ($MAXH hours)" \
  || no "the manifest states a maximum" "catalogRefreshHours has no max"

cat > "$T/Timer.qml" <<QML
import QtQuick
Item {
  property int catalogRefreshHours: $MAXH
  Timer { id: t; $(echo "$INTERVAL" | sed 's/root\.catalogRefreshHours/parent.catalogRefreshHours/') ; repeat: true }
  property int failed: 0
  Component.onCompleted: {
    if (t.interval <= 0) failed++
    if (t.interval !== Math.min(2147483647, catalogRefreshHours * 3600 * 1000)) failed++
    Qt.exit(failed)
  }
}
QML
QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/Timer.qml" >/dev/null 2>&1 \
  && ok "the interval stays positive at the maximum" \
  || no "the interval stays positive at the maximum" "rc=$? — it overflowed"

cat > "$T/TimerRaw.qml" <<QML
import QtQuick
Item {
  property int catalogRefreshHours: $MAXH
  Timer { id: t; interval: parent.catalogRefreshHours * 3600 * 1000; repeat: true }
  Component.onCompleted: Qt.exit(t.interval > 0 ? 0 : 1)
}
QML
QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/TimerRaw.qml" >/dev/null 2>&1 \
  && no "the unclamped expression overflows there" "it did not — the clamp is testing nothing" \
  || ok "the unclamped expression overflows there"

# ---- the Health strip stays out of the way until there is something to say ----

echo "=== the Health section is absent, not empty, when nothing needs doing ==="
# Gated on something being repairable, not on the list being non-empty. The
# warnings are true of a config that works and stay true for as long as it does,
# so a strip they could summon on their own is a permanent box in everybody's
# panel whose entire content is "nothing is broken". The gate is asserted on the
# shipped file rather than described in a comment.
grep -qE 'active:[[:space:]]*root\.healthBroken' "$REPO/ProfileList.qml" \
  && ok "the strip is gated on something being repairable" \
  || no "the strip is gated on something being repairable" "the Loader's active: gate is no longer root.healthBroken"

grep -qE 'visible:[[:space:]]*active' "$REPO/ProfileList.qml" \
  && ok "and it takes no height when inactive" \
  || no "and it takes no height when inactive" "a Column keeps the gap of an invisible child"

# A doctor that has not been installed yet, an older binary, a usage message: all
# of them have to read as "no section", never as an error the user cannot act on.
for guard in 'parsed.ok !== true' 'Array.isArray(parsed.issues)' 'root.healthIssues = []'; do
  grep -qF "$guard" "$REPO/Panel.qml" \
    && ok "Panel guards on \`$guard\`" \
    || no "Panel guards on \`$guard\`" "the defensive parse no longer covers this"
done

# The gate above is only as good as what it is gated on, and `healthBroken` is a
# property binding rather than a function — so it is spliced out by its own name
# and evaluated in the engine against both lists that matter.
BROKEN="$(python3 - "$REPO/ProfileList.qml" <<'PY'
import sys
s = open(sys.argv[1]).read()
i = s.find("readonly property bool healthBroken:")
if i < 0:
    sys.stderr.write("not found\n"); sys.exit(1)
d = 0; started = False
for j, ch in enumerate(s[i:], i):
    if ch == '{': d += 1; started = True
    elif ch == '}':
        d -= 1
        if started and d == 0:
            print(s[i:j+1]); sys.exit(0)
sys.stderr.write("unbalanced\n"); sys.exit(1)
PY
)" || BROKEN=""
if [ -n "$BROKEN" ]; then
  cat > "$T/Broken.qml" <<QML
import QtQuick
Item {
  id: root
  property var healthIssues: []
$BROKEN
  property int failed: 0
  Component.onCompleted: {
    try {
      // Nothing at all, and nothing that can be done: no strip either way.
      root.healthIssues = []
      if (root.healthBroken) failed++
      root.healthIssues = [{ code: "W_VARIANT_DEPRECATED", fixable: false },
                           { code: "W_LEGACY_OHMY", fixable: false }]
      if (root.healthBroken) failed++
      // One repairable thing is what earns the row.
      root.healthIssues = [{ code: "W_VARIANT_DEPRECATED", fixable: false },
                           { code: "E_FILE_FALLBACK", fixable: true }]
      if (!root.healthBroken) failed++
      // A backend that says nothing about it is not saying yes.
      root.healthIssues = [{ code: "E_SOMETHING" }]
      if (root.healthBroken) failed++
    } catch (err) { failed = 99 }
    Qt.exit(failed)
  }
}
QML
  QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/Broken.qml" >/dev/null 2>&1 \
    && ok "warnings alone never summon it; one repair does" \
    || no "warnings alone never summon it; one repair does" "rc=$?"
else
  no "ProfileList.healthBroken can be found" "extraction failed — was it renamed?"
fi

HEALTHTEXT="$(extract_fn "$REPO/ProfileList.qml" healthText)" || HEALTHTEXT=""
if [ -n "$HEALTHTEXT" ]; then
  ok "ProfileList.healthText extracted from the shipped file"
  cat > "$T/Health.qml" <<QML
import QtQuick
Item {
  id: root
  property int failed: 0
  function check(c) { if (!c) root.failed++ }
$HEALTHTEXT
  Component.onCompleted: {
    try {
      // The sentence the backend wrote is what gets drawn.
      check(root.healthText({ code: "E_MODELS_IN_CONFIG", detail: "2 agents set models." })
            === "2 agents set models.")
      // A code this file has never heard of still draws as something.
      check(root.healthText({ code: "E_FROM_THE_FUTURE", detail: "" }) === "E_FROM_THE_FUTURE")
      // And nothing at all is empty, not "undefined".
      check(root.healthText(null) === "")
      check(root.healthText({}) === "")
    } catch (err) { root.failed = 99 }
    Qt.exit(root.failed)
  }
}
QML
  QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/Health.qml" >/dev/null 2>&1 \
    && ok "it draws the backend's sentence, and never \"undefined\"" \
    || no "it draws the backend's sentence, and never \"undefined\"" "rc=$?"
else
  no "ProfileList.healthText can be found" "extraction failed — was it renamed?"
fi

# ---- every list closes on the click that opened it --------------------------
#
# Three lists in the panel open on a click, and each keeps its trigger out of the
# press that would close it in a different way. All three are declarative, so no
# spliced function reaches them — they are asserted against the shipped source
# instead. Getting one wrong is invisible until somebody clicks twice, which is
# the whole of the bug they were written for.

echo "=== every list closes on the click that opened it ==="

if grep -qE 'closePolicy: root\.dismissOnOutsidePress' "$REPO/ModelPicker.qml" \
   && grep -qE 'QQC\.Popup\.CloseOnEscape \| QQC\.Popup\.CloseOnPressOutsideParent' "$REPO/ModelPicker.qml"; then
  ok "ModelPicker exempts its own trigger from the press that closes it"
else
  no "ModelPicker exempts its own trigger from the press that closes it" \
     "CloseOnPressOutsideParent is no longer how that popup closes; the default shuts it on the press and the release reopens it"
fi

if grep -qE 'closePolicy: Popup\.CloseOnEscape \| Popup\.CloseOnPressOutsideParent' "$REPO/EffortDropdown.qml"; then
  ok "EffortDropdown still carries the one line the fork exists for"
else
  no "EffortDropdown still carries the one line the fork exists for" \
     "the fork has drifted back to the shell's default, which is the bug it was forked to escape"
fi

if grep -qE '^ *EffortDropdown \{' "$REPO/AgentRow.qml"; then
  ok "the effort control is that fork, not the shell's Dropdown"
else
  no "the effort control is that fork, not the shell's Dropdown" \
     "AgentRow went back to Ui/Dropdown, so the fork is dead code and the control cannot be closed by clicking"
fi

if grep -qE 'dismissOnOutsidePress: false' "$REPO/ProfileEditor.qml" \
   && grep -qE 'onPressed: root\.clearFallbackPicker\(\)' "$REPO/ProfileEditor.qml"; then
  ok "the fallback picker owns its own dismissal, both halves of it"
else
  no "the fallback picker owns its own dismissal, both halves of it" \
     "it needs the policy off *and* the dismiss layer; with only one the chip click closes and reopens"
fi

# ---- and the fallback list toggles, and opens where the chip is --------------

OPENFB="$(extract_fn "$REPO/ProfileEditor.qml" openFallbackPicker)" || OPENFB=""
if [ -n "$OPENFB" ]; then
  ok "ProfileEditor.openFallbackPicker extracted from the shipped file"

  # The spliced function reaches for one spacing token off the shell's Style
  # singleton, which is not on this runtime's import path. It gets a stub of the
  # same shape, in its own directory so the qmldir cannot reach the other cases.
  mkdir -p "$T/stub"
  cat > "$T/stub/Style.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject { readonly property var spacing: ({ xxs: 2 }) }
QML
  printf 'singleton Style 1.0 Style.qml\n' > "$T/stub/qmldir"

  cat > "$T/Fallback.qml" <<QML
import QtQuick
import "stub"

Item {
  id: root
  width: 400
  height: 600

  property int failed: 0
  function check(c) { if (!c) root.failed++ }

  property var rows: [ { fallbacks: [ { model: "a/one" }, { model: "b/two" } ] } ]
  property int pendingFallbackRow: -1
  property int pendingFallbackIndex: -1
  property int opens: 0
  property int closes: 0

  QtObject {
    id: fallbackPicker
    property bool popupOpen: false
    property string value: ""
    property real popupHeight: 300
    property real popupWidth: 460
    property real x: 0
    property real y: 0
    function open() { fallbackPicker.popupOpen = true; root.opens++ }
    function close() { fallbackPicker.popupOpen = false; root.closes++ }
  }

$OPENFB

  Component.onCompleted: {
    try {
      // A chip opens the list.
      root.openFallbackPicker(0, 1, 10, 100, 20)
      check(fallbackPicker.popupOpen === true)
      check(root.opens === 1 && root.closes === 0)
      check(root.pendingFallbackRow === 0 && root.pendingFallbackIndex === 1)

      // The same chip again closes it — and must not reopen, which is what the
      // default close policy used to make it do.
      root.openFallbackPicker(0, 1, 10, 100, 20)
      check(fallbackPicker.popupOpen === false)
      check(root.closes === 1)
      check(root.opens === 1)
      check(root.pendingFallbackRow === -1 && root.pendingFallbackIndex === -1)

      // A different chip while it is open moves the list rather than closing it.
      root.openFallbackPicker(0, 1, 10, 100, 20)
      root.openFallbackPicker(0, 0, 10, 60, 20)
      check(fallbackPicker.popupOpen === true)
      check(root.pendingFallbackIndex === 0)

      // It opens below a chip with room under it ...
      var below = fallbackPicker.y
      check(below > 60)

      // ... and above one that would push it off the bottom.
      root.openFallbackPicker(0, 0, 10, 60, 20)   // close it first
      root.openFallbackPicker(0, 0, 10, 560, 20)
      check(fallbackPicker.y < 560)

      // And it never leaves the editor by the left or the right.
      check(fallbackPicker.x >= 0)
      check(fallbackPicker.x <= root.width)
    } catch (err) { root.failed = 99 }
    Qt.exit(root.failed)
  }
}
QML
  QT_QPA_PLATFORM=offscreen timeout 60 "$QMLBIN" "$T/Fallback.qml" >/dev/null 2>&1 \
    && ok "a chip opens the list, the same chip closes it, another moves it" \
    || no "a chip opens the list, the same chip closes it, another moves it" "rc=$?"
else
  no "ProfileEditor.openFallbackPicker can be found" "extraction failed — was it renamed?"
fi

printf '\n%d passed' "$pass"
[ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"
printf '\n'
[ "$fail" -eq 0 ]
