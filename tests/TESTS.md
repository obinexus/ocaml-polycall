# Tests

Against the REAL libpolycall (no mocks):

- `../test/test_polycall.ml` (dune test) -- the docs/BINDING_ABI.md checklist,
  `polycall_call` against `polycall start` and `polycall daemon start`, and
  interop with the C CLI (`polycall peer serve` / `send` / `recv` /
  `register`) in both directions. Needs the `polycall` CLI on `PATH` or in
  `POLYCALL_CLI`; anything that cannot run prints `SKIP`, never `PASS`.
- `../test/test_domains.ml` (dune test, OCaml >= 5) -- parallel use from
  domains, per-thread `polycall_last_error`, and a blocked receive that must
  not stall other domains' collections.
- `load_errors.sh` -- a program linked with the binding fails cleanly (loader
  error or OCaml `Failure`, never a signal) with no library, an old 1.0
  library, or a library reporting ABI 2. The fake libraries come from
  `fixtures/fake_polycall.c` (test fixture only, never linked into the
  binding).

Adapter unit test against a MOCK core (labelled, not a core test):

- `ocaml_polycall_adapter_test.c` + `polycall_ffi_mock.c` -- the legacy C
  entry point forwards the path unchanged with `run = 1` and returns the
  status unchanged.

Package:

- `package.test.js` -- npm metadata, directory index, version/URL
  consistency across package.json, polycall-binding.json, dune-project and
  ocaml-polycall.opam.
- `../scripts/test-package.sh` -- `opam install` of the checkout into the
  current switch, then a clean dune project outside the repository that uses
  the installed library against the real core.

Memory tooling: `make test-valgrind` (memcheck) and `make test-asan`
(AddressSanitizer on the C stubs; on the core too when it was built with
`-fsanitize=address`); race tooling: `make test-tsan` (ThreadSanitizer, OCaml switch
with ocaml-option-tsan).
