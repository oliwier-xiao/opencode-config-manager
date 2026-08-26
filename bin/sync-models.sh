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

mkdir -p "$CACHE" || { echo offline; exit 1; }

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
  cp -f "$OC_CACHE" "$RAW" 2>/dev/null && status=local
fi

if command -v curl >/dev/null 2>&1; then
  code=$(curl -fsS --compressed --max-time 20 --retry 2 --retry-delay 1 \
          --etag-compare "$ETAG" --etag-save "$ETAG" \
          -o "$RAW.new" -w '%{http_code}' https://models.dev/api.json 2>/dev/null) || code=000
  case "$code" in
    200) mv -f "$RAW.new" "$RAW" && status=fresh ;;
    304) rm -f "$RAW.new"; [ "$status" = local ] || status=unchanged ;;
    *)   rm -f "$RAW.new"; [ -s "$RAW" ] && [ "$status" != local ] && status=stale ;;
  esac
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
  if timeout 30 "$OPENCODE_BIN" models 2>/dev/null | sed -E 's/[[:space:]]+$//' \
       | grep -E '^[A-Za-z0-9~._-]+/' > "$REACH.new" 2>/dev/null && [ -s "$REACH.new" ]; then
    mv -f "$REACH.new" "$REACH"
  else
    rm -f "$REACH.new"
  fi
fi
[ -s "$REACH" ] || : > "$REACH"

# ---------------------------------------------------------------- join

# Everything a picker row draws, precomputed once rather than per keystroke — including
# a lowercased haystack the filter scans without allocating a string per model per character.
jq -c --rawfile reach "$REACH" '
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
' "$RAW" > "$OUT.new" 2>/dev/null

# Producer-side ceiling. The panel refuses an oversized catalog too, but the
# cheaper place to stop it is before it is ever written.
MAX_OUT_BYTES="${MAX_OUT_BYTES:-12582912}"
if [ -s "$OUT.new" ] && [ "$(stat -c %s "$OUT.new" 2>/dev/null || echo 0)" -gt "$MAX_OUT_BYTES" ]; then
  rm -f "$OUT.new"
  [ -s "$OUT" ] || { echo offline; exit 1; }
  echo stale; exit 0
fi

if [ -s "$OUT.new" ] && jq -e '.models | length > 0' "$OUT.new" >/dev/null 2>&1; then
  mv -f "$OUT.new" "$OUT"
else
  rm -f "$OUT.new"
  [ -s "$OUT" ] || { echo offline; exit 1; }
  status=stale
fi

echo "$status"
