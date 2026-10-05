#!/usr/bin/env bash
# No secret on a command line. Every account on the machine can read every
# process's argv through /proc/<pid>/cmdline, so a config's provider keys and MCP
# tokens, and anything else read out of a config or a profile, must reach the
# helpers on stdin or through a pipe — never as an argument.
#
# Through 1.5.1 they did not: the E_BARE_AGENT_STRING repair handed jsonc-edit the
# whole opencode.json as `--payload`, and several jq calls carried profile payloads
# and agent entries as `--argjson`. The temp-file checks in hardening.test.sh could
# not see that; this suite records the argv of every command each verb starts and
# fails on any that carries a planted secret.
#
# Not secrets only. What the user named — a profile, an agent — and the folder they
# work in are theirs too, and a name or a path on a command line is as readable as a
# key. Each of those gets a canary of its own below.
#
# Two recorders, because each covers what the other might not:
#   shims   a directory at the front of PATH holding a logging wrapper for every
#           command the scripts run by name. The python helpers name their
#           interpreter absolutely, so the scripts are run from a copy of bin/ in
#           which each helper is a wrapper that records its argv and then runs the
#           real one. Runs everywhere.
#   strace  every execve(2) of the whole process tree, whatever started it. Used
#           when strace is installed and allowed to trace; skipped, and said so,
#           when it is not.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

# Minted per run and kept off this file, for the reason hardening.test.sh gives:
# a literal in the source would be "found" in any checkout that happens to sit
# where a search looks. Each one names where it was planted, so a hit says which
# path leaked rather than only that something did.
SALT="$$${RANDOM}${RANDOM}"
K_PROVIDER="sk-ant-PROVIDER-$SALT"
K_MCP="mcp-BEARER-$SALT"
K_AUTH="sk-AUTHJSON-$SALT"
K_HOME="sk-HOMECFG-$SALT"
K_OMO="sk-OMOPLUGIN-$SALT"
K_AGENT="PROMPT-INSIDE-AN-AGENT-$SALT"
K_PROFILE="PROMPT-INSIDE-A-PROFILE-$SALT"
K_PASTED="sk-PASTED-INTO-A-MODEL-FIELD-$SALT"
K_NAME="NAME-OF-A-PROFILE-$SALT"
K_TYPED="NAME-TYPED-IN-THE-PANEL-$SALT"
K_AGENTNAME="agent-named-by-the-user-$SALT"
K_PROJECT="project-folder-$SALT"
CANARIES=("$K_PROVIDER" "$K_MCP" "$K_AUTH" "$K_HOME" "$K_OMO" "$K_AGENT" "$K_PROFILE" "$K_PASTED"
          "$K_NAME" "$K_TYPED" "$K_AGENTNAME" "$K_PROJECT")

# ---------------------------------------------------------------- the shims

SHIMS="$ROOT/shims"; mkdir -p "$SHIMS"
LOG="$ROOT/argv.log"; : > "$LOG"
ENVLOG="$ROOT/env.log"; : > "$ENVLOG"
cat > "$SHIMS/.shim" <<'SHIM'
#!/bin/bash
# Records this command's argv, then becomes the real command. printf is a builtin,
# so recording the arguments does not put them on another command line.
name="${0##*/}"
{ printf '%s\037' "$name" "$@"; printf '\n'; } >> "$ARGV_LOG"
# And which commands were handed the panel's profile in their environment.
if [ -n "${ARGV_ENVLOG:-}" ] && [ -n "${OC_PROFILE_JSON+x}${OC_PREFS_JSON+x}" ]; then
  printf '%s\n' "$name" >> "$ARGV_ENVLOG"
fi
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ "$d" = "$ARGV_SHIMS" ] && continue
  [ -x "$d/$name" ] && [ ! -d "$d/$name" ] && exec "$d/$name" "$@"
done
printf 'argv shim: %s not found\n' "$name" >&2
exit 127
SHIM
chmod +x "$SHIMS/.shim"
# Every command the scripts start by name, and the interpreters their helpers are
# started through. Builtins (printf, echo, kill, [) never reach exec and need none.
for c in jq python3 python bash sh env awk gawk sed grep head tail cut tr sort uniq wc \
         cat tee sha256sum date mktemp rm mv cp ln ls mkdir chmod basename dirname \
         readlink realpath stat find flock pgrep timeout sleep xargs opencode \
         notify-send curl seq od; do
  command -v "$c" >/dev/null 2>&1 && ln -s .shim "$SHIMS/$c"
done

