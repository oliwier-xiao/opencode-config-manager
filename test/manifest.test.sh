#!/usr/bin/env bash
# manifest.json, read the way the marketplace and the shell read it, and against itself.
#
# The marketplace validates the manifest's shape (scripts/build-catalog.mjs
# validateManifest) and nothing about its settings. Whether every entry in
# barWidget.schema has a default, whether that default is one of its own options, and
# whether the version in the manifest is the newest entry in the CHANGELOG are
# questions only this repository can ask — and a drift in any of them ships as a
# settings panel that shows one thing while the widget does another.
#
# Every rule in the program below is run twice: on the real manifest, which must come
# back clean, and on a copy broken in exactly that one way, which must not. A check
# that cannot fail is the thing this file exists to avoid writing.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
M="$REPO/manifest.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

# One jq program, one line per problem, nothing when the manifest is sound. The limits
# are the marketplace's own (build-catalog.mjs: id 128, name 120, version 64, author 120,
# description 500, license 120), and the allowed kinds are its closed set.
PROBLEMS='
def trim: gsub("^\\s+|\\s+$"; "");
. as $m
| ($m.barWidget // {}) as $w
| ($w.schema // []) as $schema
| ($w.defaults // {}) as $defaults
| (
    ("id","name","version","author","description")
      | select(($m[.] | type) != "string" or ($m[.] | trim | length) == 0)
      | "\(.) is required"
  ),
  ( {id:128, name:120, version:64, author:120, description:500, license:120} | to_entries[]
      | select(($m[.key] | type) == "string" and ($m[.key] | trim | length) > .value)
      | "\(.key) is \($m[.key] | trim | length) characters, over the marketplace limit of \(.value)" ),
  ( select(($m.schemaVersion | type) != "number" or $m.schemaVersion != 1) | "schemaVersion must be the number 1" ),
  ( select(($m.id | type) == "string" and (($m.id | test("^[a-z0-9][a-z0-9._-]*$") | not) or ($m.id | contains(".."))))
      | "id must be lowercase letters, digits, dot, dash and underscore" ),
  ( select(($m.id | type) == "string" and ($m.id | startswith("omarchy."))) | "the omarchy.* namespace is reserved" ),
  ( ($m.kinds // [])[] | select(. as $k | ["bar","bar-widget","menu","overlay","panel","service"] | index($k) | not)
      | "unsupported kind \(.)" ),
  ( ($m.kinds // [])[] | (if . == "bar-widget" then "barWidget" else . end) as $key
      | select(($m.entryPoints // {}) | has($key) | not) | "kind \(.) has no entry point (\($key))" ),
  ( ($w | select(has("defaultSection")) | .defaultSection) as $d
      | select(["left","center","right"] | index($d) | not)
      | "barWidget.defaultSection must be left, center or right" ),
  ( ($schema | map(.key) | sort) as $sk | ($defaults | keys) as $dk
      | ($sk - $dk)[] | "schema key \(.) has no entry in barWidget.defaults" ),
  ( ($schema | map(.key) | sort) as $sk | ($defaults | keys) as $dk
      | ($dk - $sk)[] | "barWidget.defaults key \(.) has no schema entry" ),
  ( ($schema | group_by(.key)[] | select(length > 1) | "schema key \(.[0].key) appears \(length) times") ),
  ( $schema[] | select((has("key") and has("type") and has("label") and has("defaultValue") and has("description")) | not)
      | "schema entry \(.key // "?") lacks one of key, type, label, defaultValue, description" ),
  ( $schema[] | select(has("key") and has("defaultValue") and ($defaults[.key] != .defaultValue))
      | "\(.key): barWidget.defaults says \($defaults[.key] | tojson), the schema says \(.defaultValue | tojson)" ),
  ( $schema[] | select(.type == "enum" and (.defaultValue as $d | ((.options // []) | index($d)) == null))
      | "\(.key): defaultValue \(.defaultValue | tojson) is not one of its options" ),
  ( $schema[] | select(.type == "enum" and ((.options // []) as $o | ($o | length) != ($o | unique | length)))
      | "\(.key): options are not distinct" ),
  ( $schema[] | select(.type == "integer"
        and (((.defaultValue | type) != "number") or (has("min") and .defaultValue < .min) or (has("max") and .defaultValue > .max)))
      | "\(.key): defaultValue \(.defaultValue | tojson) is not an integer inside min..max" ),
  ( $schema[] | select(.type == "boolean" and (.defaultValue | type) != "boolean") | "\(.key): defaultValue is not a boolean" ),
  ( $schema[] | select((.type == "string" or .type == "path") and (.defaultValue | type) != "string")
      | "\(.key): defaultValue is not a string" )
'
problems(){ jq -r "$PROBLEMS" "$1" 2>&1; }

echo "=== the manifest is sound ==="
OUT="$(problems "$M")"
[ -z "$OUT" ] && ok "no problems found" || no "no problems found" "$(printf '%s' "$OUT" | head -8)"
is "it parses as an object" "$(jq -r 'type' "$M" 2>/dev/null || echo unparsable)" "object"

echo "=== each check can fail ==="
# <name> <jq edit> <fragment the problem must contain>
broke(){ local name="$1" edit="$2" want="$3" out
  jq "$edit" "$M" > "$T/bad.json" 2>/dev/null || { no "$name" "the edit itself failed: $edit"; return; }
  out="$(problems "$T/bad.json")"
  case "$out" in *"$want"*) ok "$name" ;; *) no "$name" "wanted a problem containing: $want   got: ${out:-nothing}" ;; esac; }
K="$(jq -r '.barWidget.schema[] | select(.type=="integer") | .key' "$M" | head -1)"
E="$(jq -r '.barWidget.schema[] | select(.type=="enum") | .key' "$M" | head -1)"
B="$(jq -r '.barWidget.schema[] | select(.type=="boolean") | .key' "$M" | head -1)"
broke "a default with no schema entry"   '.barWidget.defaults.orphan = 1'                                 "orphan has no schema entry"
broke "a schema entry with no default"   "del(.barWidget.defaults.\"$K\")"                                 "$K has no entry in barWidget.defaults"
broke "a default that disagrees"         ".barWidget.defaults.\"$B\" = (.barWidget.defaults.\"$B\" | not)" "$B: barWidget.defaults says"
broke "an enum default outside options"  "(.barWidget.schema[] | select(.key==\"$E\")) |= (.defaultValue = \"nope\") | .barWidget.defaults.\"$E\" = \"nope\"" "not one of its options"
broke "an integer outside min..max"      "(.barWidget.schema[] | select(.key==\"$K\")) |= (.defaultValue = (.max + 1)) | .barWidget.defaults.\"$K\" = ((.barWidget.schema[] | select(.key==\"$K\") | .max) + 1)" "inside min..max"
broke "a boolean that is a string"       "(.barWidget.schema[] | select(.key==\"$B\")) |= (.defaultValue = \"true\") | .barWidget.defaults.\"$B\" = \"true\"" "not a boolean"
broke "a kind with no entry point"       '.kinds += ["service"]'                                           "kind service has no entry point"
broke "an unsupported kind"              '.kinds += ["widget"]'                                            "unsupported kind widget"
broke "an omarchy.* id"                  '.id = "omarchy.thing"'                                           "reserved"
broke "an upper-case id"                 '.id = "Oliwier.Thing"'                                           "id must be lowercase"
broke "a description over 500"           '.description = ("x" * 501)'                                      "over the marketplace limit"
broke "schemaVersion as a string"        '.schemaVersion = "1"'                                            "schemaVersion must be the number 1"
broke "a defaultSection off the bar"     '.barWidget.defaultSection = "top"'                               "defaultSection"
broke "a name that is only spaces"       '.name = "   "'                                                   "name is required"
broke "an id with .. in it"              '.id = "oliwier..configs"'                                        "id must be lowercase"
broke "a schema key given twice"         '.barWidget.schema += [.barWidget.schema[0]]'                     "appears 2 times"
broke "a schema entry with no description" '.barWidget.schema[0] |= del(.description)'                     "lacks one of key"
broke "enum options that repeat"         "(.barWidget.schema[] | select(.key==\"$E\")) |= (.options += [.options[0]])" "options are not distinct"
P="$(jq -r '.barWidget.schema[] | select(.type=="path" or .type=="string") | .key' "$M" | head -1)"
if [ -n "$P" ]; then
  broke "a path default that is not a string" "(.barWidget.schema[] | select(.key==\"$P\")) |= (.defaultValue = 0) | .barWidget.defaults.\"$P\" = 0" "not a string"
fi

echo "=== what the manifest points at is there ==="
MISSING=""
while IFS= read -r ep; do
  case "$ep" in /*|*..*|*\\*|*:*|"") MISSING="$MISSING [unsafe: $ep]"; continue ;; esac
  [ -f "$REPO/$ep" ] || MISSING="$MISSING $ep"
done < <(jq -r '.entryPoints // {} | .[]' "$M")
[ -z "$MISSING" ] && ok "every entry point is a file in the tree" || no "every entry point is a file in the tree" "$MISSING"

VER="$(jq -r .version "$M")"
TOP="$(sed -n 's/^## \([0-9][0-9A-Za-z.+-]*\).*/\1/p' "$REPO/CHANGELOG.md" | head -1)"
is "the newest CHANGELOG.md entry is the manifest's version" "$TOP" "$VER"
ID="$(jq -r .id "$M")"; HOME_URL="$(jq -r .homepage "$M")"
grep -qF "omarchy plugin add $HOME_URL.git" "$REPO/README.md" \
  && ok "README installs from the manifest's homepage" || no "README installs from the manifest's homepage" "no 'omarchy plugin add $HOME_URL.git'"
for verb in update remove; do
  grep -qF "omarchy plugin $verb $ID" "$REPO/README.md" \
    && ok "README says how to $verb $ID" || no "README says how to $verb $ID" "no 'omarchy plugin $verb $ID'"
done

echo "=== no symlink anywhere a marketplace clone would see ==="
# The validator refuses a plugin folder holding one, in docs/ and test/ too, and
# .codegraph has been one before. The index is what the marketplace reads.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  LINKS="$(git -C "$REPO" ls-files -s | awk -F'\t' '$1 ~ /^120000/ {print $2}')"
else
  LINKS="$(find "$REPO" -path "$REPO/.git" -prune -o -type l -print)"
fi
[ -z "$LINKS" ] && ok "no tracked symlink" || no "no tracked symlink" "$(printf '%s' "$LINKS" | head -3)"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $pass passed"
[ "$fail" -eq 0 ]
