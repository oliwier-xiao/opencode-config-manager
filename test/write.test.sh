#!/usr/bin/env bash
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
REAL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
# The oh-my-openagent halves need the real package to read a roster off. Without it
# the plain-opencode halves still run — which is the path most people are on.
OMO_PKG=""
for d in "$REAL_CACHE"/opencode/packages/oh-my-open*@*/node_modules/oh-my-open*; do
  [ -f "$d/package.json" ] && OMO_PKG="$d" && break
done
skip_omo(){ [ -z "$OMO_PKG" ] && { printf '  skip %s (oh-my-openagent is not installed)\n' "$1"; return 0; }; return 1; }
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }
has(){ grep -qF "$2" "$3" && ok "$1" || no "$1" "missing: $2"; }

mk(){ local n="$1" installed="$2"
  local d="$ROOT/$n"
  rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state"
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

echo "=== omo: editing omo.jsonc keeps everything it does not own ==="
D=$(mk omo yes)
printf '{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}' > "$D/cfg/opencode.json"
cp "$REPO/test/fixtures/omo.jsonc" "$D/omo/omo.jsonc"
cp "$D/omo/omo.jsonc" "$D/before.jsonc"

run "$D" capture "Mine" mine >/dev/null
is "capture reads 9 agents" \
   "$(run "$D" list | jq -r '[.profiles[]|select(.id=="mine")][0].targets[]|select(.file=="ohmy").payload.agents|length')" "9"

PAY=$(run "$D" detect | jq -c '{agents: ((.files.ohmy.agents|map({key:.,value:{model:"anthropic/claude-opus-5"}})|from_entries)), categories: {}}')
OC_PROFILE_JSON="$(jq -cn --argjson p "$PAY" '{id:"allopus",name:"All Opus",targets:[{file:"ohmy",shape:"oh-my-openagent",manages:["agents","categories","fallback_models"],payload:$p}]}')" \
  run "$D" save >/dev/null
R=$(run "$D" apply allopus)
is "apply ok"                "$(jq -r .ok <<<"$R")" "true"
is "wrote the omo half"      "$(jq -r '[.applied[]?]|join(",")' <<<"$R")" "ohmy"
has "banner comment survived" "// OMO configuration" "$D/omo/omo.jsonc"
has "schema key survived"     '"$schema"'            "$D/omo/omo.jsonc"
has "_migrations survived"    "2026-07-opencode-config-unification" "$D/omo/omo.jsonc"
is "models actually changed" \
   "$(run "$D" detect | jq -r '.files.ohmy.agents|length')" "9"
is "every agent now opus" \
   "$("$OC" >/dev/null 2>&1; "$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '[.agents[]|select(.model=="anthropic/claude-opus-5")]|length')" "9"
is "categories cleared as the payload said" \
   "$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.categories|length')" "0"

echo "--- undo ---"
run "$D" revert >/dev/null
if diff -q "$D/before.jsonc" "$D/omo/omo.jsonc" >/dev/null; then ok "revert is byte-for-byte"; else no "revert is byte-for-byte" "$(diff "$D/before.jsonc" "$D/omo/omo.jsonc" | head -5)"; fi

echo "=== plain opencode: the omo half is skipped, never created ==="
D=$(mk plain no)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5",
 "agent":{"build":{"model":"anthropic/claude-sonnet-5"}},"mcp":{"ctx7":{"type":"local"}}}
J
OC_PROFILE_JSON='{"id":"tpl","name":"Tpl","targets":[
  {"file":"ohmy","shape":"oh-my-openagent","manages":["agents"],"payload":{"agents":{"sisyphus":"a/b"}}},
  {"file":"opencode","shape":"opencode","manages":["model","agent"],"payload":{"model":"anthropic/claude-opus-5","agent":{"plan":{"model":"anthropic/claude-opus-5"}}}}]}' \
  run "$D" save >/dev/null
