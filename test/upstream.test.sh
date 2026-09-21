#!/usr/bin/env bash
# What this plugin assumes about the two programs it sits between, asserted against
# the copies actually installed rather than against itself.
#
# The rest of the suite proves the plugin is internally consistent. That says nothing
# about the part that breaks without anyone touching this repository: oh-my-openagent
# renames a file, opencode moves a key, and every probe here answers "nothing" — which
# is refused rather than drawn, so the panel silently falls back to the roster the
# plugin was published with and looks exactly as it always did. These are the checks
# that go red instead.
#
# Nothing here needs the network. Where oh-my-openagent is not installed, its halves
# skip; the opencode halves still run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
REAL_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}"
export PROBE_CACHE="$ROOT/probe-cache"; mkdir -p "$PROBE_CACHE"

OMO_PKG=""
for d in "$REAL_CACHE"/opencode/packages/oh-my-open*@*/node_modules/oh-my-open*; do
  [ -f "$d/package.json" ] && OMO_PKG="$d" && break
done
skip_omo(){ [ -z "$OMO_PKG" ] && { printf '  skip %s (oh-my-openagent is not installed)\n' "$1"; return 0; }; return 1; }

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }
has(){ printf '%s' "$2" | jq -e --arg k "$3" 'index($k) != null' >/dev/null 2>&1 \
       && ok "$1" || no "$1" "$3 not in $2"; }
lacks(){ printf '%s' "$2" | jq -e --arg k "$3" 'index($k) == null' >/dev/null 2>&1 \
       && ok "$1" || no "$1" "$3 unexpectedly in $2"; }

# The probe functions run in a shell of their own rather than through a verb, so a
# failure names the probe that broke instead of the command that used it.
probe(){ bash -c '
  set -uo pipefail
  eval "$(sed -n "/^mktemp_tracked()/,/^}/p;/^read_capped()/,/^}/p;/^omo_package_dir()/,/^}/p;/^omo_schema_file()/,/^}/p;/^omo_fields_json()/,/^}/p;/^omo_dts_enum()/,/^}/p;/^ohmy_forbidden_for()/,/^}/p" "$1/bin/oc-profiles")"
  SELF_DIR="$1/bin"; MAX_PACKAGE_BYTES=67108864
  CACHE_HOME="${CACHE_HOME_OVERRIDE:-${XDG_CACHE_HOME:-$HOME/.cache}}"
  # read_capped stages through mktemp_tracked, which writes into the run cache.
  CACHE="${PROBE_CACHE:?}"; OC_RUN_TAG="probe-$$"
  OHMY_FORBIDDEN_AGENT='"'"'["models","provider"]'"'"'
  OHMY_FORBIDDEN_CATEGORY='"'"'["provider"]'"'"'
  OHMY_MODEL_KEYS='"'"'["models","provider","model","fallback_models"]'"'"'
  shift; "$@"' _ "$REPO" "$@" 2>/dev/null; }

echo "=== the schema is found the way the package says to find it ==="
if skip_omo "the schema resolves"; then :; else
  S="$(probe omo_schema_file "$OMO_PKG")"
  [ -n "$S" ] && [ -f "$S" ] && ok "the schema resolves" || no "the schema resolves" "got: ${S:-nothing}"
  # The pointer, not the filename. Upstream renamed the package to oh-my-openagent
  # and left the schema inside it called oh-my-opencode.schema.json; reading the
  # exports map is what survives them finishing that.
  EXP="$(jq -r '.exports["./schema.json"] // empty' "$OMO_PKG/package.json" 2>/dev/null)"
  [ -n "$EXP" ] && is "and it is the one exports names" "${S#$OMO_PKG/}" "${EXP#./}" \
                || ok "and it is the one exports names (no exports map to check)"

  # Half of upstream's rename, applied: the file moves to the name the package is
  # called now, and the exports map moves with it. Nothing in this repo is edited.
  R="$ROOT/renamed"; mkdir -p "$R/dist"
  jq '.exports["./schema.json"]="./dist/oh-my-openagent.schema.json"' \
     "$OMO_PKG/package.json" > "$R/package.json" 2>/dev/null
  cp "$S" "$R/dist/oh-my-openagent.schema.json" 2>/dev/null
  S2="$(probe omo_schema_file "$R")"
  is "a renamed schema is still found" "$(basename "${S2:-none}")" "oh-my-openagent.schema.json"

  # And the harder half: renamed to something this file has never heard of, with the
  # exports map left behind pointing at a path that no longer exists.
  U="$ROOT/unknown"; mkdir -p "$U/dist"
  jq '.exports["./schema.json"]="./dist/gone.json"' "$OMO_PKG/package.json" > "$U/package.json" 2>/dev/null
  cp "$S" "$U/dist/whatever-they-call-it-next.schema.json" 2>/dev/null
  S3="$(probe omo_schema_file "$U")"
  is "so is one under a name nobody predicted" "$(basename "${S3:-none}")" "whatever-they-call-it-next.schema.json"
