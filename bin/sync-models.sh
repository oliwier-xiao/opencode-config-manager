#!/usr/bin/bash
#
# sync-models.sh — joins `opencode models` (what you can reach right now) with
# models.dev/api.json (name, context, price, reasoning efforts), marking each `reachable`.
# Prints fresh | unchanged | cached | local | reach | stale | offline; exit 0 = cache on disk is usable.

set -uo pipefail

# Everything this writes into the cache is this user's alone, whatever umask the
# panel was started under; opencode, which is somebody else's program, keeps the
# umask it would have had.
INHERITED_UMASK="$(umask)"
umask 077
as_caller() { ( umask "$INHERITED_UMASK"; exec "$@" ); }

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

# `mkdir -m 700` sets the mode of a folder it creates and says nothing about one that
# is already there — 1.5.0 and earlier left this one 0755. bin/private-dir makes it
# 0700 either way, refuses a symlink or a folder another user owns, and brings what
# is already inside into line, all without following a link.
"$SELF_DIR/private-dir" --tree "$CACHE" 2>/dev/null || { echo offline; exit 1; }

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
# A signal ends the run as well as cleaning up after it. Trapped on its own, TERM ran
# the cleanup and then carried on — writing an empty reachable list out of the files
# the cleanup had just removed, and reporting success.
trap cleanup EXIT
trap 'cleanup; exit 143' INT TERM HUP
# A run killed outright runs no trap, and its staged files — up to MAX_FETCH_BYTES
# of half-downloaded catalogue — are then nobody's to remove: every glob is scoped
# to the run that made it. Anything left over an hour is from a run that is gone.
find "$CACHE" -maxdepth 1 -name '.stage.*' -type f -mmin +60 -delete 2>/dev/null || true
stage() { mktemp "${STAGE_PREFIX}XXXXXXXX" 2>/dev/null; }
# The clocks are small files at names anything running as this user can predict, so
# they are written like everything else here: renamed into place by bin/safe-write,
# never through a link planted at the name and never into a FIFO, which `>` would
# open and then wait on for good. The staged files above are renamed with `mv -T`
# for the same reason: a folder at the name is refused rather than moved into.
stamp_now() { date +%s | "$SELF_DIR/safe-write" "$1" 2>/dev/null || true; }
# An entity tag and nothing else: one line, a quoted run of visible characters,
# weak or not. Whatever is on file is sent back to models.dev as a header, and
# whatever models.dev sends is kept to be sent again.
etag_ok() {
  [ "$(wc -l < "$1")" -le 1 ] && LC_ALL=C grep -qxE '(W/)?"[!#-~]{0,256}"' "$1"
}

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
stamp_now "$CAT_ATTEMPT"

