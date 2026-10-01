#!/usr/bin/env bash
# A backup carries the config's bytes, and the config carries provider keys and MCP
# bearer tokens. What kept those private was the directory the config sat in, not
# the file's own mode: a 0644 opencode.json under a 0700 folder is private, and the
# same 0644 file copied below a 0755 state directory is not. So every case here
# starts from exactly that — a 0644 config inside a 0700 parent, under an ordinary
# 022 umask — and asserts that nothing this plugin keeps is open to anyone else,
# across apply, undo and every repair, and that a tree an older release left open
# is closed again on the next run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

# The umask the review names. Each case that wants a different one says so.
umask 022

mode(){ stat -c '%a' "$1" 2>/dev/null || echo missing; }
# Anything below $1 that a group or other could read, write or enter. Symlinks are
# left out: their own mode means nothing, and what they point at is not ours.
opened(){ find "$1" ! -type l -perm /077 -printf '%m %p\n' 2>/dev/null | head -5; }

# Minted per run, like the canary in hardening.test.sh, so no checkout of this file
# can be mistaken for a leak.
CANARY="sk-PRIVATE-$$-${RANDOM}${RANDOM}"

mk(){ local d="$ROOT/$1"; rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state"
  # The case under review: the config directory is the only thing keeping the
  # config private, and the file itself is world-readable.
  chmod 0700 "$d/cfg" "$d/omo"
  printf '{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-5","provider":{"anthropic":{"options":{"apiKey":"%s"}}},"mcp":{"x":{"type":"remote","url":"https://example.invalid","headers":{"Authorization":"Bearer %s"}}}}' \
    "$CANARY" "$CANARY" > "$d/cfg/opencode.json"
  chmod 0644 "$d/cfg/opencode.json"
  printf '%s' "$d"; }
