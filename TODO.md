# TODO — ocaml-polycall

Status: implemented OCaml source adapter for libpolycall 1.5.

- [x] Exact thin shim over `polycall_ffi_run_config(config_path, 1)`
- [x] OCaml runtime C stub and typed `.mli` interface
- [x] Status-returning and `Polycall.Error` API variants
- [x] Dune library metadata and runnable example
- [x] Native mock contract test and OCaml/C smoke test
- [x] npm metadata, directory index, updated README, and MIT license
- [ ] Install OCaml and execute `npm run test:ocaml` on this machine
- [ ] Run an end-to-end example against a built libpolycall shared core
- [ ] Publish `@obinexusltd/ocaml-polycall` publicly on npm