# The scripts, beside wrappers for the python helpers they start by path. Each wrapper
# records its argv the way the shims do and then runs the real helper, which sits in a
# folder of its own with its siblings (jsonc-edit loads safe-read from beside itself).
BIN="$ROOT/bin"; REAL="$ROOT/real"; mkdir -p "$BIN" "$REAL"
cp -a "$REPO/bin/." "$REAL/"
rm -rf "$REAL/__pycache__"
for h in oc-profiles sync-models.sh read-catalog read-templates run-bounded; do cp -a "$REAL/$h" "$BIN/$h"; done
for h in safe-read safe-write private-dir jsonc-edit; do
  cat > "$BIN/$h" <<WRAP
#!/bin/bash
{ printf '%s\037' "$h" "\$@"; printf '\n'; } >> "\$ARGV_LOG"
exec /usr/bin/python3 "$REAL/$h" "\$@"
WRAP
  chmod +x "$BIN/$h"
done
OC="$BIN/oc-profiles"

# ---------------------------------------------------------------- the world

mk(){ local d="$ROOT/$1"; rm -rf "$d"
  mkdir -p "$d/cfg" "$d/omo" "$d/cache" "$d/state" "$d/data/opencode" "$d/home/.opencode"
  # Every place a secret lives in a real setup, one canary each. `build` is a bare
  # string — the shape E_BARE_AGENT_STRING repairs, and the path that leaked.
  cat > "$d/cfg/opencode.json" <<J
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-5",
  "provider": { "anthropic": { "options": { "apiKey": "$K_PROVIDER" } } },
  "mcp": { "remote": { "type": "remote", "url": "https://mcp.example.invalid",
                       "headers": { "Authorization": "Bearer $K_MCP" } } },
  "agent": {
    "build": "anthropic/claude-sonnet-5",
    "plan": { "model": "anthropic/claude-opus-5", "prompt": "$K_AGENT" },
    "$K_AGENTNAME": "anthropic/claude-haiku-4-5"
  }
}
J
  # A project of the user's own, with a config of its own: detect walks up from the
  # folder it was started in and reports it.
  mkdir -p "$d/home/$K_PROJECT/.opencode"
  printf '{"model":"anthropic/claude-haiku-4-5"}' > "$d/home/$K_PROJECT/.opencode/opencode.json"
  # The unified oh-my-openagent config, holding all three shapes its repairs fix,
  # beside a key of its own that is none of this plugin's business.
  cat > "$d/omo/omo.jsonc" <<J
{
  // a comment the repairs have to keep
  "[opencode]": {
    "fallback_models": ["anthropic/claude-opus-5"],
    "agents": {
      "sisyphus": { "models": ["anthropic/claude-opus-5", "google/gemini-3.1-pro-preview"] },
      "oracle": { "model": "anthropic/claude-opus-5", "prompt_append": "$K_AGENT" }
    },
    "categories": { "deep": { "model": "anthropic/claude-opus-5" } },
    "websearch": { "apiKey": "$K_OMO" }
  }
}
J
  printf '{"anthropic":{"type":"api","key":"%s"}}' "$K_AUTH" > "$d/data/opencode/auth.json"
  printf '{"provider":{"openai":{"options":{"apiKey":"%s"}}}}' "$K_HOME" > "$d/home/.opencode/opencode.json"
  printf '%s' "$d"; }

# HOME as well as the XDG roots: the ~/.opencode config is read from $HOME, and a
# real one there would put the user's own keys into this log.
run(){ local d="$1"; shift
  HOME="$d/home" OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
  XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" XDG_DATA_HOME="$d/data" \
  OC_AUTO_RELOAD=0 ARGV_LOG="$LOG" ARGV_ENVLOG="$ENVLOG" ARGV_SHIMS="$SHIMS" PATH="$SHIMS:$PATH" \
  "$OC" "$@"; }

# One profile carrying a secret-shaped value inside a managed key, and one whose
# model field holds a pasted key — the value E_MODEL_SYNTAX quotes back.
PROFILE_JSON="$(jq -cn --arg p "$K_PROFILE" --arg n "$K_NAME" '{id:"carried", name:$n, targets:[
  {file:"opencode", shape:"opencode", manages:["model","small_model","agent"],
   payload:{model:"anthropic/claude-opus-5",
            agent:{build:{model:"anthropic/claude-opus-5", prompt:$p}}}},
  {file:"ohmy", shape:"oh-my-openagent", manages:["agents","categories"],
   payload:{agents:{sisyphus:{models:["anthropic/claude-opus-5"], prompt_append:$p}}}}]}')"
PASTED_JSON="$(jq -cn --arg k "$K_PASTED" '{id:"pasted", name:"Pasted", targets:[
  {file:"opencode", shape:"opencode", manages:["model"], payload:{model:$k}}]}')"

# ---------------------------------------------------------------- the recorder can fail

echo "=== the recorder sees what it is there to see ==="
D=$(mk control)
HOME="$D/home" ARGV_LOG="$LOG" ARGV_SHIMS="$SHIMS" PATH="$SHIMS:$PATH" \
  jq -cn --arg leak "$K_PROVIDER" '1' >/dev/null
