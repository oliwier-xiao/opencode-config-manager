#!/usr/bin/env bash
# opencode's TUI remembers the effort last cycled to for each model and sends it with
# every prompt, which beats the effort a config gives an agent. A profile that names
# an effort has to win, so applying one forgets the remembered efforts of the models
# it names, and only those, and undoing it puts them back.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
REAL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
OMO_PKG=""
for d in "$REAL_CACHE"/opencode/packages/oh-my-open*@*/node_modules/oh-my-open*; do
  [ -f "$d/package.json" ] && OMO_PKG="$d" && break
done
skip_omo(){ [ -z "$OMO_PKG" ] && { printf '  skip %s (oh-my-openagent is not installed)\n' "$1"; return 0; }; return 1; }
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

mk(){ local n="$1" installed="$2"
  local d="$ROOT/$n"
  rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state/opencode"
  if [ "$installed" = yes ]; then
    mkdir -p "$d/cache/opencode/packages/oh-my-openagent@latest/node_modules"
    [ -n "$OMO_PKG" ] && cp -r "$OMO_PKG" \
          "$d/cache/opencode/packages/oh-my-openagent@latest/node_modules/" 2>/dev/null
  fi
  printf '%s' "$d"
}
run(){ local d="$1"; shift
  OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
  XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" OC_AUTO_RELOAD=0 "$OC" "$@"; }
eff(){ jq -r --arg k "$2" '.variant[$k] // "unset"' "$1/state/opencode/model.json"; }

OPUS=anthropic/claude-opus-5-5
SONNET=anthropic/claude-sonnet-5-5
HAIKU=anthropic/claude-haiku-4-5
GPRO=google/gemini-3.1-pro-preview

seed_state(){
  printf '{"recent":[{"providerID":"anthropic","modelID":"claude-opus-5-5"}],"favorite":[],"variant":{"%s":"max","%s":"high","%s":"default","%s":"high"}}' \
    "$OPUS" "$SONNET" "$HAIKU" "$GPRO" > "$1/state/opencode/model.json"
}
opencode_profile(){
  printf '{"id":"eff","name":"Eff","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model"],"payload":{"model":"%s","small_model":"%s"}}]}' "$OPUS" "$HAIKU"
}
fresh(){
  local d; d=$(mk "$1" no)
  printf '{"$schema":"https://opencode.ai/config.json"}' > "$d/cfg/opencode.json"
  OC_PROFILE_JSON="$(opencode_profile)" run "$d" save >/dev/null
  printf '%s' "$d"
}

echo "=== applying a profile forgets the remembered effort of the models it names ==="
D=$(fresh basic); seed_state "$D"
A=$(run "$D" apply eff)
is "the apply succeeded"                 "$(jq -r .ok <<<"$A")" "true"
is "and says how many it forgot"         "$(jq -r .effortsReset <<<"$A")" "2"
is "the remembered max is gone"          "$(eff "$D" "$OPUS")" "unset"
is "so is the remembered default"        "$(eff "$D" "$HAIKU")" "unset"
is "a model the profile does not name keeps its effort" "$(eff "$D" "$SONNET")" "high"
is "another provider's model keeps it too"              "$(eff "$D" "$GPRO")" "high"
is "recent models are left alone"        "$(jq -r '.recent|length' "$D/state/opencode/model.json")" "1"
is "the file stays compact, as opencode writes it" \
   "$(grep -c '' "$D/state/opencode/model.json")" "1"
LAST=$(run "$D" list | jq -r '.state.lastBackup')
META=$(find "$D/state/omarchy" -path "*/backups/$LAST/meta.json" | head -1)
is "the backup records what was forgotten" \
   "$(jq -r --arg k "$OPUS" '.clearedEfforts[$k]' "$META")" "max"

echo "=== undoing it puts them back, without overriding a choice made since ==="
jq -c --arg k "$OPUS" '.variant[$k]="xhigh"' "$D/state/opencode/model.json" > "$D/m.json" && cp "$D/m.json" "$D/state/opencode/model.json"
R=$(run "$D" revert)
is "the revert succeeded"                "$(jq -r .ok <<<"$R")" "true"
is "a choice made since is kept"         "$(eff "$D" "$OPUS")" "xhigh"
is "an untouched one comes back"         "$(eff "$D" "$HAIKU")" "default"
is "and the rest are as they were"       "$(eff "$D" "$SONNET")" "high"

echo "=== it can be switched off ==="
D=$(fresh off); seed_state "$D"
A=$(OC_CLEAR_EFFORT_MEMORY=0 run "$D" apply eff)
is "the apply succeeded"                 "$(jq -r .ok <<<"$A")" "true"
is "nothing was forgotten"               "$(jq -r .effortsReset <<<"$A")" "0"
is "and the remembered effort is still there" "$(eff "$D" "$OPUS")" "max"

echo "=== a missing or unreadable state file never fails a switch ==="
D=$(fresh missing); rm -f "$D/state/opencode/model.json"
A=$(run "$D" apply eff)
is "no file: the apply succeeded"        "$(jq -r .ok <<<"$A")" "true"
is "no file: none is invented"           "$([ -e "$D/state/opencode/model.json" ] && echo yes || echo no)" "no"
D=$(fresh broken); printf 'not json {' > "$D/state/opencode/model.json"
A=$(run "$D" apply eff)
is "not JSON: the apply succeeded"       "$(jq -r .ok <<<"$A")" "true"
is "not JSON: the file is left as it was" "$(cat "$D/state/opencode/model.json")" "not json {"
D=$(fresh novariant); printf '{"recent":[],"favorite":[]}' > "$D/state/opencode/model.json"
A=$(run "$D" apply eff)
is "no variant map: the apply succeeded" "$(jq -r .ok <<<"$A")" "true"
is "no variant map: nothing is added"    "$(jq -c 'has("variant")' "$D/state/opencode/model.json")" "false"

echo "=== fallbacks count as named ==="
if skip_omo "the oh-my-openagent half"; then :; else
D=$(mk omo yes)
printf '{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}' > "$D/cfg/opencode.json"
cp "$REPO/test/fixtures/omo.jsonc" "$D/omo/omo.jsonc"
seed_state "$D"
OC_PROFILE_JSON='{"id":"chain","name":"Chain","targets":[{"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories"],"payload":{"agents":{"oracle":{"model":"'"$OPUS"'","reasoning":"max","fallback_models":[{"model":"'"$GPRO"'","reasoning":"high"},"'"$SONNET"'"]}},"categories":{}}}]}' \
  run "$D" save >/dev/null
A=$(run "$D" apply chain)
is "the apply succeeded"                 "$(jq -r .ok <<<"$A")" "true"
is "the agent's model is forgotten"      "$(eff "$D" "$OPUS")" "unset"
is "an object fallback is forgotten"     "$(eff "$D" "$GPRO")" "unset"
is "a bare-string fallback is forgotten" "$(eff "$D" "$SONNET")" "unset"
is "one nobody named is not"             "$(eff "$D" "$HAIKU")" "default"
fi

printf '\n%d passed' "$pass"; [ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"; printf '\n'
[ "$fail" -eq 0 ]
