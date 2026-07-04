# Tests

- `ocaml_polycall_adapter_test.c` verifies exact path forwarding, validation
  mode `1`, null handling, and unchanged statuses without libpolycall.
- `ocaml_polycall_smoke.ml` exercises explicit/default paths, raw statuses, and
  `Polycall.Error` through the real OCaml/C boundary when `ocamlc` is present.
- `package.test.js` validates npm metadata, relative directory indexes, source
  exports, author, license, and required build files.
