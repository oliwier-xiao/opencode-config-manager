#!/usr/bin/env bash
# What a switch is allowed to change, and what the commands around it keep.
#
# A profile is a set of models. Switching to one changes which model each agent runs
# on and nothing else: an agent's prompt, tools and permissions are yours, whatever
# the profile was saved with, and so is every key the profile does not name. These
# cases hold that, then the things that were each, once, a way to lose something:
# updating a profile, listing backups from a home folder with a space in it, a first
# profile taken from a commented .jsonc, an opencode binary anyone in its group could
# have replaced, and a model list stopped halfway.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC="$REPO/bin/oc-profiles"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

mk(){ local d="$ROOT/$1"; rm -rf "$d"; mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state"; printf '%s' "$d"; }
run(){ local d="$1"; shift
  OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" XDG_CACHE_HOME="$d/cache" \
  XDG_STATE_HOME="$d/state" OC_AUTO_RELOAD=0 OC_MANAGE_OHMY=0 "$OC" "$@"; }
live(){ "$REPO/bin/jsonc-edit" read "$1/cfg/opencode.json" | jq -c "$2"; }

LIVE='{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-5",
  "provider": { "anthropic": { "options": { "apiKey": "sk-live" } } },
  "mcp": { "docs": { "type": "remote", "url": "https://example.invalid/mcp" } },
  "agent": {
    "build":    { "model": "anthropic/claude-sonnet-5", "prompt": "BUILD PROMPT",
                  "tools": { "bash": false }, "permission": { "edit": "deny" } },
    "reviewer": { "description": "mine", "mode": "subagent", "model": "openai/gpt-5", "variant": "high" },
    "plain":    { "prompt": "no model here" }
  }
}'

# Saved with everything a hand-edited or imported profile could carry: its own
# prompts, tools and permissions, an agent the config does not have, and keys that
# are not models at all.
PROFILE='{"id":"p1","name":"Models only","targets":[{"file":"opencode","shape":"opencode",
  "manages":["model","small_model","agent"],
  "payload":{"model":"openai/gpt-5",
    "agent":{"build":{"model":"openai/gpt-5","variant":"high","prompt":"PROFILE PROMPT","tools":{"bash":true}},
             "newbie":{"model":"google/gemini-3-flash","prompt":"NEWBIE PROMPT","permission":{"bash":"allow"}}},
    "mcp":{"planted":{"type":"local","command":["/bin/true"]}},
    "provider":{"evil":{"options":{"baseURL":"https://example.invalid"}}}}}]}'
OTHER='{"id":"p2","name":"Other","targets":[{"file":"opencode","shape":"opencode",
  "manages":["model","small_model","agent"],
  "payload":{"model":"anthropic/claude-opus-5","agent":{"reviewer":{"model":"anthropic/claude-opus-5"}}}}]}'

echo "=== a switch changes models and nothing else ==="
D=$(mk only)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/original.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
printf '%s' "$OTHER"   | run "$D" save >/dev/null
is "the switch is made" "$(run "$D" apply p1 | jq -r .ok)" "true"
is "the base model is the profile's"    "$(live "$D" '.model')" '"openai/gpt-5"'
is "and so is build's model and effort" "$(live "$D" '.agent.build | [.model, .variant]')" '["openai/gpt-5","high"]'
is "build keeps its own prompt"         "$(live "$D" '.agent.build.prompt')" '"BUILD PROMPT"'
is "its own tools"                      "$(live "$D" '.agent.build.tools')" '{"bash":false}'
is "and its own permissions"            "$(live "$D" '.agent.build.permission')" '{"edit":"deny"}'
is "an agent the profile leaves alone loses only its pin" \
   "$(live "$D" '.agent.reviewer')" '{"description":"mine","mode":"subagent"}'
is "an agent with no model is untouched" "$(live "$D" '.agent.plain')" '{"prompt":"no model here"}'
is "an agent only the profile has gets its model and nothing more" \
   "$(live "$D" '.agent.newbie')" '{"model":"google/gemini-3-flash"}'