grep -qF "$K_PROVIDER" "$LOG" && ok "a secret passed as an argument is caught" \
  || no "a secret passed as an argument is caught" "the shims recorded nothing"
: > "$LOG"

# ---------------------------------------------------------------- every verb

echo "=== every verb, with secrets planted everywhere they live ==="
D=$(mk verbs)
# Each verb's answer is checked for the one thing that proves it got as far as the
# code that handles the secrets: a verb that refused at the door has nothing to leak.
says(){ local want="$1" name="$2"; shift 2
  local out; out="$("$@" 2>/dev/null)"
  is "$name" "$(printf '%s' "$out" | jq -r "$want" 2>/dev/null || echo unparsable)" "true"; }
says '.ok'                      "detect answers"                 run "$D" detect
says 'has("profiles")'          "list answers"                   run "$D" list
says '.seeded'                  "seed captures the live config"  run "$D" seed
says '.ok'                      "capture saves it again"         run "$D" capture "Mine" mine
detect_in_project(){ ( cd "$D/home/$K_PROJECT" && run "$D" detect ); }
says '.ok'                      "detect answers from inside a project" detect_in_project
OC_PROFILE_JSON="$PROFILE_JSON" says '.ok' "save takes a profile from the environment" run "$D" save
save_stdin(){ printf '%s' "$PROFILE_JSON" | run "$D" save; }
says '.ok'                      "save takes one on stdin"        save_stdin
OC_PREFS_JSON='{"favorites":["anthropic/claude-opus-5"],"recents":[]}' \
  says '.ok'                    "prefs are saved"                run "$D" prefs
says '.ok'                      "doctor answers"                 run "$D" doctor
says '.dryRun'                  "the bare-string repair dry-runs"   run "$D" repair --fix E_BARE_AGENT_STRING
# Two bare strings: `build`, and the agent the user named.
says '.fixed == 2'              "and applies"                    run "$D" repair --fix E_BARE_AGENT_STRING --apply
says '.dryRun'                  "the live-models repair dry-runs"   run "$D" repair --fix E_MODELS_IN_CONFIG
says '.fixed == 1'              "and applies"                    run "$D" repair --fix E_MODELS_IN_CONFIG --apply
says '.dryRun'                  "the file-fallback repair dry-runs" run "$D" repair --fix E_FILE_FALLBACK
says '.fixed == 1'              "and applies"                    run "$D" repair --fix E_FILE_FALLBACK --apply
says '.dryRun'                  "the profile repair dry-runs"    run "$D" repair --fix E_MODELS_IN_PROFILE --profile carried
says '.fixed == 1'              "and applies"                    run "$D" repair --fix E_MODELS_IN_PROFILE --profile carried --apply
says '.ok'                      "the profile applies"            run "$D" apply carried
# The panel's way: what the user typed rides in the environment, never in argv.
OC_PROFILE_NAME="$K_TYPED" says '.ok' "capture takes a typed name from the environment" run "$D" capture
typed_id="$(run "$D" list 2>/dev/null | jq -r --arg n "$K_TYPED" '.profiles[] | select(.name == $n) | .id')"
OC_PROFILE_ID="$typed_id" says '.ok' "apply takes an id from the environment" run "$D" apply
OC_PROFILE_ID="$typed_id" says '.ok' "delete takes an id from the environment" run "$D" delete
says 'length > 0'               "backups lists them"             run "$D" backups
says '.ok'                      "revert puts the last one back"  run "$D" revert
says '.ok'                      "reload answers"                 run "$D" reload
OC_PROFILE_JSON="$PASTED_JSON" run "$D" save >/dev/null 2>&1
R=$(run "$D" apply pasted 2>/dev/null)
is "a key pasted into a model field is refused" "$(printf '%s' "$R" | jq -r '.code // "none"')" "E_MODEL_SYNTAX"

# The repairs have to have done their work, or this would be a suite of verbs that
# refused early and so had nothing to leak. The revert above put back the config the
# apply replaced — the one the three repairs had already rewritten.
is "the bare agent string was repaired" "$(jq -r '.agent.build | type' "$D/cfg/opencode.json")" "object"
is "the provider key is still in the config" \
   "$(jq -r '.provider.anthropic.options.apiKey' "$D/cfg/opencode.json")" "$K_PROVIDER"
J(){ "$REPO/bin/jsonc-edit" read "$D/omo/omo.jsonc" --scope '[opencode]' | jq -r "$1"; }
is "the live models were repaired"      "$(J '.agents.sisyphus.models // "gone"')" "gone"
is "the file-level fallback was removed" "$(J '.fallback_models // "gone"')" "gone"
is "the plugin's own key was left alone" "$(J '.websearch.apiKey')" "$K_OMO"
grep -qF "a comment the repairs have to keep" "$D/omo/omo.jsonc" \
  && ok "the comment survived three repairs" || no "the comment survived three repairs" "it did not"

