#!/usr/bin/env bash
# Every suite here runs against a temporary config directory. None of them reads or
# writes the config you actually use — that is checked, not assumed: see the guard
# at the end.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

before=""
for f in "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/oh-my-openagent.json" \
         "$HOME/.omo/omo.jsonc"; do
  [ -f "$f" ] && before="$before$(sha256sum "$f")"
done

rc=0
for suite in "bash $REPO/test/safe-read.test.sh" \
             "bash $REPO/test/hardening.test.sh" \
             "node $REPO/test/model.test.js" \
             "python3 $REPO/test/jsonc.test.py" \
             "bash $REPO/test/detect.test.sh" \
             "bash $REPO/test/write.test.sh" \
             "bash $REPO/test/sync.test.sh" \
             "bash $REPO/test/qml.test.sh" \
             "bash $REPO/test/match.test.sh"; do
  printf '\n=== %s\n' "${suite##*/}"
  $suite || rc=1
done

after=""
for f in "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/opencode.json" \
         "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/oh-my-openagent.json" \
         "$HOME/.omo/omo.jsonc"; do
  [ -f "$f" ] && after="$after$(sha256sum "$f")"
done

printf '\n=== your own config\n'
if [ "$before" = "$after" ]; then
  echo "  ok   untouched"
else
  echo "  FAIL a suite wrote to your real config"; rc=1
fi
exit $rc