is "the config's agents keep their order" "$(live "$D" '.agent | keys_unsorted')" '["build","reviewer","plain","newbie"]'
is "MCP servers are the config's" "$(live "$D" '.mcp')" '{"docs":{"type":"remote","url":"https://example.invalid/mcp"}}'
is "and so are providers"         "$(live "$D" '.provider')" '{"anthropic":{"options":{"apiKey":"sk-live"}}}'
is "nothing reads as drift straight after" "$(run "$D" list | jq -c '[.effectiveProfileId, .drift]')" '["p1",false]'

echo "=== switching back and forth settles ==="
run "$D" apply p2 >/dev/null
is "the other profile pins reviewer" "$(live "$D" '.agent.reviewer')" '{"description":"mine","mode":"subagent","model":"anthropic/claude-opus-5"}'
is "and leaves build's prompt where it was" "$(live "$D" '.agent.build.prompt')" '"BUILD PROMPT"'
run "$D" apply p1 >/dev/null; first="$(live "$D" '.')"
run "$D" apply p2 >/dev/null; run "$D" apply p1 >/dev/null
is "the same profile writes the same file every time" "$(live "$D" '.')" "$first"

echo "=== undo puts back the bytes ==="
# Each switch backed up what it replaced, so the oldest backup holds the file as it
# was before any of them. The file has moved on since that backup was taken, so a
# plain revert to it is refused; --force is the terminal's way to go back anyway.
first_ts="$(run "$D" backups | jq -r 'last | .ts')"
is "going back past later switches is refused" "$(run "$D" revert "$first_ts" | jq -r .code)" "E_DRIFT"
is "unless it is forced"                       "$(run "$D" revert --force "$first_ts" | jq -r .ok)" "true"
cmp -s "$D/cfg/opencode.json" "$D/original.json" \
  && ok "and gives back the original file, byte for byte" \
  || no "and gives back the original file, byte for byte" "$(diff "$D/original.json" "$D/cfg/opencode.json" | head -5 | tr '\n' ' ')"

echo "=== undo straight after a switch puts it back, and is undoable itself ==="
D=$(mk undo)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/original.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
run "$D" apply p1 >/dev/null
cp "$D/cfg/opencode.json" "$D/switched.json"
is "undo is made" "$(run "$D" revert | jq -r .ok)" "true"
cmp -s "$D/cfg/opencode.json" "$D/original.json" && ok "the file is as it was" || no "the file is as it was" "it is not"
is "undoing the undo is made" "$(run "$D" revert | jq -r .ok)" "true"
cmp -s "$D/cfg/opencode.json" "$D/switched.json" && ok "and the switch is back" || no "and the switch is back" "it is not"

echo "=== undo does not put a whole file back over edits made since the switch ==="
# Undo restores the whole file. Over a permission tightened after the switch, that
# would quietly loosen it again, along with any MCP server or key removed since.
run "$D" apply p1 >/dev/null 2>&1
"$REPO/bin/jsonc-edit" read "$D/cfg/opencode.json" | jq '.permission = {"bash":"ask"}' > "$D/edited.json"
cp "$D/edited.json" "$D/cfg/opencode.json"
before_n="$(ls -1d "$D/state/omarchy/opencode-configs/backups"/*/ | wc -l)"
is "undo is refused"              "$(run "$D" revert | jq -r .code)" "E_DRIFT"
cmp -s "$D/cfg/opencode.json" "$D/edited.json" && ok "the edit stays" || no "the edit stays" "it was undone"
is "and no backup is left behind" "$(ls -1d "$D/state/omarchy/opencode-configs/backups"/*/ | wc -l)" "$before_n"
rm -f "$D/cfg/opencode.json"
is "a deleted config is not brought back either" "$(run "$D" revert | jq -r .code)" "E_DRIFT"
[ ! -e "$D/cfg/opencode.json" ] && ok "and it stays deleted" || no "and it stays deleted" "it was recreated"

echo "=== a backup an earlier version took, with no record of what it wrote, is not put back blind ==="
D=$(mk older)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
run "$D" apply p1 >/dev/null
M="$(ls -1d "$D/state/omarchy/opencode-configs/by-config"/*/backups/*/ | tail -1)meta.json"
jq '.files |= map(del(.written))' "$M" > "$D/meta" && cp "$D/meta" "$M"
cp "$D/cfg/opencode.json" "$D/switched.json"
is "it is refused"              "$(run "$D" revert | jq -r .code)" "E_DRIFT"
is "and says why"               "$(run "$D" revert | jq -r '.message | test("earlier version")')" "true"
cmp -s "$D/cfg/opencode.json" "$D/switched.json" && ok "and the file is untouched" || no "and the file is untouched" "it was written"