fi

echo "=== the category roster comes off structured text, not a minified bundle ==="
if skip_omo "the declarations give up the categories"; then :; else
  CATS="$(probe omo_dts_enum "$OMO_PKG/dist/config/schema/categories.d.ts" BuiltinCategoryNameSchema)"
  N="$(printf '%s' "$CATS" | jq 'length' 2>/dev/null || echo 0)"
  [ "${N:-0}" -ge 4 ] && ok "the declarations give up the categories" \
    || no "the declarations give up the categories" "got: ${CATS:-nothing}"
  has "and they are category names, not effort levels" "$CATS" "visual-engineering"
  lacks "with none of the enums beside them" "$CATS" "high"

  # Two independent readings of the same upstream fact. They agree today; the day
  # they stop, one of the two has been changed and this says which.
  BUNDLE="$(python3 - "$OMO_PKG/dist/index.js" <<'PY' 2>/dev/null
import json, re, sys
try: blob = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except OSError: print("[]"); raise SystemExit
m = re.search(r"BuiltinCategoryNameSchema\s*=\s*[A-Za-z_$][\w$]*\.enum\(\s*\[(.*?)\]\s*\)", blob, re.S)
print(json.dumps(sorted(re.findall(r'"([^"]+)"', m.group(1))) if m else []))
PY
)"
  is "the bundle regex still agrees with them" \
     "$(printf '%s' "$CATS" | jq -c 'sort')" "$(printf '%s' "${BUNDLE:-[]}" | jq -c 'sort')"
fi

echo "=== which fields an entry may carry is read, not remembered ==="
if skip_omo "the schema gives up both field sets"; then :; else
  F="$(probe omo_fields_json "$OMO_PKG")"
  A="$(printf '%s' "$F" | jq -c '.agent // []' 2>/dev/null)"
  C="$(printf '%s' "$F" | jq -c '.category // []' 2>/dev/null)"
  { [ "$(printf '%s' "$A" | jq 'length')" -gt 4 ] && [ "$(printf '%s' "$C" | jq 'length')" -gt 4 ]; } \
    && ok "the schema gives up both field sets" || no "the schema gives up both field sets" "got: ${F:-nothing}"
  has "an agent may carry a model" "$A" "model"
  has "a category may carry a model" "$C" "model"

  # The refusal this drives, on the copy installed here. It must come out as the
  # hand-kept lists did, or the derivation is not trustworthy enough to replace them.
  FA="$(probe ohmy_forbidden_for agent)"
  FC="$(probe ohmy_forbidden_for category)"
  lacks "nothing an agent declares is refused on it" "$FA" "model"
  lacks "nor on a category" "$FC" "model"
  for k in $(printf '%s' "$FA" | jq -r '.[]' 2>/dev/null); do
    lacks "refused on an agent only if undeclared: $k" "$A" "$k"
  done
  for k in $(printf '%s' "$FC" | jq -r '.[]' 2>/dev/null); do
    lacks "refused on a category only if undeclared: $k" "$C" "$k"
  done
