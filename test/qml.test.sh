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

printf '\n%d passed' "$pass"
[ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"
printf '\n'
[ "$fail" -eq 0 ]
