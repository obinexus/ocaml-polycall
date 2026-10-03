#!/usr/bin/env sh
# Thin-adapter lint: the binding must not parse configuration or implement
# runtime/network logic itself -- everything goes through libpolycall.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/src/ocaml_polycall.c $root/src/ocaml_polycall_stubs.c $root/src/polycall.ml"

# file / socket / parsing primitives (polycall_peer_open is the core's API, not open(2))
if grep -E -n '(^|[^_[:alnum:]])(fopen|open|CreateFile[AW]?|socket|connect|bind|sscanf|strtok)[[:space:]]*\(' $src; then
    echo "ocaml-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi

grep -F -q 'polycall_ffi_run_config(config_path, 1)' "$root/src/ocaml_polycall.c"
grep -F -q '#include <polycall.h>' "$root/src/ocaml_polycall.c"
grep -F -q '#include <polycall.h>' "$root/src/ocaml_polycall_stubs.c"
grep -F -q 'raise (Error status)' "$root/src/polycall.ml"
# no stub header of nonexistent symbols may come back
if [ -e "$root/generated/polycall/polycall_ffi.h" ]; then
    echo "generated/polycall/polycall_ffi.h (stub declarations) must not exist; use <polycall.h>" >&2
    exit 1
fi

echo "ocaml-polycall thin-adapter check: PASS"
