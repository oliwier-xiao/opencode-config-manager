#!/usr/bin/env bash
# The shipped templates, checked against the catalogue they are meant to be picked from.
#
# A template is config this plugin writes into somebody's opencode on one click, and
# nothing was checking it. The two things that go wrong are the two things that are
# checked here: a model id that no longer exists, and an effort on a model that does
# not take one — the second being the exact shape that loads and then fails on the
# first request.
#
# The catalogue is the one the plugin builds for itself. Without it there is nothing
# to check against, so the model-level assertions skip rather than guess; the
# structural ones always run.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAT="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy/oliwier.opencode-configs/models.json"

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

T="$REPO/assets/templates.json"

echo "=== every template is shaped like a template ==="
python3 - "$T" <<'PY' && ok "structure, ids, names and declared shapes" || no "structure, ids, names and declared shapes" "see above"
import json,sys
d=json.load(open(sys.argv[1]))
ts=d["templates"]; seen=set(); bad=[]
for t in ts:
    for k in ("id","name","shortName","vendor","description","requires","shapes"):
        if not t.get(k): bad.append(f"{t.get('id','?')}: missing {k}")
    if t["id"] in seen: bad.append(f"duplicate id {t['id']}")
    seen.add(t["id"])
    if len(t.get("shortName","")) > 3: bad.append(f"{t['id']}: shortName too long for the bar")
    for shape in t["shapes"]:
        if shape not in t: bad.append(f"{t['id']}: declares shape {shape} and has no {shape} block")
    # Every provider a template names must be one it says it requires: the panel uses
    # `requires` to tell you which key is missing before it lets you apply the thing.
    ids=set()
    def walk(o):
        if isinstance(o,dict):
            for k,v in o.items():
                if k=="model" and isinstance(v,str): ids.add(v)
                else: walk(v)
        elif isinstance(o,list):
            for v in o: walk(v)
        elif isinstance(o,str) and "/" in o: ids.add(o)
    walk({k:t[k] for k in t["shapes"] if k in t})
    for p in sorted({i.split("/")[0] for i in ids}):
        if p not in t["requires"]:
            bad.append(f"{t['id']}: uses {p}/… but does not require {p}")
for b in bad: print("   ", b)
sys.exit(1 if bad else 0)
PY

echo "=== the free templates cost nothing, and say which key they need ==="
is "Free is OpenCode Zen only" \
   "$(jq -r '[.templates[]|select(.id=="free")|.requires[]]|join(",")' "$T")" "opencode"
is "and names no other provider" \
   "$(jq -r '[.templates[]|select(.id=="free")|.. |objects|.model?|select(.)]|map(split("/")[0])|unique|join(",")' "$T")" "opencode"
is "Free (OpenRouter) is OpenRouter only" \
   "$(jq -r '[.templates[]|select(.id=="free-openrouter")|.requires[]]|join(",")' "$T")" "openrouter"
is "and names no other provider" \
   "$(jq -r '[.templates[]|select(.id=="free-openrouter")|.. |objects|.model?|select(.)]|map(split("/")[0])|unique|join(",")' "$T")" "openrouter"
is "Budget is OpenRouter only" \
   "$(jq -r '[.templates[]|select(.id=="budget")|.. |objects|.model?|select(.)]|map(split("/")[0])|unique|join(",")' "$T")" "openrouter"

if [ ! -s "$CAT" ]; then
  echo "  skip the catalogue checks (no model cache on this machine — run bin/sync-models.sh)"
  printf '\n%d passed' "$pass"; [ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"; printf '\n'
  [ "$fail" -eq 0 ]; exit
fi

echo "=== every model a template names is one the catalogue has ==="
python3 - "$T" "$CAT" <<'PY' && ok "no template names a model that does not exist" || no "no template names a model that does not exist" "see above"
import json,sys
t=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2]))
ix={m["id"]:m for m in c["models"]}
bad=[]
for tpl in t["templates"]:
    ids=set()
    def walk(o):
        if isinstance(o,dict):
            for k,v in o.items():
                if k=="model" and isinstance(v,str): ids.add(v)
                else: walk(v)
        elif isinstance(o,list):
            for v in o: walk(v)
        elif isinstance(o,str) and "/" in o: ids.add(o)
    walk({k:tpl[k] for k in tpl["shapes"] if k in tpl})
    for i in sorted(ids):
        if i not in ix: bad.append(f"{tpl['id']}: {i} is not in the catalogue")
for b in bad: print("   ", b)
sys.exit(1 if bad else 0)
PY

echo "=== no template asks a model for an effort it does not offer ==="
# The one config this plugin can write that loads and then fails.
python3 - "$T" "$CAT" <<'PY' && ok "every effort is one its own model offers" || no "every effort is one its own model offers" "see above"
import json,sys
t=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2]))
ix={m["id"]:m for m in c["models"]}
bad=[]
def entries(o, out):
    if isinstance(o,dict):
        if isinstance(o.get("model"), str) and ("variant" in o or "reasoning" in o):
            out.append(o)
        for v in o.values(): entries(v, out)
    elif isinstance(o,list):
        for v in o: entries(v, out)
for tpl in t["templates"]:
    got=[]
    entries({k:tpl[k] for k in tpl["shapes"] if k in tpl}, got)
    for e in got:
        m=ix.get(e["model"])
        if not m: continue
        want=e.get("variant") or e.get("reasoning")
        if want and want not in (m.get("variants") or []):
            bad.append(f"{tpl['id']}: {e['model']} has no effort {want!r} (offers {m.get('variants')})")
for b in bad: print("   ", b)
sys.exit(1 if bad else 0)
PY

echo "=== the free templates really are free, and reachable here ==="
for id in free free-openrouter; do
  nonfree=$(python3 - "$T" "$CAT" "$id" <<'PY'
import json,sys
t=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2])); tid=sys.argv[3]
ix={m["id"]:m for m in c["models"]}
hit=[x for x in t["templates"] if x["id"]==tid]
if not hit:
    print("NO SUCH TEMPLATE: " + tid); sys.exit(0)
tpl=hit[0]
ids=set()
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=="model" and isinstance(v,str): ids.add(v)
            else: walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk({k:tpl[k] for k in tpl["shapes"] if k in tpl})
print(",".join(sorted(i for i in ids if i in ix and not ix[i]["free"])))
PY
)
  is "$id charges for nothing" "$nonfree" ""
done

echo "=== budget is ordered by what it costs ==="
# The thinking model may be the dearest in the set; nothing in it may cost more than
# the cheapest model in the tier above the whole budget idea.
python3 - "$T" "$CAT" <<'PY' && ok "no model in Budget costs more than \$0.20/M in" || no "no model in Budget costs more than \$0.20/M in" "see above"
import json,sys
t=json.load(open(sys.argv[1])); c=json.load(open(sys.argv[2]))
ix={m["id"]:m for m in c["models"]}
tpl=[x for x in t["templates"] if x["id"]=="budget"][0]
ids=set()
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=="model" and isinstance(v,str): ids.add(v)
            else: walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk({k:tpl[k] for k in tpl["shapes"] if k in tpl})
bad=[]
for i in sorted(ids):
    m=ix.get(i)
    if m and (m["inputCost"] or 0) > 0.20:
        bad.append(f"budget: {i} costs ${m['inputCost']}/M in")
for b in bad: print("   ", b)
sys.exit(1 if bad else 0)
PY

printf '\n%d passed' "$pass"
[ "$fail" -gt 0 ] && printf ', %d FAILED' "$fail"
printf '\n'
[ "$fail" -eq 0 ]
