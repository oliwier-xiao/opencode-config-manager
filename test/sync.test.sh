#!/usr/bin/env bash
# sync-models.sh, against a cache directory of its own and stand-ins for the two
# things it shells out to. Nothing here reaches the network, and nothing here
# needs opencode to be installed: `curl` and `opencode` are both shims on PATH,
# which is also the only way to assert how many times each was actually called.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0; fail=0
is() {
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"; fail=$((fail+1)); fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT INT TERM
export XDG_CACHE_HOME="$T/cache"
C="$XDG_CACHE_HOME/omarchy/oliwier.opencode-configs"
mkdir -p "$C" "$T/bin"

# A catalogue small enough to read, carrying one model that can call tools and one
# models.dev says cannot. `curl` records every call and answers 200 with that body.
cat > "$T/api.json" <<'JSON'
{"zen":{"name":"Zen","models":{
  "good":{"tool_call":true,"modalities":{"output":["text"]},"name":"Good"},
  "notools":{"tool_call":false,"modalities":{"output":["text"]},"name":"No Tools"}}}}
JSON
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo call >> "$T/curl.calls"
# \$T/curl.mode picks the answer: a body and 200, a bare 304, or a 200 whose body
# is not JSON at all — the captive-portal page a hotel network hands back.
mode="\$(cat "$T/curl.mode" 2>/dev/null || echo 200)"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
case "\$mode" in
  304) printf '304' ;;
  portal) [ -n "\$out" ] && printf '<!doctype html><html>Sign in to WiFi</html>' > "\$out"; printf '200' ;;
  *)   [ -n "\$out" ] && cp "$T/api.json" "\$out"; printf '200' ;;
esac
EOF
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo call >> "$T/oc.calls"
[ -f "$T/oc.broken" ] && { echo "boom" >&2; exit 1; }
printf 'zen/good\nzen/notools\nzen/uncatalogued\n'
EOF
chmod +x "$T/bin/curl" "$T/bin/opencode"
export PATH="$T/bin:$PATH"
# The script prefers ~/.opencode/bin/opencode over PATH; point it at the shim
# explicitly so the run does not depend on what this machine happens to have.
export OPENCODE_BIN="$T/bin/opencode"
# opencode's own models.dev mirror is a second source the script prefers when it
# is newer. It lives under XDG_CACHE_HOME, which is this temp dir, so it is
# already absent — these assertions are about curl and nothing else.

calls() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
run() { TTL="${TTL:-86400}" REACH_TTL="${REACH_TTL:-900}" "$REPO/bin/sync-models.sh" 2>/dev/null; }
age() { touch -d "$2" "$1" 2>/dev/null; }
# The catalogue has two clocks: when it was last confirmed, and when it was last
# asked for. Real time moves both, so a test that moves one is testing a state that
# cannot happen.
age_cat() { age "$C/models.dev.stamp" "$1"; age "$C/models.dev.attempt" "$1"; }

echo "=== a cold cache is built from both sources ==="
S1="$(run)"
is "first run reports a download"   "$S1" "fresh"
is "curl was called once"           "$(calls "$T/curl.calls")" "1"
is "opencode was called once"       "$(calls "$T/oc.calls")" "1"
is "the tool-calling model is in"   "$(jq -r '[.models[].id]|index("zen/good")!=null' "$C/models.json")" "true"
is "the reachable unknown is in"    "$(jq -r '[.models[].id]|index("zen/uncatalogued")!=null' "$C/models.json")" "true"

echo "=== a model models.dev says cannot call tools does not come back as reachable ==="
# The fallback branch keeps ids models.dev has never heard of. One it HAS heard of
# and ruled out is a different thing: re-adding it hands the user a model that
# loads and then fails on the first tool call.
is "the filtered model stays out"   "$(jq -r '[.models[].id]|index("zen/notools")==null' "$C/models.json")" "true"

echo "=== nothing is due, so nothing runs ==="
is "second run is a no-op"          "$(run)" "cached"
is "curl was not called again"      "$(calls "$T/curl.calls")" "1"
is "opencode was not called again"  "$(calls "$T/oc.calls")" "1"

echo "=== a reach-only run refreshes reachability without downloading ==="
age "$C/reachable.stamp" "20 minutes ago"
is "it says so, not 'fresh'"        "$(run)" "reach"
is "curl was still not called"      "$(calls "$T/curl.calls")" "1"
is "opencode was called again"      "$(calls "$T/oc.calls")" "2"

echo "=== reach-only runs do not postpone the catalogue for ever ==="
# The regression this file exists for: the catalogue TTL was measured against
# models.json, which every reach-only run rewrites. The long clock could never
# run out, so models.dev was downloaded exactly once and never again.
for _ in 1 2 3; do age "$C/reachable.stamp" "20 minutes ago"; run >/dev/null; done
is "still no download while young"  "$(calls "$T/curl.calls")" "1"
age_cat "25 hours ago"
age "$C/reachable.stamp" "20 minutes ago"
run >/dev/null
is "an aged catalogue is fetched"   "$(calls "$T/curl.calls")" "2"

echo "=== a failing opencode is rate-limited like a working one ==="
touch "$T/oc.broken"
age "$C/reachable.stamp" "20 minutes ago"
before="$(calls "$T/oc.calls")"
run >/dev/null
is "the failed attempt was made"    "$(calls "$T/oc.calls")" "$((before+1))"
is "the old list was kept"          "$(jq -r '[.models[].id]|index("zen/uncatalogued")!=null' "$C/models.json")" "true"
# Without a stamp of its own the failure leaves no trace, so every panel open
# pays for the whole probe again. This is the assertion that says it does not.
after_fail="$(calls "$T/oc.calls")"
run >/dev/null
is "the retry is not immediate"     "$(calls "$T/oc.calls")" "$after_fail"

