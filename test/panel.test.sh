#!/usr/bin/env bash
# What the panel starts, what it opens, and what it draws, held at the source.
# There is no Quickshell here to run the panel in, so each rule is read off the
# shipped .qml files themselves: a process added without a cleared environment, a
# file read by the shell itself, a program found on PATH, a label left to guess
# whether a name is markup, or a log line carrying what a helper printed fails this
# suite before it ships. Each rule is shown to catch the thing it forbids, on a
# copy with that one thing put back, so a rule that has stopped matching anything
# fails too instead of passing quietly.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }

# Every rule lives in this one checker, which prints one line per violation. Run on
# the repository it must print nothing; run on a copy with a violation planted, it
# must name it.
cat > "$T/check.py" <<'PY'
import os, re, sys

root = sys.argv[1]
qml = sorted(f for f in os.listdir(root) if f.endswith(".qml"))
src = {f: open(os.path.join(root, f), encoding="utf-8").read() for f in qml}
model_js = open(os.path.join(root, "lib", "Model.js"), encoding="utf-8").read()

def strip(s):
    """Comments blanked and string contents kept, offsets unchanged."""
    out, i, n = [], 0, len(s)
    while i < n:
        if s.startswith("//", i):
            j = s.find("\n", i); j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif s.startswith("/*", i):
            j = s.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", s[i:j])); i = j
        elif s[i] == '"':
            j = i + 1
            while j < n and s[j] != '"':
                j += 2 if s[j] == "\\" else 1
            out.append(s[i:j + 1]); i = j + 1
        else:
            out.append(s[i]); i += 1
    return "".join(out)

code = {f: strip(s) for f, s in src.items()}

def blocks(text, kind):
    """(line, body at the block's own depth) for every `kind {` element."""
    for m in re.finditer(r"(?<![\w.])" + kind + r"\s*\{", text):
        depth, j, own = 1, m.end(), []
        while depth and j < len(text):
            ch = text[j]
            if ch == "{": depth += 1
            elif ch == "}": depth -= 1
            if depth == 1: own.append(ch)
            j += 1
        yield text.count("\n", 0, m.start()) + 1, "".join(own), text[m.end():j]

bad = []
def say(f, line, what): bad.append("%s:%d: %s" % (f, line, what))

for f, c in code.items():
    # A process is either the one wrapper or one that clears its environment itself.
    for line, own, _ in blocks(c, "Process"):
        if f != "HelperProcess.qml" and not re.search(r"\bclearEnvironment\s*:\s*true\b", own):
            say(f, line, "a Process without clearEnvironment: true")
        if not re.search(r"\bworkingDirectory\s*:", own):
            say(f, line, "a Process with no working directory of its own")
    # The shell reads no file itself, and parses no helper's output anywhere but the wrapper.
    for kind in ("FileView", "SplitParser", "StdioCollector"):
        for m in re.finditer(r"(?<![\w.])" + kind + r"\b", c):
            if kind != "StdioCollector" or f != "HelperProcess.qml":
                say(f, c.count("\n", 0, m.start()) + 1, kind + " outside HelperProcess.qml")
    # Every program is named by its absolute path.
    for m in re.finditer(r"\bcommand\s*[:=]\s*\[\s*([^,\]\s]+)", c):
        if not m.group(1).startswith('"/'):
            say(f, c.count("\n", 0, m.start()) + 1, "a command that does not start with an absolute path")
    for m in re.finditer(r"execDetached\s*\(\s*(.)", c):
        line = c.count("\n", 0, m.start()) + 1
        if m.group(1) != "{":
            say(f, line, "execDetached with a bare command list")
            continue
        call = c[m.start():c.find("})", m.start())]
        if not re.search(r"clearEnvironment\s*:\s*true", call):
            say(f, line, "execDetached without clearEnvironment: true")
        if not re.search(r'command\s*:\s*\[\s*"/', call):
            say(f, line, "execDetached of a program that is not an absolute path")
    for m in re.finditer(r"openUrlExternally", c):
        say(f, c.count("\n", 0, m.start()) + 1, "Qt.openUrlExternally")
    # A process is started through launch(), which resets what it reports; the one
    # exception is the notification, which reports nothing.
    for m in re.finditer(r"(\w+)\.running\s*=\s*true", c):
        if m.group(1) not in ("proc", "notify"):
            say(f, c.count("\n", 0, m.start()) + 1, m.group(1) + ".running = true instead of launch()")
    # Nothing a helper printed, and nothing read out of a config, is logged.
    for m in re.finditer(r"console\.\w+\s*\(([^)]*)\)", c):
        args = m.group(1)
        if not re.fullmatch(r'\s*"opencode-configs:"\s*,\s*proc\.helper\s*,\s*"[^"]*"\s*,\s*code\s*', args):
            say(f, c.count("\n", 0, m.start()) + 1, "a log line carrying more than a helper's name and status")
    # Every text item says it is plain text. Qt's default is to guess, and a guess of
    # rich text fetches the images a name points at.
    for kind in ("Text", "Label", "TextEdit", "TextArea"):
        for line, own, _ in blocks(c, kind):
            if not re.search(r"\btextFormat\s*:\s*Text\.PlainText\b", own):
                say(f, line, kind + " without textFormat: Text.PlainText")
    for m in re.finditer(r"textFormat\s*:\s*Text\.(\w+)", c):
        if m.group(1) != "PlainText":
            say(f, c.count("\n", 0, m.start()) + 1, "textFormat: Text." + m.group(1))
    # Helpers are started with fixed verbs; what they act on travels in the
    # environment or on stdin, never as an argument.
    for m in re.finditer(r"runAction\(\s*(\[[^\]]*\]|\w+)", c):
        a = m.group(1)
        line = c.count("\n", 0, m.start()) + 1
        if a.startswith("["):
            if not re.fullmatch(r'\[\s*"[a-z]+"\s*\]', a):
                say(f, line, "runAction with more than a fixed verb: " + a)
        elif a != "args":
            say(f, line, "runAction with a computed argument list")

