import json, subprocess, tempfile, os, sys
import pathlib
REPO = pathlib.Path(__file__).resolve().parent.parent
JE = str(REPO / "bin" / "jsonc-edit")
passed = failed = 0

def run(args, stdin=None):
    r = subprocess.run([JE] + args, input=stdin, capture_output=True, text=True, timeout=30)
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

# The payload goes in on stdin, the way bin/oc-profiles hands it over: never as an
# argument, because a command line is readable by every account through /proc.
def apply(text, payload, manages, scope=("[opencode]",)):
    p = tmp(text)
    args = ["apply", p, "--manages", json.dumps(manages)]
    for s in scope: args += ["--scope", s]
    out = run(args, stdin=json.dumps(payload)); os.unlink(p); return out

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

print("\n--- the payload never travels on the command line ---")
def refused(args, stdin=None, stdin_fd=None, want=""):
    kw = {"stdin": stdin_fd} if stdin_fd is not None else {"input": stdin}
    r = subprocess.run([JE] + args, capture_output=True, text=True, timeout=30, **kw)
    assert r.returncode == 1, "exit %d, wanted 1 (stderr: %s)" % (r.returncode, r.stderr.strip())
    assert r.stdout == "", "printed a file it should have refused to write: %r" % r.stdout[:200]
    assert want in r.stderr, "stderr %r does not say %r" % (r.stderr.strip(), want)

def payload_flag_refused():
    p = tmp(PLAIN)
    try:
        refused(["apply", p, "--payload", '{"model":"a/b"}', "--manages", '["model"]'],
                stdin='{"model":"a/b"}', want="Pipe the payload on stdin")
        refused(["apply", p, '--payload={"model":"a/b"}', "--manages", '["model"]'],
                stdin='{"model":"a/b"}', want="Pipe the payload on stdin")
    finally:
        os.unlink(p)
t("--payload is refused, in both spellings", payload_flag_refused)

def bad_payloads():
    p = tmp(PLAIN)
    try:
        refused(["apply", p, "--manages", '["model"]'], stdin="", want="not JSON")
        refused(["apply", p, "--manages", '["model"]'], stdin="[1, 2]", want="not a JSON object")
        refused(["apply", p, "--manages", '["model"]'], stdin="{nope", want="not JSON")
        refused(["apply", p, "--manages", '"model"'], stdin="{}", want="array of key names")
        refused(["apply", p, "--manages"], stdin="{}", want="needs a value")
    finally:
        os.unlink(p)
t("an empty, non-object or malformed payload is refused", bad_payloads)

def at_and_past_the_cap():
    cap = 4 * 1024 * 1024
    p = tmp(PLAIN)
    try:
        exact = '{"x":"' + "a" * (cap - 8) + '"}'
        assert len(exact) == cap
        out = run(["apply", p, "--manages", '["x"]'], stdin=exact)
        assert len(json.loads(out)["x"]) == cap - 8, "the payload at the cap did not land whole"
        refused(["apply", p, "--manages", '["x"]'], stdin=exact[:-1] + ' }', want="larger than")
    finally:
        os.unlink(p)
t("a payload at the cap lands; one byte past it is refused", at_and_past_the_cap)

def terminal_refused():
    import pty
    master, slave = pty.openpty()
    p = tmp(PLAIN)
    try:
        refused(["apply", p, "--manages", '["model"]'], stdin_fd=slave, want="pipe it in")
    finally:
        os.close(master); os.close(slave); os.unlink(p)
t("a terminal on stdin is refused, not waited on", terminal_refused)

def read_ignores_stdin():
    p = tmp(PLAIN)
    try:
        got = json.loads(run(["read", p], stdin='{"model":"z/z"}'))["model"]
        assert got == "a/sonnet-5", "read took %r from stdin" % got
    finally:
        os.unlink(p)
t("read takes nothing from stdin", read_ignores_stdin)

print("\n--- failing without a traceback, and without quoting the file ---")
def clean_failure(args, stdin=None, want="", env=None):
    r = subprocess.run([JE] + args, input=stdin, capture_output=True, text=True, timeout=60,
                       env=env)
    assert r.returncode == 1, "exit %d, wanted 1" % r.returncode
    assert "Traceback" not in r.stderr, "a traceback: %s" % r.stderr.strip().splitlines()[-1]
    assert want in r.stderr, "stderr %r does not say %r" % (r.stderr.strip()[:200], want)
    return r

def deep_payload():
    p = tmp(PLAIN)
    try:
        clean_failure(["apply", p, "--manages", '["model"]'],
                      stdin="[" * 200000 + "]" * 200000, want="nested too deeply")
    finally:
        os.unlink(p)
t("a payload nested past the recursion limit is refused, not a traceback", deep_payload)

def deep_config():
    p = tmp('{"a": ' + "[" * 5000 + "]" * 5000 + "}")
    try:
        clean_failure(["read", p], want="nested too deeply")
    finally:
        os.unlink(p)
t("so is a config nested that deep", deep_config)

def bad_escape():
    p = tmp('{"model": "a/b\\q"}')
    try:
        clean_failure(["read", p], want="not readable JSONC")
    finally:
        os.unlink(p)
t("a string json will not decode is refused, not a traceback", bad_escape)

def token_not_quoted():
    secret = "sk-UNQUOTED-%d" % os.getpid()
    p = tmp('{"provider": {"x": {"options": {"apiKey": %s}}}}' % secret)
    try:
        r = clean_failure(["read", p], want="cannot read the value at")
        assert secret not in r.stderr, "the error quoted the file: %s" % r.stderr.strip()
    finally:
        os.unlink(p)
t("a malformed value is located, never quoted", token_not_quoted)

def utf8_whatever_the_locale():
    text = '// zażółć gęślą jaźń\n{\n  "model": "a/b",\n  "note": "naïve – café"\n}\n'
    p = tmp(text)
    try:
        env = dict(os.environ, PYTHONIOENCODING="ascii", LC_ALL="C", LANG="C")
        r = subprocess.run([JE, "apply", p, "--manages", '["model"]', ], input=b'{"model":"c/d"}',
                           capture_output=True, timeout=30, env=env)
        assert r.returncode == 0, "exit %d: %s" % (r.returncode, r.stderr.decode(errors="replace"))
        out = r.stdout.decode("utf-8")
        assert "zażółć gęślą jaźń" in out and "naïve – café" in out, "re-encoded: %r" % out[:120]
        assert '"model": "c/d"' in out, "the edit did not land: %r" % out
    finally:
        os.unlink(p)
t("the result is UTF-8 under an ASCII locale, comments and values intact", utf8_whatever_the_locale)

def reader_gone():
    p = tmp(PLAIN)
    try:
        proc = subprocess.Popen([JE, "apply", p, "--manages", '["model"]'], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        proc.stdout.close()          # gone before a byte is written
        proc.stdin.write(b'{"model":"c/d"}'); proc.stdin.close()
        err = proc.stderr.read().decode(errors="replace"); rc = proc.wait(timeout=30)
        assert rc == 1, "exit %d, wanted 1" % rc
        assert "Traceback" not in err and "Exception ignored" not in err, "noise: %s" % err.strip()
    finally:
        os.unlink(p)
t("a reader that has gone ends it quietly, with a failure", reader_gone)

print("\n" + (("FAILED %d / " % failed) if failed else "") + "%d passed" % passed)
sys.exit(1 if failed else 0)
