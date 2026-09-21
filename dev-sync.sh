#!/usr/bin/env bash
# Put the working tree where the shell will load it, and report what the shell
# made of it.
#
# Two installs are in use and the script has to tell them apart before it writes
# anything:
#
#   copy    the plugin folder is a real directory. The tree is rsynced into it,
#           which is also the reload trigger — the shell watches that folder.
#   linked  the plugin folder is a symlink back to this checkout, so the working
#           tree already *is* the installed plugin. Nothing is copied, and above
#           all nothing under the plugin folder is deleted: every path under it
#           is a path in this repository, and `rm -rf "$DEST/.omo"` there is
#           `rm -rf` on your own work.
set -euo pipefail

# -P, because the comparison below is between real paths: run through the
# symlinked plugin folder, a logical pwd would report that folder instead of
# the checkout and the two would never match.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DEST="$HOME/.config/omarchy/plugins/oliwier.opencode-configs"
DEST_REAL="$(readlink -f "$DEST" 2>/dev/null || true)"

if [ "$DEST_REAL" = "$SRC" ]; then
  mode=linked
elif [ -L "$DEST" ]; then
  echo "dev-sync: $DEST points at $DEST_REAL, which is not this checkout." >&2
  echo "dev-sync: refusing to sync into someone else's working tree." >&2
  exit 1
else
  mode=copy
fi

# One list, used for the install and for the tree the validator reads: a staging
# copy built from different excludes would be checking a plugin nobody ships.
EXCLUDES=(
  --exclude '.git' --exclude '.codegraph' --exclude '.omo'
  --exclude 'dev-sync.sh' --exclude 'mark-preview.qml'
  --exclude '*.md' --exclude '.gitignore' --exclude 'test' --exclude 'docs'
)

if [ "$mode" = copy ]; then
  mkdir -p "$DEST"
  # rsync protects an excluded name on the receiving side as well as on the sending
  # one, so adding an --exclude does not remove what an earlier run already put
  # there: the .codegraph symlink that fails `omarchy plugin validate` would stay in
  # the plugin folder for ever. --delete-excluded would clear it, and would also
  # clear `.git` — the destination is a git checkout, which is what
  # `omarchy plugin update` fetches and fast-forwards. So the two names are removed
  # by hand instead, and nothing else on the exclude list is touched. Safe here and
  # only here: in this branch $DEST is a directory of its own, not this repository
  # under another name.
  rm -rf "$DEST/.codegraph" "$DEST/.omo"
  rsync -a --delete "${EXCLUDES[@]}" "$SRC/" "$DEST/"
  chmod +x "$DEST"/bin/*
  omarchy plugin validate "$DEST"
else
  echo "dev-sync: $DEST is this checkout — nothing to copy."
  chmod +x "$SRC"/bin/*
  # The validator refuses a plugin folder that is a symlink, and refuses the
  # .codegraph symlink inside this one, so it cannot be pointed at either path.
  # It is run against a throwaway copy of exactly what a copy install receives
  # instead — dropping the check on a linked install would mean finding out
  # about a marketplace refusal at submission time.
  staging="$(mktemp -d)"
  trap 'rm -rf "$staging"' EXIT
  mkdir -p "$staging/oliwier.opencode-configs"
  rsync -a "${EXCLUDES[@]}" "$SRC/" "$staging/oliwier.opencode-configs/"
  omarchy plugin validate "$staging/oliwier.opencode-configs"
fi

# rescanPlugins reloads plugin code, but a bar widget already mounted in a bar
# slot keeps its old instance — the change lands in the registry and not on the
# screen, which reads exactly like a bug in the change you just made. Restarting
# the shell is the only reliable way to see a BarWidget edit. On a linked install
# it is the only way to see any edit at all: the folder watch does not follow the
# symlink, so a write in this checkout never reaches the shell by itself.
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
