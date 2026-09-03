#!/usr/bin/env bash
#
# sync-models.sh — joins `opencode models` (what you can reach right now) with
# models.dev/api.json (name, context, price, reasoning efforts), marking each `reachable`.
# Prints fresh | unchanged | cached | local | reach | stale | offline; exit 0 = cache on disk is usable.

set -uo pipefail

PLUGIN_ID="oliwier.opencode-configs"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/$PLUGIN_ID"
TTL="${TTL:-86400}"                        # seconds; the panel passes catalogRefreshHours * 3600
# Reachability (`opencode models`: local, a few seconds) goes stale much faster
# than the models.dev metadata (a multi-MB download), and it is the part that
# answers "I just connected a provider / a new model dropped — where is it?".
# So it has its own short TTL: a panel open refreshes the reachable list every
# few minutes in the background, while the big catalogue keeps the long one.
REACH_TTL="${REACH_TTL:-900}"             # seconds; how often `opencode models` is re-run
RAW="$CACHE/models.dev.json"
# When the catalogue was last confirmed current, which is not when the file was
# last written: the usual answer from models.dev is `304 Not Modified`, which
# proves the copy on disk is up to date without touching a byte of it. Reading
# the clock off the file itself would make every later run think the download was
# still due. It is written at the far end of a run, after the join has agreed the
# bytes really were a catalogue — so a 200 that turned out to be a captive-portal
# page never sets it, and the next run fetches again instead of sitting on it.
CAT_STAMP="$CACHE/models.dev.stamp"
# And when it was last asked for at all, which a failure sets just as a success does.
CAT_ATTEMPT="$CACHE/models.dev.attempt"
ETAG="$CACHE/models.dev.etag"
REACH="$CACHE/reachable.txt"
# When the reachable list was last *attempted*, which is not the same as when it
# last changed. `opencode models` can fail — no opencode, a hung provider probe,
# a timeout — and a failure that leaves no trace is a failure that is retried on
# every single panel open, forever. The clock has to tick on the attempt.
REACH_STAMP="$CACHE/reachable.stamp"
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
# A run killed outright runs no trap, and its staged files — up to MAX_FETCH_BYTES
# of half-downloaded catalogue — are then nobody's to remove: every glob is scoped
# to the run that made it. Anything left over an hour is from a run that is gone.
find "$CACHE" -maxdepth 1 -name '.stage.*' -type f -mmin +60 -delete 2>/dev/null || true
stage() { mktemp "${STAGE_PREFIX}XXXXXXXX" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { echo offline; exit 1; }

fresh_enough() {
  # $1 = file, $2 = ttl seconds. Both callers pass their own pair, so the
  # reachable list can be refreshed without re-downloading the catalogue.
  [ -s "$1" ] || return 1
  [ $(( $(date +%s) - $(stat -c %Y "$1" 2>/dev/null || echo 0) )) -lt "$2" ]
}
# Each clock lives in a file only the work it gates ever writes. The catalogue was
# read off $OUT before, which every reach-only run rewrites — so the long TTL was
# measured against a file the short cycle kept touching, and the download it was
# meant to schedule was deferred once per cycle and therefore never happened at all.
RAW_FRESH=0
REACH_FRESH=0
# A download that failed is not a download that is still due. Without a record of
# the attempt, a machine with no network answers "the catalogue is stale" to every
# panel open, and every panel open spends up to a minute of curl retries finding
# that out again. This is how long it waits before asking a second time.
CAT_RETRY_TTL="${CAT_RETRY_TTL:-900}"
CAT_TRIED_RECENTLY=0
if [ "${FORCE:-0}" != 1 ]; then
  fresh_enough "$CAT_STAMP" "$TTL" && [ -s "$RAW" ] && RAW_FRESH=1
  fresh_enough "$CAT_ATTEMPT" "$CAT_RETRY_TTL" && CAT_TRIED_RECENTLY=1
  fresh_enough "$REACH_STAMP" "$REACH_TTL" && REACH_FRESH=1
  # Nothing to gain from another run: the catalogue is either current or was just
  # asked for, reachability was just asked for, and there is a list on disk to show.
  if { [ "$RAW_FRESH" = 1 ] || [ "$CAT_TRIED_RECENTLY" = 1 ]; } \
     && [ "$REACH_FRESH" = 1 ] && [ -s "$OUT" ]; then echo cached; exit 0; fi
fi

# ---------------------------------------------------------------- metadata

# When only the reachable list went stale, the catalogue on disk is still good:
# skip both downloads and re-join against it below. The reachable refresh and
# the join that follow are the whole of a reach-only run. A missing or unreadable
# $RAW is not fresh, so this block is also how a cold cache gets filled.
status=cached
if [ "$RAW_FRESH" = 0 ] && [ "$CAT_TRIED_RECENTLY" = 0 ]; then
status=offline
date +%s > "$CAT_ATTEMPT" 2>/dev/null || true

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
  # The new ETag is staged, not saved in place. curl writes it as part of the same
  # call that stores the body, before anything has looked at what came back — so a
  # response that is then rejected would leave its ETag behind, and every later run
  # would be told 304 for content that was never kept. It moves into place only
  # once the body it belongs to has been accepted.
  etag_new="$(stage)" || etag_new="$fetched.etag"
  if [ -n "$fetched" ]; then
    code=$(curl -fsS --proto '=https' --max-time 20 --max-filesize "$MAX_FETCH_BYTES" \
            --retry 2 --retry-delay 1 \
            --etag-compare "$ETAG" --etag-save "$etag_new" \
            -o "$fetched" -w '%{http_code}' https://models.dev/api.json 2>/dev/null) || code=000
    case "$code" in
      200) if checked="$(stage)" \
              && "$SELF_DIR/safe-read" "$fetched" --max-bytes "$MAX_FETCH_BYTES" \
                   --no-empty --label "the model catalogue" > "$checked" 2>/dev/null; then
             mv -f "$checked" "$RAW" && status=fresh && etag_pending="$etag_new"
           fi ;;
      304) [ "$status" = local ] || status=unchanged ;;
      *)   [ -s "$RAW" ] && [ "$status" != local ] && status=stale ;;
    esac
  fi
