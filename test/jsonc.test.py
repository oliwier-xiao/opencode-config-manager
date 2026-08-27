import json, subprocess, tempfile, os, sys
import pathlib
REPO = pathlib.Path(__file__).resolve().parent.parent
JE = str(REPO / "bin" / "jsonc-edit")
passed = failed = 0

def run(args):
    r = subprocess.run([JE] + args, capture_output=True, text=True)
    if r.returncode != 0:
        raise AssertionError("exit %d: %s" % (r.returncode, r.stderr.strip()))
    return r.stdout

def tmp(text):
    fd, p = tempfile.mkstemp(suffix=".jsonc"); os.write(fd, text.encode()); os.close(fd); return p

def t(name, fn):
    global passed, failed
    try:
        fn(); passed += 1; print("  ok   " + name)
    except Exception as e:
        failed += 1; print("  FAIL " + name + "\n       " + str(e).replace("\n", "\n       "))

SRC = '''// banner comment
{
  "$schema": "https://example.invalid/s.json",  // trailing comment
  /* block
     comment */
  "[opencode]": {
    "agents": {
      "sisyphus": { "model": "a/opus-5", "variant": "max" },
      "oracle":   { "model": "a/opus-5" }
    },
    "categories": {
      "deep": { "model": "a/opus-5" }
    }
  },
  "_migrations": ["2026-07-opencode-config-unification"]
}
'''

def apply(text, payload, manages, scope=("[opencode]",)):
    p = tmp(text)
    args = ["apply", p, "--payload", json.dumps(payload), "--manages", json.dumps(manages)]
    for s in scope: args += ["--scope", s]
    out = run(args); os.unlink(p); return out

def readback(text, scope=("[opencode]",)):
    p = tmp(text)
    args = ["read", p]
    for s in scope: args += ["--scope", s]
    out = json.loads(run(args)); os.unlink(p); return out

print("\n--- reading ---")
t("reads through the scope key", lambda: (
    lambda d: (_ for _ in ()).throw(AssertionError(d)) if sorted(d["agents"]) != ["oracle","sisyphus"] else None
)(readback(SRC)))
t("missing scope reads as empty", lambda: (
    (_ for _ in ()).throw(AssertionError("expected {}")) if readback(SRC, ("[codex]",)) != {} else None))

print("\n--- editing preserves everything it does not own ---")
def check_comments(out):
    for frag in ["// banner comment", "// trailing comment", "/* block", "comment */", "_migrations"]:
        assert frag in out, "lost %r" % frag
t("comments and unrelated keys survive an edit", lambda: check_comments(
    apply(SRC, {"agents": {"sisyphus": {"model": "a/sonnet-5"}}}, ["agents"])))
t("the edited value actually changes", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(out))
      if readback(out)["agents"]["sisyphus"] != {"model": "a/sonnet-5"} else None
)(apply(SRC, {"agents": {"sisyphus": {"model": "a/sonnet-5"}}}, ["agents"])))
t("a managed key the payload omits is deleted", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(readback(out)))
      if "categories" in readback(out) else None
)(apply(SRC, {"agents": {"oracle": {"model": "a/x-1"}}}, ["agents", "categories"])))
t("deleting leaves valid JSONC", lambda: check_comments(
    apply(SRC, {"agents": {}}, ["agents", "categories"])))
t("a new managed key is added", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(readback(out)))
      if readback(out).get("fallback_models") != [{"model": "g/flash"}] else None
)(apply(SRC, {"agents": readback(SRC)["agents"], "categories": readback(SRC)["categories"],
              "fallback_models": [{"model": "g/flash"}]}, ["agents","categories","fallback_models"])))
t("adding keeps comments", lambda: check_comments(
    apply(SRC, {"fallback_models": [{"model": "g/flash"}]}, ["fallback_models"])))

print("\n--- idempotence and no-ops ---")
def idem():
    pay = {"agents": readback(SRC)["agents"], "categories": readback(SRC)["categories"]}
    a = apply(SRC, pay, ["agents","categories"])
    b = apply(a, pay, ["agents","categories"])
    assert a == b, "second apply changed the file"
t("applying the same payload twice is stable", idem)
t("writing back what is already there does not reflow the file", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError("file reflowed:\n" + out))
      if json.dumps(readback(out), sort_keys=True) != json.dumps(readback(SRC), sort_keys=True) else None
)(apply(SRC, {"agents": readback(SRC)["agents"], "categories": readback(SRC)["categories"]}, ["agents","categories"])))

print("\n--- creating a scope that does not exist yet ---")
FRESH = '// mine\n{\n  "$schema": "x",\n  "agents": { "sisyphus": "a/opus-5" }\n}\n'
t("scope is created when absent", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(out))
      if readback(out)["agents"] != {"oracle": {"model": "a/o"}} else None
)(apply(FRESH, {"agents": {"oracle": {"model": "a/o"}}}, ["agents"])))
t("creating a scope keeps the rest of the file", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(out))
      if "// mine" not in out or '"$schema"' not in out else None
)(apply(FRESH, {"agents": {"oracle": {"model": "a/o"}}}, ["agents"])))

print("\n--- plain .json (no scope) still works ---")
PLAIN = '{\n  "model": "a/sonnet-5",\n  "mcp": { "ctx7": { "type": "local" } }\n}\n'
t("unscoped edit assigns and deletes", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(out))
      if json.loads(out) != {"model": "a/opus-5", "mcp": {"ctx7": {"type": "local"}}} else None
)(apply(PLAIN, {"model": "a/opus-5"}, ["model", "small_model"], scope=())))

print("\n--- tabs ---")
TABS = '{\n\t"[opencode]": {\n\t\t"agents": { "a": "x/y" }\n\t}\n}\n'
t("a tab-indented file stays tab-indented", lambda: (
    lambda out: (_ for _ in ()).throw(AssertionError(repr(out)))
      if "\n    " in out else None
)(apply(TABS, {"agents": {"a": "x/y"}, "categories": {"deep": {"model": "x/z"}}}, ["agents","categories"])))

print("\n" + (("FAILED %d / " % failed) if failed else "") + "%d passed" % passed)
sys.exit(1 if failed else 0)
