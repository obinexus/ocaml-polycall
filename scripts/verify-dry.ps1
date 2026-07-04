$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$adapterPath = Join-Path $root 'src/ocaml_polycall.c'
$stubPath = Join-Path $root 'src/ocaml_polycall_stubs.c'
$ocamlPath = Join-Path $root 'src/polycall.ml'
$forbidden = 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\('
$matches = Select-String -Path $adapterPath,$stubPath,$ocamlPath -Pattern $forbidden

if ($matches) {
    $matches | ForEach-Object { Write-Error $_.Line }
    throw 'ocaml-polycall must not parse configuration or implement runtime logic'
}

$adapter = Get-Content -Raw $adapterPath
$stub = Get-Content -Raw $stubPath
$ocaml = Get-Content -Raw $ocamlPath
if (-not $adapter.Contains('polycall_ffi_run_config(config_path, 1)')) {
    throw 'ocaml-polycall does not forward through polycall_ffi_run_config'
}
if (-not $stub.Contains('String_val(config_path)')) {
    throw 'ocaml-polycall does not marshal the OCaml string at its runtime boundary'
}
if (-not $ocaml.Contains('raise (Error status)')) {
    throw 'ocaml-polycall does not expose idiomatic OCaml error handling'
}

Write-Output 'ocaml-polycall thin-adapter check: PASS'
