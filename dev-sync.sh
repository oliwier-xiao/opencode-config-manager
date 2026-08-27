#!/usr/bin/env bash
# Copy the working tree into the live plugin directory and report what the shell
# made of it. Copies rather than symlinks because the shell refuses a plugin
# folder containing one, and because writing into ~/.config/omarchy/plugins is
# itself the reload trigger — the inotify watch there picks the change up.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/oliwier.opencode-configs"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.git' --exclude 'dev-sync.sh' --exclude 'mark-preview.qml' \
  --exclude '*.md' --exclude '.gitignore' --exclude 'test' --exclude 'docs' \
  "$SRC/" "$DEST/"
chmod +x "$DEST/bin/oc-profiles" "$DEST/bin/sync-models.sh" "$DEST/bin/read-catalog" "$DEST/bin/jsonc-edit"

omarchy plugin validate "$DEST"

# rescanPlugins reloads plugin code, but a bar widget already mounted in a bar
# slot keeps its old instance — the change lands in the registry and not on the
# screen, which reads exactly like a bug in the change you just made. Restarting
# the shell is the only reliable way to see a BarWidget edit.
if [ "${QUICK:-0}" = 1 ]; then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 2
else
  omarchy-restart-shell >/dev/null 2>&1 &
  sleep 6
fi
echo "--- shell says ---"
journalctl --user --since "20 seconds ago" --no-pager 2>/dev/null \
  | grep -F "oliwier.opencode-configs" \
  | grep -vF "Handler was registered but will not be used" \
  | sed 's/.*omarchy-shell\[[0-9]*\]: //' \
  | sort -u \
  || echo "(quiet)"
