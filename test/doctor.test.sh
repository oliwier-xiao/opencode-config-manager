#!/usr/bin/env bash
# doctor and repair: what they find, what they refuse, and what a fix leaves behind.
# Every case runs against a temporary config directory of its own.
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
codes(){ jq -r '[.issues[].code]|sort|join(",")'; }

echo "=== a healthy config finds nothing ==="
D=$(mk clean no)
printf '{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5","agent":{"build":{"model":"anthropic/claude-sonnet-5"}}}' > "$D/cfg/opencode.json"
R=$(run "$D" doctor)
is "doctor ok"            "$(jq -r .ok <<<"$R")" "true"
is "no issues"            "$(jq -r '.issues|length' <<<"$R")" "0"
is "one JSON line"        "$(run "$D" doctor | wc -l)" "1"

echo "=== a bare agent string is found, and repaired ==="
D=$(mk bare no)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json",
 "model":"anthropic/claude-sonnet-5",
 "agent":{"build":"opencode/muse-spark-1.3-contributor-free","plan":{"model":"anthropic/claude-opus-5"}},
 "mcp":{"ctx7":{"type":"local"}}}
J
R=$(run "$D" doctor)
is "finds the bare string" "$(codes <<<"$R")" "E_BARE_AGENT_STRING"
is "names the agent"       "$(jq -r '.issues[0].agent' <<<"$R")" "build"
is "says it is fixable"    "$(jq -r '.issues[0].fixable' <<<"$R")" "true"

BEFORE=$(sha256sum "$D/cfg/opencode.json" | cut -d' ' -f1)
R=$(run "$D" repair --fix E_BARE_AGENT_STRING)
is "dry run is a dry run"  "$(jq -r .dryRun <<<"$R")" "true"
is "dry run reports one"   "$(jq -r '.diff|length' <<<"$R")" "1"
is "dry run wrote nothing" "$(sha256sum "$D/cfg/opencode.json" | cut -d' ' -f1)" "$BEFORE"

R=$(run "$D" repair --fix E_BARE_AGENT_STRING --apply)
is "apply reports one fix" "$(jq -r .fixed <<<"$R")" "1"
is "build is an object now" \
   "$(jq -r '.agent.build.model' "$D/cfg/opencode.json")" "opencode/muse-spark-1.3-contributor-free"
is "plan was left alone"   "$(jq -r '.agent.plan.model' "$D/cfg/opencode.json")" "anthropic/claude-opus-5"
is "mcp survived"          "$(jq -r '.mcp.ctx7.type' "$D/cfg/opencode.json")" "local"
is "doctor is clean after" "$(run "$D" doctor | jq -r '.issues|length')" "0"
is "a second apply is a no-op" \
   "$(run "$D" repair --fix E_BARE_AGENT_STRING --apply | jq -r .fixed)" "0"

echo "=== a stored profile carrying models: agents are wrong, categories are not ==="
D=$(mk store no)
printf '{"$schema":"https://opencode.ai/config.json"}' > "$D/cfg/opencode.json"
OC_PROFILE_JSON='{"id":"muse","name":"Full Muse","targets":[
  {"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories","fallback_models"],
   "payload":{"agents":{
       "sisyphus":{"models":["opencode/muse-spark-1.3-contributor-free",{"model":"google/gemini-3.1-pro-preview","reasoning":"high"}]},
       "oracle":{"model":"opencode/muse-spark-1.3-contributor-free",
                 "models":["opencode/muse-spark-1.3-contributor-free","anthropic/claude-opus-5"]},
       "explore":{"model":"opencode/muse-spark-1.3-contributor-free"}},
     "categories":{"deep":{"models":["anthropic/claude-opus-5"]}}}}]}' \
  run "$D" save >/dev/null

R=$(run "$D" doctor)
is "finds the profile once" "$(jq -r '[.issues[]|select(.code=="E_MODELS_IN_PROFILE")]|length' <<<"$R")" "1"
is "counts only the agents" "$(jq -r '[.issues[]|select(.code=="E_MODELS_IN_PROFILE")][0].count' <<<"$R")" "2"
is "names the profile id"   "$(jq -r '[.issues[]|select(.code=="E_MODELS_IN_PROFILE")][0].profile' <<<"$R")" "muse"

is "repairing needs a profile" \
   "$(run "$D" repair --fix E_MODELS_IN_PROFILE --apply | jq -r .code)" "E_NO_PROFILE"
run "$D" repair --fix E_MODELS_IN_PROFILE --profile muse --apply >/dev/null
P(){ run "$D" list | jq -r "[.profiles[]|select(.id==\"muse\")][0].targets[0].payload.$1"; }
is "models is gone"          "$(P 'agents.sisyphus.models')" "null"
is "models[0] became model"  "$(P 'agents.sisyphus.model')" "opencode/muse-spark-1.3-contributor-free"
is "the rest became fallbacks" \
   "$(P 'agents.sisyphus.fallback_models[0].model')" "google/gemini-3.1-pro-preview"
