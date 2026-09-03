#!/usr/bin/env bash
# The marketplace reviewer's bar, held as tests. Each case is a way one of these
# commands was, or could be, made to write somewhere it should not, read something
# unbounded, or report success for work it did not do.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

mk(){ local d="$ROOT/$1"; rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state"
  printf '{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5"}' > "$d/cfg/opencode.json"
  printf '%s' "$d"; }
run(){ local d="$1"; shift
  OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
  XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" OC_AUTO_RELOAD=0 "$OC" "$@"; }
# A non-default config dir gets its own store, keyed by a hash of that path —
# the same shape bin/oc-profiles computes.
state_of(){ local h; h="$(printf '%s' "$1/cfg" | sha256sum | cut -c1-12)"
  printf '%s' "$1/state/omarchy/opencode-configs/by-config/$h"; }
store_of(){ printf '%s' "$(state_of "$1")/profiles.json"; }

echo "=== the profile store is never written through a planted symlink ==="
D=$(mk sym); run "$D" capture "A" a >/dev/null 2>&1
S="$(store_of "$D")"; printf 'PRECIOUS' > "$D/victim.txt"
rm -f "$S"; ln -s "$D/victim.txt" "$S"
run "$D" capture "B" b >/dev/null 2>&1
is "victim file untouched"      "$(cat "$D/victim.txt")" "PRECIOUS"
[ -L "$S" ] && ok "the link was not replaced by a real store" || no "the link was not replaced" "it was"

echo "=== a store that is not a plain file is refused, not parsed ==="
D=$(mk shapes); run "$D" capture "A" a >/dev/null 2>&1
S="$(store_of "$D")"; rm -f "$S"; mkfifo "$S"
OUT=$(timeout 10 env OPENCODE_CONFIG_DIR="$D/cfg" OMO_CONFIG_HOME="$D/omo" \
  XDG_CACHE_HOME="$D/cache" XDG_STATE_HOME="$D/state" "$OC" list 2>/dev/null); rc=$?
is "a FIFO store is refused"    "$(printf '%s' "$OUT" | jq -r '.code // "none"' 2>/dev/null || echo parse-error)" "E_STORE"
[ "$rc" != 124 ] && ok "and did not stall" || no "and did not stall" "hit the timeout"

echo "=== the lock fails closed ==="
D=$(mk lock); run "$D" capture "A" a >/dev/null 2>&1
ST="$(state_of "$D")"; chmod 0300 "$ST"
OUT=$(run "$D" capture "B" b 2>/dev/null); rc=$?
chmod 0700 "$ST"
is "an unopenable state dir refuses" "$(printf '%s' "$OUT" | jq -r '.code // "none"' 2>/dev/null || echo none)" "E_STORE"
is "and exits 2, not 0"              "$rc" "2"

echo "=== the store is written compact ==="
D=$(mk compact); run "$D" capture "A" a >/dev/null 2>&1
is "one line, not pretty-printed" "$(wc -l < "$(store_of "$D")")" "1"

echo "=== undo refuses a backup it cannot restore from ==="
D=$(mk undo); run "$D" capture "A" a >/dev/null 2>&1
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
run "$D" apply b >/dev/null 2>&1
TS=$(jq -r '.state.lastBackup' "$(store_of "$D")")
BD="$(state_of "$D")/backups/$TS"
: > "$BD/meta.json"
OUT=$(run "$D" revert 2>/dev/null)
is "an empty manifest refuses"  "$(printf '%s' "$OUT" | jq -r '.code // "ok"')" "E_NO_BACKUP"
is "and the active profile did not move" "$(jq -r '.state.activeProfileId' "$(store_of "$D")")" "b"

D=$(mk undo2); run "$D" capture "A" a >/dev/null 2>&1
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
run "$D" apply b >/dev/null 2>&1
TS=$(jq -r '.state.lastBackup' "$(store_of "$D")")
rm -f "$(state_of "$D")/backups/$TS/opencode.json"
OUT=$(run "$D" revert 2>/dev/null)
is "a missing copy refuses"     "$(printf '%s' "$OUT" | jq -r '.code // "ok"')" "E_NO_BACKUP"
is "config left as the profile set it" "$(jq -r .model "$D/cfg/opencode.json")" "anthropic/claude-opus-5"

echo "=== seed always answers in JSON ==="
D=$(mk seed)
OUT=$(OC_MANAGE_OHMY=0 OC_MANAGE_OPENCODE=0 run "$D" seed 2>/dev/null)
is "still JSON when nothing can be captured" "$(printf '%s' "$OUT" | jq -r '.ok // "none"' 2>/dev/null || echo none)" "true"

echo "=== a killed switch is all of itself or none of it ==="
D=$(mk killed)
cp "$REPO/test/fixtures/omo.jsonc" "$D/omo/omo.jsonc"
printf '{"$schema":"x","plugin":["oh-my-openagent@latest"],"model":"anthropic/claude-sonnet-5"}' > "$D/cfg/opencode.json"
# The stalling copy stays inside a bin/ that has the helpers, or every command
# would refuse for the wrong reason and the test would pass without testing.
SLOWSW="$ROOT/slowsw"; mkdir -p "$SLOWSW"
cp "$REPO/bin/safe-read" "$REPO/bin/safe-write" "$REPO/bin/jsonc-edit" "$SLOWSW/"
python3 - "$OC" "$SLOWSW/oc-profiles" <<'PYEOF'
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
out = []
for line in s.split("\n"):
    out.append(line)
    if 'wrote+=("$logical"); OC_ROLLBACK_WROTE+=("$logical")' in line:
        out.append("    sleep 4")
pathlib.Path(sys.argv[2]).write_text("\n".join(out))
PYEOF
chmod +x "$SLOWSW"/*
SLOW="$SLOWSW/oc-profiles"
grep -q "sleep 4" "$SLOW" && ok "the stalling copy was built" || no "the stalling copy was built" "unpatched"
OC_PROFILE_JSON='{"id":"two","name":"Two","targets":[
 {"file":"ohmy","shape":"oh-my-openagent","manages":["agents"],"payload":{"agents":{"sisyphus":"anthropic/claude-opus-5"}}},
 {"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
BEFORE_OMO=$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.agents|length')
BEFORE_OC=$(jq -r .model "$D/cfg/opencode.json")
OPENCODE_CONFIG_DIR="$D/cfg" OMO_CONFIG_HOME="$D/omo" XDG_CACHE_HOME="$D/cache" \
  XDG_STATE_HOME="$D/state" OC_AUTO_RELOAD=0 OC_TIMEBOXED=1 timeout -k 2 2 "$SLOW" apply two >/dev/null 2>&1
AFTER_OMO=$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.agents|length')
AFTER_OC=$(jq -r .model "$D/cfg/opencode.json")
if [ "$AFTER_OMO" = "$BEFORE_OMO" ] && [ "$AFTER_OC" = "$BEFORE_OC" ]; then
  ok "both halves put back after the kill"
else
  no "both halves put back after the kill" "omo $BEFORE_OMO->$AFTER_OMO, opencode $BEFORE_OC->$AFTER_OC"
fi

echo "=== a killed detect leaves no config in a temp file ==="
D=$(mk temps)
printf '{"$schema":"x","provider":{"anthropic":{"options":{"apiKey":"sk-SECRET-CANARY"}}}}' > "$D/cfg/opencode.json"
run "$D" detect >/dev/null 2>&1
# The config itself holds the canary by construction, and so does this file.
LEAK=$(grep -rl "sk-SECRET-CANARY" "$D/cache" "${TMPDIR:-/tmp}" 2>/dev/null \
  | grep -v "/cfg/" | grep -vF "$REPO" | head -3)
[ -z "$LEAK" ] && ok "no temp file holds the provider key" || no "no temp file holds the provider key" "$LEAK"

echo "=== a killed run leaves no staged file behind ==="
D=$(mk killtemp)
printf '{"$schema":"x","provider":{"anthropic":{"options":{"apiKey":"sk-CANARY-XYZ"}}}}' > "$D/cfg/opencode.json"
# A copy that stalls after the temporaries exist, kept inside bin/ so the helpers
# next to it are still found.
SLOWBIN="$ROOT/slowbin"; mkdir -p "$SLOWBIN"
cp "$REPO/bin/safe-read" "$REPO/bin/safe-write" "$REPO/bin/jsonc-edit" "$SLOWBIN/"
python3 - "$OC" "$SLOWBIN/oc-profiles" <<'PYEOF'
import sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
out = []
for line in s.split("\n"):
    out.append(line)
    if 'home_src="$(read_capped "$HOME_CFG"' in line:
        out.append("  sleep 6")
pathlib.Path(sys.argv[2]).write_text("\n".join(out))
PYEOF
chmod +x "$SLOWBIN"/*
OPENCODE_CONFIG_DIR="$D/cfg" OMO_CONFIG_HOME="$D/omo" XDG_CACHE_HOME="$D/cache"   XDG_STATE_HOME="$D/state" OC_AUTO_RELOAD=0 OC_TIMEBOXED=1   timeout -k 2 2 "$SLOWBIN/oc-profiles" detect >/dev/null 2>&1
[ -s "$SLOWBIN/oc-profiles" ] && grep -q "sleep 6" "$SLOWBIN/oc-profiles" \
  && ok "the stalling copy was built" || no "the stalling copy was built" "empty or unpatched"
is "nothing staged survives"    "$(find "$D/cache" -name '.stage.*' 2>/dev/null | wc -l)" "0"
LEFT=$(grep -rl "sk-CANARY-XYZ" "$D/cache" "${TMPDIR:-/tmp}" 2>/dev/null   | grep -v "/cfg/" | grep -vF "$REPO" | grep -vF "$ROOT" | wc -l)
is "and no provider key with it" "$LEFT" "0"

echo "=== a missing helper says so plainly ==="
BARE="$ROOT/bare"; mkdir -p "$BARE"; cp "$OC" "$BARE/oc-profiles"; chmod +x "$BARE/oc-profiles"
ERR=$("$BARE/oc-profiles" detect 2>&1 >/dev/null); rc=$?
case "$ERR" in *"is missing or not executable"*) ok "names the missing helper" ;;
  *) no "names the missing helper" "said: $ERR" ;; esac
is "and exits 1, not a refusal" "$rc" "1"

# There is no QML runtime here, so what the panel *states* is held at the source
# level. Each of these was a way the panel asserted something about the config it
# had not finished reading, or kept describing a shape it had already been told
# was wrong.
echo "=== the panel does not assert what it has not read ==="
qml_has(){ grep -qF "$2" "$REPO/$1" && ok "$3" || no "$3" "$1 no longer has: $2"; }
qml_lacks(){ grep -qF "$2" "$REPO/$1" && no "$3" "$1 still has: $2" || ok "$3"; }

qml_has  "Panel.qml" "Model.resolveActiveId(store)" \
         "Panel takes the active profile from resolveActiveId"
qml_lacks "Panel.qml" "store.state && store.state.activeProfileId" \
         "Panel no longer reads the stored id as the only answer"
qml_has  "Panel.qml" "root.loaded && root.detected !== null" \
         "Panel is only ready once both reads have answered"
qml_has  "Panel.qml" "ready: root.ready" \
         "and hands that down to the list"

# An effort is stepped down through the catalogue before it is written. Doing that
# for oh-my-openagent rows only left an opencode agent carrying the old model's
# effort onto a model with none — a config that loads and then fails on the first
# request. The writer half is covered in model.test.js; this is the call site.
qml_has  "ProfileEditor.qml" "var wanted = root.rows[index].variant" \
         "every row steps its effort down against the new model"
qml_lacks "ProfileEditor.qml" 'root.rows[index].file === "ohmy" ? root.rows[index].variant' \
         "and not just the oh-my-openagent ones"
qml_has  "ProfileEditor.qml" "Catalog.nearestVariant(root.catalogIndex, modelId, wanted)" \
         "through the catalogue, not by hand"
# Model.js is a .pragma library: setShape writes a global no binding depends on,
# and `list` beats `detect` every time, so without this the first paint keeps the
# wrong shape until something unrelated invalidates it.
qml_has  "Panel.qml" "root.store = Model.clone(root.store)" \
         "a shape that moved forces the rows to be drawn again"
qml_has  "ProfileList.qml" 'if (!root.ready) return "READING WHAT IS ON DISK"' \
         "the heading waits before claiming nothing matches"
qml_has  "ProfileList.qml" "(root.drift && root.ready)" \
         "the drift strip waits for the same reason"

echo "=== list answers which profile is running, not just which was chosen ==="
D=$(mk eff)
run "$D" capture "Mine" mine >/dev/null
is "effectiveProfileId is emitted" \
   "$(run "$D" list | jq -r 'has("effectiveProfileId")')" "true"

echo "=== the two places that carry a version agree ==="
MV=$(jq -r .version "$REPO/manifest.json")
SV=$(grep -m1 '^VERSION=' "$REPO/bin/oc-profiles" | cut -d'"' -f2)
is "manifest.json matches bin/oc-profiles" "$SV" "$MV"

echo "=== every shipped helper is executable ==="
for f in "$REPO"/bin/*; do
  [ -x "$f" ] || no "$(basename "$f") is executable" "it is not"
done
ok "bin/ is executable"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $pass passed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
