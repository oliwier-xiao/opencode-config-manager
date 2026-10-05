#!/usr/bin/env bash
# bin/run-bounded: the only way the panel starts a helper. Whatever a helper does, the
# shell may receive at most the cap plus one byte on stdout and a fixed amount on
# stderr, and the helper — with everything it started — is gone by the deadline.
# Each case runs a stand-in under the real wrapper: run-bounded only starts helpers
# that sit beside it under a fixed name, so the stand-ins are put there in a copy.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

mkdir -p "$T/bin"
cp "$REPO/bin/run-bounded" "$T/bin/run-bounded"
RB="$T/bin/run-bounded"
stand_in(){ # <helper name> <bash body>
  printf '#!/usr/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

echo "=== an answer within the cap passes through as it is ==="
stand_in oc-profiles 'printf "%s\n" "{\"ok\":true,\"args\":\"$*\"}"; exit 0'
out="$("$RB" 10 4096 oc-profiles list 2>/dev/null)"; rc=$?
is "exit status is the helper's own" "$rc" "0"
is "the answer is untouched" "$out" '{"ok":true,"args":"list"}'
stand_in oc-profiles 'echo partial; exit 3'
"$RB" 10 4096 oc-profiles x >/dev/null 2>&1; is "and so is a failure's" "$?" "3"

echo "=== a helper that keeps printing is cut off and killed ==="
stand_in oc-profiles 'echo started > "'"$T"'/flood.pid"; while :; do printf "%01000d\n" 0; done'
bytes="$("$RB" 10 5000 oc-profiles x 2>/dev/null | wc -c)"; rc=${PIPESTATUS[0]}
is "no more than the cap plus one byte reaches the reader" "$bytes" "5001"
is "and the helper died of the closed pipe" "$rc" "141"

echo "=== stderr is capped too ==="
stand_in oc-profiles 'while :; do printf "%01000d\n" 0 >&2; done'
ebytes="$("$RB" 10 100 oc-profiles x 2>&1 >/dev/null | wc -c)"
[ "$ebytes" -le 16384 ] && ok "stderr stops at 16 KiB ($ebytes bytes)" || no "stderr stops at 16 KiB" "$ebytes bytes"

echo "=== the deadline ends the helper and everything it started ==="
stand_in oc-profiles 'sleep 300 & echo $! > "'"$T"'/child.pid"; wait'
start=$(date +%s)
"$RB" 2 4096 oc-profiles x >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
is "a helper past its deadline exits 124" "$rc" "124"
[ "$took" -le 6 ] && ok "and it did not run on ($took s)" || no "and it did not run on" "$took s"
sleep 0.3
child="$(cat "$T/child.pid" 2>/dev/null)"
# Gone, or dead and waiting to be reaped by whoever inherited it: a zombie answers
# kill -0 without running anything, so the state letter is what is read.
state="$(sed -n 's/^[0-9]* (.*) \([A-Z]\).*/\1/p' "/proc/$child/stat" 2>/dev/null)"
if [ -n "$child" ] && [ -n "$state" ] && [ "$state" != Z ]; then
  no "the helper's own child is gone too" "pid $child is still running ($state)"; kill -9 "$child" 2>/dev/null
else
  ok "the helper's own child is gone too"
fi

echo "=== it runs only the helpers it ships beside ==="
"$RB" 10 100 ../bin/oc-profiles x >/dev/null 2>&1; is "a path is refused" "$?" "2"
"$RB" 10 100 bash -c true >/dev/null 2>&1;       is "a program by name is refused" "$?" "2"
"$RB" 10 100 sh >/dev/null 2>&1;                  is "so is an unlisted name" "$?" "2"
"$RB" abc 100 oc-profiles >/dev/null 2>&1;        is "a deadline that is not a number is refused" "$?" "2"
"$RB" 10 1e9 oc-profiles >/dev/null 2>&1;         is "so is a cap that is not one" "$?" "2"
"$RB" 0 100 oc-profiles >/dev/null 2>&1;          is "a zero deadline is refused" "$?" "2"
"$RB" 10 100 >/dev/null 2>&1;                     is "a call naming no helper is refused" "$?" "2"

echo "=== nothing is added to the helper's environment ==="
stand_in oc-profiles 'env | sort'
got="$(env -i PATH=/usr/bin:/bin HOME=/nowhere ONLY=this "$RB" 10 4096 oc-profiles 2>/dev/null \
       | grep -v -e '^PWD=' -e '^SHLVL=' -e '^_=' | tr '\n' ' ')"
is "it sees exactly what it was started with" "$got" "HOME=/nowhere ONLY=this PATH=/usr/bin:/bin "

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
