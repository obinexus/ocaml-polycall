#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if grep -E -n 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\(' \
    "$root/src/ocaml_polycall.c" "$root/src/ocaml_polycall_stubs.c" \
    "$root/src/polycall.ml"; then
    echo "ocaml-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi

grep -F -q 'polycall_ffi_run_config(config_path, 1)' \
    "$root/src/ocaml_polycall.c"
grep -F -q 'String_val(config_path)' "$root/src/ocaml_polycall_stubs.c"
grep -F -q 'raise (Error status)' "$root/src/polycall.ml"

echo "ocaml-polycall thin-adapter check: PASS"