# The one computed list: a repair, whose code must look like the backend's own.
p = code.get("Panel.qml", "")
fn = p[p.find("function fixHealthIssue"):]
fn = fn[:fn.find("\n  }\n")]
if "runAction(args" in fn:
    if not re.search(r'if \(!/\^\[EW\]_\[A-Z0-9_\]\{1,60\}\$/\.test\(code\)\) return', fn) \
       or fn.find("test(code)) return") > fn.find("var args"):
        say("Panel.qml", 1, "the repair code reaches an argument unchecked")
    if not re.search(r'var args = \["repair", "--fix", code, "--apply"\]', fn):
        say("Panel.qml", 1, "the repair argument list is not the fixed one")

# The notification: fixed words and counts, nothing the user named.
for m in re.finditer(r"notify\.command\s*=\s*\[(.*?)\]\s*\n", p, re.S):
    body = m.group(1)
    if not body.lstrip().startswith('"/usr/bin/timeout"'):
        say("Panel.qml", p.count("\n", 0, m.start()) + 1, "a notification not under /usr/bin/timeout")
    for ident in re.findall(r"\b([A-Za-z_][\w.]*)\b", re.sub(r'"[^"]*"', '""', body)):
        if ident not in ("reloaded", "running"):
            say("Panel.qml", p.count("\n", 0, m.start()) + 1, "a notification carrying " + ident)

# The wrapper: bash on run-bounded, a cleared environment, HOME as the folder,
# input on stdin and then closed, a watchdog.
h = code.get("HelperProcess.qml", "")
for need, what in (
    (r'command\s*:\s*\[\s*"/usr/bin/bash"\s*,\s*proc\.pluginDir\s*\+\s*"/bin/run-bounded"', "starts /usr/bin/bash on bin/run-bounded"),
    (r"clearEnvironment\s*:\s*true", "clears the environment"),
    (r"environment\s*:\s*proc\.env\b", "passes only its env"),
    (r"workingDirectory\s*:\s*proc\.home\b", "runs in HOME"),
    (r"proc\.write\(proc\.input\)", "writes its input to stdin"),
    (r"proc\.stdinEnabled\s*=\s*false", "and closes it"),
    (r"proc\.signal\(9\)", "has a watchdog that kills"),
    (r"answered\(-1", "reports a helper that never started"),
):
    if not re.search(need, h):
        say("HelperProcess.qml", 1, "no longer " + what)
if re.search(r"\bstderr\s*:", h):
    say("HelperProcess.qml", 1, "collects stderr")

# The environment every helper gets: the system's own PATH and nothing inherited
# that could change what runs.
pm = re.search(r"function childEnv\(extra\)\s*\{(.*?)\n  \}", p, re.S)
if not pm:
    say("Panel.qml", 1, "childEnv(extra) is gone")
else:
    body = pm.group(1)
    if not re.search(r'"PATH"\s*:\s*"/usr/bin:/bin"', body):
        say("Panel.qml", 1, "childEnv does not fix PATH to /usr/bin:/bin")
    for k in re.findall(r'"([A-Z_][A-Z0-9_]*)"\s*:', body):
        if k in ("LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV", "ENV", "PYTHONPATH",
                 "PYTHONSTARTUP", "PYTHONHOME", "NODE_OPTIONS", "PERL5OPT", "IFS"):
            say("Panel.qml", 1, "childEnv passes " + k)

# Model.plain flattens markup; every name handed to a shell component goes through it.
if not re.search(r"\.replace\(/\[<>&\]/g", model_js):
    say("lib/Model.js", 1, "plain() no longer removes markup characters")

print("\n".join(bad))
PY

check(){ python3 "$T/check.py" "$1"; }

echo "=== the shipped panel ==="
out="$(check "$REPO")"
if [ -z "$out" ]; then ok "every process, file read, label and log line follows the rules"
else no "every process, file read, label and log line follows the rules" "$(printf '%s' "$out" | head -20 | tr '\n' ';')"; fi

# ---- each rule, shown to catch what it forbids --------------------------------