fi

echo "=== a release that legalises a field stops it being refused ==="
if skip_omo "models is refused on an agent that has no such field"; then :; else
  # oh-my-openagent's 5.0 line makes `models` the canonical field on an agent, where
  # 4.19 has no such key. A list kept by hand is right for one of those and wrong for
  # the other, and the wrong one refuses the only spelling upstream wants. Both are
  # built here out of the same schema with that one field moved.
  FOUR="$ROOT/omo4"; FIVE="$ROOT/omo5"
  for d in "$FOUR" "$FIVE"; do mkdir -p "$d/dist"; cp "$OMO_PKG/package.json" "$d/"; done
  SRC="$(probe omo_schema_file "$OMO_PKG")"
  jq '.exports["./schema.json"]="./dist/s.json"' "$OMO_PKG/package.json" > "$FOUR/package.json"
  cp "$FOUR/package.json" "$FIVE/package.json"
  jq 'del(.properties.agents.properties[].properties.models)' "$SRC" > "$FOUR/dist/s.json" 2>/dev/null
  jq '.properties.agents.properties |= with_entries(.value.properties.models = {"type":"array"})' \
     "$SRC" > "$FIVE/dist/s.json" 2>/dev/null

  # ohmy_forbidden_for locates the package itself, so each shape is asked directly
  # and the refusal it would produce is derived here from the same one-line rule.
  D4="$(probe omo_fields_json "$FOUR" | jq -c '.agent' 2>/dev/null)"; [ -n "$D4" ] || D4='[]'
  D5="$(probe omo_fields_json "$FIVE" | jq -c '.agent' 2>/dev/null)"; [ -n "$D5" ] || D5='[]'
  lacks "the 4.x shape has no models on an agent" "$D4" "models"
  has   "the 5.x shape does" "$D5" "models"
  R4="$(jq -cn --argjson m '["models","provider","model","fallback_models"]' --argjson d "$D4" \
        '[ $m[] | select(. as $k | $d | index($k) | not) ]')"
  R5="$(jq -cn --argjson m '["models","provider","model","fallback_models"]' --argjson d "$D5" \
        '[ $m[] | select(. as $k | $d | index($k) | not) ]')"
  has   "so 4.x refuses models on an agent" "$R4" "models"
  lacks "and 5.x does not, with nothing here edited" "$R5" "models"
  has   "while provider stays refused on both" "$R5" "provider"
fi

echo "=== a package it cannot read falls back rather than opening the gate ==="
BLIND="$ROOT/blind"; mkdir -p "$BLIND/dist"
printf '{"name":"oh-my-openagent","version":"9.9.9"}' > "$BLIND/package.json"
is "no schema, no field set" "$(probe omo_fields_json "$BLIND" || echo NONE)" "NONE"
# The static lists are the floor. Losing the schema must not turn the refusal off —
# that would let through the one write this gate exists to stop.
FB="$(CACHE_HOME_OVERRIDE="$BLIND/nowhere" probe ohmy_forbidden_for agent)"
has "and the shipped refusal still applies" "$FB" "models"
has "including provider" "$FB" "provider"

echo "=== the panel is told when a probe has gone blind ==="
if skip_omo "a healthy install reports no blindness"; then :; else
  D="$ROOT/health"; mkdir -p "$D/cfg" "$D/omo" "$D/state" \
    "$D/cache/opencode/packages/oh-my-openagent@latest/node_modules"
  cp -r "$OMO_PKG" "$D/cache/opencode/packages/oh-my-openagent@latest/node_modules/" 2>/dev/null
  printf '{"$schema":"x","model":"anthropic/claude-opus-5"}' > "$D/cfg/opencode.json"
  DOC(){ OPENCODE_CONFIG_DIR="$D/cfg" OMO_CONFIG_HOME="$D/omo" XDG_CACHE_HOME="$D/cache" \
         XDG_STATE_HOME="$D/state" OC_AUTO_RELOAD=0 "$OC" doctor 2>/dev/null \
         | jq -r '[.issues[].code] | index("W_PROBE_BLIND") != null' 2>/dev/null; }
  is "a healthy install reports no blindness" "$(DOC)" "false"

  # Upstream moved the schema and the declarations at once, which is what a rewrite
  # of the build looks like from here. The bundle is left in place: this is about the
  # plugin noticing, not about which probe happened to survive.
  P="$D/cache/opencode/packages/oh-my-openagent@latest/node_modules/oh-my-openagent"
  find "$P" -name '*.schema.json' -delete 2>/dev/null
  rm -rf "$P/dist/config/schema" 2>/dev/null
  is "a blinded one says so" "$(DOC)" "true"
