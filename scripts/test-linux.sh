#!/bin/sh
# Full Linux test of ocaml-polycall against the REAL installed libpolycall,
# from the repository root (ocaml/opam image, as the opam user). Exit status:
# 0 = everything ran and passed, 1 = a failure, 77 = SKIP (no dune / no
# libpolycall; nothing was tested). Valgrind / ASan: make test-valgrind,
# make test-asan.
set -eu
if [ -d /opt/polycall/lib ]; then
  export PATH="/opt/polycall/bin:$PATH"
  export LD_LIBRARY_PATH="/opt/polycall/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export PKG_CONFIG_PATH="/opt/polycall/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
command -v dune >/dev/null 2>&1 || { echo "SKIP: dune not found; nothing was tested" >&2; exit 77; }
if ! pkg-config --exists polycall 2>/dev/null; then
  echo "SKIP: libpolycall (pkg-config polycall) is not installed (build it with /qa/build-linux-core.sh as root)" >&2
  exit 77
fi
: "${POLYCALL_DEV_TOKEN:=ml-$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')}"
export POLYCALL_DEV_TOKEN POLYCALL_TELEMETRY=off
echo "== libpolycall $(pkg-config --modversion polycall) ($(pkg-config --variable=libdir polycall)); polycall CLI: $(command -v polycall || echo none)"
echo "== dune build"
dune build 2>&1
echo "== dune test (test/test_polycall.exe, test/test_domains.exe on OCaml 5)"
dune test --force 2>&1
echo "== adapter unit test (MOCK core, labelled)"
make test-adapter
echo "== loader errors (fake libraries)"
sh tests/load_errors.sh
echo "== thin-adapter lint"
sh scripts/verify-dry.sh
echo "== example"
./_build/default/examples/basic.exe ocaml-polycallrc
echo "example basic.exe: PASS"