copy(){ rm -rf "$T/c"; mkdir -p "$T/c/lib"; cp "$REPO"/*.qml "$T/c/"; cp "$REPO/lib/Model.js" "$T/c/lib/"; }
plant(){ # <rule name> <file> <python expression transforming s> <expected fragment>
  copy
  python3 - "$T/c/$2" "$3" <<'PY' || { no "$1" "could not plant the violation"; return; }
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
t = eval(expr)
if t == s: sys.exit(1)
open(p, "w", encoding="utf-8").write(t)
PY
  local got; got="$(check "$T/c")"
  case "$got" in *"$4"*) ok "$1" ;; *) no "$1" "the checker said: ${got:-nothing}" ;; esac
}

echo "=== and it notices each thing it forbids ==="
plant "a process that keeps the shell's environment" Panel.qml \
  's.replace("    id: notify\n    clearEnvironment: true\n", "    id: notify\n", 1)' "without clearEnvironment"
plant "a file the shell reads itself" Panel.qml \
  's.replace("  // ---- Catalog", "  FileView { id: fv; path: \"/x\" }\n  // ---- Catalog", 1)' "FileView outside"
plant "a program found on PATH" Panel.qml \
  's.replace("[\"/usr/bin/timeout\", \"-k\"", "[\"timeout\", \"-k\"", 1)' "absolute path"
plant "a detached program with the shell's environment" Panel.qml \
  's.replace("      clearEnvironment: true,\n      environment: root.desktopEnv(),", "      environment: root.desktopEnv(),", 1)' "execDetached without clearEnvironment"
plant "a URL opened by Qt" Panel.qml \
  's.replace("  function openConfigFile(path) {", "  function openConfigFile(path) {\n    Qt.openUrlExternally(path)", 1)' "openUrlExternally"
plant "a label left to guess" EffortDropdown.qml \
  's.replace("        text: \"󰅀\"\n        textFormat: Text.PlainText\n", "        text: \"󰅀\"\n", 1)' "Text without textFormat"
plant "a label told to render markup" EffortDropdown.qml \
  's.replace("        text: \"󰅀\"\n        textFormat: Text.PlainText\n", "        text: \"󰅀\"\n        textFormat: Text.StyledText\n", 1)' "Text.StyledText"
plant "a helper's output in the log" HelperProcess.qml \
  's.replace("    if (code !== 0) console.warn(\"opencode-configs:\", proc.helper, \"exited with status\", code)", "    console.warn(\"opencode-configs:\", outCollector.text)", 1)' "log line"
plant "a profile name on a helper's command line" Panel.qml \
  's.replace("runAction([\"delete\"], root.profileEnv(id, \"\")", "runAction([\"delete\", id], root.profileEnv(id, \"\")", 1)' "more than a fixed verb"
plant "a repair code passed on unchecked" Panel.qml \
  's.replace("    if (!/^[EW]_[A-Z0-9_]{1,60}$/.test(code)) return\n", "", 1)' "unchecked"
plant "a profile name in a notification" Panel.qml \
  's.replace("\"-a\", \"OpenCode Configs\", \"-t\", \"4000\", \"OpenCode profile switched\",", "\"-a\", \"OpenCode Configs\", \"-t\", \"4000\", profile.name,", 1)' "notification carrying profile.name"
plant "a process started around launch()" Panel.qml \
  's.replace("onTriggered: if (!catalogSync.running) catalogSync.launch()", "onTriggered: if (!catalogSync.running) catalogSync.running = true", 1)' "instead of launch()"
plant "the wrapper keeping the shell's environment" HelperProcess.qml \
  's.replace("  clearEnvironment: true\n", "", 1)' "clears the environment"
plant "the wrapper collecting stderr" HelperProcess.qml \
  's.replace("  stdout: StdioCollector { id: outCollector; waitForEnd: true }\n", "  stdout: StdioCollector { id: outCollector; waitForEnd: true }\n  stderr: StdioCollector { id: errCollector }\n", 1)' "collects stderr"
plant "an inherited PATH" Panel.qml \
  's.replace("\"PATH\": \"/usr/bin:/bin\"", "\"PATH\": null", 1)' "does not fix PATH"

echo "=== every helper names its interpreter by path ==="
for f in "$REPO"/bin/*; do
  [ -f "$f" ] || continue
  first="$(head -1 "$f")"
  case "$first" in
    '#!/usr/bin/bash'|'#!/usr/bin/python3 -I') ;;
    *) no "$(basename "$f") starts from an absolute interpreter" "$first"; continue ;;
  esac
  ok "$(basename "$f"): $first"
done

echo "=== run-bounded starts only the helpers that ship beside it ==="
allow="$(grep -oE '^\s*oc-profiles\|sync-models\.sh\|read-catalog\|read-templates\)' "$REPO/bin/run-bounded" | tr -d ' ')"
[ "$allow" = "oc-profiles|sync-models.sh|read-catalog|read-templates)" ] \
  && ok "the allow-list is the four helpers" \
  || no "the allow-list is the four helpers" "found: ${allow:-nothing}"
for h in oc-profiles sync-models.sh read-catalog read-templates; do
  grep -q "helper: \"$h\"" "$REPO"/Panel.qml && ok "the panel's $h is one of them" \
    || no "the panel's $h is one of them" "Panel.qml has no HelperProcess for it"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