fi

fi # downloads skipped on a reach-only run

# ---------------------------------------------------------------- reachable

# A few seconds, and gated by REACH_TTL above — not by the catalogue TTL — so a
# panel open can trigger this freely: when the reachable list is still fresh the
# script already exited as `cached` without reaching this point, and when it is
# not, this is exactly the refresh the user is waiting for. The panel shows the
# old list meanwhile and re-reads the cache when this lands, so nothing here
# ever sits between clicking the bar and seeing the list.
# Failing here is not fatal: models then show as unreachable-unknown rather than none at all.
OPENCODE_BIN="${OPENCODE_BIN:-}"
if [ -z "$OPENCODE_BIN" ]; then
  # PATH first. ~/.opencode is where the curl installer puts a copy, and that copy
  # does not update itself — on a machine that later installed opencode from a
  # package, preferring it built the model list from an older opencode than the one
  # the user actually runs. bin/oc-profiles has always resolved this from PATH; now
  # both halves of the plugin agree on which opencode is the authority.
  for c in "$(command -v opencode 2>/dev/null)" "$HOME/.opencode/bin/opencode"; do
    [ -n "$c" ] && [ -x "$c" ] && { OPENCODE_BIN="$c"; break; }
  done
fi

# Stamped before the probe, not after, and whether or not the probe works. This is
# the clock REACH_TTL is read from, so a failure that left it untouched would be
# retried on the next panel open, and the one after that — a broken or missing
# opencode would put a fresh thirty-second subprocess behind every click on the bar.
date +%s > "$REACH_STAMP" 2>/dev/null || true

