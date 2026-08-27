#!/usr/bin/env bash
# The reviewer's bar, as tests: "Open the file once with O_NOFOLLOW and O_NONBLOCK,
# validate that descriptor as a user-owned regular file, and read the capped bytes
# through it." Each case below is one way that can go wrong.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SR="$REPO/bin/safe-read"
D="$(mktemp -d)"; trap 'rm -rf "$D"' EXIT
pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n         %s\n' "$1" "$2"; fail=$((fail+1)); }
is(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "got: $2   want: $3"; }

printf 'hello' > "$D/plain.json"

echo "--- the happy path ---"
is "reads a plain file"        "$("$SR" "$D/plain.json" --max-bytes 100)" "hello"
"$SR" "$D/plain.json" --max-bytes 100 >/dev/null; is "exit 0" "$?" "0"

echo "--- nothing there ---"
"$SR" "$D/nope.json" --max-bytes 100 >/dev/null 2>&1; is "missing file exits 1" "$?" "1"

echo "--- a FIFO must return, not stall ---"
mkfifo "$D/fifo.json"
S=$(date +%s%N)
timeout 5 "$SR" "$D/fifo.json" --max-bytes 100 >/dev/null 2>&1; rc=$?
E=$(date +%s%N); ms=$(( (E-S)/1000000 ))
is "FIFO refused (not 124/timeout)" "$rc" "2"
[ "$ms" -lt 1000 ] && ok "FIFO returned in ${ms}ms, did not block" || no "FIFO did not block" "took ${ms}ms"

echo "--- a FIFO with a writer still must not be read ---"
mkfifo "$D/fifo2.json"; ( exec 9> "$D/fifo2.json"; sleep 3 ) &
sleep 0.2
timeout 5 "$SR" "$D/fifo2.json" --max-bytes 100 >/dev/null 2>&1
is "FIFO with writer refused" "$?" "2"
wait 2>/dev/null

echo "--- symlinks ---"
ln -s "$D/plain.json" "$D/link.json"
"$SR" "$D/link.json" --max-bytes 100 >/dev/null 2>&1; is "symlink refused by default" "$?" "2"
is "symlink allowed with --follow" "$("$SR" "$D/link.json" --max-bytes 100 --follow)" "hello"
ln -s /dev/zero "$D/zero.json"
"$SR" "$D/zero.json" --max-bytes 100 --follow >/dev/null 2>&1
is "--follow still refuses a device" "$?" "2"
ln -s "$D/fifo.json" "$D/fifolink.json"
timeout 5 "$SR" "$D/fifolink.json" --max-bytes 100 --follow >/dev/null 2>&1
is "--follow still refuses a FIFO" "$?" "2"

echo "--- size cap ---"
head -c 4096 /dev/urandom > "$D/big.json"
"$SR" "$D/big.json" --max-bytes 1024 >/dev/null 2>&1; is "oversized refused" "$?" "2"
is "exactly at the cap is fine"  "$("$SR" "$D/plain.json" --max-bytes 5 | wc -c)" "5"

echo "--- other shapes ---"
mkdir "$D/dir.json"
"$SR" "$D/dir.json" --max-bytes 100 >/dev/null 2>&1; is "directory refused" "$?" "2"
"$SR" /dev/zero --max-bytes 100 >/dev/null 2>&1;     is "device refused" "$?" "2"
: > "$D/empty.json"
is "empty file reads as empty"  "$("$SR" "$D/empty.json" --max-bytes 100 | wc -c)" "0"
"$SR" "$D/empty.json" --max-bytes 100 --no-empty >/dev/null 2>&1
is "--no-empty refuses it" "$?" "2"

echo "--- ownership ---"
if [ -r /etc/shadow ] || [ -e /etc/passwd ]; then
  "$SR" /etc/passwd --max-bytes 1000000 >/dev/null 2>&1
  is "root-owned file refused" "$?" "2"
fi

echo "--- reads exactly what it measured ---"
printf 'abc' > "$D/grow.json"
out="$("$SR" "$D/grow.json" --max-bytes 100)"
is "no trailing surprise" "$out" "abc"

echo
[ "$fail" -eq 0 ] && echo "$pass passed" || echo "FAILED $fail / $pass passed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