is "the fallback kept its effort" "$(P 'agents.sisyphus.fallback_models[0].reasoning')" "high"
is "an existing model is kept"    "$(P 'agents.oracle.model')" "opencode/muse-spark-1.3-contributor-free"
is "a duplicate pin is not a fallback" \
   "$(P 'agents.oracle.fallback_models|length')" "1"
is "a clean agent is untouched"   "$(P 'agents.explore.model')" "opencode/muse-spark-1.3-contributor-free"
is "a category keeps its models"  "$(P 'categories.deep.models|length')" "1"
is "manages lost the file-level key" \
   "$(run "$D" list | jq -r '[.profiles[]|select(.id=="muse")][0].targets[0].manages|join(",")')" "agents,categories"
is "doctor is clean after"   "$(run "$D" doctor | jq -r '[.issues[]|select(.code=="E_MODELS_IN_PROFILE")]|length')" "0"

echo "=== the same shape on the live config ==="
if skip_omo "live models repair"; then :; else
D=$(mk live yes)
printf '{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}' > "$D/cfg/opencode.json"
cat > "$D/omo/omo.jsonc" <<'J'
{
  // a comment that has to survive the repair
  "[opencode]": {
    "agents": {
      "sisyphus": { "models": ["opencode/muse-spark-1.3-contributor-free", "anthropic/claude-opus-5"] },
      "oracle": { "model": "anthropic/claude-opus-5", "variant": "high" }
    },
    "categories": { "deep": { "models": ["anthropic/claude-opus-5"] } }
  }
}
J
R=$(run "$D" doctor)
is "finds the live config"  "$(jq -r '[.issues[]|select(.code=="E_MODELS_IN_CONFIG")][0].count' <<<"$R")" "1"
is "variant is information" "$(jq -r '[.issues[]|select(.code=="W_VARIANT_DEPRECATED")][0].fixable' <<<"$R")" "false"
is "variant is one row"     "$(jq -r '[.issues[]|select(.code=="W_VARIANT_DEPRECATED")]|length' <<<"$R")" "1"

BEFORE=$(sha256sum "$D/omo/omo.jsonc" | cut -d' ' -f1)
run "$D" repair --fix E_MODELS_IN_CONFIG >/dev/null
is "dry run wrote nothing"  "$(sha256sum "$D/omo/omo.jsonc" | cut -d' ' -f1)" "$BEFORE"

R=$(run "$D" repair --fix E_MODELS_IN_CONFIG --apply)
is "apply reports one fix"  "$(jq -r .fixed <<<"$R")" "1"
J(){ "$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r "$1"; }
is "models is gone"         "$(J '.agents.sisyphus.models')" "null"
is "the pin survived"       "$(J '.agents.sisyphus.model')" "opencode/muse-spark-1.3-contributor-free"
is "the rest became a fallback" "$(J '.agents.sisyphus.fallback_models[0].model')" "anthropic/claude-opus-5"
is "the other agent is untouched" "$(J '.agents.oracle.variant')" "high"
is "the category kept its models" "$(J '.categories.deep.models|length')" "1"
grep -qF "a comment that has to survive" "$D/omo/omo.jsonc" \
  && ok "the comment survived" || no "the comment survived" "it did not"
is "doctor is clean after"  "$(run "$D" doctor | jq -r '[.issues[]|select(.code=="E_MODELS_IN_CONFIG")]|length')" "0"

echo "--- undo puts it back ---"
run "$D" revert >/dev/null
is "revert restores models" "$(J '.agents.sisyphus.models|length')" "2"
fi

echo "=== a file-level fallback_models under [opencode] ==="
if skip_omo "file-level fallback_models"; then :; else
D=$(mk filefb yes)
printf '{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}' > "$D/cfg/opencode.json"
cat > "$D/omo/omo.jsonc" <<'J'
{
  "[opencode]": {
    "fallback_models": ["anthropic/claude-opus-5"],
    "agents": { "oracle": { "model": "anthropic/claude-opus-5" } }
  }
}
J
is "found" "$(run "$D" doctor | jq -r '[.issues[]|select(.code=="E_FILE_FALLBACK")]|length')" "1"
run "$D" repair --fix E_FILE_FALLBACK --apply >/dev/null
K(){ "$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r "$1"; }
is "the file-level key is gone" "$(K '.fallback_models')" "null"
is "the agent is untouched"     "$(K '.agents.oracle.model')" "anthropic/claude-opus-5"
fi

echo "=== refusals ==="
D=$(mk refuse no)
printf '{"$schema":"https://opencode.ai/config.json"}' > "$D/cfg/opencode.json"
R=$(run "$D" repair --fix W_VARIANT_DEPRECATED --apply); rc=$?
is "information is not repairable" "$(jq -r .code <<<"$R")" "E_NOT_FIXABLE"
is "and refuses with 2"            "$rc" "2"
is "an unknown code is refused"    "$(run "$D" repair --fix NOPE --apply | jq -r .code)" "E_BAD_FIX"
is "an unknown option is refused"  "$(run "$D" repair --wat 2>/dev/null | jq -r .code)" "E_BAD_FIX"
is "no --fix is refused"           "$(run "$D" repair --apply | jq -r .code)" "E_BAD_FIX"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