echo "=== a switch that would write nothing is refused ==="
D=$(mk nothing)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
is "the refusal names it"   "$(OC_MANAGE_OPENCODE=0 run "$D" apply p1 | jq -r .code)" "E_NOTHING_TO_APPLY"
is "no profile became active" "$(run "$D" list | jq -r '.state.activeProfileId')" "null"
is "and Undo points nowhere new" "$(run "$D" list | jq -r '.state.lastBackup')" "null"

echo "=== a model or effort that is not one stops the switch ==="
D=$(mk gate)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/before.json"
printf '%s' '{"id":"s","name":"S","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],
  "payload":{"model":"openai/gpt-5","small_model":"gpt-5-mini"}}]}' | run "$D" save >/dev/null
printf '%s' '{"id":"v","name":"V","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],
  "payload":{"agent":{"build":{"model":"openai/gpt-5","variant":{"effort":"max"}}}}}]}' | run "$D" save >/dev/null
printf '%s' '{"id":"o","name":"O","targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],
  "payload":{"model":{"provider":"openai"}}}]}' | run "$D" save >/dev/null
is "a small model without a provider" "$(run "$D" apply s | jq -r .code)" "E_MODEL_SYNTAX"
is "an effort that is not a string"   "$(run "$D" apply v | jq -r .code)" "E_MODEL_SYNTAX"
is "a model that is not a string"     "$(run "$D" apply o | jq -r .code)" "E_MODEL_SYNTAX"
cmp -s "$D/cfg/opencode.json" "$D/before.json" && ok "and the file is untouched" || no "and the file is untouched" "it was written"

echo "=== a switch the store cannot record is put back ==="
D=$(mk store)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/before.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
S="$(dirname "$(find "$D/state" -name profiles.json | head -1)")"
chmod 500 "$S"
out="$(run "$D" apply p1)"; rc=$?
chmod 700 "$S"
is "it says so"                     "$(jq -r .code <<<"$out")" "E_STORE"
is "as a write that was put back"   "$rc" "3"
cmp -s "$D/cfg/opencode.json" "$D/before.json" && ok "and the config is as it was" || no "and the config is as it was" "the switch stayed"

echo "=== a config that will not read stops the switch ==="
D=$(mk unread)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
printf '{ "model": "a/b", "agent": { "build": { "prompt": "x" ' > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/broken.json"
run "$D" apply p1 >/dev/null 2>&1
cmp -s "$D/cfg/opencode.json" "$D/broken.json" \
  && ok "the broken file is left exactly as it was" || no "the broken file is left exactly as it was" "it was written"

echo "=== a profile saved with an agent map brings back only models once the map is gone ==="
# Captured while build was allowed every shell command. The agent map was then dropped
# for a global "ask"; switching back must not bring the old allowance with it.
D=$(mk nomap)
printf '%s\n' '{"model":"anthropic/claude-sonnet-5","agent":{"build":{"model":"openai/gpt-5","prompt":"OLD PROMPT","permission":{"bash":"allow"}}}}' > "$D/cfg/opencode.json"
run "$D" capture Old old >/dev/null
is "the capture holds the old allowance" \
   "$(run "$D" list | jq -c '.profiles[] | select(.id=="old") | .targets[0].payload.agent.build.permission')" '{"bash":"allow"}'
printf '%s\n' '{"model":"anthropic/claude-sonnet-5","permission":{"bash":"ask"}}' > "$D/cfg/opencode.json"
is "the switch is made"                    "$(run "$D" apply old | jq -r .ok)" "true"
is "build gets its model and nothing else" "$(live "$D" '.agent')" '{"build":{"model":"openai/gpt-5"}}'
is "the global policy is still ask"        "$(live "$D" '.permission')" '{"bash":"ask"}'

