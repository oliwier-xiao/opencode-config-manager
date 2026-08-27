#!/usr/bin/env bash
#
# sync-models.sh — joins `opencode models` (what you can reach right now) with
# models.dev/api.json (name, context, price, reasoning efforts), marking each `reachable`.
# Prints fresh | unchanged | cached | local | stale | offline; exit 0 = cache on disk is usable.

set -uo pipefail

PLUGIN_ID="oliwier.opencode-configs"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/$PLUGIN_ID"
TTL="${TTL:-86400}"                        # seconds; the panel passes catalogRefreshHours * 3600
RAW="$CACHE/models.dev.json"
ETAG="$CACHE/models.dev.etag"
REACH="$CACHE/reachable.txt"
OUT="$CACHE/models.json"
OC_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/opencode/models.json"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p -m 700 "$CACHE" || { echo offline; exit 1; }

# Ceilings, all of them at the end the bytes come out of rather than after they have
# been materialised somewhere. models.dev/api.json is a few MB; this is room to grow.
MAX_FETCH_BYTES="${MAX_FETCH_BYTES:-16777216}"
MAX_REACH_BYTES="${MAX_REACH_BYTES:-1048576}"

# Exclusive and unpredictable, in the directory it will be renamed within, so the
# rename is atomic and nothing can be waiting at the name. `$RAW.new` was neither.
# Every staged file carries this run's own prefix, so cleanup is a glob rather than
# an array. An array would not survive: stage() is called inside $( ), and a
# subshell's appends are lost to the parent — which is how a trap ends up cleaning
# nothing at all while looking like it works.
RUN_TAG="$$-$(date +%s 2>/dev/null || echo 0)"
STAGE_PREFIX="$CACHE/.stage.$RUN_TAG."
cleanup() { rm -f "$STAGE_PREFIX"* 2>/dev/null; return 0; }
trap cleanup EXIT INT TERM HUP
stage() { mktemp "${STAGE_PREFIX}XXXXXXXX" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { echo offline; exit 1; }

fresh_enough() {
  [ -s "$OUT" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$OUT" 2>/dev/null || echo 0) )) -lt "$TTL" ]
}
if [ "${FORCE:-0}" != 1 ] && fresh_enough; then echo cached; exit 0; fi

# ---------------------------------------------------------------- metadata

status=offline

# opencode keeps a byte-identical mirror of models.dev; using it when newer costs no request.
if [ -s "$OC_CACHE" ] && { [ ! -s "$RAW" ] || [ "$OC_CACHE" -nt "$RAW" ]; }; then
  # opencode's cache is a file at a predictable path like any other: read through
  # the descriptor, bounded, rather than copied by name.
  if t="$(stage)" && "$SELF_DIR/safe-read" "$OC_CACHE" --max-bytes "$MAX_FETCH_BYTES" \
       --no-empty --label "opencode's model cache" > "$t" 2>/dev/null; then
    mv -f "$t" "$RAW" && status=local
  fi
fi

if command -v curl >/dev/null 2>&1; then
  # One fixed https URL, and no -L, so there are no redirects to follow and no hop
  # to validate. --proto says so out loud. No --compressed: a bounded download that
  # expands without bound on the way in is not bounded. --max-filesize stops the
  # transfer, and the descriptor check below is the bound that does not depend on a
  # declared length being present or honest.
  fetched="$(stage)" || fetched=""
  if [ -n "$fetched" ]; then
    code=$(curl -fsS --proto '=https' --max-time 20 --max-filesize "$MAX_FETCH_BYTES" \
            --retry 2 --retry-delay 1 \
            --etag-compare "$ETAG" --etag-save "$ETAG" \
            -o "$fetched" -w '%{http_code}' https://models.dev/api.json 2>/dev/null) || code=000
    case "$code" in
      200) if checked="$(stage)" \
              && "$SELF_DIR/safe-read" "$fetched" --max-bytes "$MAX_FETCH_BYTES" \
                   --no-empty --label "the model catalogue" > "$checked" 2>/dev/null; then
             mv -f "$checked" "$RAW" && status=fresh
           fi ;;
      304) [ "$status" = local ] || status=unchanged ;;
      *)   [ -s "$RAW" ] && [ "$status" != local ] && status=stale ;;
    esac
  fi
fi

[ -s "$RAW" ] || { echo offline; exit 1; }

# ---------------------------------------------------------------- reachable

# Three seconds, so it runs on the catalog's refresh schedule, never on the panel-open path.
# Failing here is not fatal: models then show as unreachable-unknown rather than none at all.
OPENCODE_BIN="${OPENCODE_BIN:-}"
if [ -z "$OPENCODE_BIN" ]; then
  for c in "$HOME/.opencode/bin/opencode" "$(command -v opencode 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && { OPENCODE_BIN="$c"; break; }
  done
fi

