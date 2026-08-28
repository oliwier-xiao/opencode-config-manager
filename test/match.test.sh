#!/usr/bin/env bash
# What the panel is entitled to call "the running profile".
#
# The store only remembers the profile that was last switched *to*. Several ordinary
# paths leave that null over a config that still matches a saved profile byte for
# byte — a revert to a backup taken before any profile was active is the common one.
# Reading the stored id as the only answer is what put "Custom · no profile matches
# what is on disk" over a config that matched "Saved config" exactly.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

mk(){ local d="$ROOT/$1"
  rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state"; printf '%s' "$d"; }
run(){ local d="$1"; shift
  OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
  XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" OC_AUTO_RELOAD=0 "$OC" "$@"; }
# A non-default config dir gets its own store, under a digest of that path.
store_of(){ local d="$1"
  printf '%s/state/omarchy/opencode-configs/by-config/%s/profiles.json' \
    "$d" "$(printf '%s' "$d/cfg" | sha256sum | cut -c1-12)"; }
# What a revert to a pre-profile backup leaves behind, without waiting for one.
forget_active(){ local f; f="$(store_of "$1")"
  python3 - "$f" <<'PY'
import json,sys
p=json.load(open(sys.argv[1])); p["state"]["activeProfileId"]=None
json.dump(p, open(sys.argv[1],"w"))
PY
}
cfg(){ printf '{"$schema":"https://opencode.ai/config.json","model":"%s"}' "$2" > "$1/cfg/opencode.json"; }

echo "=== a config that matches a profile is never reported as matching none ==="
D=$(mk match); cfg "$D" "anthropic/claude-opus-5"
run "$D" capture "Mine" mine >/dev/null
L=$(run "$D" list)
is "the captured profile matches disk"  "$(jq -c '.matches' <<<"$L")"            '["mine"]'
is "it reads as the running profile"    "$(jq -r  '.effectiveProfileId' <<<"$L")" "mine"
is "nothing has drifted"                "$(jq -r  '.drift' <<<"$L")"             "false"

forget_active "$D"
L=$(run "$D" list)
is "matches still names it"                    "$(jq -c '.matches' <<<"$L")"             '["mine"]'
is "a forgotten id falls back to the match"    "$(jq -r  '.effectiveProfileId' <<<"$L")" "mine"
is "and that is still not drift"               "$(jq -r  '.drift' <<<"$L")"             "false"
is "the store itself was not rewritten"        "$(jq -r  '.state.activeProfileId' <<<"$L")" "null"

echo "=== a config that matches nothing still says so ==="
cfg "$D" "anthropic/claude-haiku-4-5"
L=$(run "$D" list)
is "no profile matches"       "$(jq -c '.matches' <<<"$L")"             '[]'
is "no effective profile"     "$(jq -r  '.effectiveProfileId' <<<"$L")" "null"
is "reported as drift"        "$(jq -r  '.drift' <<<"$L")"             "true"

echo "=== a drifted active profile is still the active profile ==="
D=$(mk drift); cfg "$D" "anthropic/claude-opus-5"
run "$D" capture "Mine" mine >/dev/null
# capture only saves; switching is what marks a profile active.
run "$D" apply mine >/dev/null
cfg "$D" "anthropic/claude-haiku-4-5"
L=$(run "$D" list)
is "the id the user chose is kept"  "$(jq -r '.effectiveProfileId' <<<"$L")" "mine"
is "and the edit is reported"       "$(jq -r '.drift' <<<"$L")"             "true"

echo "=== revert records the profile the restored config matches ==="
D=$(mk revert); cfg "$D" "anthropic/claude-opus-5"
run "$D" capture "A" a >/dev/null
# Exactly the state a revert to a pre-profile backup leaves: the switch below then
# writes a backup whose meta names no profile to go back to.
forget_active "$D"
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],"payload":{"model":"anthropic/claude-sonnet-5"}}]}' \
  run "$D" save >/dev/null
run "$D" apply b >/dev/null
is "switched to B" "$(jq -r '.model' "$D/cfg/opencode.json")" "anthropic/claude-sonnet-5"
is "the backup names no profile to return to" \
   "$(jq -r '.fromProfileId' "$D/state/omarchy/opencode-configs/by-config/$(printf '%s' "$D/cfg" | sha256sum | cut -c1-12)/backups/$(run "$D" list | jq -r '.state.lastBackup')/meta.json")" \
   "null"
R=$(run "$D" revert)
is "revert succeeded"   "$(jq -r '.ok' <<<"$R")" "true"
is "the config came back" "$(jq -r '.model' "$D/cfg/opencode.json")" "anthropic/claude-opus-5"
is "and A is recorded as active again" \
   "$(run "$D" list | jq -r '.state.activeProfileId')" "a"

echo "=== revert adopts nothing when nothing matches ==="
D=$(mk revert2); cfg "$D" "anthropic/claude-opus-5"
run "$D" capture "A" a >/dev/null
forget_active "$D"
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],"payload":{"model":"anthropic/claude-sonnet-5"}}]}' \
  run "$D" save >/dev/null
run "$D" apply b >/dev/null
run "$D" delete a >/dev/null
R=$(run "$D" revert)
is "revert still succeeded" "$(jq -r '.ok' <<<"$R")" "true"
is "no profile is invented" "$(run "$D" list | jq -r '.state.activeProfileId')" "null"
is "and it reads as custom" "$(run "$D" list | jq -r '.effectiveProfileId')"    "null"

printf '\n%d passed' "$pass"; [ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"; printf '\n'
[ "$fail" -eq 0 ]