fi

echo "=== opencode still answers the two questions asked of it ==="
if command -v opencode >/dev/null 2>&1; then
  OCA="$(timeout 20 opencode generate 2>/dev/null | head -c 67108864 \
        | jq -c '[.components.schemas.Config.properties.agent.properties | keys[]]' 2>/dev/null)"
  N="$(printf '%s' "${OCA:-[]}" | jq 'length' 2>/dev/null || echo 0)"
  [ "${N:-0}" -ge 3 ] && ok "generate still names the agents where they were" \
    || no "generate still names the agents where they were" "got: ${OCA:-nothing}"
  has "including build" "${OCA:-[]}" "build"
  # One `provider/model` per line, which is the whole contract behind the picker.
  M="$(timeout 30 opencode models 2>/dev/null | head -c 1048576 | grep -cE '^[A-Za-z0-9~._-]+/' || echo 0)"
  [ "${M:-0}" -ge 1 ] && ok "models still prints provider/model per line" \
    || no "models still prints provider/model per line" "matched $M lines"
else
  printf '  skip opencode probes (opencode is not installed)\n'
fi

echo "=== the built-in fallback is what the probe would have said ==="
# It is only read when a probe failed. One that draws a different panel than the
# probe would have is a second failure hidden behind the first, and the only way to
# see it is to compare the two while both still work.
if command -v node >/dev/null 2>&1; then
  CMP="$(cd "$REPO" && node -e '
    const fs=require("fs"), cp=require("child_process");
    const src=fs.readFileSync("lib/Model.js","utf8").replace(/^\.pragma library\s*$/m,"");
    const M={}; new Function("exports",src+"\n;Object.assign(exports,{roster});")(M);
    let det; try{ det=JSON.parse(cp.execSync("./bin/oc-profiles detect",{encoding:"utf8",maxBuffer:1e8})); }
    catch(e){ console.log("SKIP"); process.exit(0); }
    const f=M.roster(), r=det.roster||{}, eq=(a,b)=>JSON.stringify(a)===JSON.stringify(b);
    const out=[];
    const cmp=(n,a,b)=>{ if(!Array.isArray(b)||!b.length) return; out.push(n+"="+(eq(a,b)?"MATCH":"DIFFERS")); };
    cmp("opencode", f.opencode.agents, (r.opencode||{}).agents);
    cmp("ohmyAgents", f.ohmy.agents, (r.ohmy||{}).agents);
    cmp("ohmyCategories", f.ohmy.categories, (r.ohmy||{}).categories);
    console.log(out.join(" ")||"SKIP");
  ' 2>/dev/null)"
  if [ -z "$CMP" ] || [ "$CMP" = SKIP ]; then
    printf '  skip built-in fallback comparison (detect did not answer)\n'
  else
    for part in $CMP; do
      case "$part" in
        *=MATCH)   ok "the built-in ${part%%=*} roster matches the probe" ;;
        *=DIFFERS) no "the built-in ${part%%=*} roster matches the probe" \
                      "lib/Model.js is stale against the installed software" ;;
      esac
    done
  fi
else
  printf '  skip built-in fallback comparison (no node)\n'
fi

echo
if [ "$fail" -gt 0 ]; then echo "FAILED $fail / $((pass+fail)) passed"; exit 1; fi
echo "$pass passed"