if [ -n "$OPENCODE_BIN" ]; then
  # head -c first: a subprocess can print more than anyone expected, and the cheap
  # place to stop that is the pipe it comes out of, not the file it lands in.
  if reach="$(stage)" \
     && timeout 30 "$OPENCODE_BIN" models 2>/dev/null | head -c "$MAX_REACH_BYTES" \
        | sed -E 's/[[:space:]]+$//' \
        | grep -E '^[A-Za-z0-9~._-]+/' > "$reach" 2>/dev/null && [ -s "$reach" ]; then
    mv -f "$reach" "$REACH"
  fi
fi
[ -s "$REACH" ] || : > "$REACH"

# ---------------------------------------------------------------- join

# Everything a picker row draws, precomputed once rather than per keystroke — including
# a lowercased haystack the filter scans without allocating a string per model per character.
# Both inputs are this plugin's own files, but they sit at predictable paths in a
# directory anything running as this user can write, so they are read the same way
# everything else is rather than handed to jq by name.
raw_in="$(stage)" || { echo offline; exit 1; }
"$SELF_DIR/safe-read" "$RAW" --max-bytes "$MAX_FETCH_BYTES" --no-empty \
  --label "the model catalogue" > "$raw_in" 2>/dev/null || { echo offline; exit 1; }
reach_in="$(stage)" || { echo offline; exit 1; }
"$SELF_DIR/safe-read" "$REACH" --max-bytes "$MAX_REACH_BYTES" \
  --label "the reachable-model list" > "$reach_in" 2>/dev/null || : > "$reach_in"

staged="$(stage)" || { echo offline; exit 1; }
jq -c --rawfile reach "$reach_in" '
  ($reach | split("\n") | map(select(length > 0))) as $reachable
  | ($reachable | map({key:., value:true}) | from_entries) as $reach_set
  | { generated: (now | floor),
      source: "models.dev + opencode models",
      reachableCount: ($reachable | length),
      providers: [ to_entries[]
        | .key as $p | .value.name as $pn
        | { id: $p, name: ($pn // $p),
            env: (.value.env // []),
            reachable: ( (.value.models // {}) | keys
                         | map(select($reach_set[($p + "/" + .)])) | length ) }
        | select(.reachable > 0) ],
      models: [ to_entries[]
        | .key as $p | .value.name as $pn
        | (.value.models // {}) | to_entries[]
        | .value as $m
        | ($p + "/" + .key) as $full
        | select($m.tool_call == true)
        | select(($m.modalities.output // []) | index("text"))
        | select(($m.status // "active") != "deprecated")
        | { id: $full,
            provider: $p,
            providerName: ($pn // $p),
            modelId: .key,
            name: ($m.name // .key),
            context: ($m.limit.context // 0),
            maxOutput: ($m.limit.output // 0),
            inputCost: ($m.cost.input // null),
            outputCost: ($m.cost.output // null),
            cacheRead: ($m.cost.cache_read // null),
            reasoning: ($m.reasoning // false),
            attachment: ($m.attachment // false),
            openWeights: ($m.open_weights // false),
            released: ($m.release_date // null),
            variants: [ ($m.reasoning_options // [])[] | select(.type == "effort") | .values[] ],
            vision: ((($m.modalities.input // []) | index("image")) != null),
            free: (($m.cost.input // 1) == 0 and ($m.cost.output // 1) == 0),
            reachable: ($reach_set[$full] // false),
            search: (($p + " " + ($pn // "") + " " + .key + " " + ($m.name // "")) | ascii_downcase) } ]
    }
  # A model opencode can reach but models.dev has never heard of is still selectable; keep it.
  | . as $cat
  | .models += [ $reachable[]
      | select(. as $id | ($cat.models | map(.id) | index($id)) | not)
      | (split("/")) as $parts
      | { id: ., provider: $parts[0], providerName: $parts[0],
          modelId: ($parts[1:] | join("/")),
          name: ($parts[-1]), context: 0, maxOutput: 0,
          inputCost: null, outputCost: null, cacheRead: null,
          reasoning: false, attachment: false, openWeights: false, released: null,
          variants: [], vision: false, free: false, reachable: true,
          search: (. | ascii_downcase) } ]
  | .totalCount = (.models | length)
' "$raw_in" > "$staged" 2>/dev/null

# Producer-side ceiling. The panel refuses an oversized catalog too, but the
# cheaper place to stop it is before it is ever written.
MAX_OUT_BYTES="${MAX_OUT_BYTES:-12582912}"
if [ -s "$staged" ] && [ "$(stat -c %s "$staged" 2>/dev/null || echo 0)" -gt "$MAX_OUT_BYTES" ]; then
  [ -s "$OUT" ] || { echo offline; exit 1; }
  echo stale; exit 0
fi

if [ -s "$staged" ] && jq -e '.models | length > 0' "$staged" >/dev/null 2>&1; then
  mv -f "$staged" "$OUT"
else
  [ -s "$OUT" ] || { echo offline; exit 1; }
  status=stale
fi

echo "$status"