echo "=== an agent map that is not an object is refused, not written over ==="
printf '%s\n' '{"model":"anthropic/claude-sonnet-5","agent":["build"]}' > "$D/cfg/opencode.json"
cp "$D/cfg/opencode.json" "$D/listmap.json"
is "the switch is refused" "$(run "$D" apply old 2>/dev/null | jq -r .code)" "E_AGENT_SHAPE"
cmp -s "$D/cfg/opencode.json" "$D/listmap.json" \
  && ok "and the file is left exactly as it was" || no "and the file is left exactly as it was" "it was written"

echo "=== updating a profile keeps what the capture does not cover ==="
D=$(mk update)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
printf '%s' '{"id":"keep","name":"Keep","shortName":"KP","description":"my words",
  "targets":[{"file":"opencode","shape":"opencode","manages":["model","small_model","agent"],"payload":{"model":"a/b"}},
             {"file":"ohmy","shape":"oh-my-openagent","manages":["agents","categories"],
              "payload":{"agents":{"oracle":{"model":"anthropic/claude-opus-5"}},"categories":{}}}]}' \
  | run "$D" save >/dev/null
created="$(run "$D" list | jq -r '.profiles[] | select(.id=="keep") | .createdAt')"
sleep 1
OC_PROFILE_ID=keep OC_PROFILE_NAME=Keep run "$D" capture >/dev/null
after="$(run "$D" list | jq -c '.profiles[] | select(.id=="keep")')"
is "its short name"        "$(jq -r .shortName <<<"$after")" "KP"
is "its description"       "$(jq -r .description <<<"$after")" "my words"
is "when it was made"      "$(jq -r .createdAt <<<"$after")" "$created"
is "the live models are recaptured" \
   "$(jq -r '.targets[] | select(.file=="opencode") | .payload.model' <<<"$after")" "anthropic/claude-sonnet-5"
is "and the half that was not read this time is still there" \
   "$(jq -r '.targets[] | select(.file=="ohmy") | .payload.agents.oracle.model' <<<"$after")" "anthropic/claude-opus-5"
is "the list keeps one profile under that id" "$(run "$D" list | jq '[.profiles[] | select(.id=="keep")] | length')" "1"

echo "=== backups list under a home folder with a space in it ==="
H="$ROOT/home with space"; mkdir -p "$H/cfg"
printf '%s\n' "$LIVE" > "$H/cfg/opencode.json"
runh(){ HOME="$H" XDG_STATE_HOME="$H/state" OPENCODE_CONFIG_DIR="$H/cfg" XDG_CACHE_HOME="$H/cache" \
        OMO_CONFIG_HOME="$H/omo" OC_AUTO_RELOAD=0 OC_MANAGE_OHMY=0 "$OC" "$@"; }
printf '%s' "$PROFILE" | runh save >/dev/null
printf '%s' "$OTHER"   | runh save >/dev/null
runh apply p1 >/dev/null; runh apply p2 >/dev/null
B="$(runh backups 2>/dev/null)"
is "both switches are listed" "$(jq -r 'length' <<<"$B" 2>/dev/null)" "2"
is "newest first, each by its timestamp" \
   "$(jq -r '[.[].toProfileId] | join(",")' <<<"$B" 2>/dev/null)" "p2,p1"
is "and the path each one came from is whole" \
   "$(jq -r '.[0].files[0].path' <<<"$B" 2>/dev/null)" "$H/cfg/opencode.json"
is "undo from there works too" "$(runh revert | jq -r .activeProfileId)" "p1"

echo "=== pruning deletes the oldest backup, also within one second ==="
D=$(mk prune)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
printf '%s' "$PROFILE" | run "$D" save >/dev/null
BK="$D/state/omarchy/opencode-configs/by-config/$(printf '%s' "$D/cfg" | sha256sum | cut -c1-12)/backups"
for n in 2020-01-01T00-00-00Z 2020-01-01T00-00-00Z-2; do
  mkdir -m 700 "$BK/$n"
  printf '{"ts":"%s","fromProfileId":null,"toProfileId":null,"files":[]}' "$n" > "$BK/$n/meta.json"
done
OC_BACKUPS_KEEP=2 run "$D" apply p1 >/dev/null
[ -d "$BK/2020-01-01T00-00-00Z-2" ] && ok "the later of two same-second backups is kept" \
  || no "the later of two same-second backups is kept" "it was deleted"
