# @obinexusltd/ocaml-polycall

OCaml source binding for
[libpolycall](https://github.com/obinexus/libpolycall) 1.5, published on npm as
`@obinexusltd/ocaml-polycall`.

The binding is deliberately thin. An OCaml external function passes its string
through a runtime C stub, and the native shim makes exactly one call to
`polycall_ffi_run_config(config_path, 1)`. Parsing, validation, and runtime
behavior remain in libpolycall.

## Install

```powershell
npm install @obinexusltd/ocaml-polycall
```

This is a native source package. It publishes OCaml interfaces and sources,
C sources and headers, Dune metadata, examples, tests, scripts, configuration,
and build metadata. Compiler- and platform-specific binaries are excluded.

## OCaml API

Return the libpolycall status directly:

```ocaml
let status =
  Polycall.run_config ~config_path:"ocaml-polycallrc" ()
in
if status <> 0 then exit status
```

Use an exception for startup paths where failure should unwind immediately:

```ocaml
try
  Polycall.run_config_or_error ~config_path:"ocaml-polycallrc" ()
with
| Polycall.Error status ->
    Printf.eprintf "libpolycall status: %d\n" status
```

- `Polycall.run_config` returns the core status unchanged.
- `Polycall.run_config_or_error` raises `Polycall.Error status` when nonzero.
- Omitting `config_path` uses `ocaml-polycallrc`.

The public signature is in [`src/polycall.mli`](src/polycall.mli).

## Build and test

Build the native adapter and run every locally available check:

```powershell
npm run build
npm test
```

This machine currently has GCC and GNU Make but not `ocamlc`, Dune, or OPAM.
Consequently, `npm test` runs the native mock contract test, thin-boundary
audit, and npm package checks while clearly reporting the OCaml smoke test as
skipped. When `ocamlc` is on `PATH`, that OCaml/C test runs automatically.

After installing OCaml, run the language-specific gates directly:

```powershell
npm run build:ocaml
npm run test:ocaml
```

The native test proves that the configuration path is forwarded unchanged,
validation mode is always `1`, and statuses are preserved. The OCaml test then
exercises default/explicit paths and `Polycall.Error` through the real runtime
stub.

## Dune integration

[`dune-project`](dune-project) and [`src/dune`](src/dune) define the public
library `ocaml-polycall`. Build libpolycall first and make its library visible
to the C linker, then run:

```powershell
dune build
```

The Dune foreign stubs link with `-lpolycall`. Configure the compiler's library
search path, or adapt `c_library_flags`, when libpolycall is outside a standard
location.

A standalone example is available at [`examples/basic.ml`](examples/basic.ml).

## JavaScript build-tool entry point

The CommonJS entry point indexes all published project directories:

```js
const binding = require('@obinexusltd/ocaml-polycall');

console.log(binding.ocamlModule);
console.log(binding.runtimeStub);
console.log(binding.directories.src.relativeFiles);
console.log(binding.resolve('examples', 'basic.ml'));
```

Indexed relative directories are `src`, `include`, `generated`, `dist`,
`examples`, `tests`, and `scripts`. `resolve()` rejects paths that escape the
selected directory.

## Publish

```powershell
npm pack --dry-run
npm publish --access public
```

Publishing is never performed automatically.

## Author and license

Nnamdi Michael Okpala (`okpalan@protonmail.com`). Licensed under MIT.
