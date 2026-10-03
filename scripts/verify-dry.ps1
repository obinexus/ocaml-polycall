# Thin-adapter lint (Windows): the binding must not parse configuration or
# implement runtime/network logic itself -- everything goes through libpolycall.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $root 'src/ocaml_polycall.c'
$stubPath = Join-Path $root 'src/ocaml_polycall_stubs.c'
$ocamlPath = Join-Path $root 'src/polycall.ml'
# file / socket / parsing primitives (polycall_peer_open is the core's API, not open(2))
$forbidden = '(^|[^_A-Za-z0-9])(fopen|open|CreateFile[AW]?|socket|connect|bind|sscanf|strtok)\s*\('
$found = Select-String -Path $adapterPath,$stubPath,$ocamlPath -Pattern $forbidden -CaseSensitive

if ($found) {
    $found | ForEach-Object { Write-Error $_.Line }
    throw 'ocaml-polycall must not parse configuration or implement runtime logic'
}

$adapter = Get-Content -Raw $adapterPath
$stub = Get-Content -Raw $stubPath
$ocaml = Get-Content -Raw $ocamlPath
if (-not $adapter.Contains('polycall_ffi_run_config(config_path, 1)')) {
    throw 'ocaml-polycall does not forward through polycall_ffi_run_config'
}
if (-not $adapter.Contains('#include <polycall.h>') -or -not $stub.Contains('#include <polycall.h>')) {
    throw 'ocaml-polycall must use the real <polycall.h>'
}
if (-not $ocaml.Contains('raise (Error status)')) {
    throw 'ocaml-polycall does not expose idiomatic OCaml error handling'
}
if (Test-Path (Join-Path $root 'generated/polycall/polycall_ffi.h')) {
    throw 'generated/polycall/polycall_ffi.h (stub declarations) must not exist; use <polycall.h>'
}

Write-Output 'ocaml-polycall thin-adapter check: PASS'