# And the recorder has to have been in the path the payload takes: a jsonc-edit
# apply that was never recorded would make every check below pass by default.
grep -q $'jsonc-edit\037apply' "$LOG" && ok "jsonc-edit apply was recorded" \
  || no "jsonc-edit apply was recorded" "no record of it — the shims missed the write path"
grep -q $'^jq\037' "$LOG" && ok "jq was recorded" || no "jq was recorded" "no record of it"

# A profile handed over in the environment — which only this account can read — is
# unset once read, so the only command that may see it is the one that starts
# oc-profiles itself: the timebox it re-runs itself under. Through 1.5.1 every jq,
# python3 and flock it started had it too. (The panel itself now pipes the profile
# in on stdin; the environment is still accepted from a terminal.)
echo "=== the environment hand-off stops at oc-profiles ==="
seen="$(sort -u "$ENVLOG" | tr '\n' ' ')"
case " $seen " in
  *" timeout "*) ok "the hand-off reached oc-profiles" ;;
  *) no "the hand-off reached oc-profiles" "seen by: ${seen:-nothing}" ;;
esac
others="$(sort -u "$ENVLOG" | grep -vx -e bash -e timeout | tr '\n' ' ')"
[ -z "$others" ] && ok "and nothing oc-profiles started inherited it" \
  || no "and nothing oc-profiles started inherited it" "also handed to: $others"

echo "=== no command line carried a secret ==="
for c in "${CANARIES[@]}"; do
  hit="$(grep -F -- "$c" "$LOG" | head -1 | tr '\037' ' ' | cut -c1-240)"
  [ -z "$hit" ] && ok "argv never held ${c%-$SALT}" || no "argv never held ${c%-$SALT}" "$hit"
done

# ---------------------------------------------------------------- strace, when it can

echo "=== the same, seen by the kernel ==="
if ! command -v strace >/dev/null 2>&1; then
  printf '  skip every execve (strace is not installed)\n'
elif ! strace -f -qq -e trace=execve -o /dev/null true >/dev/null 2>&1; then
  printf '  skip every execve (strace is not allowed to trace here)\n'
else
  D=$(mk kernel)
  TRACE="$ROOT/execve.log"
  trace(){ local d="$1"; shift
    HOME="$d/home" OPENCODE_CONFIG_DIR="$d/cfg" OMO_CONFIG_HOME="$d/omo" \
    XDG_CACHE_HOME="$d/cache" XDG_STATE_HOME="$d/state" XDG_DATA_HOME="$d/data" \
    OC_AUTO_RELOAD=0 strace -f -qq -s 1048576 -e trace=execve -o "$TRACE.$#.$RANDOM" "$OC" "$@"; }
  trace "$D" detect >/dev/null 2>&1
  trace "$D" capture "Mine" mine >/dev/null 2>&1
  OC_PROFILE_NAME="$K_TYPED" trace "$D" capture >/dev/null 2>&1
  ( cd "$D/home/$K_PROJECT" && trace "$D" detect >/dev/null 2>&1 )
  OC_PROFILE_JSON="$PROFILE_JSON" trace "$D" save >/dev/null 2>&1
  trace "$D" doctor >/dev/null 2>&1
  trace "$D" repair --fix E_BARE_AGENT_STRING --apply >/dev/null 2>&1
  trace "$D" repair --fix E_MODELS_IN_CONFIG --apply >/dev/null 2>&1
  trace "$D" repair --fix E_FILE_FALLBACK --apply >/dev/null 2>&1
  trace "$D" repair --fix E_MODELS_IN_PROFILE --profile carried --apply >/dev/null 2>&1
  trace "$D" apply carried >/dev/null 2>&1
  trace "$D" revert >/dev/null 2>&1
  is "the traced repair landed" "$(jq -r '.agent.build | type' "$D/cfg/opencode.json")" "object"
  # Only the argument vector: strace prints the environment as a count unless asked
  # (-v), and the environment is the one place OC_PROFILE_JSON is meant to be.
  n=$(cat "$TRACE".* 2>/dev/null | grep -c 'execve(' || true)
  [ "${n:-0}" -gt 50 ] && ok "strace saw the process tree ($n execs)" \
    || no "strace saw the process tree" "only ${n:-0} execs recorded"
  for c in "${CANARIES[@]}"; do
    hit="$(cat "$TRACE".* 2>/dev/null | grep -F -- "$c" | head -1 | cut -c1-240)"
    [ -z "$hit" ] && ok "no execve carried ${c%-$SALT}" || no "no execve carried ${c%-$SALT}" "$hit"
  done
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