# opencode keeps its own copy of the same catalogue, and a newer one is taken as it
# is: if the download below fails, the list is still built from it. Its entity tag
# is not the one on file, so the one on file goes — kept, a 304 would vouch for a
# copy it never described.
if [ -s "$OC_CACHE" ] && { [ ! -s "$RAW" ] || [ "$OC_CACHE" -nt "$RAW" ]; }; then
  # opencode's cache is a file at a predictable path like any other: read through
  # the descriptor, bounded, rather than copied by name.
  if t="$(stage)" && "$SELF_DIR/safe-read" "$OC_CACHE" --max-bytes "$MAX_FETCH_BYTES" \
       --no-empty --label "opencode's model cache" > "$t" 2>/dev/null; then
    mv -fT "$t" "$RAW" && status=local && rm -f "$ETAG"
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
  # The tag on file goes to curl as a staged copy, never by its name: curl opens what
  # it is given with fopen(), so it follows a link, waits on a FIFO, and sends what
  # it finds as a request header — a link planted at this predictable name would send
  # the first line of any file this user can read to models.dev. Read like every
  # other file here, and passed on only if it is an entity tag.
  etag_args=()
  if et="$(stage)" && "$SELF_DIR/safe-read" "$ETAG" --max-bytes 512 --no-empty \
       --label "the catalogue's entity tag" > "$et" 2>/dev/null && etag_ok "$et"; then
    etag_args=(--etag-compare "$et")
  fi
  if [ -n "$fetched" ]; then
    # -q first: no ~/.curlrc. A line in it could add a proxy, a header or an output
    # file to a request this script means to be exactly what it says.
    # --retry-max-time: a 429 or 503 names its own wait in Retry-After, and curl
    # sleeps it out between attempts, outside --max-time.
    code=$(curl -q -fsS --proto '=https' --connect-timeout 10 --max-time 20 \
            --max-filesize "$MAX_FETCH_BYTES" --retry 2 --retry-delay 1 --retry-max-time 30 \
            "${etag_args[@]}" --etag-save "$etag_new" \
            -o "$fetched" -w '%{http_code}' https://models.dev/api.json 2>/dev/null) || code=000
    case "$code" in
      200) if checked="$(stage)" \
              && "$SELF_DIR/safe-read" "$fetched" --max-bytes "$MAX_FETCH_BYTES" \
                   --no-empty --label "the model catalogue" > "$checked" 2>/dev/null; then
             mv -fT "$checked" "$RAW" && status=fresh && etag_pending="$etag_new"
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
# Found where it is installed, the same way bin/oc-profiles finds it: OPENCODE_BIN
# when one is named, then PATH — which the panel sets to the system's own directories
# — then the places opencode's installers put it. PATH before ~/.opencode, because the
# copy the curl installer leaves there does not update itself, and a machine that
# later installed opencode from a package should not have its model list built from
# the older one. What is found has to be a regular file once its links are followed,
# owned by root or by this user and writable by nobody else; anything else at one of
# those names is passed over.
OPENCODE_BIN_IN="${OPENCODE_BIN:-}"
OPENCODE_BIN=""
for c in "$OPENCODE_BIN_IN" "$(type -P opencode 2>/dev/null)" /usr/bin/opencode /usr/local/bin/opencode \
         "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" \
         "$HOME/.bun/bin/opencode" "$HOME/.npm-global/bin/opencode"; do
  case "$c" in /*) ;; *) continue ;; esac
  real="$(readlink -f -- "$c" 2>/dev/null)" || continue
  [ -f "$real" ] && [ -x "$real" ] || continue
  owner="$(stat -c %u -- "$real" 2>/dev/null)" || continue
  [ "$owner" = 0 ] || [ "$owner" = "$EUID" ] || continue
  mode="$(stat -c %a -- "$real" 2>/dev/null)" || continue
  (( (8#$mode & 8#022) == 0 )) || continue
  OPENCODE_BIN="$real"
  break
done

# Stamped before the probe, not after, and whether or not the probe works. This is
# the clock REACH_TTL is read from, so a failure that left it untouched would be
# retried on the next panel open, and the one after that — a broken or missing
# opencode would put a fresh thirty-second subprocess behind every click on the bar.
stamp_now "$REACH_STAMP"

if [ -n "$OPENCODE_BIN" ]; then
  # head -c first: a subprocess can print more than anyone expected, and the cheap
  # place to stop that is the pipe it comes out of, not the file it lands in.
  if printed="$(stage)" && reach="$(stage)"; then
    # From HOME, with a search path of the system's directories behind its own: the
    # folder this was started in is nobody's choice of project, and opencode reads the
    # project config of the folder it starts in.
    timeout_bin="$(type -P timeout 2>/dev/null)" || timeout_bin=timeout
    # opencode is told not to download a catalogue of its own and handed one to read:
    # its own cache, or this plugin's, copied the way every file here is read. Left to
    # itself, `opencode models` fetched the catalogue — whole, decompressed, with no
    # size limit — and read its cache by name, at a path anything can put a FIFO at.
    oc_models="$(stage)" || oc_models=/dev/null
    if [ "$oc_models" != /dev/null ]; then
      "$SELF_DIR/safe-read" "$OC_CACHE" --max-bytes "$MAX_FETCH_BYTES" --no-empty \
          --label "opencode's model cache" > "$oc_models" 2>/dev/null \
        || "$SELF_DIR/safe-read" "$RAW" --max-bytes "$MAX_FETCH_BYTES" --no-empty \
             --label "the model catalogue" > "$oc_models" 2>/dev/null \
        || : > "$oc_models"
    fi
    # -k 2: this timeout puts opencode in a process group of its own, out of reach of
    # the deadline the panel set, and TERM alone does not end a program that handles it.
    ( cd "$HOME" 2>/dev/null || cd /
      PATH="${OPENCODE_BIN%/*}:/usr/bin:/bin" OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_MODELS_PATH="$oc_models" \
        as_caller "$timeout_bin" -k 2 30 "$OPENCODE_BIN" models ) \
      2>/dev/null | head -c "$MAX_REACH_BYTES" > "$printed"
    probe_rc="${PIPESTATUS[0]}"
    # Judged on what it printed, never on how it exited. opencode returns non-zero
    # when any single configured provider has no credentials — the exact state of
    # someone half-way through adding one — and under `pipefail` that verdict would
    # throw away a complete, correct list of every other provider's models.
    #
    # Judged, though, only on a whole printing. The timeout above kills a hung probe
    # mid-line, and half of an id matches the id pattern exactly as well as all of
    # one: it would reach the picker as a model, and the config as a model that does
    # not exist. Command substitution eats trailing newlines, so an empty result here
    # is the proof that the last line was finished. And a printing the deadline or
    # the byte cap ended is not a whole one even when the cut fell between two lines:
    # it is the head of a list, missing every model after it.
    case "$probe_rc" in 124|137|141|143) : > "$printed" ;; esac
    [ "$(stat -c %s "$printed" 2>/dev/null || echo 0)" -lt "$MAX_REACH_BYTES" ] || : > "$printed"
    if [ -s "$printed" ] && [ -z "$(tail -c 1 "$printed")" ]; then
      # Lines are measured before the trailing blanks are trimmed: sed's trim costs
      # the square of a run of blanks, and a model key from the catalogue can carry
      # one tens of kilobytes long. Nothing longer than an id the join would keep —
      # 64 bytes of provider, 128 of model, room for the blanks — passes the grep.
      LC_ALL=C grep -E '^[A-Za-z0-9~._-]{1,64}/.{1,192}$' "$printed" \
        | sed -E 's/[[:space:]]+$//' > "$reach" 2>/dev/null
      [ -s "$reach" ] && mv -fT "$reach" "$REACH"
    fi
  fi
fi
[ -s "$REACH" ] || printf '' | "$SELF_DIR/safe-write" "$REACH" --allow-empty 2>/dev/null || true

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

# What the join may hold. jq builds its whole answer before it prints a byte of it, so
# the cap on what comes out, below, cannot bound what jq held on the way there: that
# bound has to be inside. The join measures every string the catalogue supplies before
# it builds anything out of it, and caps both counts as the lists grow, so what it
# holds is the catalogue plus a bounded amount per model. Parsing has a cost of its
# own that no program can shape — a file of nothing but empty brackets costs jq a few
# hundred bytes a pair — so jq also runs under an address-space ceiling: the real
# catalogue needs under 100 MiB of it, and at 512 MiB jq stops rather than grows, with
# no core file kept. What it prints passes through head on the way to the disk, so the
# staged file never outgrows the cap it is then checked against.
MAX_PROVIDERS="${MAX_PROVIDERS:-1024}"
MAX_MODELS="${MAX_MODELS:-32768}"
MAX_JQ_KB="${MAX_JQ_KB:-524288}"
MAX_OUT_BYTES="${MAX_OUT_BYTES:-12582912}"
bounded_jq() (
  ulimit -c 0 2>/dev/null
  # A hard limit already under the ceiling cannot be raised to it, and need not be.
  ulimit -v "$MAX_JQ_KB" 2>/dev/null \
    || { lim="$(ulimit -v)"; [ "$lim" != unlimited ] && [ "$lim" -le "$MAX_JQ_KB" ]; } \
    || exit 1
  # Without HOME: jq sources $HOME/.jq before every program, and a file there can
  # redefine limit or utf8bytelength out from under every bound below, or, as a
  # FIFO, hold the run until its deadline.
  unset HOME
  exec jq "$@"
)

staged="$(stage)" || { echo offline; exit 1; }
# -n and `input`: the join runs once, over the first value in the file. Given a file
# of many, jq ran the whole program once per value, the reachable list included.
bounded_jq -cn --rawfile reach "$reach_in" \
  --argjson max_providers "$MAX_PROVIDERS" --argjson max_models "$MAX_MODELS" '
  # Every string the catalogue supplies is measured before anything is built out of
  # it. An id joins a provider key to each model key of that provider, and the search
  # text joins the provider name to each of them, so a string nobody measured is
  # multiplied rather than copied: a 1 MiB key over 4,096 models was 4 GiB of jq, out
  # of a download under 2 MiB. So a key is what bin/oc-profiles would write, a
  # provider/model id and nothing else, in at most 64 bytes of provider and 128 of
  # model; a name, a date, an effort or an env var is a string of at most 128 bytes or
  # is not used; and a field of the wrong type reads as missing, so a malformed entry
  # is one entry left out rather than the whole catalogue. On the real catalogue none
  # of this changes a byte.
  def provider_ok: type == "string" and utf8bytelength <= 64 and test("^[A-Za-z0-9~._-]+$");
  def model_ok: type == "string" and utf8bytelength <= 128
                and test("^[^/[:space:]]+(/[^/[:space:]]+)*$");
  def brief: if type == "string" and utf8bytelength <= 128 then . else null end;
  def number: if type == "number" then . else null end;
  def obj: if type == "object" then . else {} end;
  def arr: if type == "array" then . else [] end;
  (input | obj) as $root
  | ($reach | split("\n") | map(select(length > 0))) as $reachable
  | ($reachable | map({key:., value:true}) | from_entries) as $reach_set
  | [ limit($max_providers; $root | keys_unsorted[]
        | select(provider_ok and ($root[.] | type == "object"))) ] as $pkeys
  | { generated: (now | floor),
      source: "models.dev + opencode models",
      reachableCount: ($reachable | length),
      providers: [ $pkeys[] as $p | $root[$p] as $pv
        | { id: $p, name: (($pv.name | brief) // $p),
            env: [ limit(16; $pv.env | arr | .[] | brief | strings) ],
            reachable: ([ $pv.models | obj | keys_unsorted[]
                          | select(model_ok and ($reach_set[$p + "/" + .] // false)) ] | length) }
        | select(.reachable > 0) ],
      # Capped as the list grows: catalogue rows first, then the fallback below.
      models: [ limit($max_models;
        ( $pkeys[] as $p | $root[$p] as $pv | ($pv.name | brief) as $pn
          | ($pv.models | obj) as $ms
          | $ms | keys_unsorted[] | select(model_ok) | . as $k
          | $ms[$k] | objects | . as $m
          | ($p + "/" + $k) as $full
          | select($m.tool_call == true)
          | select(any($m.modalities | obj | .output | arr | .[]; . == "text"))
          # Deprecated, but reachable, means you are using it today. Hiding it would
          # take a model out of the picker while it is still selected in the config —
          # and it would come back through the fallback below stripped of its name,
          # context and price. Deprecated and unreachable is just history, and goes.
          | select((($m.status // "active") != "deprecated") or ($reach_set[$full] // false))
          | ($m.limit | obj) as $lim | ($m.cost | obj) as $cost
          | { id: $full,
              provider: $p,
              providerName: ($pn // $p),
              modelId: $k,
              name: (($m.name | brief) // $k),
              context: (($lim.context | number) // 0),
              maxOutput: (($lim.output | number) // 0),
              inputCost: ($cost.input | number),
              outputCost: ($cost.output | number),
              cacheRead: ($cost.cache_read | number),
              reasoning: ($m.reasoning == true),
              attachment: ($m.attachment == true),
              openWeights: ($m.open_weights == true),
              released: ($m.release_date | brief),
              variants: [ limit(16; $m.reasoning_options | arr | .[] | obj
                                    | select(.type == "effort") | .values | arr | .[]
                                    | select(. == null or brief != null)) ],
              vision: any($m.modalities | obj | .input | arr | .[]; . == "image"),
              free: ((($cost.input | number) // 1) == 0 and (($cost.output | number) // 1) == 0),
              reachable: ($reach_set[$full] // false),
              search: (($p + " " + ($pn // "") + " " + $k + " " + (($m.name | brief) // ""))
                       | ascii_downcase) } ),
        # A model opencode can reach but models.dev has never heard of is still
        # selectable; keep it. One models.dev knows and the filters above dropped is not
        # that, and does not come back. Which is which is asked of the catalogue one
        # reachable id at a time, rather than read off a set of every id it spells built
        # before anything had been measured.
        ( $reachable[]
          | select(utf8bytelength <= 193)
          | split("/") as $parts | ($parts[1:] | join("/")) as $rest
          | select(($parts[0] | provider_ok) and ($rest | model_ok))
          | select($root[$parts[0]] | obj | .models | obj | has($rest) | not)
          | { id: ., provider: $parts[0], providerName: $parts[0], modelId: $rest,
              name: $parts[-1], context: 0, maxOutput: 0,
              inputCost: null, outputCost: null, cacheRead: null,
              reasoning: false, attachment: false, openWeights: false, released: null,
              variants: [], vision: false, free: false, reachable: true,
              search: ascii_downcase } ) ) ]
    }
  | .totalCount = (.models | length)
' "$raw_in" 2>/dev/null | head -c "$((MAX_OUT_BYTES + 1))" > "$staged"

# Producer-side ceiling. The panel refuses an oversized catalog too, but the
# cheaper place to stop it is before it is ever written.
if [ -s "$staged" ] && [ "$(stat -c %s "$staged" 2>/dev/null || echo 0)" -gt "$MAX_OUT_BYTES" ]; then
  [ -s "$OUT" ] || { echo offline; exit 1; }
  echo stale; exit 0
fi

if [ -s "$staged" ] && bounded_jq -e '.models | length > 0' "$staged" >/dev/null 2>&1; then
  mv -fT "$staged" "$OUT"
  # Here, and only here, and only for the three answers that are actually about the
  # catalogue: a body that parsed (`fresh`), opencode's own newer copy (`local`), or
  # models.dev saying our copy is still current (`unchanged`, a 304). A run whose
  # download failed and fell back to whatever was already on disk has confirmed
  # nothing — stamping it there is the same mistake as measuring the clock off the
  # file the short cycle rewrites: the retry it was meant to schedule never comes.
  if [ "$RAW_FRESH" = 0 ]; then
    case "$status" in
      fresh|local|unchanged)
        stamp_now "$CAT_STAMP"
        # The ETag becomes the truth about what is on disk only now. Saved any
        # earlier, a body that was accepted by size and then turned out not to be a
        # catalogue would have every later request answered 304 — a permanent
        # day-old list, repairable only by deleting the cache. Which is exactly
        # what people did.
        [ -n "${etag_pending:-}" ] && [ -s "$etag_pending" ] && etag_ok "$etag_pending" \
          && mv -fT "$etag_pending" "$ETAG" ;;
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
