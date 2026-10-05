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


print("\n--- every splice reads back as exactly what was asked ---")

def apply_raw(text, payload, manages, scope=()):
    p = tmp(text)
    args = ["apply", p, "--manages", json.dumps(manages)]
    for sc in scope: args += ["--scope", sc]
    r = subprocess.run([JE] + args, input=json.dumps(payload), capture_output=True, text=True, timeout=30)
    os.unlink(p)
    return r

def strip_ref(text):
    """An independent JSONC reader: comments out (string-aware), trailing commas out."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; out.append(c); i += 1; continue
        if text.startswith("//", i):
            j = text.find("\n", i); i = n if j < 0 else j; continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2); i = n if j < 0 else j + 2; continue
        out.append(c); i += 1
    s2, res, in_str, i = "".join(out), [], False, 0
    while i < len(s2):
        c = s2[i]
        if in_str:
            res.append(c)
            if c == "\\":
                res.append(s2[i + 1]); i += 2; continue
            if c == '"':
                in_str = False
            i += 1; continue
        if c == '"':
            in_str = True; res.append(c); i += 1; continue
        if c == ",":
            j = i + 1
            while j < len(s2) and s2[j] in " \t\r\n":
                j += 1
            if j < len(s2) and s2[j] in "}]":
                i += 1; continue
        res.append(c); i += 1
    return json.loads("".join(res))

def comment_after_last_member():
    # 1.5.2 put the new member's comma after the comment, inside it, and its own
    # reader — which took commas as optional — called the result fine.
    r = apply_raw('{\n  "model": "a/b" // daily driver\n}\n', {"model": "a/b", "small_model": "a/c"},
                  ["model", "small_model"])
    assert r.returncode == 0, r.stderr
    got = strip_ref(r.stdout)
    assert got == {"model": "a/b", "small_model": "a/c"}, got
    assert "// daily driver" in r.stdout, "the comment was lost"
t("a comment after the last member keeps the new comma out of it", comment_after_last_member)

def adjacent_deletes():
    # Two deletions next to each other, the last one without a comma of its own: the
    # ranges overlapped and the closing brace went with them.
    text = '{\n  "provider": {"x": 1},\n  "model": "a/b",\n  "small_model": "s/m",\n  "agent": {"build": {"model": "a/b"}}\n}\n'
    r = apply_raw(text, {"model": "z/z"}, ["model", "small_model", "agent"])
    assert r.returncode == 0, r.stderr
    assert strip_ref(r.stdout) == {"provider": {"x": 1}, "model": "z/z"}, r.stdout
t("adjacent deletions leave the object whole", adjacent_deletes)

def one_line_object():
    r = apply_raw('{ "model": "a/b" }', {"agent": {"b": {"model": "x/y"}}}, ["model", "agent"])
    assert r.returncode == 0, r.stderr
    assert strip_ref(r.stdout) == {"agent": {"b": {"model": "x/y"}}}, r.stdout
t("a one-line object can lose its only member and gain another", one_line_object)

def line_separator_in_a_value():
    r = apply_raw('{\n  "agent": {}\n}\n', {"agent": {"build": {"model": "a/b", "prompt": "x y z\u0085w"}}},
                  ["agent"])
    assert r.returncode == 0, r.stderr
    assert strip_ref(r.stdout)["agent"]["build"]["prompt"] == "x y z\u0085w", r.stdout
t("U+2028, U+2029 and U+0085 in a value stay inside the string", line_separator_in_a_value)

def missing_comma_refused():
    p = tmp('{\n  "a": 1\n  "b": 2\n}\n')
    try:
        r = subprocess.run([JE, "read", p], capture_output=True, text=True, timeout=30)
        assert r.returncode == 1, "a file with a missing comma was read: %r" % r.stdout
    finally:
        os.unlink(p)
t("a missing comma is a file that does not read", missing_comma_refused)

def trailing_comma_kept():
    r = apply_raw('{\n  "a": 1,\n  "model": "q/q",\n}\n', {"model": "w/w", "small_model": "s/s"},
                  ["model", "small_model"])
    assert r.returncode == 0, r.stderr
    assert strip_ref(r.stdout) == {"a": 1, "model": "w/w", "small_model": "s/s"}, r.stdout
    assert r.stdout.rstrip().endswith(",\n}") or '"s/s",' in r.stdout, "the trailing-comma style was dropped"
t("a trailing comma, which JSONC allows, is kept as the file's style", trailing_comma_kept)

def bom_kept():
    p = tmp("﻿" + '{"model":"a/b"}')
    try:
        r = subprocess.run([JE, "apply", p, "--manages", '["model"]'], input=b'{"model":"c/d"}',
                           capture_output=True, timeout=30)
        assert r.returncode == 0, r.stderr
        assert r.stdout.startswith("﻿".encode()), "the byte-order mark was dropped"
        assert json.loads(r.stdout.decode()[1:]) == {"model": "c/d"}
    finally:
        os.unlink(p)
t("a byte-order mark is read past and written back", bom_kept)

def nan_refused():
    p = tmp('{"model": NaN}')
    try:
        r = subprocess.run([JE, "read", p], capture_output=True, text=True, timeout=30)
        assert r.returncode == 1, "NaN read as JSON"
    finally:
        os.unlink(p)
t("NaN is not JSON", nan_refused)

def fuzz():
    # Seeded, so a failure names the case that made it. Every result is read back by
    # the independent reader above and has to be exactly what was asked for.
    import random, importlib.machinery, importlib.util
    # Loading the helper as a module would otherwise leave a bytecode cache in bin/,
    # inside the plugin folder that nothing is meant to write to.
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("jsonc_edit_fuzz", JE)
    spec = importlib.util.spec_from_file_location("jsonc_edit_fuzz", JE, loader=loader)
    je = importlib.util.module_from_spec(spec); loader.exec_module(je)
    keys = ["agents", "categories", "fallback_models", "model", "small_model", "agent"]
    def val(r, d=0):
        k = r.random()
        if d > 2 or k < 0.4: return r.choice(["a/b", "x/y-z", 1, True, None, "naïve –  "])
        if k < 0.7: return {r.choice(["m", "n", "o"]): val(r, d + 1) for _ in range(r.randint(0, 3))}
        return [val(r, d + 1) for _ in range(r.randint(0, 3))]
    def doc(r, scoped):
        def member(k, v, indent):
            com = r.choice(["", " // note", " /* c */"])
            return '%s%s: %s%s' % (indent, json.dumps(k), json.dumps(v), com)
        inner_keys = r.sample(keys + ["provider", "mcp"], r.randint(0, 6))
        inner = {k: val(r) for k in inner_keys}
        trail = r.random() < 0.3
        def obj(d, indent):
            if not d: return "{}"
            parts = [member(k, v, indent + "  ") for k, v in d.items()]
            body = ""
            for i, part in enumerate(parts):
                last = i == len(parts) - 1
                if "//" in part:
                    code, com = part.split(" //", 1)
                    body += code + ("," if (not last or trail) else "") + " //" + com + "\n"
                else:
                    body += part + ("," if (not last or trail) else "") + "\n"
            return "{\n" + body + indent + "}"
        if scoped:
            outer = {"$schema": "s", "[opencode]": inner} if r.random() < 0.8 else {"$schema": "s"}
            text = "// banner\n{\n  \"$schema\": \"s\",\n  \"[opencode]\": " + obj(inner, "  ") + "\n}\n" \
                if "[opencode]" in outer else '{\n  "$schema": "s"\n}\n'
            return text
        return "// banner\n" + obj(inner, "") + "\n"
    bad = []
    for seed in range(1500):
        r = random.Random(seed)
        scoped = r.random() < 0.5
        text = doc(r, scoped)
        before = strip_ref(text)
        scope = ["[opencode]"] if scoped else []
        managed = r.sample(keys, r.randint(1, 5))
        payload = {k: val(r) for k in managed if r.random() < 0.5}
        updates = {k: (payload[k] if k in payload else je.DELETE) for k in managed}
        d0, _ = je.parse(text)
        out = je.apply_all(text, scope, updates, je.detect_indent(text))
        want = je.expected_document(d0, scope, updates)
        got_own, _ = je.parse(out)
        if got_own != want or strip_ref(out) != want or strip_ref(text) != before:
            bad.append(seed)
    assert not bad, "seeds %s" % bad[:10]
t("1500 seeded splices read back exactly, by an independent reader too", fuzz)

print("\n" + (("FAILED %d / " % failed) if failed else "") + "%d passed" % passed)
sys.exit(1 if failed else 0)