[ -d "$BK/2020-01-01T00-00-00Z" ] && no "and the earlier one is the one deleted" "it is still there" \
  || ok "and the earlier one is the one deleted"
is "the newest is listed first" "$(run "$D" backups | jq -r '.[1].ts')" "2020-01-01T00-00-00Z-2"

echo "=== the first profile can come from a commented .jsonc ==="
D=$(mk seed)
cat > "$D/cfg/opencode.jsonc" <<'JSONC'
// my opencode
{
  "$schema": "https://opencode.ai/config.json",
  /* the default */ "model": "anthropic/claude-sonnet-5", // trailing
  "agent": { "build": { "model": "openai/gpt-5", }, },
}
JSONC
is "seed answers ok" "$(run "$D" seed | jq -r .ok)" "true"
is "and the profile holds the commented file's models" \
   "$(run "$D" list | jq -c '[.profiles[0].targets[] | select(.file=="opencode") | .payload | .model, .agent.build.model]')" \
   '["anthropic/claude-sonnet-5","openai/gpt-5"]'

echo "=== an opencode binary others could have replaced is not run ==="
D=$(mk resolver)
printf '%s\n' "$LIVE" > "$D/cfg/opencode.json"
mkdir -p "$D/bin"
cat > "$D/bin/opencode" <<'SH'
#!/usr/bin/bash
[ "${1:-}" = "--version" ] && echo 9.9.9-canary
exit 0
SH
chmod 0755 "$D/bin/opencode"
is "a private one is run" "$(OPENCODE_BIN="$D/bin/opencode" run "$D" detect | jq -r .opencodeVersion)" "9.9.9-canary"
chmod 0775 "$D/bin/opencode"
got="$(OPENCODE_BIN="$D/bin/opencode" PATH=/usr/bin:/bin run "$D" detect | jq -r .opencodeVersion)"
[ "$got" != "9.9.9-canary" ] && ok "a group-writable one is not (got: $got)" || no "a group-writable one is not" "it was run"
chmod 0757 "$D/bin/opencode"
got="$(OPENCODE_BIN="$D/bin/opencode" PATH=/usr/bin:/bin run "$D" detect | jq -r .opencodeVersion)"
[ "$got" != "9.9.9-canary" ] && ok "nor a world-writable one (got: $got)" || no "nor a world-writable one" "it was run"
chmod 0755 "$D/bin/opencode"; ln -s "$D/bin/opencode" "$D/bin/opencode-link"
is "a link to a private one resolves to it" \
   "$(OPENCODE_BIN="$D/bin/opencode-link" run "$D" detect | jq -r .opencodeVersion)" "9.9.9-canary"

echo "=== a model list stopped halfway leaves the old one ==="
S="$ROOT/sync"; mkdir -p "$S/bin" "$S/cache/omarchy/oliwier.opencode-configs"
CACHE="$S/cache/omarchy/oliwier.opencode-configs"
printf '%s\n' '{"version":1,"models":[{"id":"zen/kept"}]}' > "$CACHE/models.json"
cp "$CACHE/models.json" "$S/before.json"
cat > "$S/bin/curl" <<'SH'
#!/usr/bin/bash
sleep 30
SH
chmod +x "$S/bin/curl"
(
  cd "$S" || exit 1
  XDG_CACHE_HOME="$S/cache" PATH="$S/bin:/usr/bin:/bin" OPENCODE_BIN=/nonexistent FORCE=1 TTL=0 \
    exec "$REPO/bin/sync-models.sh" >/dev/null 2>&1
) &
pid=$!
sleep 1.5
kill -TERM "$pid" 2>/dev/null
wait "$pid"; rc=$?
is "it exits as a terminated run" "$rc" "143"
cmp -s "$CACHE/models.json" "$S/before.json" \
  && ok "and the list it had is still there, whole" || no "and the list it had is still there, whole" "it changed"
# The attempt is recorded before the download starts — a failed or stopped one still
# counts against the retry clock — so that marker is meant to be there.
left="$(find "$S/cache" -newer "$S/before.json" -type f ! -name models.json ! -name models.dev.attempt 2>/dev/null \
        | grep -v -e '\.lock$' | head -3)"
[ -z "$left" ] && ok "nothing half-written is left behind" || no "nothing half-written is left behind" "$left"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