if [ -n "$OPENCODE_BIN" ]; then
  # head -c first: a subprocess can print more than anyone expected, and the cheap
  # place to stop that is the pipe it comes out of, not the file it lands in.
  if printed="$(stage)" && reach="$(stage)"; then
    timeout 30 "$OPENCODE_BIN" models 2>/dev/null | head -c "$MAX_REACH_BYTES" > "$printed"
    # Judged on what it printed, never on how it exited. opencode returns non-zero
    # when any single configured provider has no credentials — the exact state of
    # someone half-way through adding one — and under `pipefail` that verdict would
    # throw away a complete, correct list of every other provider's models.
    #
    # Judged, though, only on a whole printing. The timeout above kills a hung probe
    # mid-line, and half of an id matches the id pattern exactly as well as all of
    # one: it would reach the picker as a model, and the config as a model that does
    # not exist. Command substitution eats trailing newlines, so an empty result here
    # is the proof that the last line was finished.
    if [ -s "$printed" ] && [ -z "$(tail -c 1 "$printed")" ]; then
      sed -E 's/[[:space:]]+$//' "$printed" \
        | grep -E '^[A-Za-z0-9~._-]+/' > "$reach" 2>/dev/null
      [ -s "$reach" ] && mv -f "$reach" "$REACH"
    fi
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
# An empty object rather than a hard stop. models.dev is what supplies names, context
# and prices; what a model IS, is `opencode models`. On a machine that has never
# reached the network the catalogue is missing and every one of those is unknown —
# but the reachable list is right there, and a picker holding every model you can
# actually use, without prices, beats a picker holding nothing. This is the aeroplane
# case, and the first-run-behind-a-proxy case.
"$SELF_DIR/safe-read" "$RAW" --max-bytes "$MAX_FETCH_BYTES" --no-empty \
  --label "the model catalogue" > "$raw_in" 2>/dev/null || printf '{}' > "$raw_in"
reach_in="$(stage)" || { echo offline; exit 1; }
"$SELF_DIR/safe-read" "$REACH" --max-bytes "$MAX_REACH_BYTES" \
  --label "the reachable-model list" > "$reach_in" 2>/dev/null || : > "$reach_in"

staged="$(stage)" || { echo offline; exit 1; }
jq -c --rawfile reach "$reach_in" '
  ($reach | split("\n") | map(select(length > 0))) as $reachable
  | ($reachable | map({key:., value:true}) | from_entries) as $reach_set
  # Every id models.dev describes, before any of the filters below run. The
  # fallback at the end needs to tell "never heard of it" from "heard of it and
  # ruled it out": tested against the filtered list, a model models.dev says
  # cannot call tools comes straight back as a first-class row, which is a model
  # that loads and then fails on the first tool call an agent makes.
  | ( [ to_entries[] | .key as $p | (.value.models // {}) | keys[] | ($p + "/" + .) ]
      | map({key:., value:true}) | from_entries ) as $known_set
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
        # Deprecated, but reachable, means you are using it today. Hiding it would
        # take a model out of the picker while it is still selected in the config —
        # and it would come back through the fallback below stripped of its name,
        # context and price. Deprecated and unreachable is just history, and goes.
        | select((($m.status // "active") != "deprecated") or ($reach_set[$full] // false))
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
  # One models.dev knows and the filters above dropped is not that, and does not come back.
  | . as $cat
  | .models += [ $reachable[]
      | select($known_set[.] | not)
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
  # Here, and only here, and only for the three answers that are actually about the
  # catalogue: a body that parsed (`fresh`), opencode's own newer copy (`local`), or
  # models.dev saying our copy is still current (`unchanged`, a 304). A run whose
  # download failed and fell back to whatever was already on disk has confirmed
  # nothing — stamping it there is the same mistake as measuring the clock off the
  # file the short cycle rewrites: the retry it was meant to schedule never comes.
  if [ "$RAW_FRESH" = 0 ]; then
    case "$status" in
      fresh|local|unchanged)
        date +%s > "$CAT_STAMP" 2>/dev/null
        # The ETag becomes the truth about what is on disk only now. Saved any
        # earlier, a body that was accepted by size and then turned out not to be a
        # catalogue would have every later request answered 304 — a permanent
        # day-old list, repairable only by deleting the cache. Which is exactly
        # what people did.
        [ -n "${etag_pending:-}" ] && [ -s "$etag_pending" ] && mv -f "$etag_pending" "$ETAG" ;;
    esac
  fi
  # A run that ends here has a list. `cached` means it skipped the downloads;
  # `offline` means it tried and could not reach models.dev, and then built the
  # list out of reachability alone. Neither may keep a word that says otherwise.
  case "$status" in cached|offline) status=reach ;; esac
else
  # Nothing came out of the join. If this run had just accepted a body, that body
  # was not a catalogue — it passed the size check and failed the parse — and the
  # network was plainly reachable, so the next run should ask again rather than sit
  # on a captive-portal page for the length of the backoff. A download that simply
  # failed is the opposite case and keeps its backoff.
  case "$status" in fresh|local) rm -f "$CAT_ATTEMPT" 2>/dev/null ;; esac
  [ -s "$OUT" ] || { echo offline; exit 1; }
  status=stale
fi

echo "$status"
