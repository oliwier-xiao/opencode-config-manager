#!/usr/bin/env bash
# test/baseline.sh: the marketplace's own Automated Security Baseline, run locally on
# what would be pushed. Adapted from tests/baseline.sh in oliwier-xiao/omarchy-auto-pilot4agents.
#
#   test/baseline.sh <folder holding the scanner modules>
#
# A listing update goes through this scan on its exact commit. Every commit of this plugin
# the marketplace has recorded came back `passed` with no finding and no capability, which
# is what makes an update verify without a maintainer having to accept anything. One
# reference to a package manager, a privilege wrapper or a service manager anywhere the
# scanner reads turns that into review-required, so this checks for exactly that result.
#
# The scanner is not vendored here. Fetch the seven modules once, pinned to the commit
# this was checked against, into any folder outside the repository:
#
#   REF=0ea26c19890d57be6dad8e7cf6a5e2a7071a7a54
#   for f in security-baseline-analysis.mjs security-baseline-policy.mjs security-baseline-scope.mjs \
#            security-baseline-limits.mjs security-baseline-error.mjs security-github-snapshot.mjs \
#            github-repository.mjs; do
#     gh api -H "Accept: application/vnd.github.raw" \
#       "repos/omacom/omarchy-plugin-marketplace/contents/scripts/$f?ref=$REF" > "$DIR/$f"
#   done
#
# test/run.sh runs this too when OC_MKT_SCRIPTS names that folder.
#
# The harness approximates resolveSecuritySnapshot's file selection (excluded folders,
# scanned extensions, extensionless and executable files, forced entry points) and prints
# the outcome, each finding and each capability with its evidence. Exit 0 when the outcome
# is passed with nothing to report, 1 when it is not, 2 when the scanner or node is missing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="${1:-}"
MODULES="security-baseline-analysis.mjs security-baseline-policy.mjs security-baseline-scope.mjs
security-baseline-limits.mjs security-baseline-error.mjs security-github-snapshot.mjs github-repository.mjs"

if [ -z "$SCANNER" ] || [ ! -d "$SCANNER" ]; then
  echo "baseline: pass the folder holding the scanner modules (see the header of this script)"
  exit 2
fi
for m in $MODULES; do
  if [ ! -s "$SCANNER/$m" ]; then
    echo "baseline: $SCANNER/$m is missing (see the header of this script)"
    exit 2
  fi
done
NODE="$(command -v node || true)"
if [ -z "$NODE" ]; then
  echo "baseline: node is required to run the scanner"
  exit 2
fi

W="$(mktemp -d "${TMPDIR:-/tmp}/oc-baseline.XXXXXX")" || exit 2
trap 'rm -rf "$W"' EXIT INT TERM
mkdir -p "$W/scripts" "$W/export"
for m in $MODULES; do cp "$SCANNER/$m" "$W/scripts/$m"; done

# The marketplace reads the pushed tree. Export what git tracks when this is a checkout,
# otherwise the working tree without caches.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO" archive --format=tar HEAD | tar -x -C "$W/export"
  SRC="git HEAD"
else
  (cd "$REPO" && find . -path ./.git -prune -o -path ./.codegraph -prune -o -path ./.omo -prune \
     -o -name __pycache__ -prune -o -type f -print) |
    while IFS= read -r f; do
      mkdir -p "$W/export/$(dirname "$f")"
      cp -p "$REPO/$f" "$W/export/$f"
    done
  SRC="working tree"
fi

REPO_NAME="$(/usr/bin/python3 -I -S -B -c '
import json, sys
home = json.load(open(sys.argv[1])).get("homepage", "")
print("/".join(home.rstrip("/").split("/")[-2:]) if home.startswith("https://github.com/") else "owner/repo")
' "$REPO/manifest.json")"

cat >"$W/harness.mjs" <<'EOF'
import fs from "node:fs";
import path from "node:path";
import { detectElevatedCapabilities, detectUnsafeRemoteExecution } from "./scripts/security-baseline-analysis.mjs";
import { isSecurityScanPath } from "./scripts/security-baseline-scope.mjs";
import { isBinaryAssetPath } from "./scripts/security-github-snapshot.mjs";
const root = process.argv[2], repo = process.argv[3];
const excluded = new Set([".github", "coverage", "docs", "fixtures", "node_modules", "spec", "specs", "test", "tests"]);
const walk = (d, r = "") => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => e.name === ".git" ? [] :
  e.isDirectory() ? walk(path.join(d, e.name), r ? `${r}/${e.name}` : e.name) :
  e.isFile() ? [{ abs: path.join(d, e.name), path: r ? `${r}/${e.name}` : e.name }] : []);
let manifest = {};
try { manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8")); } catch {}
const forced = new Set(Object.values(manifest.entryPoints || {}));
const files = walk(root).flatMap((f) => {
  const mode = (fs.statSync(f.abs).mode & 0o111) ? "100755" : "100644";
  const parts = f.path.toLowerCase().split("/");
  if (parts.slice(0, -1).some((x) => excluded.has(x)) && !forced.has(f.path)) return [];
  if (!(isSecurityScanPath(f.path) || mode === "100755" || !parts.at(-1).includes(".") || forced.has(f.path))) return [];
  if (isBinaryAssetPath(f.path) && mode !== "100755") return [];
  return [{ path: f.path, content: fs.readFileSync(f.abs, "utf8"), mode, binary: false }];
});
const findings = detectUnsafeRemoteExecution(files, repo), caps = detectElevatedCapabilities(files, repo);
console.log("SCANNED:", files.length, "files");
console.log("OUTCOME:", findings.length ? "needs-fixes" : caps.length ? "review-required" : "passed");
for (const x of findings) console.log("FINDING", x.ruleId, JSON.stringify(x.evidence));
for (const c of caps) console.log("CAP", c.id, JSON.stringify(c.evidence.map((e) => `${e.path}:${e.line} ${String(e.snippet).slice(0, 100)}`)));
EOF

echo "=== marketplace security baseline ($SRC, scanner in $SCANNER) ==="
OUT="$(cd "$W" && "$NODE" harness.mjs "$W/export" "$REPO_NAME" 2>&1)"; NRC=$?
printf '%s\n' "$OUT"
if [ "$NRC" -ne 0 ]; then
  echo "FAIL  the scanner did not run (exit $NRC)"
  exit 1
fi
fail=0
printf '%s\n' "$OUT" | grep -qx 'OUTCOME: passed' || { echo "FAIL  outcome is not passed"; fail=1; }
if printf '%s\n' "$OUT" | grep -q '^FINDING'; then echo "FAIL  the scanner reports findings"; fail=1; fi
if printf '%s\n' "$OUT" | grep -q '^CAP'; then echo "FAIL  the scanner reports capabilities a maintainer would have to accept"; fail=1; fi
if [ "$fail" -eq 0 ]; then
  echo "PASS  passed, no finding, no capability"
  exit 0
fi
exit 1
