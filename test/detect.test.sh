#!/usr/bin/env bash
# Detection matrix. Nothing here touches the real config: every scenario gets its
# own OPENCODE_CONFIG_DIR, OMO_CONFIG_HOME, XDG_CACHE_HOME and XDG_STATE_HOME.
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
# Whatever version happens to be installed. Pinning a literal here made the suite fail
# on somebody else's machine every time oh-my-openagent shipped a release.
OMO_VER=""
[ -n "$OMO_PKG" ] && OMO_VER="$(jq -r '.version // empty' "$OMO_PKG/package.json" 2>/dev/null)"
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }
# The oh-my-openagent halves read a roster off the real installed package, so anything
# counted out of it is a moving target. Assert the floor, not the number of the day.
atleast(){ [ "$2" -ge "$3" ] 2>/dev/null && ok "$1" || no "$1" "got: $2   want: >= $3"; }

mk(){ # mk <name> <omo-installed?> ; creates dirs, echoes the scenario root
  local n="$1" installed="$2"
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

echo "=== A. plain opencode: no plugin, no package, no omo config ==="
D=$(mk plain no)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5",
 "agent":{"build":{"model":"anthropic/claude-sonnet-5"},"my-reviewer":{"mode":"subagent"}},
 "mcp":{"ctx7":{"type":"local"}}}
J
A=$(run "$D" detect)
is "shape is opencode"            "$(jq -r .shape <<<"$A")"                 "opencode"
is "ohMy.active false"            "$(jq -r .ohMy.active <<<"$A")"           "false"
is "ohMy.stale false"             "$(jq -r .ohMy.stale <<<"$A")"           "false"
is "opencode roster detected"     "$(jq -r '.roster.opencode.agents|length>0' <<<"$A")" "true"
is "no omo roster"                "$(jq -r '.roster.ohmy.agents|length' <<<"$A")"       "0"
is "roster has no scout"          "$(jq -r '[.roster.opencode.agents[]|select(.=="scout")]|length' <<<"$A")" "0"

echo "=== B. oh-my-openagent: declared + installed + omo.jsonc ==="
D=$(mk omo yes)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"],"model":"anthropic/claude-opus-5"}
J
cp "$REPO/test/fixtures/omo.jsonc" "$D/omo/omo.jsonc"
B=$(run "$D" detect)
is "shape is oh-my-openagent"     "$(jq -r .shape <<<"$B")"                 "oh-my-openagent"
is "declared"                     "$(jq -r .ohMy.declaredInOpencodeJson <<<"$B")" "true"
is "installed"                    "$(jq -r .ohMy.installed <<<"$B")"        "true"
is "version detected"             "$(jq -r .ohMyVersion <<<"$B")"           "$OMO_VER"
is "reads through [opencode]"     "$(jq -r '.files.ohmy.agents|length' <<<"$B")" "9"
is "categories read"              "$(jq -r '.files.ohmy.categories|length' <<<"$B")" "8"
is "scope reported"               "$(jq -r '.files.ohmy.scope' <<<"$B")"    "[opencode]"
is "path is omo.jsonc"            "$(basename "$(jq -r '.files.ohmy.path' <<<"$B")")" "omo.jsonc"
atleast "omo roster detected"     "$(jq -r '.roster.ohmy.agents|length' <<<"$B")" 11
is "roster names sisyphus"        "$(jq -r '[.roster.ohmy.agents[]|select(.=="sisyphus")]|length' <<<"$B")" "1"
atleast "omo categories detected" "$(jq -r '.roster.ohmy.categories|length' <<<"$B")" 8
is "no E_JSONC warning"           "$(jq -r '[.warnings[]|select(.code=="E_JSONC")]|length' <<<"$B")" "0"

echo "=== C. omo declared but not configured yet ==="
D=$(mk fresh yes)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json","plugin":["oh-my-openagent@latest"]}
J
C=$(run "$D" detect)
is "shape is oh-my-openagent"     "$(jq -r .shape <<<"$C")"                 "oh-my-openagent"
is "configured false"             "$(jq -r .ohMy.configured <<<"$C")"       "false"
is "not stale"                    "$(jq -r .ohMy.stale <<<"$C")"            "false"

echo "=== D. leftover config, plugin removed, package gone ==="
D=$(mk stale no)
cat > "$D/cfg/opencode.json" <<'J'
{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5"}
J
printf '{"agents":{"librarian":"anthropic/claude-haiku-4-5"}}' > "$D/cfg/oh-my-openagent.json"
E=$(run "$D" detect)
is "shape falls back to opencode" "$(jq -r .shape <<<"$E")"                 "opencode"
is "reported as stale"            "$(jq -r .ohMy.stale <<<"$E")"            "true"
is "warning raised"               "$(jq -r '[.warnings[]|select(.code=="W_OHMY_STALE")]|length' <<<"$E")" "1"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $pass passed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