run(){ local d="$1"; shift
  OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
  XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" OC_AUTO_RELOAD=0 "$OC" "$@"; }
root_of(){ printf '%s' "$1/state/omarchy/opencode-configs"; }
state_of(){ local h; h="$(printf '%s' "$1/cfg" | sha256sum | cut -c1-12)"
  printf '%s' "$(root_of "$1")/by-config/$h"; }
store_of(){ printf '%s' "$(state_of "$1")/profiles.json"; }
cache_of(){ printf '%s' "$1/cache/omarchy/oliwier.opencode-configs"; }
last_backup(){ jq -r '.state.lastBackup // ""' "$(store_of "$1")"; }

# One omo.jsonc in the unified shape, with the same key planted in it.
omo(){ cat > "$1/omo/omo.jsonc" <<J
{
  // the unified config, 0644 under a 0700 folder like the opencode one
  "[opencode]": {
    $2
    "agents": { "oracle": { "model": "anthropic/claude-opus-5" }$3 }
  },
  "[claude]": { "apiKey": "$CANARY" }
}
J
  chmod 0644 "$1/omo/omo.jsonc"; }

# Everything a backup directory and its copies must be, wherever it came from.
backup_is_private(){ local d="$1" ts="$2" what="$3" f
  local bd; bd="$(state_of "$d")/backups/$ts"
  [ -n "$ts" ] && [ -d "$bd" ] || { no "$what: a backup was taken" "none at '$ts'"; return; }
  is "$what: the state root is 0700"        "$(mode "$(root_of "$d")")" "700"
  is "$what: the backups folder is 0700"    "$(mode "$(state_of "$d")/backups")" "700"
  is "$what: the backup folder is 0700"     "$(mode "$bd")" "700"
  for f in "$bd"/*; do
    is "$what: $(basename "$f") is 0600"    "$(mode "$f")" "600"
  done
  # From the plugin's own folders down. ~/.local/state/omarchy above them is shared
  # with Omarchy and every other plugin, and is not this plugin's to tighten.
  is "$what: nothing under state is open"   "$(opened "$(root_of "$d")")" ""
  is "$what: nothing under the cache is open" "$(opened "$(cache_of "$d")")" ""
}

echo "=== apply: a 0644 config under a 0700 folder is backed up 0600 under 0700 ==="
D=$(mk apply)
omo "$D" "" ""
ORIG_OC="$ROOT/apply.opencode.orig"; cp "$D/cfg/opencode.json" "$ORIG_OC"
ORIG_OMO="$ROOT/apply.omo.orig"; cp "$D/omo/omo.jsonc" "$ORIG_OMO"
run "$D" capture "A" a >/dev/null 2>&1
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[
 {"file":"ohmy","shape":"oh-my-openagent","manages":["agents"],"payload":{"agents":{"oracle":{"model":"anthropic/claude-sonnet-5"}}}},
 {"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
R=$(run "$D" apply b 2>/dev/null)
is "the switch landed"                      "$(jq -r '.ok' <<<"$R" 2>/dev/null)" "true"
TS=$(last_backup "$D")
backup_is_private "$D" "$TS" "apply"
BD="$(state_of "$D")/backups/$TS"
cmp -s "$BD/opencode.json" "$ORIG_OC" && ok "apply: the copy is the config's own bytes" \
  || no "apply: the copy is the config's own bytes" "it differs"
cmp -s "$BD/ohmy.json" "$ORIG_OMO" && ok "apply: and so is the omo copy" \
  || no "apply: and so is the omo copy" "it differs"
is "apply: the profile store is 0600"       "$(mode "$(store_of "$D")")" "600"
# The plugin keeps its own files private. The user's config keeps whatever mode the
# user gave it: making it private behind their back is not this plugin's call.
is "apply: the live config kept its 0644"   "$(mode "$D/cfg/opencode.json")" "644"
is "apply: and so did the omo config"       "$(mode "$D/omo/omo.jsonc")" "644"

echo "=== undo: the backup undo takes of the config it replaces is private too ==="
R=$(run "$D" revert 2>/dev/null)
is "the undo landed"                        "$(jq -r '.ok' <<<"$R" 2>/dev/null)" "true"
TS2=$(last_backup "$D")
[ "$TS2" != "$TS" ] && ok "undo took a backup of its own" || no "undo took a backup of its own" "still $TS"
backup_is_private "$D" "$TS2" "undo"
cmp -s "$D/cfg/opencode.json" "$ORIG_OC" && ok "undo: the config is back byte for byte" \
  || no "undo: the config is back byte for byte" "it differs"
is "undo: the live config kept its 0644"    "$(mode "$D/cfg/opencode.json")" "644"
echo "--- and the undo of that undo ---"
R=$(run "$D" revert 2>/dev/null)
is "undoing the undo landed"                "$(jq -r '.ok' <<<"$R" 2>/dev/null)" "true"
backup_is_private "$D" "$(last_backup "$D")" "undo of undo"

echo "=== repair E_BARE_AGENT_STRING backs up opencode.json 0600 ==="
D=$(mk bare)
printf '{"$schema":"https://opencode.ai/config.json","agent":{"build":"anthropic/claude-sonnet-5"},"provider":{"anthropic":{"options":{"apiKey":"%s"}}}}' \
  "$CANARY" > "$D/cfg/opencode.json"; chmod 0644 "$D/cfg/opencode.json"
R=$(run "$D" repair --fix E_BARE_AGENT_STRING --apply 2>/dev/null)
is "the repair landed"                      "$(jq -r '.fixed' <<<"$R" 2>/dev/null)" "1"
backup_is_private "$D" "$(last_backup "$D")" "repair bare"
is "repair bare: the live config kept its 0644" "$(mode "$D/cfg/opencode.json")" "644"
R=$(run "$D" revert 2>/dev/null)
is "and its undo landed"                    "$(jq -r '.ok' <<<"$R" 2>/dev/null)" "true"
backup_is_private "$D" "$(last_backup "$D")" "undo of repair bare"

echo "=== repair E_MODELS_IN_CONFIG backs up the omo config 0600 ==="
D=$(mk models)
omo "$D" "" ', "sisyphus": { "models": ["anthropic/claude-opus-5", "anthropic/claude-sonnet-5"] }'
R=$(run "$D" repair --fix E_MODELS_IN_CONFIG --apply 2>/dev/null)
is "the repair landed"                      "$(jq -r '.fixed' <<<"$R" 2>/dev/null)" "1"
backup_is_private "$D" "$(last_backup "$D")" "repair models"
is "repair models: the omo config kept its 0644" "$(mode "$D/omo/omo.jsonc")" "644"

echo "=== repair E_FILE_FALLBACK backs up the omo config 0600 ==="
D=$(mk filefb)
omo "$D" '"fallback_models": ["anthropic/claude-opus-5"],' ""
R=$(run "$D" repair --fix E_FILE_FALLBACK --apply 2>/dev/null)
is "the repair landed"                      "$(jq -r '.fixed' <<<"$R" 2>/dev/null)" "1"
backup_is_private "$D" "$(last_backup "$D")" "repair fallback"

echo "=== repair E_MODELS_IN_PROFILE backs up the store 0600 ==="
D=$(mk store)
OC_PROFILE_JSON='{"id":"muse","name":"Muse","targets":[{"file":"ohmy","shape":"oh-my-openagent","manages":["agents"],
  "payload":{"agents":{"sisyphus":{"models":["anthropic/claude-opus-5","anthropic/claude-sonnet-5"]}}}}]}' \
  run "$D" save >/dev/null 2>&1
R=$(run "$D" repair --fix E_MODELS_IN_PROFILE --profile muse --apply 2>/dev/null)
is "the repair landed"                      "$(jq -r '.fixed' <<<"$R" 2>/dev/null)" "1"
# This backup holds the store rather than a config, so undo never points at it;
# it is found as the newest folder instead.
SB=$(ls -1 "$(state_of "$D")/backups" | sort | tail -1)
backup_is_private "$D" "$SB" "repair store"
[ -f "$(state_of "$D")/backups/$SB/store.json" ] && ok "repair store: the store copy is there" \
  || no "repair store: the store copy is there" "missing"

echo "=== an umask of 000 changes none of it ==="
D=$(mk umask0)
( umask 000
  run "$D" capture "A" a >/dev/null 2>&1
  OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
    run "$D" save >/dev/null 2>&1
  run "$D" apply b >/dev/null 2>&1
  run "$D" detect >/dev/null 2>&1 )
backup_is_private "$D" "$(last_backup "$D")" "umask 000"

echo "=== a tree an older release left open is closed on the next run ==="
D=$(mk migrate)
run "$D" capture "A" a >/dev/null 2>&1
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
run "$D" apply b >/dev/null 2>&1
TS=$(last_backup "$D")
# What 1.5.0 and earlier left on disk under a 022 umask: folders 0755, files 0644,
# and the .lock file releases before 1.2 created beside the store.
: > "$(state_of "$D")/.lock"
chmod -R go+rX "$D/state/omarchy" "$D/cache/omarchy"
find "$D/state/omarchy" "$D/cache/omarchy" -type f -exec chmod 0644 {} +
[ -n "$(opened "$(root_of "$D")")" ] && ok "the old layout was rebuilt" || no "the old layout was rebuilt" "nothing is open"
# A link inside the tree, at a file and at a folder outside it. The repair must not
# reach through either: chmod follows a link, which is why it is not used.
printf 'NOT OURS' > "$D/outside.txt"; chmod 0644 "$D/outside.txt"
mkdir -p "$D/outside.d"; chmod 0755 "$D/outside.d"
ln -s "$D/outside.txt" "$(state_of "$D")/backups/$TS/link.json"
ln -s "$D/outside.d" "$(state_of "$D")/backups/linked-dir"
# And a FIFO, which an open without O_NONBLOCK would sit inside for ever.
mkfifo "$(state_of "$D")/backups/$TS/pipe"
OUT=$(timeout 20 env OPENCODE_CONFIG_DIR="$D/cfg" OMO_CONFIG_HOME="$D/omo" \
  XDG_CACHE_HOME="$D/cache" XDG_STATE_HOME="$D/state" OC_AUTO_RELOAD=0 "$OC" list 2>/dev/null); rc=$?
[ "$rc" != 124 ] && ok "a read-only list did not stall on the FIFO" || no "did not stall" "hit the timeout"
is "list still answers"                     "$(jq -r '.effectiveProfileId' <<<"$OUT" 2>/dev/null)" "b"
is "the old .lock is 0600 now"              "$(mode "$(state_of "$D")/.lock")" "600"
is "the old backup copy is 0600 now"        "$(mode "$(state_of "$D")/backups/$TS/opencode.json")" "600"
is "the old store is 0600 now"              "$(mode "$(store_of "$D")")" "600"
is "the old cache folder is 0700 now"       "$(mode "$(cache_of "$D")")" "700"
is "the file a link points at kept 0644"    "$(mode "$D/outside.txt")" "644"
is "the folder a link points at kept 0755"  "$(mode "$D/outside.d")" "755"
[ -L "$(state_of "$D")/backups/$TS/link.json" ] && [ -L "$(state_of "$D")/backups/linked-dir" ] \
  && ok "and both links are still links" || no "and both links are still links" "one was replaced"
# Only folders and regular files are tightened; the planted entries were there to be
# stepped around, and have had their say.
rm -f "$(state_of "$D")/backups/$TS/link.json" "$(state_of "$D")/backups/linked-dir" \
      "$(state_of "$D")/backups/$TS/pipe"
backup_is_private "$D" "$TS" "migrated"
echo "--- the same tree is closed by every other entry point too ---"
for cmd in detect doctor backups "capture C c"; do
  chmod -R go+rX "$(root_of "$D")"
  run "$D" $cmd >/dev/null 2>&1
  is "$cmd closes it"                       "$(opened "$(root_of "$D")")" ""
done

echo "=== the plugin's own folders are checked, not assumed ==="
D=$(mk linkroot)
mkdir -p "$D/state/omarchy" "$D/elsewhere"; chmod 0755 "$D/elsewhere"
ln -s "$D/elsewhere" "$(root_of "$D")"
OUT=$(run "$D" capture "A" a 2>/dev/null); rc=$?
is "a symlinked state root is refused"      "$(jq -r '.code // "none"' <<<"$OUT" 2>/dev/null)" "E_STORE"
is "with exit 2"                            "$rc" "2"
is "and nothing was written where it points" "$(ls -A "$D/elsewhere" | wc -l)" "0"
is "nor was that folder's mode changed"     "$(mode "$D/elsewhere")" "755"

D=$(mk linkbackups)
run "$D" capture "A" a >/dev/null 2>&1
OC_PROFILE_JSON='{"id":"b","name":"B","targets":[{"file":"opencode","shape":"opencode","manages":["model"],"payload":{"model":"anthropic/claude-opus-5"}}]}' \
  run "$D" save >/dev/null 2>&1
mkdir -p "$D/elsewhere"; chmod 0755 "$D/elsewhere"
rm -rf "$(state_of "$D")/backups"; ln -s "$D/elsewhere" "$(state_of "$D")/backups"
OUT=$(run "$D" apply b 2>/dev/null); rc=$?
is "a symlinked backups folder is refused"  "$(jq -r '.code // "none"' <<<"$OUT" 2>/dev/null)" "E_STORE"
is "with exit 2"                            "$rc" "2"
is "no copy landed where it points"         "$(ls -A "$D/elsewhere" | wc -l)" "0"
is "and the config was not switched"        "$(jq -r .model "$D/cfg/opencode.json")" "anthropic/claude-sonnet-5"

D=$(mk linkcache)
mkdir -p "$D/cache/omarchy" "$D/elsewhere"; chmod 0755 "$D/elsewhere"
ln -s "$D/elsewhere" "$(cache_of "$D")"
OUT=$(run "$D" detect 2>/dev/null); rc=$?
# detect stages copies of the config in the cache, provider keys included, so a
# cache folder that cannot be shown to be private is not one to stage them in.
is "a symlinked cache folder is refused"    "$(jq -r '.code // "none"' <<<"$OUT" 2>/dev/null)" "E_STORE"
is "and nothing was staged where it points" "$(grep -rl "$CANARY" "$D/elsewhere" 2>/dev/null | wc -l)" "0"

echo "=== the model sync keeps its cache private too ==="
D=$(mk sync)
mkdir -p "$D/bin"
cat > "$D/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf 'zen/good\n'
EOF
cat > "$D/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [ "\$prev" = "-o" ] && out="\$a"; prev="\$a"; done
[ -n "\$out" ] && printf '%s' '{"zen":{"name":"Zen","models":{"good":{"tool_call":true,"modalities":{"output":["text"]},"name":"Good"}}}}' > "\$out"
printf '200'
EOF
chmod +x "$D/bin/opencode" "$D/bin/curl"
# A cache 1.5.0 left open: the folder 0755 and a stamp file 0644.
mkdir -p "$(cache_of "$D")"; chmod 0755 "$(cache_of "$D")"
: > "$(cache_of "$D")/models.dev.attempt"; chmod 0644 "$(cache_of "$D")/models.dev.attempt"
S=$(PATH="$D/bin:$PATH" OPENCODE_BIN="$D/bin/opencode" XDG_CACHE_HOME="$D/cache" FORCE=1 \
    "$REPO/bin/sync-models.sh" 2>/dev/null)
is "the sync ran"                           "$S" "fresh"
is "the cache folder is 0700"               "$(mode "$(cache_of "$D")")" "700"
is "nothing in it is open"                  "$(opened "$(cache_of "$D")")" ""
rm -rf "$(cache_of "$D")"; mkdir -p "$D/elsewhere2"; chmod 0755 "$D/elsewhere2"
ln -s "$D/elsewhere2" "$(cache_of "$D")"
S=$(PATH="$D/bin:$PATH" OPENCODE_BIN="$D/bin/opencode" XDG_CACHE_HOME="$D/cache" FORCE=1 \
    "$REPO/bin/sync-models.sh" 2>/dev/null); rc=$?
is "a symlinked cache folder stops the sync" "$S/$rc" "offline/1"
is "and nothing was written where it points" "$(ls -A "$D/elsewhere2" | wc -l)" "0"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $((pass+fail)) passed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