echo "=== a non-zero exit does not throw away a list opencode did print ==="
# opencode exits non-zero when one configured provider has no credentials. Under
# `pipefail` that verdict used to discard a complete list of all the others.
rm -f "$T/oc.broken"
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo call >> "$T/oc.calls"
printf 'zen/good\nzen/late-arrival\n'
exit 1
EOF
chmod +x "$T/bin/opencode"
age "$C/reachable.stamp" "20 minutes ago"
run >/dev/null
is "the printed list was kept"      "$(jq -r '[.models[].id]|index("zen/late-arrival")!=null' "$C/models.json")" "true"

echo "=== a 304 confirms the catalogue without rewriting it ==="
# models.dev answers 304 once the catalogue has settled, and a 304 does not touch
# the file. Reading the clock off the file would leave the download permanently
# due: every panel open would spend a request and an `opencode models` probe.
echo 304 > "$T/curl.mode"
age_cat "25 hours ago"; age "$C/reachable.stamp" "20 minutes ago"
before="$(calls "$T/curl.calls")"
is "the check happens"              "$(run)" "unchanged"
is "and it cost one request"        "$(calls "$T/curl.calls")" "$((before+1))"
before="$(calls "$T/curl.calls")"; ocbefore="$(calls "$T/oc.calls")"
is "the next run is a no-op"        "$(run)" "cached"
is "no second request"              "$(calls "$T/curl.calls")" "$before"
is "and no second probe"            "$(calls "$T/oc.calls")" "$ocbefore"

echo "=== a 200 that is not a catalogue is re-fetched, not sat on ==="
# safe-read checks size and file type, never that the bytes are JSON. A captive
# portal answers 200 with a login page; holding that for a whole TTL would freeze
# the picker for a day on a network the user has already left.
echo portal > "$T/curl.mode"
age_cat "25 hours ago"; age "$C/reachable.stamp" "20 minutes ago"
is "the bad body is rejected"       "$(run)" "stale"
echo 200 > "$T/curl.mode"
before="$(calls "$T/curl.calls")"
age "$C/reachable.stamp" "20 minutes ago"
is "the next run fetches again"     "$(run)" "fresh"
is "it really did request"          "$(calls "$T/curl.calls")" "$((before+1))"
is "and the catalogue is back"      "$(jq -r '[.models[].id]|index("zen/good")!=null' "$C/models.json")" "true"

echo "=== a probe killed mid-line is discarded, not installed ==="
# `timeout 30` stops a hung opencode wherever it happens to be, and half an id
# matches the id pattern as well as a whole one. It would reach the picker as a
# model and the config as a model that does not exist.
cp "$C/reachable.txt" "$T/reach.before"
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo call >> "$T/oc.calls"
printf 'zen/good\nzen/trunc'
EOF
chmod +x "$T/bin/opencode"
age "$C/reachable.stamp" "20 minutes ago"
run >/dev/null
is "the whole list was kept"        "$(cmp -s "$T/reach.before" "$C/reachable.txt" && echo same)" "same"
is "no half-written id got in"      "$(jq -r '[.models[].id]|index("zen/trunc")==null' "$C/models.json")" "true"

echo "=== a machine that cannot reach models.dev backs off instead of retrying ==="
# curl here answers 000 the way it does with no route to the host. Without a record
# of the attempt, every panel open would spend the full --max-time/--retry budget
# rediscovering that, because a failed download leaves the catalogue still due.
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo call >> "$T/curl.calls"
printf '000'
exit 7
EOF
chmod +x "$T/bin/curl"
rm -f "$C/models.dev.stamp" "$C/models.dev.attempt"
before="$(calls "$T/curl.calls")"
age "$C/reachable.stamp" "20 minutes ago"; run >/dev/null
is "it tries once"                  "$(calls "$T/curl.calls")" "$((before+1))"
age "$C/reachable.stamp" "20 minutes ago"; run >/dev/null
age "$C/reachable.stamp" "20 minutes ago"; run >/dev/null
is "and not again straight away"    "$(calls "$T/curl.calls")" "$((before+1))"
age "$C/models.dev.attempt" "20 minutes ago"
age "$C/reachable.stamp" "20 minutes ago"; run >/dev/null
is "but it does try again later"    "$(calls "$T/curl.calls")" "$((before+2))"

echo "=== with no catalogue at all, the reachable list alone still fills the picker ==="
# The aeroplane: opencode works, models.dev does not. Before, the script stopped
# before it ever ran the probe, and the picker had nothing in it.
cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
echo call >> "$T/oc.calls"
printf 'zen/good\nzen/offline-only\n'
EOF
chmod +x "$T/bin/opencode"
rm -f "$C/models.dev.json" "$C/models.json" "$C/models.dev.stamp" "$C/models.dev.attempt" "$C/reachable.stamp"
out="$(run)"
is "the run still produces a list"   "$([ -s "$C/models.json" ] && echo yes)" "yes"
is "and it does not claim offline"   "$out" "reach"
is "every reachable model is there"  "$(jq -r '[.models[].id]|index("zen/offline-only")!=null' "$C/models.json")" "true"
is "flagged unreachable-unknown"     "$(jq -r '[.models[]|select(.id=="zen/offline-only")][0].context' "$C/models.json")" "0"

echo "=== FORCE goes past every gate ==="
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo call >> "$T/curl.calls"
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && cp "$T/api.json" "\$out"
printf '200'
EOF
chmod +x "$T/bin/curl"
before="$(calls "$T/curl.calls")"
FORCE=1 run >/dev/null
is "forced run downloads anyway"    "$(calls "$T/curl.calls")" "$((before+1))"

printf '\n%d passed' "$pass"
[ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"
printf '\n'
[ "$fail" -eq 0 ]