R=$(run "$D" apply tpl)
is "apply still succeeds"        "$(jq -r .ok <<<"$R")" "true"
is "opencode half applied"       "$(jq -r '[.applied[]?]|join(",")' <<<"$R")" "opencode"
is "omo half skipped"            "$(jq -r '[.skipped[]?]|join(",")' <<<"$R")" "ohmy"
[ -f "$D/cfg/oh-my-openagent.json" ] && no "no omo file invented" "it was created" || ok "no omo file invented"
[ -f "$D/omo/omo.jsonc" ] && no "no omo.jsonc invented" "it was created" || ok "no omo.jsonc invented"
is "model written"               "$(jq -r .model "$D/cfg/opencode.json")" "anthropic/claude-opus-5"
is "mcp untouched"               "$(jq -c .mcp "$D/cfg/opencode.json")" '{"ctx7":{"type":"local"}}'
is "agent entry is an object"    "$(jq -r '.agent.plan|type' "$D/cfg/opencode.json")" "object"

echo "=== plain opencode: a bare-string agent is refused ==="
OC_PROFILE_JSON='{"id":"bad","name":"Bad","targets":[{"file":"opencode","shape":"opencode","manages":["agent"],"payload":{"agent":{"plan":"anthropic/claude-opus-5"}}}]}' \
  run "$D" save >/dev/null
B=$(run "$D" apply bad)
is "refused with E_AGENT_SHAPE"  "$(jq -r .code <<<"$B")" "E_AGENT_SHAPE"
is "file left alone"             "$(jq -r '.agent.plan|type' "$D/cfg/opencode.json")" "object"

echo "=== plain opencode: a providers-only config still captures ==="
D=$(mk barecfg no)
printf '{"$schema":"https://opencode.ai/config.json","mcp":{"ctx7":{"type":"local"}}}' > "$D/cfg/opencode.json"
C=$(run "$D" capture "Bare" bare)
is "capture succeeds"            "$(jq -r .ok <<<"$C")" "true"

echo "=== omo 4.19 fields: reasoning is a real field, models is not ==="
D=$(mk fields yes)
printf '{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}' > "$D/cfg/opencode.json"
cp "$REPO/test/fixtures/omo.jsonc" "$D/omo/omo.jsonc"

OC_PROFILE_JSON='{"id":"eff","name":"Eff","targets":[{"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories"],"payload":{"agents":{"oracle":{"model":"anthropic/claude-opus-5","reasoning":"high"}},"categories":{}}}]}' \
  run "$D" save >/dev/null
E=$(run "$D" apply eff)
is "reasoning is accepted"       "$(jq -r .ok <<<"$E")" "true"
is "and it reaches the file"     "$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.agents.oracle.reasoning')" "high"

# The shape oh-my-openagent's own 4.19 migration writes, and the one its schema then
# has no field for: every agent it touches loses its pin at startup.
OC_PROFILE_JSON='{"id":"mods","name":"Mods","targets":[{"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories"],"payload":{"agents":{"oracle":{"models":[{"model":"anthropic/claude-opus-5"}]}},"categories":{}}}]}' \
  run "$D" save >/dev/null
M=$(run "$D" apply mods)
is "models is refused"           "$(jq -r .code <<<"$M")" "E_FIELD_4X"
is "the file was left alone"     "$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.agents.oracle.reasoning')" "high"

echo "=== the [opencode] block never gets a file-level fallback_models ==="
OC_PROFILE_JSON='{"id":"fb","name":"Fb","targets":[{"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories","fallback_models"],"payload":{"agents":{},"categories":{},"fallback_models":[{"model":"google/gemini-3-flash-preview"}]}}]}' \
  run "$D" save >/dev/null
F=$(run "$D" apply fb)
is "apply still succeeds"        "$(jq -r .ok <<<"$F")" "true"
is "but the key is not written"  "$("$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r '.fallback_models // "absent"')" "absent"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $pass passed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
