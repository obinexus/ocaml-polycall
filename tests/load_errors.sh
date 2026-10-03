#!/bin/sh
# A program linked with ocaml-polycall must fail cleanly -- a clear loader or
# OCaml error, never a crash -- when libpolycall is missing, is an old 1.0
# library without the ABI v1 symbols, or reports a binding ABI other than 1.
# Uses tests/fixtures/fake_polycall.c (fake libraries, test-only). Run after
# `dune build` from the repository root.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1
CC=${CC:-cc}
EXE=_build/default/examples/basic.exe
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }
[ -x "$EXE" ] || { echo "SKIP  load errors: $EXE missing (run dune build)"; exit 77; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/empty" "$TMP/v10" "$TMP/abi2"
$CC -shared -fPIC -Wl,-soname,libpolycall.so.1 -DFAKE_V10 tests/fixtures/fake_polycall.c -o "$TMP/v10/libpolycall.so.1" || exit 1
$CC -shared -fPIC -Wl,-soname,libpolycall.so.1 -DFAKE_ABI=2 tests/fixtures/fake_polycall.c -o "$TMP/abi2/libpolycall.so.1" || exit 1

run() { LD_LIBRARY_PATH=$1 "$EXE" ocaml-polycallrc 2>&1; }

OUT=$(run "$TMP/empty"); RC=$?; echo "  $OUT" | head -2
if [ $RC -ne 0 ] && [ $RC -lt 128 ] && echo "$OUT" | grep -q "libpolycall.so.1"; then
  ok "missing libpolycall.so.1 -> loader error naming the library (exit $RC, no signal)"
else bad "missing library (rc=$RC): $OUT"; fi

OUT=$(run "$TMP/v10"); RC=$?; echo "  $OUT" | head -2
if [ $RC -ne 0 ] && [ $RC -lt 128 ] && echo "$OUT" | grep -q "undefined symbol: polycall_"; then
  ok "old 1.0 library -> error naming the missing ABI v1 symbol (exit $RC, no signal)"
else bad "1.0 library (rc=$RC): $OUT"; fi

OUT=$(run "$TMP/abi2"); RC=$?; echo "  $OUT" | head -2
if [ $RC -ne 0 ] && [ $RC -lt 128 ] && echo "$OUT" | grep -q "reports binding ABI 2"; then
  ok "library reporting ABI 2 -> refused at start-up (exit $RC)"
else bad "ABI mismatch (rc=$RC): $OUT"; fi

echo "--- load errors: $PASS passed, $FAIL failed ---"
[ $FAIL -eq 0 ]
